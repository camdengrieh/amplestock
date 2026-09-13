// SPDX-License-Identifier: MIT
pragma solidity >=0.6.2 <0.9.0;

import {Snapshots} from "./Snapshots.sol";
import {PropertiesAsserts} from "./utils/PropertiesAsserts.sol";
// Imports the SPECIFIC section needs. Every one is *aliased*, so the GLOBAL section can import the same symbol
// under its own name without an "identifier already declared" clash between two agents editing one file.
import {Constants as SpecC} from "../../src/types/Constants.sol";
import {
    Checkpoint as SpecCheckpoint,
    ConstituentStatus as SpecStatus,
    PlacementRecord as SpecRecord,
    VestingPosition as SpecPosition
} from "../../src/types/Types.sol";
import {IERC20 as SpecIERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
// Imports the GLOBAL section needs, aliased for the same reason.
import {HookStateLib as GlobHookState} from "../../src/hook/HookStateLib.sol";
import {IAmpsQuoter as GlobQuoter} from "../../src/interfaces/IAmpsQuoter.sol";
import {IFeedRegistry as GlobFeeds} from "../../src/interfaces/IFeedRegistry.sol";
import {LadderLib as GlobLadderLib} from "../../src/lib/LadderLib.sol";
import {PriceLib as GlobPriceLib} from "../../src/lib/PriceLib.sol";
import {Constants as GlobC} from "../../src/types/Constants.sol";
import {Reentrancy as GlobReentrancy} from "../../src/types/Errors.sol";
import {
    BondMarket as GlobMarket,
    Checkpoint as GlobCheckpoint,
    ConstituentConfig as GlobConstituent,
    ConstituentStatus as GlobStatus,
    GateState as GlobGate,
    PlacementRecord as GlobRecord,
    PoolClass as GlobPoolClass,
    PoolConfig as GlobPoolConfig,
    Session as GlobSession,
    VestingPosition as GlobPosition
} from "../../src/types/Types.sol";
import {EnumerableSet as GlobSet} from "./utils/EnumerableSet.sol";
import {FullMath as GlobFullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {PoolId as GlobPoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @notice Contains the functions that check the properties (invariants)
abstract contract Properties is PropertiesAsserts, Snapshots {
    // `using ... for ...` is not inherited across contracts since solc 0.7, so `Base`'s directive for the two
    // ghost address sets has to be repeated here.
    using GlobSet for GlobSet.AddressSet;

    // ―――――――――――――――――――― Global properties ―――――――――――――――――――――
    // These properties must always hold after any function call.
    // They MUST BE PUBLIC so that fuzzers can find and call them.

    // ───────── GLOBAL PROPERTIES ─────────
    //
    // Public `property_*` functions. There are two shapes here and the difference is load-bearing:
    //
    //   * `property_x() public returns (bool)` — no arguments and a `bool` return, so Medusa registers it as a
    //     **property test** and evaluates it after *every* call in the sequence. Medusa runs a property test on a
    //     state copy that is thrown away, so a property in this shape must be a pure read: anything it wrote to
    //     `ghosts` would be rolled back. Reserved for the cheap, read-only invariants.
    //   * `property_x(uint256 seed) public` — takes an argument, so Medusa registers it as an **assertion test**:
    //     the fuzzer calls it as an ordinary transaction and its writes commit. Everything that walks 32 pools,
    //     everything that costs more than ~1M gas, and everything that maintains its own high-water ghost is in
    //     this shape. `previewNavPerShareX18()`, `totalAssetsUsd18()`, `previewRedeem()` and `checkpoint()` each
    //     walk every pool at ~150k gas a pool, so a no-argument property may not touch them.
    //
    // Every function carries its Spec ID as the first line of its natspec (`/// @notice GL-NN: …`); that token is
    // how `/fizz-convert` reconciles `contracts/PROPERTIES.md` with this file.

    /// @notice GL-01: the AMPS held by every account the campaign can reach sums to exactly `amps.totalSupply()`.
    /// @dev SHOULD-HOLD. Closed-form ERC-20 identity: OZ `ERC20._update` is the only writer of `_balances` and
    ///      `_totalSupply` and moves them equal-and-opposite, and `Amps` adds no hook, fee, rebase or blocklist
    ///      (`src/token/Amps.sol` NatSpec). Plan I3; guard G-40.
    /// @dev The closure is `ghosts.ampsHolders`: {Base-_seedGhosts} seeds it with every protocol address and every
    ///      actor, and every handler that takes a fuzzer-chosen `to` calls {Base-noteAmpsHolder} on the success
    ///      arm. Past {Base-GHOST_HOLDER_WALK_MAX} entries the walk is truncated and the assertion degrades to the
    ///      sound one-sided bound — a partial sum over *distinct* holders can never exceed the supply — rather
    ///      than growing without limit.
    /// @param seed Unused; its presence is what makes this an assertion test rather than a property test.
    function property_ampsClosureSumsToSupply(uint256 seed) public {
        seed;
        uint256 n = ghosts.ampsHolders.length();
        uint256 walk = n > GHOST_HOLDER_WALK_MAX ? GHOST_HOLDER_WALK_MAX : n;
        uint256 sum;
        for (uint256 i; i < walk; ++i) {
            sum += amps.balanceOf(ghosts.ampsHolders.at(i));
        }
        if (walk == n) {
            eq(sum, amps.totalSupply(), "GL-01: the tracked AMPS closure does not sum to totalSupply");
        } else {
            lte(sum, amps.totalSupply(), "GL-01: the tracked AMPS closure exceeds totalSupply");
        }
    }

    /// @notice GL-02: `totalSupply() <= S0 + SUM_m market(m).totalIssued`.
    /// @dev SHOULD-HOLD. Plan I3/I10 rev-6 ("genesis + bonds up; redemption and the fee/buyback burn down; ask
    ///      inventory never minted"); x-ray E-1 and X-6 (on-chain: Yes); guards G-7, G-40.
    /// @param seed Unused.
    function property_supplyUnderGenesisPlusIssuance(uint256 seed) public {
        seed;
        uint256 ceiling = GlobC.S0;
        for (uint256 i; i < marketIds.length; ++i) {
            ceiling += uint256(_marketTotalIssued(marketIds[i]));
        }
        lte(amps.totalSupply(), ceiling, "GL-02: totalSupply above S0 + everything the markets ever issued");
    }

    /// @notice GL-03: the supply ledger closes — every wei of supply above `S0` is a bond mint the campaign
    ///         attributed, and every burn the campaign attributed really happened.
    /// @dev SHOULD-HOLD. x-ray E-1 enumerates every mint site (`VaultNavLib.genesisAllocate`,
    ///      `AmpsVault.mintVesting`) and every burn site (`AmpsVault.sol:848`/`:882`,
    ///      `VaultPlacementLib.sol:257`/`:383`/`:1271`), all behind `Amps`' `onlyVault` (G-40).
    ///
    /// @dev **Why the burn side is an inequality and the mint side is not.** The two halves of the ledger are not
    ///      equally attributable from a handler. Every mint goes through exactly one entry point — `AmpsBonds.bond`
    ///      — and returns the amount it minted, so `ghosts.mintedByBonds` is exact and the mint half is stated as
    ///      an equality against the markets' own `totalIssued`. Burns happen in five places, three of them *inside*
    ///      `VaultPlacementLib` on the compound / place / rollout / deployBonded paths, where the handler sees only
    ///      the entry point's return value: `compound` reports its `burned`, but a buyback burn inside a plain
    ///      `place` is invisible to the caller, and `redeemProRata`'s inventory burn is only knowable through
    ///      `previewRedeem`, which is a *preview* and drifts from the realised burn by the odd wei. The realised
    ///      total burn is therefore taken from the chain — `S0 + mintedByBonds - totalSupply()` — and the ghost is
    ///      required only never to *overstate* it. An over-statement is a real finding (a burn the campaign
    ///      recorded that the token did not perform); an under-statement is the unattributed placement burn, and
    ///      SP-24 is where the compound path's burn is pinned to the wei.
    /// @param seed Unused.
    function property_supplyLedgerCloses(uint256 seed) public {
        seed;
        uint256 supply = amps.totalSupply();
        uint256 ceiling = GlobC.S0 + ghosts.mintedByBonds;
        lte(supply, ceiling, "GL-03: supply above S0 plus every mint the campaign attributed");

        uint256 issuedOnChain;
        for (uint256 i; i < marketIds.length; ++i) {
            issuedOnChain += uint256(_marketTotalIssued(marketIds[i]));
        }
        eq(ghosts.mintedByBonds, issuedOnChain, "GL-03: the mint ledger disagrees with the markets' own issuance");

        gte(ceiling - supply, ghosts.burnedTotal, "GL-03: the campaign recorded a burn the token never performed");
    }

    /// @notice GL-04: `amps.balanceOf(0) == 0` and the minter role is still the vault.
    /// @dev SHOULD-HOLD. G-40 (`Amps.sol:34`), and the zero-address clause is OZ `_update`'s own `require`.
    /// @return ok Always true; a violation reverts through {PropertiesAsserts}.
    function property_shareTokenRolesIntact() public returns (bool ok) {
        eq(amps.balanceOf(address(0)), 0, "GL-04: the zero address holds AMPS");
        t(amps.vault() == address(vault), "GL-04: the AMPS minter is no longer the vault");
        return true;
    }

    /// @notice GL-05: `AmpsBonds` holds at least the AMPS it still owes its bonders.
    /// @dev SHOULD-HOLD. x-ray I-6: the delta pairs `_positions[to].push({principal: issued})` and
    ///      `mintVesting(address(this), ampsOut)` (`AmpsBonds.sol:411-419` / `:454`), and `record.claimed = vested`
    ///      against a transfer of `vested - claimed` (`:566` / `:569`). An inequality because donation is possible.
    /// @dev `claimableTotal + unvestedOf` is the shell's own partition of `principal - claimed` (GL-09), so the
    ///      walk needs two calls an owner rather than one a position. Truncating the owner walk only *lowers* the
    ///      computed debt, so the assertion stays sound however many bonders the campaign creates.
    /// @param seed Unused.
    function property_bondShellCoversItsBook(uint256 seed) public {
        seed;
        uint256 n = ghosts.bonders.length();
        uint256 walk = n > 32 ? 32 : n;
        uint256 owed;
        for (uint256 i; i < walk; ++i) {
            address owner = ghosts.bonders.at(i);
            owed += _claimableTotal(owner) + _unvestedOf(owner);
        }
        gte(amps.balanceOf(address(bonds)), owed, "GL-05: the bond shell holds less AMPS than it owes");
    }

    /// @notice GL-06: per-market issuance ledger — principals written against a market never exceed its
    ///         `totalIssued`, and claimed never exceeds principal.
    /// @dev SHOULD-HOLD. Closed-form delta pair in `bond` step 6: `stored.totalIssued += issued` and
    ///      `_positions[to].push({principal: issued})` are written from the same local in the same block, and
    ///      neither field has another write site (`AmpsBonds.sol:404-419`). Plan I28.
    /// @dev Stated as `<=` rather than `==` on the principal leg because the owner set is open: an unclamped
    ///      `bond` takes a fuzzer-chosen `to`, so a walk over `ghosts.bonders` is a subset and its sum is a lower
    ///      bound. The exact equality is asserted on the ghost ledger instead, once it has been armed by a bond.
    /// @param seed Chooses the market.
    function property_perMarketIssuanceLedger(uint256 seed) public {
        uint16 marketId = marketFrom(seed);
        uint256 principalSum;
        uint256 claimedSum;
        uint256 n = ghosts.bonders.length();
        uint256 walk = n > 16 ? 16 : n;
        for (uint256 i; i < walk; ++i) {
            address owner = ghosts.bonders.at(i);
            uint256 count = bonds.positionCount(owner);
            if (count > 32) count = 32;
            for (uint256 j; j < count; ++j) {
                GlobPosition memory record = bonds.position(owner, j);
                if (record.marketId != marketId) continue;
                principalSum += uint256(record.principal);
                claimedSum += uint256(record.claimed);
            }
        }
        lte(claimedSum, principalSum, "GL-06: claimed above principal on one market");
        lte(principalSum, uint256(_marketTotalIssued(marketId)), "GL-06: principals above the market's totalIssued");

        if (ghosts.bondIssuedTotal != 0) {
            uint256 issuedOnChain;
            for (uint256 i; i < marketIds.length; ++i) {
                issuedOnChain += uint256(_marketTotalIssued(marketIds[i]));
            }
            lte(ghosts.bondIssuedTotal, issuedOnChain, "GL-06: the ghost issued more than the markets record");
        }
    }

    /// @notice GL-07: for every market, `issuedThisEpoch <= totalIssued`.
    /// @dev SHOULD-HOLD. Both fields are incremented by the same `issued` in `bond` step 6, and `issuedThisEpoch`
    ///      is only ever reset to zero by `_rollEpoch`, so containment is exact.
    /// @return ok Always true.
    function property_epochIssuanceContained() public returns (bool ok) {
        for (uint256 i; i < marketIds.length; ++i) {
            (uint128 total, uint128 epoch,,) = _marketCounters(marketIds[i]);
            lte(uint256(epoch), uint256(total), "GL-07: issuedThisEpoch above totalIssued");
        }
        return true;
    }

    /// @notice GL-08: splitting one large bond into many small ones does not bypass the caps.
    /// @dev EXPLORATORY. The cap in force can be *lowered* by governance mid-window, so the bound has to be the
    ///      highest cap seen during the window rather than the one standing now — otherwise a legal issuance
    ///      followed by `setCapBpsPerEpoch(0)` would read as a violation. The window's high-water is maintained by
    ///      this property, which is why it is an assertion test: a property test's writes are discarded.
    /// @param seed Chooses the market.
    function property_bondCapsBindCumulatively(uint256 seed) public {
        {
            (uint256 issuedToday, uint256 dailyCapacity) = bonds.dailyIssuance();
            if (dailyCapacity > ghosts.dayCapHigh) ghosts.dayCapHigh = dailyCapacity;
            uint256 bound = ghosts.dayCapHigh;
            lte(issuedToday, bound + bound / 100 + 1, "GL-08: rolling-day issuance above the cap plus 1% slack");
        }

        uint16 marketId = marketFrom(seed);
        (, uint128 epoch, uint32 epochStart, uint16 capBps) = _marketCounters(marketId);
        uint256 cap = GlobFullMath.mulDiv(amps.totalSupply(), uint256(capBps), GlobC.BPS);
        if (ghosts.epochStartSeen[marketId] != epochStart) {
            ghosts.epochStartSeen[marketId] = epochStart;
            ghosts.epochCapHigh[marketId] = cap;
        } else if (cap > ghosts.epochCapHigh[marketId]) {
            ghosts.epochCapHigh[marketId] = cap;
        }
        uint256 epochBound = ghosts.epochCapHigh[marketId];
        lte(uint256(epoch), epochBound + epochBound / 100 + 1, "GL-08: epoch issuance above the cap plus 1% slack");
    }

    /// @notice GL-09: the vesting book is internally consistent for every position of one owner.
    /// @dev SHOULD-HOLD. `Types.sol:325` ("`claimed <= principal` always"); `claimableTotal` sums `vested - claimed`
    ///      and `unvestedOf` sums `principal - vested`, so the two partition `principal - claimed` exactly
    ///      (`AmpsBonds.sol:256-272`). Plan I28.
    /// @param seed Chooses the owner.
    function property_vestingBookIsConsistent(uint256 seed) public {
        address owner = _bonderFrom(seed);
        if (owner == address(0)) return;
        uint256 count = bonds.positionCount(owner);
        if (count == 0) return;
        uint256 walk = count > 24 ? 24 : count;

        uint256 outstanding;
        for (uint256 j; j < walk; ++j) {
            GlobPosition memory record = bonds.position(owner, j);
            lte(uint256(record.claimed), uint256(record.principal), "GL-09: claimed above principal");
            uint256 undelivered = uint256(record.principal) - uint256(record.claimed);
            uint256 claimableNow = _claimable(owner, j);
            lte(claimableNow, undelivered, "GL-09: claimable above the undelivered principal");
            if (record.vestSeconds == 0 || block.timestamp >= uint256(record.start) + uint256(record.vestSeconds)) {
                eq(claimableNow, undelivered, "GL-09: a fully elapsed position is not fully vested");
            }
            outstanding += undelivered;
        }

        if (walk == count) {
            eq(
                _claimableTotal(owner) + _unvestedOf(owner),
                outstanding,
                "GL-09: claimableTotal + unvestedOf does not partition principal - claimed"
            );
        }
    }

    /// @notice GL-10: a vesting position is immutable except for `claimed`, and `claimed` only rises.
    /// @dev SHOULD-HOLD. `claimed` is written only as `record.claimed = uint128(vested)` with
    ///      `vested = _vested(record) <= principal` (`AmpsBonds.sol:566`, `:585`, `_vested` at `:1206-1213`).
    /// @dev Self-contained: the first observation of a position records its four frozen fields, and every later
    ///      one compares against that record. No handler wiring is needed for it to be honest.
    /// @param seed Chooses the owner and the position.
    function property_positionFieldsImmutable(uint256 seed) public {
        address owner = _bonderFrom(seed);
        if (owner == address(0)) return;
        uint256 count = bonds.positionCount(owner);
        if (count == 0) return;
        uint256 j = seed % count;
        GlobPosition memory record = bonds.position(owner, j);

        if (!ghosts.positionSeen[owner][j]) {
            ghosts.positionSeen[owner][j] = true;
            ghosts.principalSeen[owner][j] = uint256(record.principal);
            ghosts.startSeen[owner][j] = uint256(record.start);
            ghosts.vestSecondsAtPurchase[owner][j] = uint256(record.vestSeconds);
            ghosts.marketIdSeen[owner][j] = uint256(record.marketId);
            ghosts.maxClaimed[owner][j] = uint256(record.claimed);
            return;
        }

        eq(uint256(record.principal), ghosts.principalSeen[owner][j], "GL-10: a position's principal moved");
        eq(uint256(record.start), ghosts.startSeen[owner][j], "GL-10: a position's start moved");
        eq(uint256(record.vestSeconds), ghosts.vestSecondsAtPurchase[owner][j], "GL-10: a position's vest moved");
        eq(uint256(record.marketId), ghosts.marketIdSeen[owner][j], "GL-10: a position's marketId moved");
        gte(uint256(record.claimed), ghosts.maxClaimed[owner][j], "GL-10: a position's claimed fell");
        lte(uint256(record.claimed), uint256(record.principal), "GL-10: claimed above principal");
        ghosts.maxClaimed[owner][j] = uint256(record.claimed);
    }

    /// @notice GL-11: `claimable(owner, id)` never falls while nothing has been claimed from the position, and
    ///         never exceeds the undelivered principal.
    /// @dev SHOULD-HOLD. Plan I38 ("`claim()` … succeeds regardless of collateral removal, market pause, policy
    ///      swap or guardian freeze") and I28 ("`claimable(t)` monotone in `t`"); `AmpsBonds.sol:1203-1205`, "the
    ///      position's own `vestSeconds` is used, never the governed one" — which is what makes it immune to
    ///      `setVestSeconds`, a market pause, a policy swap, a retired constituent and a guardian freeze.
    /// @dev Self-contained: `ghosts.vestedSeen` holds the `claimed` this property last saw, so the monotone leg is
    ///      only asserted across observations that no claim separated. Both ghosts start at zero, which is what
    ///      the first observation of a fresh position reads, so the first comparison is vacuously true.
    /// @param seed Chooses the owner and the position.
    function property_claimableIsMonotoneAndOwnerOnly(uint256 seed) public {
        address owner = _bonderFrom(seed);
        if (owner == address(0)) return;
        uint256 count = bonds.positionCount(owner);
        if (count == 0) return;
        uint256 j = seed % count;
        GlobPosition memory record = bonds.position(owner, j);
        uint256 claimableNow = _claimable(owner, j);

        lte(
            claimableNow,
            uint256(record.principal) - uint256(record.claimed),
            "GL-11: claimable above the undelivered principal"
        );
        if (ghosts.vestedSeen[owner][j] == uint256(record.claimed)) {
            gte(claimableNow, ghosts.lastClaimable[owner][j], "GL-11: claimable fell without a claim");
        }
        ghosts.vestedSeen[owner][j] = uint256(record.claimed);
        ghosts.lastClaimable[owner][j] = claimableNow;
    }

    /// @notice GL-12: `bonds.positionCount(owner)` is monotone non-decreasing.
    /// @dev SHOULD-HOLD. `_positions[to]` is only ever `push`ed (`AmpsBonds.sol:411`); no `pop`, `delete` or
    ///      length write exists in the contract.
    /// @param seed Chooses the owner.
    function property_positionCountMonotone(uint256 seed) public {
        address owner = _bonderFrom(seed);
        if (owner == address(0)) return;
        uint256 count = bonds.positionCount(owner);
        gte(count, ghosts.maxPositionCount[owner], "GL-12: positionCount fell");
        ghosts.maxPositionCount[owner] = count;
    }

    /// @notice GL-13: `market(id).totalIssued` is monotone non-decreasing for every market.
    /// @dev SHOULD-HOLD. `stored.totalIssued += issued` (`AmpsBonds.sol:407`) is the field's only write site.
    /// @param seed Unused.
    function property_totalIssuedMonotone(uint256 seed) public {
        seed;
        for (uint256 i; i < marketIds.length; ++i) {
            uint16 id = marketIds[i];
            uint128 total = _marketTotalIssued(id);
            gte(uint256(total), uint256(ghosts.maxTotalIssued[id]), "GL-13: a market's totalIssued fell");
            ghosts.maxTotalIssued[id] = total;
        }
    }

    /// @notice GL-14: every position with `claimable > 0` can actually be claimed.
    /// @dev SHOULD-HOLD. Plan I38; `AmpsBonds.claim` NatSpec ("Structurally ungated. The only reads are
    ///      `_positions[msg.sender]` and the immutable {amps}"); x-ray I-6.
    /// @dev The claim is executed, not simulated: `vm.snapshotState`/`vm.revertToState` are not implemented in
    ///      Medusa 1.5.1, so the Medusa-safe shape is to assert on the `catch` arm of the real call. A claim is an
    ///      ordinary user action, so committing it costs the campaign nothing.
    /// @param seed Chooses the owner and the position.
    function property_everyVestedPositionIsClaimable(uint256 seed) public {
        address owner = _bonderFrom(seed);
        if (owner == address(0)) return;
        uint256 count = bonds.positionCount(owner);
        if (count == 0) return;
        uint256 j = seed % count;
        uint256 claimableNow = _claimable(owner, j);
        if (claimableNow == 0) return;

        vm.prank(owner);
        try bonds.claim(j, owner) returns (uint256 paid) {
            gte(paid, claimableNow, "GL-14: a claim paid less than it reported claimable");
        } catch {
            ghosts.livenessReverts[keccak256("GL-14:claim")] += 1;
            t(false, "GL-14: a vested position could not be claimed");
        }
    }

    /// @notice GL-15: a third party cannot grief a bonder by growing their position array — a per-id read stays
    ///         O(1) however many positions an attacker pushed onto them.
    /// @dev SHOULD-HOLD. Fix-log wave-1 lead: "Third-party growth of a bonder's position array | Accepted
    ///      (griefing of `claimAll`/lens only; **per-id `claim` unaffected**)". Plan I38.
    /// @param seed Chooses the owner and the position.
    function property_positionArrayGriefingBounded(uint256 seed) public {
        address owner = _bonderFrom(seed);
        if (owner == address(0)) return;
        uint256 count = bonds.positionCount(owner);
        if (count == 0) return;
        uint256 j = seed % count;

        uint256 before = gasleft();
        uint256 claimableNow = _claimable(owner, j);
        uint256 used = before - gasleft();
        claimableNow;
        if (used > ghosts.maxPerIdClaimGas) ghosts.maxPerIdClaimGas = used;
        lte(used, 200_000, "GL-15: a per-id claimable read is not O(1) in the position count");
    }

    /// @notice GL-16: a market that is closed or detached has not issued.
    /// @dev SHOULD-HOLD. Guard G-34 is the first thing `bond` does after its zero checks —
    ///      `if (!stored.open || marketIdOf[stored.collateral] != marketId) revert MarketClosed(marketId)`
    ///      (`AmpsBonds.sol:371`) — and it sits ahead of every counter write at `:405-408`.
    /// @dev Self-contained: the first observation of a shut market latches its three counters and every later one
    ///      compares against that latch, so no handler has to record the closure. `issuedThisEpoch` is compared
    ///      with `<=` rather than `==` because `_rollEpoch` may zero it.
    /// @param seed Chooses the market.
    function property_closedMarketHasNotIssued(uint256 seed) public {
        uint16 id = marketFrom(seed);
        GlobMarket memory record;
        bool found;
        try bonds.market(id) returns (GlobMarket memory r) {
            record = r;
            found = true;
        } catch {}
        if (!found) return;

        bool shut = !record.open || bonds.marketIdOf(record.collateral) != id;
        if (!shut) {
            ghosts.closedSeen[id] = false;
            return;
        }
        if (!ghosts.closedSeen[id]) {
            ghosts.closedSeen[id] = true;
            ghosts.issuedAtClose[id] = record.totalIssued;
            ghosts.epochIssuedAtClose[id] = record.issuedThisEpoch;
            ghosts.lastBondAtClose[id] = record.lastBondAt;
            return;
        }
        eq(uint256(record.totalIssued), uint256(ghosts.issuedAtClose[id]), "GL-16: a closed market issued");
        eq(uint256(record.lastBondAt), uint256(ghosts.lastBondAtClose[id]), "GL-16: a closed market stamped a bond");
        lte(
            uint256(record.issuedThisEpoch),
            uint256(ghosts.epochIssuedAtClose[id]),
            "GL-16: a closed market's epoch issuance rose"
        );
    }

    /// @notice GL-17: the registry's recorded `marketId` and the bond shell's own attribution agree.
    /// @dev SHOULD-HOLD. G-34's conjunction on the bond path plus `_setMarketOpen`'s repair leg
    ///      `if (live != stored) config.marketId = live;` (`PoolRegistry.sol:906`); x-ray X-9.
    /// @param seed Chooses the constituent.
    function property_marketAttributionAgrees(uint256 seed) public {
        uint16 cid = constituentFrom(seed);
        GlobConstituent memory config = registry.constituent(cid);
        if (config.marketId == 0 || config.token == address(0)) return;

        uint16 live = bonds.marketIdOf(config.token);
        t(live == 0 || live == config.marketId, "GL-17: the registry and the bond shell disagree on the market id");
        if (live == 0) return;
        try bonds.market(live) returns (GlobMarket memory record) {
            t(record.collateral == config.token, "GL-17: a live market's collateral is not the constituent's token");
        } catch {}
    }

    /// @notice GL-18: NAV/share is exactly `floor((A + 1) * 1e18 / (T + VIRTUAL_SHARES))`, and reconstructing `A`
    ///         from it never overstates `A`.
    /// @dev SHOULD-HOLD. x-ray I-8 (on-chain: Yes) `AmpsVault.sol:1497-1501`; `AmpsVault.spokeWeightBps` NatSpec
    ///      ("the inverse of {_navPerShare} up to the `+ 1` wei", `:526-528`). Plan I6, I22.
    /// @param seed Unused.
    function property_navPerShareIdentity(uint256 seed) public {
        seed;
        uint256 supply = amps.totalSupply();
        uint256 assetsUsd18 = vault.totalAssetsUsd18();
        uint256 nav = vault.previewNavPerShareX18();

        if (supply == 0) {
            eq(nav, 0, "GL-18: a zero supply must price at exactly zero");
            return;
        }
        eq(
            nav,
            GlobFullMath.mulDiv(assetsUsd18 + 1, GlobC.WAD, supply + GlobC.VIRTUAL_SHARES),
            "GL-18: NAV/share is not the closed-form identity"
        );
        lte(
            GlobFullMath.mulDiv(nav, supply + GlobC.VIRTUAL_SHARES, GlobC.WAD),
            assetsUsd18 + 1,
            "GL-18: reconstructing A from NAV/share overstates A"
        );
    }

    /// @notice GL-19: `A` decomposes into `SUM_j P_j x (claim_j + idle_j + the pool position's counter side at the
    ///         reference sqrt price)`, with nothing else in it and nothing counted twice.
    /// @dev SHOULD-HOLD. `VaultNavLib.totalAssetsUsd18`'s own stated identity (`VaultNavLib.sol:105`); plan I5, I6,
    ///      I7, I21; `LadderPositionValuer.amountsOf` "resolves the reference exactly as `VaultNavLib` does".
    /// @dev The rebuild mirrors the library term by term — one `counterValueUsd18` over the *summed* balance per
    ///      asset, exactly as the library does it, so the two agree to the wei in principle. A 1 bp band is
    ///      allowed anyway: the reference sqrt price is recomputed by the valuer on its own call, and a violation
    ///      inside that band is a rounding artefact rather than an accounting failure.
    /// @param seed Unused.
    function property_assetsDecomposeIntoA(uint256 seed) public {
        seed;
        uint256 reported = vault.totalAssetsUsd18();
        uint256 rebuilt;
        uint256 count = vault.assetCount();
        for (uint256 i; i < count; ++i) {
            address token = vault.assetAt(i);
            if (token == address(amps)) continue;
            (uint8 decimals, GlobPoolId poolId, bool hasPool) = _assetMeta(token);
            uint256 balance = _balanceOf(token, address(vault)) + _claim(address(vault), token);
            if (hasPool && vault.pRefX18() != 0) {
                (, uint256 counterSide) = _valuerAmounts(poolId);
                balance += counterSide;
            }
            if (balance == 0) continue;
            uint256 answerUsd8 = _latestAnswerUsd8(token);
            if (answerUsd8 == 0) continue;
            rebuilt += GlobPriceLib.counterValueUsd18(balance, decimals, answerUsd8);
        }

        uint256 band = (reported > rebuilt ? reported : rebuilt) / 10_000 + 1000;
        lte(rebuilt, reported + band, "GL-19: the decomposition of A exceeds A");
        lte(reported, rebuilt + band, "GL-19: A exceeds its own decomposition");
    }

    /// @notice GL-20: the asset registry is well formed — monotone, duplicate-free, never AMPS, `isAsset` agrees,
    ///         and AMPS never appears in a redemption basket.
    /// @dev SHOULD-HOLD. Plan I5 ("NAV values every AMPS leg at zero; `assets[AMPS].enabled == false`);
    ///      `_registerAsset` ("AMPS is never an asset (I5), and re-registration is a no-op so the list can never
    ///      carry a duplicate", `AmpsVault.sol:1679-1685`); guard G-5.
    /// @param seed Unused.
    function property_assetRegistryWellFormed(uint256 seed) public {
        seed;
        uint256 count = vault.assetCount();
        gte(count, ghosts.maxAssetCount, "GL-20: assetCount fell");
        ghosts.maxAssetCount = count;

        for (uint256 i; i < count; ++i) {
            address token = vault.assetAt(i);
            t(token != address(amps), "GL-20: AMPS is a registered asset");
            t(vault.isAsset(token), "GL-20: assetAt returned a token isAsset does not know");
            for (uint256 j = i + 1; j < count; ++j) {
                t(vault.assetAt(j) != token, "GL-20: the asset list carries a duplicate");
            }
        }

        (address[] memory tokens,,) = vault.previewRedeem(GlobC.WAD);
        for (uint256 i; i < tokens.length; ++i) {
            t(tokens[i] != address(amps), "GL-20: AMPS appears in a redemption basket");
        }
    }

    /// @notice GL-21: `inventoryAmps()` is the vault's idle AMPS plus its AMPS claim plus the AMPS side of every
    ///         ladder at the reference price, and excludes the AMPS `AmpsBonds` holds for vesting.
    /// @dev SHOULD-HOLD. `VaultNavLib.inventoryAmps` NatSpec ("the idle balance, the ERC-6909 claim and the AMPS
    ///      inside the vault's positions … it excludes the AMPS `AmpsBonds` holds for vesting (I30)"); plan I10,
    ///      I30. The I30 clause is what the rebuild proves: the shell's balance is never a term in it.
    /// @param seed Unused.
    function property_inventoryAmpsDecomposes(uint256 seed) public {
        seed;
        uint256 reported = vault.inventoryAmps();
        uint256 rebuilt = _balanceOf(address(amps), address(vault)) + _claim(address(vault), address(amps));
        if (vault.pRefX18() != 0) {
            for (uint256 p; p < pools.length; ++p) {
                (uint256 ampsSide,) = _valuerAmounts(pools[p]);
                rebuilt += ampsSide;
            }
        }
        uint256 band = (reported > rebuilt ? reported : rebuilt) / 10_000 + 1000;
        lte(reported, rebuilt + band, "GL-21: inventoryAmps above its own decomposition");
        lte(rebuilt, reported + band, "GL-21: inventoryAmps below its own decomposition");
    }

    /// @notice GL-22: the protocol is solvent against its own redemption promise — `previewRedeem(totalSupply())`
    ///         never pays more of an asset than the vault holds plus what a full ladder unwind would free.
    /// @dev SHOULD-HOLD. Plan I23; with `shares == T` the payout identity collapses to
    ///      `b*(1 - fee/BPS) + released <= b + released`, a closed-form bound (`VaultRedeemLib._payout:667`).
    /// @param seed Unused.
    function property_redemptionIsCovered(uint256 seed) public {
        seed;
        uint256 supply = amps.totalSupply();
        if (supply == 0) return;

        uint256 count = vault.assetCount();
        address[] memory assets = new address[](count);
        uint256[] memory available = new uint256[](count);
        for (uint256 i; i < count; ++i) {
            assets[i] = vault.assetAt(i);
            available[i] = _balanceOf(assets[i], address(vault)) + _claim(address(vault), assets[i]);
        }
        for (uint256 p; p < pools.length; ++p) {
            address counter = counterOf(pools[p]);
            if (counter == address(0)) continue;
            uint256 freeable = _fullUnwindCounter(pools[p]);
            for (uint256 i; i < count; ++i) {
                if (assets[i] == counter) {
                    available[i] += freeable;
                    break;
                }
            }
        }

        (address[] memory tokens, uint256[] memory amounts,) = vault.previewRedeem(supply);
        for (uint256 k; k < tokens.length; ++k) {
            for (uint256 i; i < count; ++i) {
                if (assets[i] != tokens[k]) continue;
                lte(amounts[k], available[i] + 1, "GL-22: previewRedeem(T) pays more than the vault can free");
                break;
            }
        }
    }

    /// @notice GL-23: the PoolManager can cover the ERC-6909 claims the protocol holds.
    /// @dev EXPLORATORY. Summed over the accounts the campaign can give claims to, so it is a subset bound and
    ///      cannot false-positive on an account it does not know about.
    /// @param seed Chooses the token: AMPS or one registered asset.
    function property_poolManagerCoversClaims(uint256 seed) public {
        uint256 count = vault.assetCount();
        address token = seed % (count + 1) == 0 ? address(amps) : vault.assetAt(seed % count);
        if (token == address(0)) return;

        uint256 outstanding = _claim(address(vault), token) + _claim(address(hook), token)
            + _claim(address(bonds), token) + _claim(address(ampsRouter), token) + _claim(vault.creator(), token)
            + _claim(address(this), token);
        for (uint256 i; i < actors.length; ++i) {
            outstanding += _claim(actors[i], token);
        }
        gte(
            _balanceOf(token, address(poolManager)),
            outstanding,
            "GL-23: the PoolManager cannot cover the claims the protocol holds"
        );
    }

    /// @notice GL-24: zero-state safety — the NAV denominator is never zero, NAV/share is finite, a zero supply
    ///         prices at exactly zero, and a zero NAV/share never lets a market issue.
    /// @dev SHOULD-HOLD. Plan I22 ("`T + VIRTUAL_SHARES > 0`; NAV/share finite for all reachable states"); x-ray
    ///      I-8 ("`supply == 0` short-circuits to zero rather than to `1e18 / VIRTUAL_SHARES`", `AmpsVault.sol:1499`).
    /// @param seed Unused.
    function property_zeroStateSafety(uint256 seed) public {
        seed;
        uint256 supply = amps.totalSupply();
        gt(supply + GlobC.VIRTUAL_SHARES, 0, "GL-24: the NAV denominator is zero");

        uint256 nav = vault.previewNavPerShareX18();
        if (supply == 0) eq(nav, 0, "GL-24: a zero supply does not price at zero");
        lt(nav, uint256(type(uint128).max), "GL-24: NAV/share is not finite");

        if (nav == 0) {
            for (uint256 i; i < marketIds.length; ++i) {
                (uint256 out,,,,,) = _bondQuote(marketIds[i], GlobC.WAD);
                eq(out, 0, "GL-24: a market quotes AMPS against a zero NAV/share");
            }
        }
    }

    /// @notice GL-25: **[MANDATORY V-06]** the first-depositor / donation-inflation grief does not exist — one
    ///         whole unit of collateral still quotes a non-zero `ampsOut` on any market that says it would accept
    ///         the bond.
    /// @dev EXPLORATORY. Stated at one whole collateral unit rather than at "any deposit > 0" because the latter is
    ///      false here by design: `ampsBonds_bond_dust` expects a 1-wei deposit to revert `ZeroAmount`. The gate is
    ///      `reason == bytes32(0)`, which is `AmpsBonds.quote`'s own statement that the bond would succeed — so a
    ///      zero `ampsOut` behind it is the shell contradicting itself, which is exactly the grief.
    /// @param seed Chooses the market.
    function property_noShareInflationGrief(uint256 seed) public {
        uint16 id = marketFrom(seed);
        GlobMarket memory record;
        bool found;
        try bonds.market(id) returns (GlobMarket memory r) {
            record = r;
            found = true;
        } catch {}
        if (!found || !record.open || record.decimals > 18) return;

        uint256 oneUnit = 10 ** uint256(record.decimals);
        (uint256 out,,,,, bytes32 reason) = _bondQuote(id, oneUnit);
        if (reason != bytes32(0)) return;
        gt(out, 0, "GL-25: one whole collateral unit quotes zero AMPS on a market that would accept the bond");
    }

    /// @notice GL-26: the disclosure surface answers in every reachable state — after a hostile donation, a frozen
    ///         gate, a paused issuer beacon and a stale feed alike.
    /// @dev SHOULD-HOLD. `LadderPositionValuer` NatSpec ("**Never gated, never reverting** (ruling 7) … all return
    ///      `(0, 0)`"); fix-log wave-1 findings 2 and 3 (a constituent whose `balanceOf` reverts must not revert
    ///      `previewRedeem`), wave-2 finding 2.
    /// @param seed Chooses the pool the two per-pool views are asked about.
    function property_disclosureNeverReverts(uint256 seed) public {
        GlobPoolId poolId = poolFrom(seed);
        uint256 fails;

        try vault.checkpointData() returns (GlobCheckpoint memory) {}
        catch {
            fails |= 1;
        }
        try vault.navPerShareX18() returns (uint256) {}
        catch {
            fails |= 2;
        }
        try vault.previewNavPerShareX18() returns (uint256) {}
        catch {
            fails |= 4;
        }
        try vault.inventoryAmps() returns (uint256) {}
        catch {
            fails |= 8;
        }
        try vault.previewRedeem(1) returns (address[] memory, uint256[] memory, uint256) {}
        catch {
            fails |= 16;
        }
        try pot.quote(GlobC.WAD, GlobC.WAD / 10) returns (uint256, bytes32) {}
        catch {
            fails |= 32;
        }
        try bonds.dailyIssuance() returns (uint256, uint256) {}
        catch {
            fails |= 64;
        }
        try valuer.amountsOf(poolId) returns (uint256, uint256) {}
        catch {
            fails |= 128;
        }
        try quoter.quotePool(poolId) returns (GlobQuoter.PoolQuote memory) {}
        catch {
            fails |= 256;
        }

        if (fails != 0) ghosts.livenessReverts[keccak256("GL-26:disclosure")] += 1;
        eq(fails, 0, "GL-26: a disclosure view reverted");
    }

    /// @notice GL-27: the ungated redemption floor is always open — a holder can always burn one wei of shares.
    /// @dev SHOULD-HOLD. Plan I14 ("`redeemProRata` exempt by construction"); `AmpsVault.redeemProRata` NatSpec
    ///      ("The body below contains no reference to `_oracleGate`, `_registry`, `_GUARDIAN`, `_standbyVault`, a
    ///      freeze timestamp, a pause flag or any price", `:826-834`), proved at the storage level by
    ///      `test/unit/GuardSymmetry.t.sol`.
    /// @dev The redemption is executed rather than simulated: `vm.snapshotState`/`vm.revertToState` are not
    ///      implemented in Medusa 1.5.1, so the Medusa-safe shape is to assert on the `catch` arm of the real call.
    /// @param seed Chooses the actor.
    function property_theFloorIsAlwaysOpen(uint256 seed) public {
        address who = actors[seed % actors.length];
        if (amps.balanceOf(who) == 0) return;
        uint256 supplyBefore = amps.totalSupply();

        vm.prank(who);
        try vault.redeemProRata(1, who) returns (address[] memory, uint256[] memory) {
            lt(amps.totalSupply(), supplyBefore, "GL-27: a one-wei redemption burned no supply");
        } catch {
            ghosts.livenessReverts[keccak256("GL-27:redeemOneWei")] += 1;
            t(false, "GL-27: a one-wei redemption by a holder was refused");
        }
    }

    /// @notice GL-28: splitting a redemption never pays more than doing it once.
    /// @dev SHOULD-HOLD. Closed form: every payout term is a round-down `FullMath.mulDiv`, and
    ///      `floor(x*a/T) + floor(x*b/T) <= floor(x*(a+b)/T)`. The formula is x-ray I-9
    ///      (`VaultRedeemLib._payout:663-671`, `previewUnwind:849-864`, `redemption:631`).
    /// @param seed Chooses the two halves.
    function property_redemptionIsNotSplittableForProfit(uint256 seed) public {
        uint256 supply = amps.totalSupply();
        if (supply < 4) return;
        uint256 a = clampBetween(seed, 1, supply / 2);
        uint256 b = clampBetween(uint256(keccak256(abi.encode(seed, "GL-28"))), 1, supply / 2);

        (address[] memory ta, uint256[] memory aa, uint256 ia) = vault.previewRedeem(a);
        (address[] memory tb, uint256[] memory ab, uint256 ib) = vault.previewRedeem(b);
        (address[] memory tc, uint256[] memory ac, uint256 ic) = vault.previewRedeem(a + b);

        lte(ia + ib, ic, "GL-28: splitting a redemption burns less inventory");
        if (ta.length != tb.length || ta.length != tc.length) return;
        for (uint256 i; i < ta.length; ++i) {
            if (ta[i] != tb[i] || ta[i] != tc[i]) continue;
            lte(aa[i] + ab[i], ac[i], "GL-28: splitting a redemption pays more than doing it once");
        }
    }

    /// @notice GL-29: `previewRedeem` is monotone in shares — more shares never pays less of any asset and never
    ///         burns less inventory.
    /// @dev SHOULD-HOLD. Every term of `VaultRedeemLib._payout` / `previewUnwind` is a `FullMath.mulDiv` floor of a
    ///      quantity linear and non-decreasing in `shares`, and `SqrtPriceMath.getAmount{0,1}Delta` is
    ///      non-decreasing in liquidity. Stated as x-ray I-9.
    /// @param seed Chooses the two sizes.
    function property_previewRedeemIsMonotone(uint256 seed) public {
        uint256 supply = amps.totalSupply();
        if (supply < 2) return;
        uint256 small = clampBetween(seed, 1, supply - 1);
        uint256 large = clampBetween(uint256(keccak256(abi.encode(seed, "GL-29"))), small, supply);

        (address[] memory ts, uint256[] memory as_, uint256 is_) = vault.previewRedeem(small);
        (address[] memory tl, uint256[] memory al, uint256 il) = vault.previewRedeem(large);

        lte(is_, il, "GL-29: more shares burned less inventory");
        if (ts.length != tl.length) return;
        for (uint256 i; i < ts.length; ++i) {
            if (ts[i] != tl[i]) continue;
            lte(as_[i], al[i], "GL-29: more shares paid less of an asset");
        }
    }

    /// @notice GL-30: there is no free round trip through a protocol-owned ladder on the quoter — buying AMPS with
    ///         `x` and selling it straight back into the same pool quotes strictly less than `x`.
    /// @dev EXPLORATORY.
    /// @param seed Chooses the pool and the size.
    function property_noFreeRoundTripOnTheQuoter(uint256 seed) public {
        GlobPoolId poolId = poolFrom(seed);
        uint256 amountIn = counterUnit(poolId) * clampBetween(seed >> 8, 1, 20);

        (uint256 ampsOut,, bool refuseBuy,) = quoter.quoteExactIn(poolId, false, amountIn);
        if (refuseBuy || ampsOut == 0) return;
        (uint256 back,, bool refuseSell,) = quoter.quoteExactIn(poolId, true, ampsOut);
        if (refuseSell) return;
        lt(back, amountIn, "GL-30: a same-pool quoted round trip returns at least what it cost");
    }

    /// @notice GL-31: no actor gains USD value it was not funded with.
    /// @dev **Left as a TODO on purpose (`[-]` in `contracts/PROPERTIES.md`).** EXPLORATORY, and not assertable in
    ///      this harness as stated: `OracleGateHandler.env_secondary` walks the Chainlink answers and the display
    ///      multipliers arbitrarily, so an actor's *USD* value moves with the fuzzer's own price steps and is not a
    ///      function of what the harness minted it. A basis-versus-value comparison would fire on every upward feed
    ///      walk, which is noise rather than a lead. Making it real needs a price-neutral accounting layer — per
    ///      token, in raw units, differenced against a mint ledger — that `fizz_data/property-plan.md` does not
    ///      specify, plus a mint hook inside `AmpsBondsHandler`'s direct `stocks[i].mint` calls.
    ///      `ghosts.actorValueBasis` and `ghosts.actorMintedValueUsd18` are in place for whoever picks it up.

    /// @notice GL-32: keeper-callable upkeep does not bleed the vault by a thousand cuts — the NAV/share the
    ///         campaign has lost across every placement, compound, rollout and bonded deployment stays under
    ///         100 bp of the NAV/share high-water.
    /// @dev EXPLORATORY. The bleed is *attributed*, not inferred from the NAV/share level: NAV/share also moves
    ///      with the feeds, so only the per-call drift the placement handlers record (`ghosts.cumulativeBleedUsd18`,
    ///      the same measurement SP-17 asserts a per-call bound on) is a keeper cost.
    /// @param seed Unused.
    function property_cumulativeKeeperBleedBounded(uint256 seed) public {
        seed;
        uint256 nav = vault.navPerShareX18();
        if (nav > ghosts.navPerShareHigh) ghosts.navPerShareHigh = nav;
        lte(
            ghosts.cumulativeBleedUsd18,
            ghosts.navPerShareHigh / 100,
            "GL-32: cumulative keeper bleed above 100 bp of the NAV/share high-water"
        );
    }

    /// @notice GL-33: the reference price never rounds below NAV.
    /// @dev SHOULD-HOLD. x-ray I-11 ("`P_ref = max(navPerShareX18, rateLimited(P_mkt))` … The NAV floor is
    ///      unconditional at `VaultNavLib.sol:382`"); plan I24. The rate-limit leg of GL-33 needs the previous
    ///      checkpoint's `P_ref` and the elapsed time, which only the checkpointing handler holds — it is asserted
    ///      there rather than here, because an upward move that lands on a *risen NAV floor* is unbounded by
    ///      `refUpRateBps` and a global reading of it would be wrong.
    /// @return ok Always true.
    function property_referencePriceFloorsAtNav() public returns (bool ok) {
        uint256 nav = vault.navPerShareX18();
        if (nav != 0) gte(vault.pRefX18(), nav, "GL-33: the reference price is below NAV/share");
        return true;
    }

    /// @notice GL-34: every governed scalar sits inside its hard band.
    /// @dev SHOULD-HOLD. Guard G-24 (`AmpsVault.sol:1702`, "the single band site every governed vault scalar
    ///      funnels through"); x-ray I-1 (`redeemFeeBps` in `[0, 500]`), I-2 (`ampsFeeBps` in `[100, 600]`).
    /// @param seed Chooses the pool whose `buyFeeBps` band is checked, and the market whose discount band is.
    function property_governedScalarsInBand(uint256 seed) public {
        lte(uint256(vault.redeemFeeBps()), uint256(GlobC.REDEEM_FEE_BPS_MAX), "GL-34: redeemFeeBps out of band");
        lte(
            uint256(vault.rolloutBpsPerDay()),
            uint256(GlobC.ROLLOUT_BPS_PER_DAY_MAX),
            "GL-34: rolloutBpsPerDay out of band"
        );
        lte(uint256(vault.entryFloorBps()), uint256(GlobC.ENTRY_FLOOR_BPS_MAX), "GL-34: entryFloorBps out of band");
        {
            uint256 value = uint256(vault.refUpRateBps());
            gte(value, uint256(GlobC.REF_UP_RATE_BPS_MIN), "GL-34: refUpRateBps out of band");
            lte(value, uint256(GlobC.REF_UP_RATE_BPS_MAX), "GL-34: refUpRateBps out of band");
        }
        {
            uint256 value = uint256(vault.refDivergenceBps());
            gte(value, uint256(GlobC.REF_DIVERGENCE_BPS_MIN), "GL-34: refDivergenceBps out of band");
            lte(value, uint256(GlobC.REF_DIVERGENCE_BPS_MAX), "GL-34: refDivergenceBps out of band");
        }
        {
            uint256 value = uint256(vault.twapWindow());
            gte(value, uint256(GlobC.TWAP_WINDOW_MIN), "GL-34: twapWindow out of band");
            lte(value, uint256(GlobC.TWAP_WINDOW_MAX), "GL-34: twapWindow out of band");
        }
        {
            uint256 value = uint256(vault.ladderTiltX18());
            gte(value, uint256(GlobC.LADDER_TILT_X18_MIN), "GL-34: ladderTiltX18 out of band");
            lte(value, uint256(GlobC.LADDER_TILT_X18_MAX), "GL-34: ladderTiltX18 out of band");
        }
        {
            uint256 value = uint256(vault.ladderDoublings());
            gte(value, uint256(GlobC.LADDER_DOUBLINGS_MIN), "GL-34: ladderDoublings out of band");
            lte(value, uint256(GlobC.LADDER_DOUBLINGS_MAX), "GL-34: ladderDoublings out of band");
        }
        {
            uint256 value = vault.deployThresholdUsd18();
            gte(value, GlobC.DEPLOY_THRESHOLD_USD18_MIN, "GL-34: deployThresholdUsd18 out of band");
            lte(value, GlobC.DEPLOY_THRESHOLD_USD18_MAX, "GL-34: deployThresholdUsd18 out of band");
        }
        {
            uint256 value = uint256(hook.ampsFeeBps());
            gte(value, uint256(GlobC.AMPS_FEE_BPS_MIN), "GL-34: ampsFeeBps out of band");
            lte(value, uint256(GlobC.AMPS_FEE_BPS_MAX), "GL-34: ampsFeeBps out of band");
        }
        {
            GlobPoolId poolId = poolFrom(seed);
            uint256 value = uint256(hook.buyFeeBps(poolId));
            if (registry.poolConfig(poolId).poolClass == GlobPoolClass.ENTRY) {
                gte(value, uint256(GlobC.BUY_FEE_BPS_ENTRY_MIN), "GL-34: an entry pool's buyFeeBps out of band");
                lte(value, uint256(GlobC.BUY_FEE_BPS_ENTRY_MAX), "GL-34: an entry pool's buyFeeBps out of band");
            } else {
                gte(value, uint256(GlobC.BUY_FEE_BPS_SPOKE_MIN), "GL-34: a spoke's buyFeeBps out of band");
                lte(value, uint256(GlobC.BUY_FEE_BPS_SPOKE_MAX), "GL-34: a spoke's buyFeeBps out of band");
            }
        }
        lte(uint256(bonds.dailyCapBps()), uint256(GlobC.BOND_DAILY_CAP_BPS_MAX), "GL-34: bond dailyCapBps out of band");
        lte(
            uint256(bonds.minAccretionBps()), uint256(GlobC.MIN_ACCRETION_BPS_MAX), "GL-34: minAccretionBps out of band"
        );
        {
            uint256 value = uint256(bonds.epochSeconds());
            gte(value, uint256(GlobC.BOND_EPOCH_SECONDS_MIN), "GL-34: bond epochSeconds out of band");
            lte(value, uint256(GlobC.BOND_EPOCH_SECONDS_MAX), "GL-34: bond epochSeconds out of band");
        }
        {
            uint256 value = uint256(bonds.vestSeconds());
            gte(value, uint256(GlobC.BOND_VEST_SECONDS_MIN), "GL-34: bond vestSeconds out of band");
            lte(value, uint256(GlobC.BOND_VEST_SECONDS_MAX), "GL-34: bond vestSeconds out of band");
        }

        try bonds.market(marketFrom(seed)) returns (GlobMarket memory record) {
            gte(uint256(record.dMinBps), uint256(GlobC.DISCOUNT_BPS_MIN), "GL-34: a market's dMinBps out of band");
            lte(uint256(record.dMaxBps), uint256(GlobC.DISCOUNT_BPS_MAX), "GL-34: a market's dMaxBps out of band");
            lte(uint256(record.dMinBps), uint256(record.dMaxBps), "GL-34: a market's dMin above its dMax");
            lte(
                uint256(record.capBpsPerEpoch),
                uint256(GlobC.BOND_CAP_BPS_PER_EPOCH_MAX),
                "GL-34: a market's capBpsPerEpoch out of band"
            );
        } catch {}
    }

    /// @notice GL-35: `creatorBpsAt(t)` is monotone non-increasing, equals `CREATOR_FEE_BPS` at genesis, never
    ///         exceeds it, and is exactly zero from `genesisTimestamp + CREATOR_DECAY_SECONDS`.
    /// @dev SHOULD-HOLD. x-ray I-21's closed form
    ///      `CREATOR_FEE_BPS x max(0, 1 - (t - genesisTimestamp)/CREATOR_DECAY_SECONDS)` (`AmpsVault.sol:574-583`,
    ///      duplicated at `VaultPlacementLib.sol:1566-1572`); plan I31.
    /// @param seed Unused.
    function property_creatorBpsIsMonotone(uint256 seed) public {
        seed;
        uint256 nowBps = uint256(vault.creatorBpsAt(block.timestamp));
        lte(nowBps, uint256(GlobC.CREATOR_FEE_BPS), "GL-35: creatorBps above CREATOR_FEE_BPS");
        lte(nowBps, uint256(ghosts.lastCreatorBps), "GL-35: creatorBps rose");
        ghosts.lastCreatorBps = uint16(nowBps);

        uint256 genesis = uint256(vault.genesisTimestamp());
        eq(
            uint256(vault.creatorBpsAt(genesis)),
            uint256(GlobC.CREATOR_FEE_BPS),
            "GL-35: creatorBps at genesis is not the full fee"
        );
        eq(
            uint256(vault.creatorBpsAt(genesis + uint256(GlobC.CREATOR_DECAY_SECONDS))),
            0,
            "GL-35: creatorBps is not zero once the decay window has closed"
        );
    }

    /// @notice GL-36: cumulative value paid to `vault.creator()` stays at or below cumulative swap volume times
    ///         `CREATOR_FEE_BPS`, and nothing at all is paid after the decay window closes.
    /// @dev SHOULD-HOLD. Plan I31 as amended by revisions 6/7 ("creator <= volume x creatorBps in every currency";
    ///      "creator payouts are the only transfer of protocol-held AMPS to a non-pool address"); x-ray I-21.
    /// @param seed Unused.
    function property_creatorSliceIsBoundedCumulatively(uint256 seed) public {
        seed;
        lte(
            ghosts.creatorPaidUsd18,
            GlobFullMath.mulDiv(ghosts.swapVolumeUsd18, uint256(GlobC.CREATOR_FEE_BPS), GlobC.BPS) + GlobC.WAD,
            "GL-36: the creator was paid more than volume x CREATOR_FEE_BPS"
        );
        if (block.timestamp >= uint256(vault.genesisTimestamp()) + uint256(GlobC.CREATOR_DECAY_SECONDS)) {
            eq(ghosts.creatorPaidSinceDecay, 0, "GL-36: the creator was paid after the decay window closed");
        }
    }

    /// @notice GL-37: the rotation credit is transaction-scoped — nobody carries one between handler calls.
    /// @dev SHOULD-HOLD. Plan I26 ("`tload(ROTATION_CREDIT)` … **zero at the start of every transaction**"), with
    ///      the rev-6 amendment limiting the credit to the router's ROTATE hops; the counters live in EIP-1153
    ///      transient storage, which is cleared at the end of every transaction by the EVM itself.
    /// @return ok Always true.
    function property_rotationCreditIsTransactionScoped() public returns (bool ok) {
        for (uint256 i; i < actors.length; ++i) {
            eq(_rotationCreditOf(actors[i]), 0, "GL-37: an actor carries a rotation credit between calls");
        }
        eq(_rotationCreditOf(address(ampsRouter)), 0, "GL-37: the router carries a rotation credit between calls");
        eq(_rotationCreditOf(address(this)), 0, "GL-37: the harness carries a rotation credit between calls");
        return true;
    }

    /// @notice GL-38: the hook is custody-free — it holds no ERC-6909 claim of AMPS or of any registered asset, and
    ///         a token donated into it is trapped rather than moved.
    /// @dev SHOULD-HOLD. Plan I13 ("Hook holds zero ERC-20/ERC-6909; no returns-delta bit; `beforeSwap` returns
    ///      `ZERO_DELTA`, `afterSwap` returns 0; no `donate()` or `poolManager.swap()` anywhere in the codebase").
    /// @dev The ERC-20 half is stated as "never *pays out*" rather than "always zero" on purpose:
    ///      `ampsVault_donateERC20` deliberately drops loose balances on the hook, and it is legitimate for one to
    ///      sit there. `ghosts.hookDonated` is the running total of what the campaign put there.
    /// @param seed Unused.
    function property_hookHoldsAndMovesNothing(uint256 seed) public {
        seed;
        eq(_claim(address(hook), address(amps)), 0, "GL-38: the hook holds an AMPS claim");
        gte(
            _balanceOf(address(amps), address(hook)),
            ghosts.hookDonated[address(amps)],
            "GL-38: the hook paid out AMPS that was donated to it"
        );

        uint256 count = vault.assetCount();
        for (uint256 i; i < count; ++i) {
            address token = vault.assetAt(i);
            eq(_claim(address(hook), token), 0, "GL-38: the hook holds an asset claim");
            gte(
                _balanceOf(token, address(hook)),
                ghosts.hookDonated[token],
                "GL-38: the hook paid out a token that was donated to it"
            );
        }
    }

    /// @notice GL-39: `AmpsRouter` holds nothing between calls — no AMPS, no counter asset, no ERC-6909 claim and
    ///         no ether.
    /// @dev SHOULD-HOLD. `AmpsRouter` NatSpec ("the assets it touched are swept to `msg.sender` on a best-effort
    ///      basis"); `_sweep` ("The invariant that matters is that this contract holds nothing *between*
    ///      transactions", `AmpsRouter.sol:426-435`). No donation handler targets the router, so the equality is
    ///      the right shape here where GL-38's ERC-20 leg is not.
    /// @param seed Unused.
    function property_routerHoldsNothing(uint256 seed) public {
        seed;
        eq(_balanceOf(address(amps), address(ampsRouter)), 0, "GL-39: the router holds AMPS between calls");
        eq(_claim(address(ampsRouter), address(amps)), 0, "GL-39: the router holds an AMPS claim between calls");
        eq(address(ampsRouter).balance, 0, "GL-39: the router holds ether between calls");

        uint256 count = vault.assetCount();
        for (uint256 i; i < count; ++i) {
            address token = vault.assetAt(i);
            eq(_balanceOf(token, address(ampsRouter)), 0, "GL-39: the router holds a counter asset between calls");
            eq(_claim(address(ampsRouter), token), 0, "GL-39: the router holds an asset claim between calls");
        }
    }

    /// @notice GL-40: `vault.liveCells()` equals the number of placement records that actually hold liquidity, and
    ///         never exceeds `Constants.MAX_LIVE_CELLS`.
    /// @dev EXPLORATORY.
    /// @param seed Unused.
    function property_liveCellCounterIsHonest(uint256 seed) public {
        seed;
        uint256 counted = uint256(countLiveCells());
        eq(uint256(vault.liveCells()), counted, "GL-40: liveCells disagrees with the vault's own records");
        lte(counted, uint256(GlobC.MAX_LIVE_CELLS), "GL-40: the live cell count is above MAX_LIVE_CELLS");
        if (counted > ghosts.liveCellHigh) ghosts.liveCellHigh = counted;
    }

    /// @notice GL-41: the liquidity the vault records for a pool equals the liquidity the PoolManager actually
    ///         holds for the vault's positions on that pool's canonical grid.
    /// @dev EXPLORATORY. `LadderPositionValuer.totalLiquidity` enumerates the grid at the PoolManager by
    ///      `extsload`, so it is an independent witness rather than a second reading of the same book.
    /// @param seed Chooses the pool.
    function property_recordedLiquidityMatchesPoolManager(uint256 seed) public {
        GlobPoolId poolId = poolFrom(seed);
        uint256 n = vault.ladderLength(poolId);
        uint256 recorded;
        for (uint256 i; i < n; ++i) {
            (,, uint128 liquidity,,,,,,,) = vault.ladderAt(poolId, i);
            recorded += uint256(liquidity);
        }
        uint256 actual;
        try valuer.totalLiquidity(poolId) returns (uint128 v) {
            actual = uint256(v);
        } catch {
            return;
        }
        eq(recorded, actual, "GL-41: the vault's recorded liquidity is not the PoolManager's");
    }

    /// @notice GL-42: every live `PlacementRecord` is exactly one canonical cell of its pool's doubling grid, and
    ///         no two live records in one pool share a cell or a lower tick.
    /// @dev SHOULD-HOLD. Guard G-29 (`VaultPlacementLib.sol:855`, `OffGrid`: "Every bucket must be exactly one cell
    ///      of the pool's canonical doubling grid, which is what the position valuer enumerates"); `_writeRecords`
    ///      merges by lower tick rather than pushing (`:903-916`); plan I34.
    /// @param seed Chooses the pool.
    function property_everyRecordIsOneCanonicalCell(uint256 seed) public {
        GlobPoolId poolId = poolFrom(seed);
        GlobPoolConfig memory config = registry.poolConfig(poolId);
        if (!config.registered || config.tickSpacing == 0) return;
        int256 width = int256(GlobLadderLib.doublingTicks(config.tickSpacing));

        GlobRecord[] memory records = ladderOf(poolId);
        for (uint256 i; i < records.length; ++i) {
            if (records[i].liquidity == 0) continue;
            eq(
                int256(records[i].upperTick) - int256(records[i].lowerTick),
                width,
                "GL-42: a live record is not one doubling wide"
            );
            eq(
                int256(records[i].lowerTick) % int256(config.tickSpacing),
                int256(0),
                "GL-42: a live record is off the spacing"
            );
            lt(
                uint256(records[i].bucketIndex),
                uint256(GlobC.GRID_CELLS),
                "GL-42: a bucket index outside the canonical grid"
            );

            for (uint256 j = i + 1; j < records.length; ++j) {
                if (records[j].liquidity == 0) continue;
                t(
                    records[j].lowerTick != records[i].lowerTick,
                    "GL-42: two live records in one pool share a lower tick"
                );
                t(
                    records[j].bucketIndex != records[i].bucketIndex,
                    "GL-42: two live records in one pool share a canonical cell"
                );
            }
        }
    }

    /// @notice GL-43: ladder sidedness holds for every live cell — an ask sits above the anchor it was placed
    ///         against, a bid below it.
    /// @dev SHOULD-HOLD. Plan I9 ("Asks (AMPS-only) lie strictly above the tick, bids … strictly below,
    ///      unconditionally"); guard G-30 (`VaultPlacementLib.sol:873`, "Sidedness in v4's own terms … so no cell
    ///      is straddled at placement").
    /// @dev Measured against the record's own `anchorTick` when the campaign has no placement stamp for the cell,
    ///      and against `ghosts.tickAtPlacement` when a placement handler recorded one. One cell width of slack is
    ///      allowed on the anchor leg because `LadderLib.bucketBounds` aligns the anchor to the spacing first, so
    ///      the first cell on each side straddles it by less than one bucket (ruling AX).
    /// @param seed Chooses the pool.
    function property_ladderSidednessHolds(uint256 seed) public {
        GlobPoolId poolId = poolFrom(seed);
        GlobPoolConfig memory config = registry.poolConfig(poolId);
        if (!config.registered || config.tickSpacing == 0) return;
        bytes32 key = GlobPoolId.unwrap(poolId);
        int256 width = int256(GlobLadderLib.doublingTicks(config.tickSpacing));

        GlobRecord[] memory records = ladderOf(poolId);
        for (uint256 i; i < records.length; ++i) {
            if (records[i].liquidity == 0) continue;
            int256 anchorRef = int256(records[i].anchorTick);
            if (records[i].bucketIndex < 24 && ghosts.tickAtPlacementSet[key][records[i].bucketIndex]) {
                anchorRef = int256(ghosts.tickAtPlacement[key][records[i].bucketIndex]);
            }
            if (records[i].above) {
                gte(
                    int256(records[i].upperTick),
                    anchorRef,
                    "GL-43: a live ask sits below the tick it was placed against"
                );
                gte(
                    int256(records[i].lowerTick) + width,
                    anchorRef,
                    "GL-43: a live ask straddles its anchor by a whole cell"
                );
            } else {
                lte(
                    int256(records[i].lowerTick),
                    anchorRef,
                    "GL-43: a live bid sits above the tick it was placed against"
                );
                lte(
                    int256(records[i].upperTick) - width,
                    anchorRef,
                    "GL-43: a live bid straddles its anchor by a whole cell"
                );
            }
        }
    }

    /// @notice GL-44: `ladderLength(pool)` is monotone non-decreasing and never exceeds `Constants.GRID_CELLS`.
    /// @dev SHOULD-HOLD. `if (n >= Constants.GRID_CELLS) revert OffGrid(...)` sits immediately before the only
    ///      `records.push` (`VaultPlacementLib.sol:914-916`), and no `pop`/`delete` exists in `src/vault/**`.
    /// @param seed Unused.
    function property_ladderLengthMonotoneAndBounded(uint256 seed) public {
        seed;
        for (uint256 p; p < pools.length; ++p) {
            bytes32 key = GlobPoolId.unwrap(pools[p]);
            uint256 length = vault.ladderLength(pools[p]);
            lte(length, uint256(GlobC.GRID_CELLS), "GL-44: ladderLength above GRID_CELLS");
            gte(length, ghosts.maxLadderLength[key], "GL-44: ladderLength fell");
            ghosts.maxLadderLength[key] = length;
        }
    }

    /// @notice GL-45: `vault.lastPlacementAt(pool)` is monotone non-decreasing and never ahead of the chain.
    /// @dev SHOULD-HOLD. The only writes are `cooldown[poolId] = uint32(block.timestamp)`
    ///      (`VaultPlacementLib.sol:288`, `:466`; `VaultRolloutLib.sol:190-192`, `:322`).
    /// @param seed Unused.
    function property_lastPlacementAtMonotone(uint256 seed) public {
        seed;
        for (uint256 p; p < pools.length; ++p) {
            bytes32 key = GlobPoolId.unwrap(pools[p]);
            uint32 stamp = vault.lastPlacementAt(pools[p]);
            gte(uint256(stamp), uint256(ghosts.maxLastPlacementAt[key]), "GL-45: lastPlacementAt fell");
            lte(uint256(stamp), block.timestamp, "GL-45: lastPlacementAt is ahead of the chain");
            ghosts.maxLastPlacementAt[key] = stamp;
        }
    }

    /// @notice GL-46: the checkpoint's `timestamp` and `blockNumber` are monotone non-decreasing and never ahead of
    ///         the chain.
    /// @dev SHOULD-HOLD. `_checkpointTimestamp = uint32(block.timestamp); _checkpointBlock = uint32(block.number);`
    ///      (`AmpsVault.sol:1533-1534`) are the fields' only write sites, and `_checkpoint`'s `elapsed` underflows
    ///      on a future stamp.
    /// @dev The block leg is skipped once `block.number` passes `type(uint32).max`, where the stored value's own
    ///      truncation stops being comparable with the chain's.
    /// @param seed Unused.
    function property_checkpointStampsMonotone(uint256 seed) public {
        seed;
        GlobCheckpoint memory snapshot = vault.checkpointData();
        gte(uint256(snapshot.timestamp), uint256(ghosts.maxCheckpointTimestamp), "GL-46: the checkpoint timestamp fell");
        lte(uint256(snapshot.timestamp), block.timestamp, "GL-46: the checkpoint timestamp is ahead of the chain");
        ghosts.maxCheckpointTimestamp = snapshot.timestamp;

        if (block.number <= uint256(type(uint32).max)) {
            gte(uint256(snapshot.blockNumber), uint256(ghosts.maxCheckpointBlock), "GL-46: the checkpoint block fell");
            lte(uint256(snapshot.blockNumber), block.number, "GL-46: the checkpoint block is ahead of the chain");
            ghosts.maxCheckpointBlock = snapshot.blockNumber;
        }
    }

    /// @notice GL-47: a pool's `highWaterTick` only rises, except across a vault-driven `resetHighWater`.
    /// @dev SHOULD-HOLD. `if (truncatedTick > s.highWaterTick) s.highWaterTick = truncatedTick;`
    ///      (`TruncatedOracleLib.sol:309`) is a rise-only write, and `resetHighWater` writes
    ///      `min(lastTruncatedTick, floorTick)` (`:332-335`) behind `onlyVault` (`AmpsHook.sol:1577`). Plan I33.
    /// @dev The only caller of `resetHighWater` is a vault placement path, and every one of those re-stamps the
    ///      pool's `lastPlacementAt`. The rise-only leg is therefore asserted across observations that no placement
    ///      separated.
    /// @dev **No ordering against `lastTruncatedTick` is asserted** (2026-09-11 campaign): the mark is a running
    ///      *maximum* of the truncated ticks written since the last reset, so after a pool is swapped up and back
    ///      down in one block (`ampsRouter_rotateRoundTrip`) it sits *above* `lastTruncatedTick` by design, and
    ///      after a reset to `floorTick < lastTruncatedTick` it sits below until the next write. The generated
    ///      "never above `lastTruncatedTick`" clause misread `:309` and was removed.
    /// @param seed Chooses the pool.
    function property_highWaterRisesOnly(uint256 seed) public {
        GlobPoolId poolId = poolFrom(seed);
        bytes32 key = GlobPoolId.unwrap(poolId);

        int24 highWater;
        try hook.highWaterTick(poolId) returns (int24 v) {
            highWater = v;
        } catch {
            return;
        }

        uint32 stamp = vault.lastPlacementAt(poolId);
        if (ghosts.maxHighWaterSet[key] && ghosts.hwPlacementStamp[key] == stamp) {
            gte(int256(highWater), int256(ghosts.maxHighWater[key]), "GL-47: highWaterTick fell without a reset");
        }
        ghosts.maxHighWaterSet[key] = true;
        ghosts.maxHighWater[key] = highWater;
        ghosts.hwPlacementStamp[key] = stamp;
    }

    /// @notice GL-48: a pool's `observationCoverage` never shrinks while the clock only moves forward.
    /// @dev EXPLORATORY.
    /// @param seed Chooses the pool.
    function property_observationCoverageMonotone(uint256 seed) public {
        GlobPoolId poolId = poolFrom(seed);
        bytes32 key = GlobPoolId.unwrap(poolId);
        try hook.observationCoverage(poolId) returns (uint32 coverage) {
            gte(uint256(coverage), uint256(ghosts.maxCoverage[key]), "GL-48: a pool's observation coverage shrank");
            ghosts.maxCoverage[key] = coverage;
        } catch {}
    }

    /// @notice GL-49: rollout cannot drain the entry pools — cumulative movement over any rolling day stays within
    ///         the decayed allowance.
    /// @dev SHOULD-HOLD. Plan I32 ("Rollout moves <= `rolloutBpsPerDay` of the POL tranche per day … never takes
    ///      the entry pools below `entryFloorBps`"); x-ray G-32, G-33, I-19, E-4; fix-log wave-4 finding 12
    ///      ("`moved` decays linearly … `windowStart` advances on **every** charge"). The entry-floor leg needs the
    ///      pre-call inventory and is asserted by `ampsVault_rollout` itself (SP-28's neighbourhood).
    /// @param seed Unused.
    function property_rolloutDrainIsBounded(uint256 seed) public {
        seed;
        if (ghosts.rolloutWindowStart == 0) return;
        if (block.timestamp >= uint256(ghosts.rolloutWindowStart) + uint256(GlobC.ONE_DAY)) return;
        uint256 allowance = GlobFullMath.mulDiv(ghosts.polTrancheAmps, uint256(vault.rolloutBpsPerDay()), GlobC.BPS);
        lte(
            ghosts.rolloutMovedInWindow,
            allowance + allowance / 100 + 1,
            "GL-49: rollout moved more than a rolling day's allowance"
        );
    }

    /// @notice GL-50: `activeConstituentCount()` is the number of ids whose stored status is ACTIVE, and every id
    ///         in `[1, constituentCount()]` is ACTIVE or RETIRED.
    /// @dev SHOULD-HOLD. The counter is written only beside a status write (`PoolRegistry.sol:290-291`, `:344-347`,
    ///      `:370-374`), and the FROZEN overlay's two inputs have no reachable writer in this campaign.
    /// @param seed Unused.
    function property_activeSetIsConsistent(uint256 seed) public {
        seed;
        uint16 count = registry.constituentCount();
        uint256 active;
        for (uint16 id = 1; id <= count; ++id) {
            GlobConstituent memory config = registry.constituent(id);
            t(
                config.status == GlobStatus.ACTIVE || config.status == GlobStatus.RETIRED,
                "GL-50: a constituent is neither ACTIVE nor RETIRED"
            );
            if (config.status == GlobStatus.ACTIVE) ++active;
        }
        eq(
            uint256(registry.activeConstituentCount()),
            active,
            "GL-50: activeConstituentCount disagrees with the stored statuses"
        );
    }

    /// @notice GL-51: `status == RETIRED` if and only if `retiredAt != 0`.
    /// @dev SHOULD-HOLD. The two writes are paired with the status in the same block:
    ///      `config.status = RETIRED; … config.retiredAt = uint32(block.timestamp);` (`PoolRegistry.sol:344-346`)
    ///      and `config.status = ACTIVE; … config.retiredAt = 0;` (`:370-377`).
    /// @param seed Unused.
    function property_retiredIffStamped(uint256 seed) public {
        seed;
        uint16 count = registry.constituentCount();
        for (uint16 id = 1; id <= count; ++id) {
            GlobConstituent memory config = registry.constituent(id);
            if (config.status == GlobStatus.RETIRED) {
                neq(uint256(config.retiredAt), 0, "GL-51: a RETIRED constituent carries no retirement stamp");
            } else {
                eq(uint256(config.retiredAt), 0, "GL-51: a non-RETIRED constituent carries a retirement stamp");
            }
        }
    }

    /// @notice GL-52: a retired name is an exit-only book — no open bond market, no rollout weight.
    /// @dev SHOULD-HOLD. Plan I37 verbatim ("a retired constituent has no open bond market and zero rollout
    ///      weight"), enforced at `PoolRegistry.sol:353` and `:414-416`; x-ray X-9; fix-log wave-1 finding 10.
    /// @param seed Unused.
    function property_retiredNamesAreExitOnly(uint256 seed) public {
        seed;
        uint16 count = registry.constituentCount();
        for (uint16 id = 1; id <= count; ++id) {
            GlobConstituent memory config = registry.constituent(id);
            if (config.status != GlobStatus.RETIRED) continue;
            eq(uint256(config.rolloutWeightBps), 0, "GL-52: a retired name carries rollout weight");
            if (config.marketId == 0) continue;
            try bonds.market(config.marketId) returns (GlobMarket memory record) {
                t(!record.open, "GL-52: a retired name has an open bond market");
            } catch {}
        }
    }

    /// @notice GL-53: the index weight vector normalises, every ACTIVE weight sits in its band, and no observed
    ///         bond discount exceeds its market's `dMaxBps`.
    /// @dev EXPLORATORY.
    ///
    /// @dev **The vector is only checked while the ACTIVE set is the whole population.** `retireConstituent` takes
    ///      a name out of the ACTIVE set without renormalising the survivors — the smoke run leaves the remaining
    ///      weights summing to 9,667 bp — and both `indexCapBps()` and `indexFloorBps()` are functions of `n`, so
    ///      a retirement moves the band under weights that were legal when they were set. Renormalising is a
    ///      separate governance action (`setIndexWeights`), which means the gap is a legitimate transient rather
    ///      than a violation. Asserting through it would report the fuzzer's own retirement as a bug on every call
    ///      after it, which is exactly the noise that costs a campaign its signal.
    /// @param seed Unused.
    function property_weightVectorNormalises(uint256 seed) public {
        seed;
        uint16 count = registry.constituentCount();
        if (registry.activeConstituentCount() == count) {
            uint256 cap = uint256(registry.indexCapBps());
            uint256 floorBps = uint256(registry.indexFloorBps());
            uint256 sum;
            uint256 n;
            for (uint16 id = 1; id <= count; ++id) {
                GlobConstituent memory config = registry.constituent(id);
                if (config.status != GlobStatus.ACTIVE) continue;
                ++n;
                sum += uint256(config.targetWeightBps);
                lte(uint256(config.targetWeightBps), cap, "GL-53: an ACTIVE target weight above the index cap");
                gte(uint256(config.targetWeightBps), floorBps, "GL-53: an ACTIVE target weight below the index floor");
            }
            if (n != 0) eq(sum, GlobC.BPS, "GL-53: the ACTIVE target weights do not sum to BPS");
        }

        for (uint256 i; i < marketIds.length; ++i) {
            uint16 seen = ghosts.maxDiscountSeen[marketIds[i]];
            if (seen == 0) continue;
            try bonds.market(marketIds[i]) returns (GlobMarket memory record) {
                lte(uint256(seen), uint256(record.dMaxBps), "GL-53: an observed discount above its market's dMax");
            } catch {}
        }
    }

    /// @notice GL-54: the population counters are monotone non-decreasing and bounded.
    /// @dev SHOULD-HOLD. `if (marketCount >= Constants.MAX_COLLATERALS) revert CollateralSetFull(...)` then
    ///      `marketId = marketCount + 1` (`AmpsBonds.sol:615`, `:635-636`); `Constants.sol:721-722`; plan I37.
    /// @param seed Unused.
    function property_populationCountersBounded(uint256 seed) public {
        seed;
        uint16 constituents = registry.constituentCount();
        lte(uint256(constituents), uint256(GlobC.MAX_CONSTITUENTS), "GL-54: constituentCount above MAX_CONSTITUENTS");
        gte(uint256(constituents), uint256(ghosts.maxConstituentCount), "GL-54: constituentCount fell");
        ghosts.maxConstituentCount = constituents;

        uint16 markets = bonds.marketCount();
        lte(uint256(markets), uint256(GlobC.MAX_COLLATERALS), "GL-54: marketCount above MAX_COLLATERALS");
        gte(uint256(markets), uint256(ghosts.maxMarketCount), "GL-54: marketCount fell");
        ghosts.maxMarketCount = markets;

        uint16 poolsRegistered = registry.poolCount();
        gte(uint256(poolsRegistered), uint256(ghosts.maxPoolCount), "GL-54: poolCount fell");
        ghosts.maxPoolCount = poolsRegistered;
    }

    /// @notice GL-55: a held-back feed jump implies there is a latch to hold it against, and a different round.
    /// @dev SHOULD-HOLD. A `Pending` is written only on the latch branch (`FeedRegistry.sol:667-678`) and only when
    ///      `againstLatch && pending.roundId != roundId` (`:372-378`); `_latch` deletes it (`:749`).
    /// @param seed Unused.
    function property_pendingImpliesALatch(uint256 seed) public {
        seed;
        address[] memory tokens = feedTokens();
        for (uint256 i; i < tokens.length; ++i) {
            uint80 pendingRound;
            try feeds.pendingAnswer(tokens[i]) returns (GlobFeeds.Pending memory pending) {
                pendingRound = pending.roundId;
            } catch {
                continue;
            }
            if (pendingRound == 0) continue;
            try feeds.acceptedAnswer(tokens[i]) returns (GlobFeeds.Accepted memory accepted) {
                neq(uint256(accepted.answerUsd8), 0, "GL-55: a pending answer with no accepted latch behind it");
                neq(uint256(pendingRound), uint256(accepted.roundId), "GL-55: pending and accepted share a round id");
            } catch {}
        }
    }

    /// @notice GL-56: a live protocol freeze outranks every other layer.
    /// @dev SHOULD-HOLD. `_resolveState` is documented as "The precedence order, most restrictive first" and tests
    ///      `frozen` first: `if (frozen) return GateState.SCHEDULED_FREEZE;` (`OracleGate.sol:958`, with
    ///      `_protocolFrozen()` at `:981`).
    /// @param seed Chooses the pool and the constituent probed.
    function property_freezeOutranksEveryLayer(uint256 seed) public {
        if (uint256(gate.protocolFreezeUntil()) <= block.timestamp) return;

        try gate.stateByPool(poolFrom(seed)) returns (GlobGate state) {
            t(state == GlobGate.SCHEDULED_FREEZE, "GL-56: a pool is not SCHEDULED_FREEZE under a live protocol freeze");
        } catch {}
        try gate.state(constituentFrom(seed)) returns (GlobGate state) {
            t(
                state == GlobGate.SCHEDULED_FREEZE,
                "GL-56: a constituent is not SCHEDULED_FREEZE under a live protocol freeze"
            );
        } catch {}
    }

    /// @notice GL-57: every guardian freeze is bounded — a freeze stamp is never more than
    ///         `GUARDIAN_FREEZE_MAX_SECONDS` ahead of now.
    /// @dev SHOULD-HOLD. Guard G-43 / x-ray I-22: `_requireFreezeWindow` reverts `OutOfBand("freezeUntil", …)`
    ///      outside `[now + 1, now + GUARDIAN_FREEZE_MAX_SECONDS]` (`OracleGate.sol:991-995`); `unfreezeProtocol`
    ///      writes 0 (`:648`). "Strictly in the future" is only true at the moment the stamp is set — an expired
    ///      freeze keeps a past stamp — so only the ceiling is a standing invariant.
    /// @param seed Unused.
    function property_freezesAreBoundedAndExpire(uint256 seed) public {
        seed;
        uint256 ceiling = block.timestamp + uint256(GlobC.GUARDIAN_FREEZE_MAX_SECONDS);
        uint32 protocolUntil = gate.protocolFreezeUntil();
        if (protocolUntil != 0) {
            lte(uint256(protocolUntil), ceiling, "GL-57: the protocol freeze reaches beyond the maximum window");
        }
        uint16 count = registry.constituentCount();
        for (uint16 id = 1; id <= count; ++id) {
            uint32 until = gate.constituentFreezeUntil(id);
            if (until == 0) continue;
            lte(uint256(until), ceiling, "GL-57: a constituent freeze reaches beyond the maximum window");
        }
    }

    /// @notice GL-58: the gate's layer-A watchdog stamp only advances and is never ahead of the chain.
    /// @dev SHOULD-HOLD. `_stamp()` writes `_lastBlock`/`_lastTimestamp` (`OracleGate.sol:804-805`) and nothing
    ///      else writes either field.
    /// @param seed Unused.
    function property_watchdogStampMonotone(uint256 seed) public {
        seed;
        (uint32 blockNumber, uint32 timestamp,) = gate.watchdog();
        gte(uint256(timestamp), uint256(ghosts.maxGateTimestamp), "GL-58: the watchdog timestamp fell");
        lte(uint256(timestamp), block.timestamp, "GL-58: the watchdog timestamp is ahead of the chain");
        ghosts.maxGateTimestamp = timestamp;
        if (block.number <= uint256(type(uint32).max)) {
            gte(uint256(blockNumber), uint256(ghosts.maxGateBlock), "GL-58: the watchdog block fell");
            lte(uint256(blockNumber), block.number, "GL-58: the watchdog block is ahead of the chain");
            ghosts.maxGateBlock = blockNumber;
        }
    }

    /// @notice GL-59: the launch latches never come back down.
    /// @dev SHOULD-HOLD. x-ray I-14 and I-15 (both on-chain: Yes): "`_genesisMinted: false -> true`, one-way …
    ///      there is no reverse path" (`AmpsVault.sol:999`), "`_initialized: false -> true`, one-way"
    ///      (`:1035-1036`). `ghosts.genesisTimestampSeen` is stamped at the end of {Base-setup}.
    /// @return ok Always true.
    function property_launchLatchesHold() public returns (bool ok) {
        t(vault.genesisMinted(), "GL-59: genesisMinted came back down");
        t(vault.initialized(), "GL-59: initialized came back down");
        eq(
            uint256(vault.genesisTimestamp()),
            uint256(ghosts.genesisTimestampSeen),
            "GL-59: the genesis timestamp moved"
        );
        return true;
    }

    /// @notice GL-60: the keeper purse is segregated and self-limiting.
    /// @dev SHOULD-HOLD. Plan I21 ("`BountyPot` excluded from `A`; never pays more than it holds; depleted =>
    ///      unpaid, not reverting"); x-ray I-20 ("no 24-hour interval can pay out more than two ceilings") and E-5.
    /// @param seed Unused.
    function property_theBountyPotIsBounded(uint256 seed) public {
        seed;
        lte(ghosts.potPaidRaw, ghosts.potFundedRaw, "GL-60: the pot paid out more than it was ever funded");
        lte(pot.balance(), _balanceOf(pot.token(), address(pot)), "GL-60: the pot's book is above its own balance");
        lte(pot.spentLast24h(), pot.dailyCeilingUsd18(), "GL-60: spentLast24h above the daily ceiling");
        t(!vault.isAsset(address(pot)), "GL-60: the bounty pot is a valued asset");

        uint256 scale = pot.usdScale();
        if (scale == 0) return;
        uint256 twoCeilingsRaw = 2 * (pot.dailyCeilingUsd18() / scale);
        uint256 window;
        for (uint256 i; i < PAY_RING; ++i) {
            uint32 stamp = ghosts.payRingStamp[i];
            if (stamp == 0) continue;
            if (block.timestamp - uint256(stamp) > uint256(GlobC.ONE_DAY)) continue;
            window += ghosts.payRingAmount[i];
        }
        lte(window, twoCeilingsRaw + 1, "GL-60: a rolling day paid out more than two daily ceilings");
    }

    /// @notice GL-61: no transient lock is ever left armed — a fresh permissionless entry point never reverts
    ///         `Reentrancy`.
    /// @dev EXPLORATORY. The Medusa-safe shape: `vm.snapshotState`/`vm.revertToState` are not implemented in
    ///      Medusa 1.5.1, so the call is made for real and the assertion is on the `catch` arm, discriminating on
    ///      the selector so that a legitimate refusal is not read as a stuck lock.
    /// @param seed Unused.
    function property_noStuckTransientLock(uint256 seed) public {
        seed;
        try vault.checkpoint() returns (GlobCheckpoint memory) {}
        catch (bytes memory reason) {
            ghosts.livenessReverts[keccak256("GL-61:checkpoint")] += 1;
            t(!_isReentrancy(reason), "GL-61: vault.checkpoint() reverted Reentrancy from a fresh transaction");
        }
    }

    /// @notice GL-62: narrow storage types never brick the protocol.
    /// @dev EXPLORATORY. `checkpoint()` is called for real and a **panic** — not any revert — is what fails the
    ///      property: a narrow cast that overflows raises `Panic(0x11)`, while a legitimate refusal is an ordinary
    ///      revert and is recorded rather than asserted on.
    /// @param seed Unused.
    function property_narrowTypesDoNotBrick(uint256 seed) public {
        seed;
        uint256 nav = vault.previewNavPerShareX18();
        lt(nav, uint256(type(uint128).max), "GL-62: NAV/share no longer fits uint128");
        if (nav > ghosts.maxNavPerShareSeen) ghosts.maxNavPerShareSeen = nav;

        uint256 refPrice = vault.pRefX18();
        lt(refPrice, uint256(type(uint128).max), "GL-62: pRef no longer fits uint128");
        if (refPrice > ghosts.maxPRefSeen) ghosts.maxPRefSeen = refPrice;

        for (uint256 i; i < marketIds.length; ++i) {
            lt(
                uint256(_marketTotalIssued(marketIds[i])),
                uint256(type(uint128).max),
                "GL-62: a market's totalIssued is at its uint128 ceiling"
            );
        }
        lt(pot.spentLast24h(), uint256(type(uint128).max), "GL-62: the pot's window no longer fits uint128");

        try vault.checkpoint() returns (GlobCheckpoint memory) {}
        catch Panic(uint256 code) {
            code;
            t(false, "GL-62: checkpoint() panicked, which is a narrow cast that no longer fits");
        } catch {
            ghosts.livenessReverts[keccak256("GL-62:checkpoint")] += 1;
        }
    }

    /// @notice GL-63: no privilege escalation — every role-gated selector refuses a call from an ordinary actor.
    /// @dev SHOULD-HOLD. x-ray guards G-3 (`AmpsVault.sol:372`), G-4 (`:939`), G-10 (`:1057`), G-16 (`:1320`),
    ///      G-19 (`:1402`), G-40 (`Amps.sol:34`); X-6 and X-8.
    /// @dev Every probe is a raw `call` behind a single-shot `vm.prank`, so a refusal is an ordinary `false` rather
    ///      than a revert that would abort the property before it reached the next selector.
    /// @param seed Chooses which actor does the calling.
    function property_noPrivilegeEscalation(uint256 seed) public {
        address caller = actors[seed % actors.length];
        uint256 accepted;

        accepted += _accepted(caller, address(vault), abi.encodeWithSignature("setRedeemFeeBps(uint16)", uint16(1)));
        accepted += _accepted(
            caller, address(vault), abi.encodeWithSignature("mintVesting(address,uint256)", caller, uint256(1))
        );
        accepted += _accepted(
            caller,
            address(vault),
            abi.encodeWithSignature("place(bytes32,bool,uint256)", GlobPoolId.unwrap(poolFrom(seed)), true, uint256(1))
        );
        accepted += _accepted(caller, address(vault), abi.encodeWithSignature("withdrawRetiredBids(uint16)", uint16(1)));
        accepted += _accepted(caller, address(vault), abi.encodeWithSignature("emergencyMigrate(address)", caller));
        accepted += _accepted(caller, address(vault), abi.encodeWithSignature("unlockCallback(bytes)", bytes("")));
        accepted += _accepted(
            caller, address(amps), abi.encodeWithSignature("mint(address,uint256)", caller, uint256(1))
        );
        accepted += _accepted(
            caller, address(amps), abi.encodeWithSignature("burn(address,uint256)", caller, uint256(1))
        );
        accepted += _accepted(caller, address(amps), abi.encodeWithSignature("setVault(address)", caller));
        accepted += _accepted(caller, address(hook), abi.encodeWithSignature("setAmpsFeeBps(uint16)", uint16(200)));
        accepted += _accepted(
            caller, address(hook), abi.encodeWithSignature("resetHighWater(bytes32)", GlobPoolId.unwrap(poolFrom(seed)))
        );
        accepted += _accepted(
            caller, address(registry), abi.encodeWithSignature("retireConstituent(uint16)", uint16(1))
        );
        accepted += _accepted(
            caller, address(gate), abi.encodeWithSignature("freezeProtocol(uint32)", uint32(block.timestamp + 60))
        );
        accepted += _accepted(caller, address(gate), abi.encodeWithSignature("setGraceSeconds(uint32)", uint32(3600)));
        accepted += _accepted(caller, address(bonds), abi.encodeWithSignature("setDailyCapBps(uint16)", uint16(1)));
        accepted += _accepted(
            caller,
            address(pot),
            abi.encodeWithSignature("pay(address,uint256,uint256)", caller, uint256(0), uint256(0))
        );
        accepted += _accepted(
            caller, address(pot), abi.encodeWithSignature("sweep(address,uint256)", caller, uint256(1))
        );
        accepted += _accepted(
            caller, address(feeds), abi.encodeWithSignature("setConfirmSeconds(uint32)", uint32(3600))
        );
        accepted += _accepted(caller, address(ampsRouter), abi.encodeWithSignature("unlockCallback(bytes)", bytes("")));

        if (accepted != 0) ghosts.livenessReverts[keccak256("GL-63:privileged")] += accepted;
        eq(accepted, 0, "GL-63: a role-gated selector accepted a call from an ordinary actor");
    }

    /// @notice GL-64: `PriceLib`'s USD-value / raw-amount pair round trips in the protocol's favour.
    /// @dev SHOULD-HOLD. Closed form: `counterAmountFromUsd18(v) = ceil(v*S/P)` and
    ///      `counterValueUsd18(r) = floor(r*P/S)`, so `floor(ceil(v*S/P)*P/S) >= v` and
    ///      `ceil(floor(r*P/S)*S/P) <= r`. Plan I20 and the two functions' own rounding NatSpec.
    /// @param seed Chooses the decimals, the price and the two magnitudes.
    function property_priceLibUsdRawRoundTrip(uint256 seed) public {
        uint8 decimals = uint8(clampBetween(seed, 0, 18));
        uint256 priceUsd8 = clampBetween(seed >> 8, 1, 1e14);
        uint256 value = clampBetween(seed >> 40, 0, 1e30);
        uint256 raw = clampBetween(seed >> 80, 0, 1e30);

        uint256 required = GlobPriceLib.counterAmountFromUsd18(value, decimals, priceUsd8);
        gte(
            GlobPriceLib.counterValueUsd18(required, decimals, priceUsd8),
            value,
            "GL-64: cover-then-value under-covers the value it was asked to cover"
        );

        uint256 valued = GlobPriceLib.counterValueUsd18(raw, decimals, priceUsd8);
        lte(
            GlobPriceLib.counterAmountFromUsd18(valued, decimals, priceUsd8),
            raw,
            "GL-64: value-then-cover asks for more than the balance it valued"
        );
    }

    /// @notice GL-65: the USD-price / v4-price conversion round trips to within one tick, in `PriceLib` and across
    ///         the `GatePriceMath` boundary the gate actually uses.
    /// @dev SHOULD-HOLD. Plan I20 ("`PriceLib` round trips within 1 tick; rounding always favours the protocol");
    ///      the forward leg "Rounds **up** … so a ladder anchored here never sells AMPS below its reference price",
    ///      the reverse "Rounds **down**".
    /// @dev Stated as a two-sided band rather than as "never recovers a price above the one that produced it":
    ///      the forward leg rounds the *sqrt price* up, so the recovered price can legitimately sit one ulp above
    ///      the input. The band is what the plan's "within 1 tick" actually claims.
    /// @param seed Chooses the decimals, the counter price and the AMPS price.
    function property_priceLibSqrtRoundTrip(uint256 seed) public {
        uint8 decimals = uint8(clampBetween(seed, 6, 18));
        uint256 counterPriceUsd8 = clampBetween(seed >> 8, 1e6, 1e12);
        uint256 ampsPriceUsd18 = clampBetween(seed >> 40, 1e12, 1e24);

        uint160 sqrtPriceX96 =
            GlobPriceLib.ampsPerCounterToSqrtPriceX96OrZero(ampsPriceUsd18, counterPriceUsd8, decimals);
        if (sqrtPriceX96 == 0) return;
        uint256 back = GlobPriceLib.sqrtPriceX96ToAmpsPriceUsd18(sqrtPriceX96, counterPriceUsd8, decimals);
        uint256 band = ampsPriceUsd18 / 10_000 + 1;
        lte(back, ampsPriceUsd18 + band, "GL-65: the sqrt-price round trip recovered a price a tick too high");
        gte(back + band, ampsPriceUsd18, "GL-65: the sqrt-price round trip lost more than a tick");

        // The `GatePriceMath` boundary, exercised through the exact code it forwards to: `GatePriceMath.fairTick`
        // is `return PriceLib.fairTick(...)` and `GatePriceMath.ampsPriceUsd18` is
        // `PriceLib.sqrtPriceX96ToAmpsPriceUsd18(PriceLib.tickToSqrtPriceX96(tick), ...)`. Compared in *tick* space
        // rather than in price space, because `alignTick` clamps into the usable range and a clamped tick's price
        // is not within any band of the input — the claim is "within one tick", and that is what this measures.
        int24 spacing = 60;
        int24 raw = GlobPriceLib.sqrtPriceX96ToTick(sqrtPriceX96);
        int24 fair = GlobPriceLib.fairTick(ampsPriceUsd18, counterPriceUsd8, decimals, spacing);
        lte(int256(fair), int256(raw) + int256(spacing), "GL-65: the fair tick sits more than one spacing above");
        gte(int256(fair) + int256(spacing), int256(raw), "GL-65: the fair tick sits more than one spacing below");
    }

    /// @notice GL-66: `tick -> sqrtPrice -> tick` is the identity, and `alignTick` is idempotent and directional.
    /// @dev SHOULD-HOLD. `tickToSqrtPriceX96` "Exact for every tick in range"; `sqrtPriceX96ToTick` "Rounds **down**
    ///      by construction: returns the greatest tick whose sqrt price is `<= sqrtPriceX96`"; `alignTick`'s NatSpec
    ///      on the floor/ceil pair and the usable-range clamp.
    /// @param seed Chooses the tick and the spacing.
    function property_tickRoundTripAndAlign(uint256 seed) public {
        int24 tick = int24(int256(clampBetween(seed, 0, 1_774_000)) - 887_000);
        eq(
            int256(GlobPriceLib.sqrtPriceX96ToTick(GlobPriceLib.tickToSqrtPriceX96(tick))),
            int256(tick),
            "GL-66: tick -> sqrtPrice -> tick is not the identity"
        );

        int24 spacing = int24(int256(clampBetween(seed >> 32, 1, 200)));
        int24 down = GlobPriceLib.alignTick(tick, spacing, false);
        int24 up = GlobPriceLib.alignTick(tick, spacing, true);
        lte(int256(down), int256(up), "GL-66: alignTick's floor is above its ceiling");
        eq(int256(down) % int256(spacing), int256(0), "GL-66: alignTick's floor is off the spacing");
        eq(int256(up) % int256(spacing), int256(0), "GL-66: alignTick's ceiling is off the spacing");
        eq(int256(GlobPriceLib.alignTick(down, spacing, false)), int256(down), "GL-66: alignTick is not idempotent");
        eq(int256(GlobPriceLib.alignTick(up, spacing, true)), int256(up), "GL-66: alignTick is not idempotent");
    }

    /// @notice GL-67: `LadderLib`'s amount / liquidity pair never gives back more than it was given, on the AMPS
    ///         side and on the counter side alike.
    /// @dev SHOULD-HOLD. `LadderLib` header: "Every amount/liquidity conversion rounds **down**, so a placed
    ///      position never claims more inventory than the vault holds and a valuation never overstates what a
    ///      position contains".
    /// @param seed Chooses the range and the two amounts.
    function property_ladderAmountLiquidityRoundTrip(uint256 seed) public {
        int24 spacing = 60;
        int24 width = GlobLadderLib.doublingTicks(spacing);
        int24 lowerTick = int24(int256(clampBetween(seed, 0, 400_000)) - 200_000);
        lowerTick = GlobPriceLib.alignTick(lowerTick, spacing, false);
        int24 upperTick = lowerTick + width;

        uint160 sqrtLower = GlobPriceLib.tickToSqrtPriceX96(lowerTick);
        uint160 sqrtUpper = GlobPriceLib.tickToSqrtPriceX96(upperTick);

        uint256 amount0 = clampBetween(seed >> 32, 1, 1e27);
        uint128 liquidity0 = GlobLadderLib.liquidityForAmount0Above(sqrtLower, sqrtUpper, amount0);
        lte(
            GlobLadderLib.amount0ForLiquidity(sqrtLower, sqrtUpper, liquidity0),
            amount0,
            "GL-67: the AMPS leg gave back more than it was given"
        );

        uint256 amount1 = clampBetween(seed >> 96, 1, 1e27);
        uint128 liquidity1 = GlobLadderLib.liquidityForAmount1Below(sqrtLower, sqrtUpper, amount1);
        lte(
            GlobLadderLib.amount1ForLiquidity(sqrtLower, sqrtUpper, liquidity1),
            amount1,
            "GL-67: the counter leg gave back more than it was given"
        );
    }

    /// @notice GL-68: `LadderLib`'s weight/split pair loses nothing.
    /// @dev SHOULD-HOLD. `LadderLib.weights` ("the last element absorbs the residue so the vector sums to `WAD`
    ///      **exactly**"); `split` ("the last takes the remainder, so `sum(out) == amount` with no dust left
    ///      behind"); plan I34.
    /// @param seed Chooses the tilt, the bucket count and the amount.
    function property_ladderSplitIsExact(uint256 seed) public {
        uint256 tiltX18 = clampBetween(seed, uint256(GlobC.LADDER_TILT_X18_MIN), uint256(GlobC.LADDER_TILT_X18_MAX));
        uint8 n = uint8(clampBetween(seed >> 32, 2, 14));

        uint256[] memory weights = GlobLadderLib.weights(tiltX18, n);
        uint256 weightSum;
        for (uint256 i; i < weights.length; ++i) {
            weightSum += weights[i];
            if (i != 0) gte(weights[i], weights[i - 1], "GL-68: the weight vector is not monotone in k");
        }
        eq(weightSum, GlobC.WAD, "GL-68: the weight vector does not sum to WAD exactly");

        uint256 amount = clampBetween(seed >> 64, 0, 1e30);
        uint256[] memory parts = GlobLadderLib.split(amount, weights);
        uint256 partsSum;
        for (uint256 i; i < parts.length; ++i) {
            partsSum += parts[i];
        }
        eq(partsSum, amount, "GL-68: split lost dust");
    }

    /// @notice GL-69: `HookStateLib`'s pack/unpack pairs are exact inverses for in-band field values, signed
    ///         `int24`s included.
    /// @dev EXPLORATORY.
    /// @param seed Chooses every field.
    function property_hookStatePackRoundTrip(uint256 seed) public {
        GlobHookState.Dynamic memory dynamicIn;
        dynamicIn.lastTick = _fuzzTick(seed);
        dynamicIn.lastUpdate = uint32(clampBetween(seed >> 24, 0, uint256(type(uint32).max)));
        dynamicIn.fairTick = _fuzzTick(seed >> 56);
        dynamicIn.innerBandTicks = _fuzzTick(seed >> 88);
        dynamicIn.outerRailTicks = _fuzzTick(seed >> 120);
        dynamicIn.dynCapBps = uint16(clampBetween(seed >> 152, 0, uint256(type(uint16).max)));
        dynamicIn.session = GlobSession(uint8(clampBetween(seed >> 168, 0, 3)));
        dynamicIn.gateFlags = uint8(clampBetween(seed >> 176, 0, 255));
        dynamicIn.fVolBps = uint8(clampBetween(seed >> 184, 0, 255));
        dynamicIn.gateRefreshedAt = uint32(clampBetween(seed >> 192, 0, uint256(type(uint32).max)));
        dynamicIn.gateAttemptedAt = uint32(clampBetween(seed >> 216, 0, uint256(type(uint32).max)));

        GlobHookState.Dynamic memory dynamicOut = GlobHookState.unpackDynamic(GlobHookState.packDynamic(dynamicIn));
        eq(int256(dynamicOut.lastTick), int256(dynamicIn.lastTick), "GL-69: DYNAMIC lastTick did not round trip");
        eq(
            uint256(dynamicOut.lastUpdate),
            uint256(dynamicIn.lastUpdate),
            "GL-69: DYNAMIC lastUpdate did not round trip"
        );
        eq(int256(dynamicOut.fairTick), int256(dynamicIn.fairTick), "GL-69: DYNAMIC fairTick did not round trip");
        eq(
            int256(dynamicOut.innerBandTicks),
            int256(dynamicIn.innerBandTicks),
            "GL-69: DYNAMIC innerBandTicks did not round trip"
        );
        eq(
            int256(dynamicOut.outerRailTicks),
            int256(dynamicIn.outerRailTicks),
            "GL-69: DYNAMIC outerRailTicks did not round trip"
        );
        eq(uint256(dynamicOut.dynCapBps), uint256(dynamicIn.dynCapBps), "GL-69: DYNAMIC dynCapBps did not round trip");
        eq(uint256(dynamicOut.session), uint256(dynamicIn.session), "GL-69: DYNAMIC session did not round trip");
        eq(uint256(dynamicOut.gateFlags), uint256(dynamicIn.gateFlags), "GL-69: DYNAMIC gateFlags did not round trip");
        eq(uint256(dynamicOut.fVolBps), uint256(dynamicIn.fVolBps), "GL-69: DYNAMIC fVolBps did not round trip");
        eq(
            uint256(dynamicOut.gateRefreshedAt),
            uint256(dynamicIn.gateRefreshedAt),
            "GL-69: DYNAMIC gateRefreshedAt did not round trip"
        );
        eq(
            uint256(dynamicOut.gateAttemptedAt),
            uint256(dynamicIn.gateAttemptedAt),
            "GL-69: DYNAMIC gateAttemptedAt did not round trip"
        );

        GlobHookState.Armed memory armedIn;
        armedIn.surgeBps = uint16(clampBetween(seed >> 8, 0, uint256(type(uint16).max)));
        armedIn.surgeArmedAt = uint32(clampBetween(seed >> 32, 0, uint256(type(uint32).max)));
        armedIn.captureFeeBps = uint16(clampBetween(seed >> 64, 0, uint256(type(uint16).max)));
        armedIn.captureArmedAt = uint32(clampBetween(seed >> 96, 0, uint256(type(uint32).max)));
        armedIn.uiMultiplierX9 = uint64(clampBetween(seed >> 128, 0, uint256(type(uint64).max)));
        armedIn.varianceX12 = uint64(clampBetween(seed >> 160, 0, uint256(type(uint64).max)));
        armedIn.lastCorporateCheck = uint32(clampBetween(seed >> 200, 0, uint256(type(uint32).max)));

        GlobHookState.Armed memory armedOut = GlobHookState.unpackArmed(GlobHookState.packArmed(armedIn));
        eq(uint256(armedOut.surgeBps), uint256(armedIn.surgeBps), "GL-69: ARMED surgeBps did not round trip");
        eq(
            uint256(armedOut.surgeArmedAt),
            uint256(armedIn.surgeArmedAt),
            "GL-69: ARMED surgeArmedAt did not round trip"
        );
        eq(
            uint256(armedOut.captureFeeBps),
            uint256(armedIn.captureFeeBps),
            "GL-69: ARMED captureFeeBps did not round trip"
        );
        eq(
            uint256(armedOut.captureArmedAt),
            uint256(armedIn.captureArmedAt),
            "GL-69: ARMED captureArmedAt did not round trip"
        );
        eq(
            uint256(armedOut.uiMultiplierX9),
            uint256(armedIn.uiMultiplierX9),
            "GL-69: ARMED uiMultiplierX9 did not round trip"
        );
        eq(uint256(armedOut.varianceX12), uint256(armedIn.varianceX12), "GL-69: ARMED varianceX12 did not round trip");
        eq(
            uint256(armedOut.lastCorporateCheck),
            uint256(armedIn.lastCorporateCheck),
            "GL-69: ARMED lastCorporateCheck did not round trip"
        );
    }

    /// @notice GL-70: each `PriceLib` value/amount conversion rounds in its documented direction and is monotone
    ///         in its input.
    /// @dev SHOULD-HOLD. `PriceLib` header: "values *of* protocol assets round **down** → NAV is never overstated
    ///      … counter amounts *required* round **up** → the protocol never accepts less than it is owed". Plan I20.
    ///      The two sqrt-price legs of the same header are GL-65's; this one covers the USD pair.
    /// @param seed Chooses the decimals, the price and the four magnitudes.
    function property_priceLibDirections(uint256 seed) public {
        uint8 decimals = uint8(clampBetween(seed, 0, 18));
        uint256 priceUsd8 = clampBetween(seed >> 8, 1, 1e14);

        uint256 rawSmall = clampBetween(seed >> 40, 0, 1e28);
        uint256 rawLarge = clampBetween(seed >> 72, rawSmall, 1e28);
        lte(
            GlobPriceLib.counterValueUsd18(rawSmall, decimals, priceUsd8),
            GlobPriceLib.counterValueUsd18(rawLarge, decimals, priceUsd8),
            "GL-70: counterValueUsd18 is not monotone in the amount"
        );

        uint256 valueSmall = clampBetween(seed >> 104, 0, 1e28);
        uint256 valueLarge = clampBetween(seed >> 136, valueSmall, 1e28);
        lte(
            GlobPriceLib.counterAmountFromUsd18(valueSmall, decimals, priceUsd8),
            GlobPriceLib.counterAmountFromUsd18(valueLarge, decimals, priceUsd8),
            "GL-70: counterAmountFromUsd18 is not monotone in the value"
        );

        // The value rounds down: re-covering it never asks for more than the balance it was measured on.
        uint256 valued = GlobPriceLib.counterValueUsd18(rawSmall, decimals, priceUsd8);
        lte(
            GlobPriceLib.counterAmountFromUsd18(valued, decimals, priceUsd8),
            rawSmall,
            "GL-70: the required amount did not round in the protocol's favour"
        );
        // The required amount rounds up: valuing it never reports less than the value it was asked to cover.
        gte(
            GlobPriceLib.counterValueUsd18(
                GlobPriceLib.counterAmountFromUsd18(valueSmall, decimals, priceUsd8), decimals, priceUsd8
            ),
            valueSmall,
            "GL-70: the value leg did not round in the protocol's favour"
        );
    }

    /// @notice GL-71: the two independent implementations of the bond accretion floor agree exactly, and the floor
    ///         is anti-monotone in both the haircut and the demanded accretion.
    /// @dev SHOULD-HOLD. x-ray I-10: the floor is "**computed twice independently** … Rounding directions are
    ///      numerator down, denominator up, quotient down in both. **If violated** — … a policy swap becomes an
    ///      issuance decision". `BondPolicy.qFloorX18` is `public pure` "so a reviewer can diff the two
    ///      implementations against one call"; {_shellQFloorX18} is `AmpsBonds._qFloorX18`'s body verbatim, which is
    ///      the copy the shell actually prices with and which no external call can reach.
    /// @param seed Chooses the price, the NAV, the haircut and the accretion.
    function property_qFloorImplementationsAgree(uint256 seed) public {
        uint256 collateralPriceUsd18 = clampBetween(seed, 0, 1e30);
        uint256 navPerShareX18 = clampBetween(seed >> 32, 1, 1e30);
        uint16 haircutBps = uint16(clampBetween(seed >> 64, 0, uint256(GlobC.H_SESSION_BPS_MAX)));
        uint16 accretionBps = uint16(clampBetween(seed >> 96, 0, uint256(GlobC.MIN_ACCRETION_BPS_MAX)));

        uint256 policyFloor = bondPolicy.qFloorX18(collateralPriceUsd18, navPerShareX18, haircutBps, accretionBps);
        eq(
            policyFloor,
            _shellQFloorX18(collateralPriceUsd18, navPerShareX18, haircutBps, accretionBps),
            "GL-71: the policy's accretion floor and the shell's disagree"
        );

        if (haircutBps < GlobC.H_SESSION_BPS_MAX) {
            lte(
                bondPolicy.qFloorX18(collateralPriceUsd18, navPerShareX18, haircutBps + 1, accretionBps),
                policyFloor,
                "GL-71: the accretion floor rose with the haircut"
            );
        }
        if (accretionBps < GlobC.MIN_ACCRETION_BPS_MAX) {
            lte(
                bondPolicy.qFloorX18(collateralPriceUsd18, navPerShareX18, haircutBps, accretionBps + 1),
                policyFloor,
                "GL-71: the accretion floor rose with the demanded accretion"
            );
        }
    }

    /// @notice GL-72: ladder cell geometry is contiguous and the anchor residue is bounded.
    /// @dev SHOULD-HOLD. `LadderLib.bucketBounds` NatSpec ("Buckets are contiguous and non-overlapping by
    ///      construction (`upper_k == lower_{k+1}` above, `lower_k == upper_{k+1}` below)"); ruling AX (fix-log
    ///      wave 2, `test_i32_theStraddleOfTheFirstAskCellIsBoundedByOneTickSpacing`); plan I34.
    /// @param seed Chooses the spacing, the anchor and the bucket count.
    function property_ladderGeometryIsContiguous(uint256 seed) public {
        int24 spacing = int24(int256(clampBetween(seed, 1, 200)));
        int24 anchorTick = int24(int256(clampBetween(seed >> 32, 0, 400_000)) - 200_000);
        uint8 n = uint8(clampBetween(seed >> 64, 2, 14));

        int24 width = GlobLadderLib.doublingTicks(spacing);
        gte(int256(width), int256(spacing), "GL-72: a doubling is narrower than the spacing");
        eq(int256(width) % int256(spacing), int256(0), "GL-72: a doubling is not a whole number of spacings");

        (int24 askLower, int24 askUpper) = GlobLadderLib.bucketBounds(anchorTick, spacing, 0, true);
        gte(int256(askLower), int256(anchorTick), "GL-72: the first ask cell opens below the anchor");
        lt(
            int256(askLower) - int256(anchorTick),
            int256(spacing),
            "GL-72: the first ask cell straddles the anchor by a whole spacing or more"
        );
        for (uint8 k = 1; k < n; ++k) {
            (int24 lowerTick, int24 upperTick) = GlobLadderLib.bucketBounds(anchorTick, spacing, k, true);
            eq(int256(lowerTick), int256(askUpper), "GL-72: the ask buckets are not contiguous");
            eq(int256(lowerTick) % int256(spacing), int256(0), "GL-72: an ask bound is off the spacing");
            askUpper = upperTick;
        }

        (int24 bidLower, int24 bidUpper) = GlobLadderLib.bucketBounds(anchorTick, spacing, 0, false);
        lte(int256(bidUpper), int256(anchorTick), "GL-72: the first bid cell closes above the anchor");
        lt(
            int256(anchorTick) - int256(bidUpper),
            int256(spacing),
            "GL-72: the first bid cell straddles the anchor by a whole spacing or more"
        );
        for (uint8 k = 1; k < n; ++k) {
            (int24 lowerTick, int24 upperTick) = GlobLadderLib.bucketBounds(anchorTick, spacing, k, false);
            eq(int256(upperTick), int256(bidLower), "GL-72: the bid buckets are not contiguous");
            eq(int256(upperTick) % int256(spacing), int256(0), "GL-72: a bid bound is off the spacing");
            bidLower = lowerTick;
        }
    }

    /// @notice GL-73: `BondPolicy.discountBps` stays inside `[dMin, dMax]`, is non-decreasing in the deficit and
    ///         non-increasing in the fill.
    /// @dev SHOULD-HOLD. x-ray I-12 ("Bond discount `d in [dMinBps, dMaxBps]` … The policy clamps to the same pair
    ///      at `BondPolicy.sol:86-87`"); the header rounding table.
    /// @param seed Chooses every input.
    function property_discountIsBandedAndMonotone(uint256 seed) public {
        uint16 dMinBps = uint16(clampBetween(seed, uint256(GlobC.DISCOUNT_BPS_MIN), uint256(GlobC.DISCOUNT_BPS_MAX)));
        uint16 dMaxBps = uint16(clampBetween(seed >> 16, uint256(dMinBps), uint256(GlobC.DISCOUNT_BPS_MAX)));
        uint16 dBaseBps =
            uint16(clampBetween(seed >> 32, uint256(GlobC.DISCOUNT_BPS_MIN), uint256(GlobC.DISCOUNT_BPS_MAX)));
        uint64 kWeightX18 = uint64(clampBetween(seed >> 48, 0, uint256(GlobC.BOND_COEFFICIENT_X18_MAX)));
        uint64 kFillX18 = uint64(clampBetween(seed >> 80, 0, uint256(GlobC.BOND_COEFFICIENT_X18_MAX)));
        uint64 deficitX18 = uint64(clampBetween(seed >> 112, 0, GlobC.WAD));
        uint64 fillX18 = uint64(clampBetween(seed >> 144, 0, GlobC.WAD));

        uint16 d = bondPolicy.discountBps(dBaseBps, dMinBps, dMaxBps, kWeightX18, kFillX18, deficitX18, fillX18);
        gte(uint256(d), uint256(dMinBps), "GL-73: the discount fell below dMin");
        lte(uint256(d), uint256(dMaxBps), "GL-73: the discount rose above dMax");

        if (deficitX18 < GlobC.WAD) {
            uint16 wider =
                bondPolicy.discountBps(dBaseBps, dMinBps, dMaxBps, kWeightX18, kFillX18, uint64(GlobC.WAD), fillX18);
            gte(uint256(wider), uint256(d), "GL-73: the discount fell as the index deficit grew");
        }
        if (fillX18 < GlobC.WAD) {
            uint16 fuller =
                bondPolicy.discountBps(dBaseBps, dMinBps, dMaxBps, kWeightX18, kFillX18, deficitX18, uint64(GlobC.WAD));
            lte(uint256(fuller), uint256(d), "GL-73: the discount rose as the epoch filled");
        }
    }

    /// @notice GL-74: zero inputs are safe on every conversion.
    /// @dev SHOULD-HOLD. Explicit guards: `if (shares == 0) revert ZeroAmount();` (`AmpsVault.sol:842`),
    ///      `if (amountIn == 0) revert ZeroAmount();` (`AmpsBonds.sol:367`),
    ///      `if (supply == 0 || shares == 0) return …` (`VaultRedeemLib.previewUnwind:831`), `BountyPot._quote`'s
    ///      chost branch.
    /// @param seed Chooses the market probed.
    function property_zeroInputsAreSafe(uint256 seed) public {
        (, uint256[] memory amounts, uint256 inventoryBurned) = vault.previewRedeem(0);
        for (uint256 i; i < amounts.length; ++i) {
            eq(amounts[i], 0, "GL-74: previewRedeem(0) pays something");
        }
        eq(inventoryBurned, 0, "GL-74: previewRedeem(0) burns inventory");

        vm.prank(actor);
        (bool ok,) = address(vault).call(abi.encodeWithSignature("redeemProRata(uint256,address)", uint256(0), actor));
        t(!ok, "GL-74: redeemProRata(0) did not revert");

        uint16 marketId = marketFrom(seed);
        vm.prank(actor);
        (ok,) = address(bonds)
            .call(
                abi.encodeWithSignature("bond(uint16,uint256,uint256,address)", marketId, uint256(0), uint256(0), actor)
            );
        t(!ok, "GL-74: bond(m, 0, ...) did not revert");

        (uint256 quoted,,,,,) = _bondQuote(marketId, 0);
        eq(quoted, 0, "GL-74: quote(m, 0) is non-zero");

        (uint256 payableRaw,) = pot.quote(0, 0);
        eq(payableRaw, 0, "GL-74: pot.quote(0, 0) would pay something");

        uint256[] memory parts = GlobLadderLib.split(0, GlobLadderLib.weights(GlobC.WAD, 4));
        for (uint256 i; i < parts.length; ++i) {
            eq(parts[i], 0, "GL-74: split(0, w) is non-zero");
        }
    }

    /// @notice GL-75: the fee the hook returns is `base + dyn` clamped into `[F_MIN_BPS, TOTAL_FEE_BPS_MAX]`, is a
    ///         whole number of basis points in pips, and never reaches `MAX_LP_FEE`.
    /// @dev SHOULD-HOLD. Plan I16 ("Returned fee = `base + dyn` … `dyn <= dynCap_state`, total <= `MAX_LP_FEE`");
    ///      `Constants.sol:459-461` ("The highest total fee the hook can ever return … far below `MAX_LP_FEE`,
    ///      which is what invariant I16 asserts"). Read through `AmpsQuoter.quoteExactIn`, which reports the fee the
    ///      hook itself would charge.
    /// @param seed Chooses the pool, the direction and the size.
    function property_hookFeeIsWithinI16(uint256 seed) public {
        GlobPoolId poolId = poolFrom(seed);
        bool zeroForOne = seed % 2 == 0;
        uint256 amountIn =
            zeroForOne ? clampBetween(seed >> 8, 1e12, 1e20) : counterUnit(poolId) * clampBetween(seed >> 8, 1, 20);

        (, uint24 feePips,,) = quoter.quoteExactIn(poolId, zeroForOne, amountIn);
        if (feePips == 0) return;
        eq(uint256(feePips) % uint256(GlobC.PIPS_PER_BPS), 0, "GL-75: the fee is not a whole number of basis points");
        uint256 bps = uint256(feePips) / uint256(GlobC.PIPS_PER_BPS);
        gte(bps, uint256(GlobC.F_MIN_BPS), "GL-75: the fee is below F_MIN_BPS");
        lte(bps, uint256(GlobC.TOTAL_FEE_BPS_MAX), "GL-75: the fee is above TOTAL_FEE_BPS_MAX");
        lt(uint256(feePips), uint256(GlobC.MAX_LP_FEE), "GL-75: the fee reached MAX_LP_FEE");
    }

    /// @notice GL-76: the credit blend never rounds a fee down in the swapper's favour.
    /// @dev SHOULD-HOLD. `AmpsHook._quote` on the blend: "Rounded up, so a credit never rounds a fee down in the
    ///      swapper's favour. `mulDivRoundingUp` carries the 512-bit intermediate…". Plan I16 rev-6/7.
    /// @dev The dynamic part of the fee does not depend on the credit, so the *difference* between the uncredited
    ///      and the fully credited quote is exactly the base spread — stated as an upper bound rather than an
    ///      equality because the total is clamped into `[F_MIN_BPS, TOTAL_FEE_BPS_MAX]` and a clamp can absorb part
    ///      of the spread.
    /// @param seed Chooses the pool and the size.
    function property_blendedBaseNeverRoundsDown(uint256 seed) public {
        GlobPoolId poolId = poolFrom(seed);
        uint256 ampsIn = clampBetween(seed >> 8, 1e12, 1e20);

        (, uint24 uncredited,,) = quoter.quoteSellWithCredit(poolId, ampsIn, 0);
        (, uint24 half,,) = quoter.quoteSellWithCredit(poolId, ampsIn, ampsIn / 2);
        (, uint24 full,,) = quoter.quoteSellWithCredit(poolId, ampsIn, ampsIn);
        if (uncredited == 0) return;

        lte(uint256(half), uint256(uncredited), "GL-76: the fee rose as the credit grew");
        lte(uint256(full), uint256(half), "GL-76: the fee rose as the credit grew");

        uint256 ampsFeeBps = uint256(hook.ampsFeeBps());
        uint256 buyFeeBps = uint256(hook.buyFeeBps(poolId));
        gte(
            uint256(uncredited),
            ampsFeeBps * uint256(GlobC.PIPS_PER_BPS),
            "GL-76: an uncredited sell priced below ampsFeeBps"
        );
        gte(
            uint256(full),
            buyFeeBps * uint256(GlobC.PIPS_PER_BPS),
            "GL-76: a fully credited sell priced below buyFeeBps"
        );
        if (ampsFeeBps >= buyFeeBps) {
            lte(
                uint256(uncredited) - uint256(full),
                (ampsFeeBps - buyFeeBps) * uint256(GlobC.PIPS_PER_BPS),
                "GL-76: the credit blend moved the fee further than the base spread"
            );
        }
    }

    /// @notice GL-77: the quoter and the hook never disagree about executability.
    /// @dev SHOULD-HOLD. Fix-log wave-3 finding 14: "`quoteExactIn`, `quoteSellWithCredit`, `quoteRotation` and
    ///      `wouldRevert` evaluate `afterSwap`'s own rule against it, reading `fairTick` and the *effective*
    ///      `outerRailTicks` from the hook **so the two cannot disagree**".
    /// @dev The converse of the second clause — "executable and `degraded == 0` implies a non-zero output" — is
    ///      asserted only in the direction that cannot be confused with an empty book: a pool with no depth on the
    ///      side being quoted legitimately quotes zero without refusing.
    /// @param seed Chooses the pool, the direction and the size.
    function property_quoterAgreesWithTheHook(uint256 seed) public {
        GlobPoolId poolId = poolFrom(seed);
        bool zeroForOne = seed % 2 == 0;
        uint256 amountIn =
            zeroForOne ? clampBetween(seed >> 8, 1e12, 1e20) : counterUnit(poolId) * clampBetween(seed >> 8, 1, 20);

        (uint256 out,, bool refuse,) = quoter.quoteExactIn(poolId, zeroForOne, amountIn);
        (bool wouldRefuse,,) = quoter.wouldRevert(poolId, zeroForOne, true, amountIn);

        if (refuse) t(wouldRefuse, "GL-77: quoteExactIn refused a route wouldRevert says is fine");
        if (out != 0) t(!refuse, "GL-77: a refused route still quoted an output");
    }

    /// @notice GL-78: execution gets monotonically worse with size and never better than linear.
    /// @dev EXPLORATORY.
    /// @param seed Chooses the pool, the direction and the size.
    function property_priceImpactIsMonotone(uint256 seed) public {
        GlobPoolId poolId = poolFrom(seed);
        bool zeroForOne = seed % 2 == 0;
        uint256 amountIn =
            zeroForOne ? clampBetween(seed >> 8, 1e12, 1e19) : counterUnit(poolId) * clampBetween(seed >> 8, 1, 10);

        (uint256 single,, bool refuseSingle,) = quoter.quoteExactIn(poolId, zeroForOne, amountIn);
        (uint256 doubled,, bool refuseDouble,) = quoter.quoteExactIn(poolId, zeroForOne, 2 * amountIn);
        if (refuseSingle || refuseDouble) return;

        gte(doubled, single, "GL-78: a larger input quoted a smaller output");
        lte(doubled, 2 * single + 2, "GL-78: doubling the input more than doubled the output");
    }

    /// @notice GL-79: `bonds.quote` is monotone non-decreasing in `amountIn` up to the capacity clamp, and the
    ///         `capacityLeft` it reports does not depend on the amount quoted.
    /// @dev SHOULD-HOLD. Closed form: `q` is computed from market state alone and the amount enters only as
    ///      `ampsOut = mulDiv(amountIn18, q, WAD)` plus the `capacityLeft` clamp (`AmpsBonds._quote:855-897`,
    ///      `BondPolicy.quote:67-92`); `mulDiv` by a fixed `q` is monotone and `min(x, cap)` preserves it.
    /// @param seed Chooses the market and the two sizes.
    function property_bondQuoteIsMonotone(uint256 seed) public {
        uint16 marketId = marketFrom(seed);
        uint256 small = clampBetween(seed >> 16, 1, 1e21);
        uint256 large = clampBetween(seed >> 48, small, 1e21);

        (uint256 outSmall,,,, uint256 capacitySmall, bytes32 reasonSmall) = _bondQuote(marketId, small);
        (uint256 outLarge,,,, uint256 capacityLarge, bytes32 reasonLarge) = _bondQuote(marketId, large);
        if (reasonSmall == bytes32("noQuote") || reasonLarge == bytes32("noQuote")) return;

        lte(outSmall, outLarge, "GL-79: a larger deposit quoted less AMPS");
        eq(capacitySmall, capacityLarge, "GL-79: capacityLeft depends on the amount quoted");
    }

    /// @notice GL-80: bid inventory placed into a constituent's pool and later withdrawn comes back at or below
    ///         what went in.
    /// @dev EXPLORATORY. Both legs are ghosts recorded by the placement and withdrawal handlers, so an unrun
    ///      withdrawal reads as zero rather than as a violation.
    /// @param seed Chooses the constituent.
    function property_retiredBidsNeverOverReturn(uint256 seed) public {
        uint16 id = constituentFrom(seed);
        lte(
            ghosts.bidWithdrawnRaw[id],
            ghosts.bidPlacedRaw[id],
            "GL-80: more counter asset came out of a bid ladder than went into it"
        );
    }

    /// @notice GL-81: the valuer never overstates a pool — its counter term stays within what a full unwind of the
    ///         recorded ladder could free, and it is zero when the ladder holds no liquidity.
    /// @dev EXPLORATORY. `bidCounterIn(record)` is the counter a cell holds when the price is at or above its upper
    ///      bound, i.e. the most that cell can ever contain, so the sum over the records is a sound ceiling for the
    ///      valuer's own reading at the reference price.
    /// @param seed Chooses the pool.
    function property_valuerNeverOverstatesAPool(uint256 seed) public {
        GlobPoolId poolId = poolFrom(seed);
        (uint256 ampsSide, uint256 counterSide) = _valuerAmounts(poolId);

        GlobRecord[] memory records = ladderOf(poolId);
        uint256 ceiling;
        uint256 liveLiquidity;
        for (uint256 i; i < records.length; ++i) {
            if (records[i].liquidity == 0) continue;
            liveLiquidity += uint256(records[i].liquidity);
            ceiling += bidCounterIn(records[i]);
        }

        lte(counterSide, ceiling + records.length + 1, "GL-81: the valuer overstates a pool's counter side");
        if (liveLiquidity == 0) {
            eq(counterSide, 0, "GL-81: an empty ladder still values a counter side");
            eq(ampsSide, 0, "GL-81: an empty ladder still values an AMPS side");
        }
    }

    // ―――――――――――――― Helpers the global properties share ――――――――――――――

    /// @dev `market(id).totalIssued`, or zero for a market the shell cannot read.
    function _marketTotalIssued(uint16 marketId) internal view returns (uint128 total) {
        try bonds.market(marketId) returns (GlobMarket memory record) {
            return record.totalIssued;
        } catch {
            return 0;
        }
    }

    /// @dev The four issuance counters of one market, all zero for a market the shell cannot read.
    function _marketCounters(uint16 marketId)
        internal
        view
        returns (uint128 total, uint128 issuedThisEpoch, uint32 epochStart, uint16 capBpsPerEpoch)
    {
        try bonds.market(marketId) returns (GlobMarket memory record) {
            return (record.totalIssued, record.issuedThisEpoch, record.epochStart, record.capBpsPerEpoch);
        } catch {
            return (0, 0, 0, 0);
        }
    }

    /// @dev `bonds.quote`, with `bytes32("noQuote")` as the reason when the shell refuses to answer at all.
    function _bondQuote(uint16 marketId, uint256 amountIn)
        internal
        view
        returns (
            uint256 ampsOut,
            uint256 qX18,
            uint16 discountBps,
            bool floorBinding,
            uint256 capacityLeft,
            bytes32 reason
        )
    {
        try bonds.quote(marketId, amountIn) returns (uint256 a, uint256 b, uint16 c, bool d, uint256 e, bytes32 f) {
            return (a, b, c, d, e, f);
        } catch {
            return (0, 0, 0, false, 0, bytes32("noQuote"));
        }
    }

    /// @dev `bonds.claimable`, zero when the shell cannot answer.
    function _claimable(address owner, uint256 positionId) internal view returns (uint256 amount) {
        try bonds.claimable(owner, positionId) returns (uint256 v) {
            return v;
        } catch {
            return 0;
        }
    }

    /// @dev `bonds.claimableTotal`, zero when the shell cannot answer.
    function _claimableTotal(address owner) internal view returns (uint256 amount) {
        try bonds.claimableTotal(owner) returns (uint256 v) {
            return v;
        } catch {
            return 0;
        }
    }

    /// @dev `bonds.unvestedOf`, zero when the shell cannot answer.
    function _unvestedOf(address owner) internal view returns (uint256 amount) {
        try bonds.unvestedOf(owner) returns (uint256 v) {
            return v;
        } catch {
            return 0;
        }
    }

    /// @dev The bonder a fuzzed seed selects, or the zero address when none has been recorded yet.
    function _bonderFrom(uint256 seed) internal view returns (address owner) {
        uint256 n = ghosts.bonders.length();
        if (n == 0) return address(0);
        return ghosts.bonders.at(seed % n);
    }

    /// @dev `hook.rotationCredit`, zero when the hook cannot answer.
    function _rotationCreditOf(address who) internal view returns (uint256 credit) {
        try hook.rotationCredit(who) returns (uint256 v) {
            return v;
        } catch {
            return 0;
        }
    }

    /// @dev `valuer.amountsOf`, which is documented never to revert but is wrapped anyway.
    function _valuerAmounts(GlobPoolId poolId) internal view returns (uint256 ampsSide, uint256 counterSide) {
        try valuer.amountsOf(poolId) returns (uint256 a, uint256 c) {
            return (a, c);
        } catch {
            return (0, 0);
        }
    }

    /// @dev `FeedRegistry.latestAnswer(token).answerUsd8`, which is the price `VaultNavLib.answer` reads (through a
    ///      gas-bounded `staticcall` to the same selector). Zero when the registry cannot price the token.
    function _latestAnswerUsd8(address token) internal view returns (uint256 answerUsd8) {
        try feeds.latestAnswer(token) returns (uint256 a, uint32, bool) {
            return a;
        } catch {
            return 0;
        }
    }

    /// @dev `VaultNavLib.assetMeta` reimplemented locally: the library's copy is a `public` function on a linked
    ///      library, and depending on a link at the harness level is more fragile than repeating fifteen lines.
    function _assetMeta(address token) internal view returns (uint8 decimals, GlobPoolId poolId, bool hasPool) {
        uint16 id = registry.constituentIdOf(token);
        if (id != 0) {
            GlobConstituent memory config = registry.constituent(id);
            return (config.decimals, registry.poolIdOf(id), true);
        }
        GlobPoolId hub = registry.hubPoolId();
        GlobPoolConfig memory hubConfig = registry.poolConfig(hub);
        if (hubConfig.counter == token) return (hubConfig.counterDecimals, hub, true);

        GlobPoolId wethPoolId = registry.wethPoolId();
        GlobPoolConfig memory wethConfig = registry.poolConfig(wethPoolId);
        if (wethConfig.counter == token) return (wethConfig.counterDecimals, wethPoolId, true);

        return (18, GlobPoolId.wrap(bytes32(0)), false);
    }

    /// @dev `AmpsBonds._qFloorX18`'s body verbatim — the second, private implementation of the accretion floor that
    ///      GL-71 diffs `BondPolicy.qFloorX18` against.
    function _shellQFloorX18(
        uint256 collateralPriceUsd18,
        uint256 navPerShareX18,
        uint16 haircutBps,
        uint16 accretionBps
    ) internal pure returns (uint256 floorX18) {
        if (haircutBps >= GlobC.BPS || navPerShareX18 == 0) return 0;
        uint256 numerator = GlobFullMath.mulDiv(collateralPriceUsd18, GlobC.BPS - haircutBps, GlobC.BPS);
        uint256 denominator =
            GlobFullMath.mulDivRoundingUp(navPerShareX18, GlobC.BPS + uint256(accretionBps), GlobC.BPS);
        floorX18 = GlobFullMath.mulDiv(numerator, GlobC.WAD, denominator);
    }

    /// @dev Whether a revert payload is `Errors.Reentrancy()`.
    function _isReentrancy(bytes memory reason) internal pure returns (bool yes) {
        if (reason.length < 4) return false;
        bytes4 selector;
        assembly {
            selector := mload(add(reason, 0x20))
        }
        return selector == GlobReentrancy.selector;
    }

    /// @dev The most counter asset a pool's recorded ladder could ever free: every cell valued as if the price sat
    ///      at or above its upper bound, which is the maximum that cell can contain.
    function _fullUnwindCounter(GlobPoolId poolId) internal view returns (uint256 amount) {
        GlobRecord[] memory records = ladderOf(poolId);
        for (uint256 i; i < records.length; ++i) {
            if (records[i].liquidity == 0) continue;
            amount += bidCounterIn(records[i]);
        }
    }

    /// @dev Calls `target` as `caller` and returns 1 when the call was **accepted**, which is the count GL-63 is
    ///      asserting to be zero. A raw `call` so that a refusal cannot abort the property.
    function _accepted(address caller, address target, bytes memory payload) internal returns (uint256 accepted) {
        vm.prank(caller);
        (bool ok,) = target.call(payload);
        return ok ? 1 : 0;
    }

    /// @dev A fuzzed tick anywhere in the signed `int24` range, for the pack/unpack round trips.
    function _fuzzTick(uint256 seed) internal returns (int24 tick) {
        return int24(int256(clampBetween(seed, 0, 16_777_215)) - 8_388_608);
    }

    // ───────── SPECIFIC PROPERTIES ─────────
    // These properties must hold after specific function calls.
    // They MUST BE INTERNAL and called at the end of the relevant handlers.
    //
    // **Everything below is measured from values the handler captured itself**, passed in as parameters rather
    // than read out of `Snapshots.State`. Two reasons, both load-bearing:
    //   1. A `vm.prank` is consumed by the *next* external call, view calls included, so a handler has to take its
    //      "before" reads before the prank and its "after" reads after the call — which is exactly a local capture.
    //   2. `Snapshots.sol` belongs to the GLOBAL half of this suite. Parameter passing keeps the two halves from
    //      having to agree on 86 field names to compile.
    // The handlers still call `snapshotBefore()` / `snapshotAfter()` where the wiring plan asks for them.
    //
    // Reads that can revert (`previewNavPerShareX18` behind an unconfirmed NAV, a quote on a closed market) are
    // taken through the `_try*` helpers at the bottom, which answer `0` rather than reverting: a property must
    // never be the reason a handler fails.

    /// @dev What a bond handler observes around `AmpsBonds.bond`. One memory struct rather than twenty locals: the
    ///      legacy pipeline (`via_ir = false`) runs out of stack otherwise.
    struct BondObs {
        uint16 marketId;
        uint32 vestSeconds;
        address to;
        address collateral;
        uint256 amountIn;
        uint256 minAmpsOut;
        uint256 issued;
        uint256 positionId;
        uint256 supplyBefore;
        uint256 supplyAfter;
        uint256 shellAmpsBefore;
        uint256 shellAmpsAfter;
        uint256 bonderCollBefore;
        uint256 bonderCollAfter;
        uint256 vaultHeldBefore;
        uint256 vaultHeldAfter;
        /// @dev The bond shell's balance of the collateral before the call: a donation resting there is forwarded
        ///      to the vault with the next bond (`AmpsBonds._issue`, `CollateralForwarded`).
        uint256 shellCollBefore;
        uint256 shellCollAfter;
        uint256 navBefore;
        uint256 navAfter;
        uint256 countBefore;
        uint256 capacityBefore;
        /// @dev The NAV/share the bond priced against: `checkpointData().navPerShareX18` read after the call, which
        ///      the bond's own `_checkpoint()` stored before `_price` ran (`AmpsBonds.sol:385-388`).
        uint256 navBondBasis;
        /// @dev The collateral's USD price per whole token, X18, from the same `latestAnswer` the shell read
        ///      (`AmpsBonds._collateralPriceUsd18`).
        uint256 collateralPriceUsd18;
        uint8 collateralDecimals;
        uint16 haircutBps;
        uint16 minAccretionBps;
    }

    /// @dev What a claim handler observes around `AmpsBonds.claim` / `claimAll`.
    struct ClaimObs {
        bool single;
        address recipient;
        uint256 paid;
        uint256 supplyBefore;
        uint256 supplyAfter;
        uint256 shellBefore;
        uint256 shellAfter;
        uint256 recipBefore;
        uint256 recipAfter;
        SpecPosition posBefore;
        SpecPosition posAfter;
    }

    /// @dev What a redemption handler observes around `AmpsVault.redeemProRata`.
    struct RedeemObs {
        uint16 feeBps;
        uint256 shares;
        uint256 previewInventoryBurned;
        uint256 supplyBefore;
        uint256 supplyAfter;
        uint256 callerAmpsBefore;
        uint256 callerAmpsAfter;
        uint256 navBefore;
        uint256 navAfter;
        uint256 aBefore;
        uint256 aAfter;
    }

    /// @dev What a placement-class handler observes around `place` / `compound` / `rollout` / `deployBonded` /
    ///      `withdrawRetiredBids`.
    struct PlaceObs {
        bool above;
        uint32 lastPlacementBefore;
        uint32 lastPlacementAfter;
        uint256 placed;
        uint256 navBefore;
        uint256 navAfter;
        uint256 vaultAmpsBefore;
        uint256 vaultAmpsAfter;
        /// @dev The vault guard's fair tick as of the call's entry (`_requireConverged` captures its inputs
        ///      once, so the exit check compares the post-call tick against this, not against a post-call recompute).
        int24 fairBefore;
    }

    /// @dev What a router handler observes around `buy` / `sell` / `rotate`. `payerIn` is the *input* currency on
    ///      the payer, `recipOut` the *output* currency on the recipient — the two are always different tokens on
    ///      every leg this suite drives, which is what makes the deltas separable.
    struct TradeObs {
        address payer;
        address recipient;
        uint256 amountIn;
        uint256 reportedOut;
        uint256 supplyBefore;
        uint256 supplyAfter;
        uint256 payerInBefore;
        uint256 payerInAfter;
        uint256 recipOutBefore;
        uint256 recipOutAfter;
        uint256 pmInBefore;
        uint256 pmInAfter;
        uint256 routerInBefore;
        uint256 routerInAfter;
        /// @dev The router's balance of the *output* asset before and after: whatever it shed went to its caller
        ///      with the trade (`AmpsRouter._sweep`, "swept to `msg.sender` on a best-effort basis").
        uint256 routerOutBefore;
        uint256 routerOutAfter;
        uint256 hookAmps;
    }

    // ――――――――――――――――――――――― Bonds ―――――――――――――――――――――――――

    /// @notice SP-01: `totalSupply` rises by at most the AMPS this call's bond issued, and by zero elsewhere.
    /// @dev SHOULD-HOLD — x-ray X-6 and E-1: `AmpsVault.mintVesting` is the only post-genesis mint site and
    ///      `AmpsBonds.bond` its only caller (G-6, G-40). Every handler passes `issued == 0` except the bond ones.
    /// @param supplyBefore `amps.totalSupply()` before the call.
    /// @param supplyAfter `amps.totalSupply()` after the call.
    /// @param issued The AMPS this call's bond issued, or zero.
    function property_mintAttribution(uint256 supplyBefore, uint256 supplyAfter, uint256 issued) internal {
        lte(supplyAfter, supplyBefore + issued, "SP-01: supply rose by more than this call's bond issued");
    }

    /// @notice SP-02: a bond appends exactly one fully determined position to `to`, and none elsewhere.
    /// @dev SHOULD-HOLD — the struct is written literally, once, with those five fields (`AmpsBonds.sol:411-419`),
    ///      and `positionId` is the pre-push length (`:410`).
    /// @param o The bond observation.
    function property_bondAppendsOnePosition(BondObs memory o) internal {
        eq(bonds.positionCount(o.to), o.countBefore + 1, "SP-02: bond did not append exactly one position");
        eq(o.positionId, o.countBefore, "SP-02: positionId is not the pre-push array length");

        SpecPosition memory p = bonds.position(o.to, o.positionId);
        eq(uint256(p.principal), o.issued, "SP-02: principal is not the ampsOut the bond returned");
        eq(uint256(p.claimed), 0, "SP-02: a fresh position is not unclaimed");
        eq(uint256(p.start), block.timestamp, "SP-02: a fresh position is not stamped now");
        eq(uint256(p.vestSeconds), uint256(o.vestSeconds), "SP-02: vestSeconds is not the value in force at purchase");
        eq(uint256(p.marketId), uint256(o.marketId), "SP-02: marketId is not the market bonded");
    }

    /// @notice SP-03: a bond mints exactly `ampsOut` and every wei of it lands in `AmpsBonds`' own custody.
    /// @dev SHOULD-HOLD — plan I30 and x-ray X-6, enforced by `if (to != bonds_) revert ZeroAddress()` around
    ///      `IAmps.mint` (`AmpsVault.sol:978`).
    /// @param o The bond observation.
    function property_bondMintsIntoCustody(BondObs memory o) internal {
        eq(o.supplyAfter, o.supplyBefore + o.issued, "SP-03: supply did not rise by exactly ampsOut");
        eq(o.shellAmpsAfter, o.shellAmpsBefore + o.issued, "SP-03: the minted AMPS did not land in AmpsBonds");
    }

    /// @notice SP-04: a bond moves exactly `amountIn` of collateral from the bonder into the vault's holding, plus
    ///         whatever stray balance of that collateral the bond shell forwarded, with nothing left on the shell.
    /// @dev SHOULD-HOLD — guard G-35 (`if (settled != amountIn) revert DepositMismatch`, `AmpsBonds.sol:388`) and
    ///      plan I12 for the shell's zero balance. The forwarded term is fix-log wave-1 finding 1: a donation
    ///      resting on the shell is forwarded to the vault best-effort with the next bond (`AmpsBonds._issue`,
    ///      `CollateralForwarded`), so the vault's holding rises by `amountIn` *plus* that dust (2026-09-12
    ///      campaign: 20 wei donated to the shell, then a bond — the vault received `amountIn + 20`). A forward
    ///      that fails leaves the dust on the shell, which the last leg reports.
    /// @param o The bond observation.
    function property_bondDepositConservation(BondObs memory o) internal {
        gte(o.bonderCollBefore, o.bonderCollAfter, "SP-04: the bonder's collateral rose across its own bond");
        eq(o.bonderCollBefore - o.bonderCollAfter, o.amountIn, "SP-04: the bonder did not pay exactly amountIn");
        gte(o.vaultHeldAfter, o.vaultHeldBefore, "SP-04: the vault's holding of the collateral fell on a deposit");
        uint256 forwarded = o.shellCollBefore > o.shellCollAfter ? o.shellCollBefore - o.shellCollAfter : 0;
        eq(
            o.vaultHeldAfter - o.vaultHeldBefore,
            o.amountIn + forwarded,
            "SP-04: the vault did not receive exactly amountIn plus what the shell forwarded"
        );
        eq(o.shellCollAfter, 0, "SP-04: collateral came to rest on the bond shell");
    }

    /// @notice SP-05: a bond is accretive — the AMPS it issued is worth, at the NAV/share it priced against, no
    ///         more than the haircut-adjusted collateral it took, less the demanded accretion (plan I27's identity
    ///         `ampsOut · nav · (1 + minAccretionBps) <= collateralIn · P_i · (1 − hSession)`).
    /// @dev SHOULD-HOLD — plan I27 and x-ray E-2 ("issuance is accretive to NAV/share by construction"), G-38;
    ///      `AmpsBonds._price` reverts `AccretionFloorViolated` above `_qFloorX18` (`AmpsBonds.sol:541-544`). The
    ///      floor is recomputed here from the shell's own inputs — the stored NAV the bond priced against, the
    ///      same `latestAnswer`, the gate's haircut, `minAccretionBps` — through `BondPolicy.qFloorX18`; a stale
    ///      feed only *widens* the shell's haircut (`_haircutFor`), which lowers its floor below this one, so the
    ///      bound is conservative without mirroring that branch.
    ///
    ///      **Why this is stated as the identity and not as "preview NAV/share after ≥ before"** (2026-09-10 and
    ///      2026-09-11 campaigns, lead L-1 in the report). With `P_mkt` below NAV/share the vault sets
    ///      `P_ref = NAV/share`, and `LadderPositionValuer` prices every position at the *previous* checkpoint's
    ///      `P_ref`; after any downward move each checkpoint therefore re-derives `A` at a slightly lower
    ///      reference and NAV/share converges downward by a geometric step whose ratio depends on how much of the
    ///      book straddles the reference (0.023 in one diagnostic; near 1 late in a long sequence). The bond's own
    ///      `_checkpoint()` takes one such step, so any preview-to-preview comparison across a bond contains it,
    ///      and no fixed tolerance bounds it (1e-9 was exceeded after four same-block pre-checkpoints). The step
    ///      is a valuation artefact that moves no value; issuance is what this property is about, and the
    ///      identity measures exactly that on the basis the bond used.
    /// @param o The bond observation.
    function property_bondIsAccretive(BondObs memory o) internal {
        if (o.issued == 0 || o.navBondBasis == 0 || o.collateralPriceUsd18 == 0) return;
        if (o.collateralDecimals > GlobPriceLib.MAX_COUNTER_DECIMALS) return;
        uint256 floorX18 = bondPolicy.qFloorX18(o.collateralPriceUsd18, o.navBondBasis, o.haircutBps, o.minAccretionBps);
        uint256 amountIn18 = o.amountIn * (10 ** (GlobPriceLib.MAX_COUNTER_DECIMALS - o.collateralDecimals));
        uint256 bound = GlobFullMath.mulDiv(amountIn18, floorX18, GlobC.WAD) + 1;
        lte(o.issued, bound, "SP-05: a bond issued AMPS above the accretion floor on its own NAV basis");
    }

    /// @notice SP-06: no bond issues more than the capacity that was on offer, or less than the caller's floor.
    /// @dev SHOULD-HOLD — plan I28 and G-39 (`AmpsBonds.sol:401`, `SlippageExceeded`), with the clamp at `:405-410`.
    ///      The "capacity falls by what was issued" leg is deliberately not asserted: `_rollEpoch` can reset the
    ///      window inside the same call, which is a legal way for capacity to *rise* across a bond.
    /// @param o The bond observation.
    function property_bondWithinCapacityOnOffer(BondObs memory o) internal {
        lte(o.issued, o.capacityBefore, "SP-06: a bond issued more than the capacity on offer");
        gte(o.issued, o.minAmpsOut, "SP-06: a bond issued below the caller's minAmpsOut");
    }

    /// @notice SP-07: a bond never issues more AMPS than the quote taken in the same block promised, and a bond
    ///         that lands was never quoted with a refusal reason.
    /// @dev SHOULD-HOLD — `AmpsBonds._quote` NatSpec ":829" ("the pricing arithmetic is shared with `bond`"); the
    ///      same-block precondition is x-ray X-7.
    /// @dev **The plan's stronger claim — `quote.ampsOut == issued` to the wei — is not true of this contract, and
    ///      the reason is structural rather than a rounding artifact.** `bond` settles the collateral in step 3
    ///      (`AmpsBonds.sol:385`, `depositBonded`) and prices it in step 4 (`:388`, `_price`), so the fill term the
    ///      policy scores is measured *after* the deposit has landed; `quote` is a `view` and necessarily scores it
    ///      before. A bigger deposit raises the fill, which lowers the discount, which lowers the AMPS — so the
    ///      realised issue is weakly worse than the quote by exactly the deposit's own effect on the market.
    ///      Measured on the real world with `checkpoint`, `quote` and `bond` in one block: 6.2e-14 relative on a
    ///      first bond into a fresh market, 2.2e-6 once three earlier bonds had moved the same book. The property
    ///      is therefore stated one-sided — which is also the clause a bonder cares about, since it is the
    ///      direction in which a quote could mislead one.
    /// @dev **The quote's basis and the bond's basis differ by one checkpoint** (2026-09-11 campaign, lead L-1).
    ///      `quote` prices off the stored `checkpointData().navPerShareX18`; `bond` runs the vault's `_checkpoint()`
    ///      inside `depositBonded` first and prices off the value that stores, which after a downward reference
    ///      move is lower by the self-referential convergence step (see {property_bondIsAccretive}). `q_floor` is
    ///      proportional to `1 / navPerShare` and the market leg is NAV-independent, so the quote's promise holds
    ///      exactly up to that ratio: `issued <= quoted · navQuoteBasis / navBondBasis` when the basis fell, and
    ///      `issued <= quoted` otherwise (a rising basis only lowers the floor). The rescale is one wei of
    ///      flooring slack on each side.
    /// @param quoted `quote.ampsOut`.
    /// @param issued The `ampsOut` the bond returned.
    /// @param reason The refusal reason the quote named.
    /// @param navQuoteBasis `checkpointData().navPerShareX18` immediately before the quote.
    /// @param navBondBasis The same immediately after the bond (what its own checkpoint stored before pricing).
    function property_quoteMatchesBond(
        uint256 quoted,
        uint256 issued,
        bytes32 reason,
        uint256 navQuoteBasis,
        uint256 navBondBasis
    ) internal {
        uint256 bound = quoted;
        if (navBondBasis != 0 && navQuoteBasis > navBondBasis) {
            bound = GlobFullMath.mulDiv(quoted + 1, navQuoteBasis, navBondBasis) + 1;
        }
        lte(issued, bound, "SP-07: the bond issued more AMPS than the same-block quote promised");
        eq(uint256(reason), 0, "SP-07: a bond that landed was quoted with a refusal reason");
    }

    /// @notice SP-08: consumed collateral bought AMPS, at or above the caller's floor.
    /// @dev EXPLORATORY. The "clamped surplus reaches holders as NAV" leg is SP-05's identity: the collateral the
    ///      capacity clamp does not convert into AMPS still lands in the vault at full value, which the floor
    ///      identity prices in (issued AMPS worth at most the collateral taken). A preview-to-preview NAV/share
    ///      comparison would carry the convergence step described in {property_bondIsAccretive}, so it is not
    ///      asserted here.
    /// @param o The bond observation.
    function property_bondSurplusReachesHolders(BondObs memory o) internal {
        if (o.amountIn == 0) return;
        gt(o.issued, 0, "SP-08: collateral was consumed and no AMPS was issued");
        gte(o.issued, o.minAmpsOut, "SP-08: collateral was consumed below the caller's floor");
    }

    /// @notice SP-09: a claim moves AMPS out of the bond shell and nothing else.
    /// @dev SHOULD-HOLD — `record.claimed = uint128(vested)` immediately before `transfer(to, amount)`
    ///      (`AmpsBonds.sol:563-569`; `claimAll` at `:576-591`); `Amps.mint/burn` are `onlyVault` (`Amps.sol:34`).
    /// @param o The claim observation.
    function property_claimMovesOnlyTheShellsAmps(ClaimObs memory o) internal {
        eq(o.supplyAfter, o.supplyBefore, "SP-09: a claim moved totalSupply");
        gte(o.shellBefore, o.shellAfter, "SP-09: the bond shell gained AMPS on a claim");
        eq(o.shellBefore - o.shellAfter, o.paid, "SP-09: the shell did not pay exactly the claimed amount");
        if (o.recipient != address(bonds)) {
            gte(o.recipAfter, o.recipBefore, "SP-09: the claim recipient lost AMPS");
            eq(o.recipAfter - o.recipBefore, o.paid, "SP-09: the recipient did not receive exactly the claim");
        }
        if (!o.single) return;

        eq(uint256(o.posAfter.principal), uint256(o.posBefore.principal), "SP-09: a claim moved `principal`");
        eq(uint256(o.posAfter.start), uint256(o.posBefore.start), "SP-09: a claim moved `start`");
        eq(uint256(o.posAfter.vestSeconds), uint256(o.posBefore.vestSeconds), "SP-09: a claim moved `vestSeconds`");
        eq(uint256(o.posAfter.marketId), uint256(o.posBefore.marketId), "SP-09: a claim moved `marketId`");
        gte(uint256(o.posAfter.claimed), uint256(o.posBefore.claimed), "SP-09: `claimed` fell across a claim");
        eq(
            uint256(o.posAfter.claimed) - uint256(o.posBefore.claimed),
            o.paid,
            "SP-09: `claimed` did not rise by exactly the amount transferred"
        );
    }

    // ―――――――――――――――――――――― Redemption ――――――――――――――――――――――

    /// @notice SP-10: a redemption burns exactly the shares it was given plus the inventory it released.
    /// @dev SHOULD-HOLD — plan I23; `burn(msg.sender, shares)` (`AmpsVault.sol:848`) and
    ///      `burn(address(this), inventoryBurned)` (`:882`) are the only two supply writes (x-ray I-9).
    /// @param o The redemption observation.
    function property_redemptionBurnIsExact(RedeemObs memory o) internal {
        gte(o.callerAmpsBefore, o.callerAmpsAfter, "SP-10: the redeemer's AMPS rose across its own redemption");
        eq(o.callerAmpsBefore - o.callerAmpsAfter, o.shares, "SP-10: the redeemer did not burn exactly `shares`");
        gte(o.supplyBefore, o.supplyAfter, "SP-10: a redemption raised totalSupply");
        eq(
            o.supplyBefore - o.supplyAfter,
            o.shares + o.previewInventoryBurned,
            "SP-10: supply did not fall by shares + inventoryBurned"
        );
    }

    /// @notice SP-11: the redemption preview is the redemption payout.
    /// @dev SHOULD-HOLD — `AmpsVault.previewRedeem:555-557` and `VaultRedeemLib.previewUnwind:808-811` ("agree to
    ///      the wei"). `gained` counts the ERC-6909 claim as well as the ERC-20 balance, because the payout falls
    ///      back to claims when an ERC-20 leg fails (fix-log wave-2 finding 1).
    /// @dev **The plan's second clause — "and never more than the vault held" — is GL-22's, not this one's.** A
    ///      redemption is paid out of the vault's balances *plus* what unwinding its ladder positions releases, and
    ///      the released half is not readable as a balance before the call: measured against `heldBalance` alone the
    ///      clause is false on a live ladder by construction (observed immediately, 486,552 promised against 36,414
    ///      held, in a pool whose depth was all in positions). GL-22 states it against a full ladder unwind, which
    ///      is the quantity it is actually about.
    /// @param predicted What `previewRedeem` promised, per token.
    /// @param gained What the recipient actually gained, per token (ERC-20 + ERC-6909).
    function property_previewIsThePayout(uint256[] memory predicted, uint256[] memory gained) internal {
        for (uint256 i; i < predicted.length && i < gained.length; ++i) {
            eq(gained[i], predicted[i], "SP-11: the recipient's gain is not what previewRedeem promised");
        }
    }

    /// @notice SP-12: one user cannot operate on another's position.
    /// @dev SHOULD-HOLD — `burn(msg.sender, shares)` on the redemption path and `_positions[msg.sender]` on the
    ///      claim path (plan I38). Every actor that is neither the caller nor the named recipient must be untouched.
    /// @param before Per-actor reading before the call.
    /// @param afterv The same reading after the call.
    /// @param self The caller.
    /// @param to The named recipient.
    /// @param reason The failure message.
    function property_onlyTheCallersOwnPosition(
        uint256[] memory before,
        uint256[] memory afterv,
        address self,
        address to,
        string memory reason
    ) internal {
        for (uint256 i; i < before.length && i < afterv.length && i < actors.length; ++i) {
            if (actors[i] == self || actors[i] == to) continue;
            eq(afterv[i], before[i], reason);
        }
    }

    /// @notice SP-13: a non-dust redemption is accretive to the holders who stay.
    /// @dev SHOULD-HOLD — fix-log wave 4 on `keepBps` and the inventory burn ("the protocol-favourable
    ///      direction"); plan I5 and I23. With a zero fee the `VIRTUAL_SHARES` dust bounds the fall at 2 bp.
    /// @param o The redemption observation.
    function property_redemptionIsAccretive(RedeemObs memory o) internal {
        if (o.navBefore == 0 || o.navAfter == 0) return;
        if (o.feeBps > 0 && o.shares >= 1e12) {
            gte(o.navAfter, o.navBefore, "SP-13: a fee-paying redemption lowered NAV/share");
        } else {
            gte(
                o.navAfter,
                o.navBefore * (SpecC.BPS - 2) / SpecC.BPS,
                "SP-13: a redemption bled more than 2 bp of NAV/share"
            );
        }
    }

    /// @notice SP-14: a single redemption never pays out more USD value than its pro-rata slice of `A`, net of fee.
    /// @dev EXPLORATORY. Measured on `totalAssetsUsd18()`, with 25 bp + 1e-6 USD of slack. `A` values a position's
    ///      counter side at the reference price while a redemption realises it at the pool price, the gap the fourth
    ///      audit wave accepted and could not close into a profitable path (`docs/audits/fix-log.md`); the
    ///      2026-09-10 campaign measured a sell-then-redeem sequence paying ~2 bp above the fee-netted reference-basis
    ///      slice, far inside the 250 bp redemption fee. Growth past 25 bp is a lead for human review.
    /// @param o The redemption observation.
    function property_redemptionPaysAtMostProRata(RedeemObs memory o) internal {
        if (o.aBefore == 0 || o.supplyBefore == 0 || o.aAfter >= o.aBefore) return;
        uint256 slice = o.aBefore * o.shares / o.supplyBefore;
        uint256 bound = slice * (SpecC.BPS - o.feeBps) / SpecC.BPS;
        lte(o.aBefore - o.aAfter, bound + bound * 25 / SpecC.BPS + 1e12, "SP-14: a redemption paid more than pro rata");
    }

    /// @notice SP-15: a redemption never creates, destroys or re-shapes a ladder record.
    /// @dev SHOULD-HOLD — plan I35 and the `PlacementRecord` NatSpec (`Types.sol:426-429`); `unwind` writes only
    ///      `record.liquidity = live - removed` (`VaultRedeemLib.sol:757`).
    /// @param before The pool's records before the call.
    /// @param afterv The same pool's records after it.
    function property_redemptionKeepsLadderGeometry(SpecRecord[] memory before, SpecRecord[] memory afterv) internal {
        eq(afterv.length, before.length, "SP-15: a redemption changed ladderLength");
        for (uint256 i; i < before.length && i < afterv.length; ++i) {
            eq(int256(afterv[i].lowerTick), int256(before[i].lowerTick), "SP-15: a redemption moved `lowerTick`");
            eq(int256(afterv[i].upperTick), int256(before[i].upperTick), "SP-15: a redemption moved `upperTick`");
            t(afterv[i].above == before[i].above, "SP-15: a redemption flipped a record's side");
            lte(uint256(afterv[i].liquidity), uint256(before[i].liquidity), "SP-15: a redemption added liquidity");
        }
    }

    /// @notice SP-16: a full-balance redemption never reverts.
    /// @dev SHOULD-HOLD — plan I14; fix-log wave-1 findings 2/3 and wave-4 finding 8 (the claims-only fallback)
    ///      exist to keep this true. Asserted on the `catch` arm, which is the Medusa-safe shape: `vm.snapshotState`
    ///      / `vm.revertToState` are not implemented in Medusa 1.5.1.
    /// @param ok Whether `redeemProRata(balance, actor)` succeeded.
    function property_fullRedemptionNeverReverts(bool ok) internal {
        t(ok, "SP-16: a full-balance redemption reverted");
    }

    // ―――――――――――――――――――――― Placement ――――――――――――――――――――――

    /// @notice SP-17: R1 — every placement path leaves `navAfter >= navBefore·(1 − 2 bp)`.
    /// @dev SHOULD-HOLD — plan I11 and guard G-20 (`AmpsVault.sol:1459`) with
    ///      `PLACEMENT_BLEED_BPS_MAX = 2` (`Constants.sol:643`); x-ray E-3.
    /// @param navBefore NAV/share before the call.
    /// @param navAfter NAV/share after it.
    function property_placementBleedBound(uint256 navBefore, uint256 navAfter) internal {
        if (navBefore == 0 || navAfter == 0) return;
        gte(
            navAfter,
            navBefore * (SpecC.BPS - SpecC.PLACEMENT_BLEED_BPS_MAX) / SpecC.BPS,
            "SP-17: a placement bled more than PLACEMENT_BLEED_BPS_MAX of NAV/share"
        );
    }

    /// @notice SP-18: a placement conserves inventory — the ask side spends exactly `placed`, the bid side spends
    ///         no AMPS at all, and nothing is minted to fill an ask.
    /// @dev SHOULD-HOLD — plan I10 ("the vault's ask inventory … is never minted") and I34;
    ///      `VaultPlacementLib._split:1260-1273` and `compound:373-400` cancel exactly. The per-bucket
    ///      `tilt^k / Σ tilt^j` half of the plan's statement is left to GL-68, which fuzzes `LadderLib.split`
    ///      directly rather than inferring the weights back out of liquidity.
    /// @param o The placement observation.
    function property_placementConservesInventoryAndShape(PlaceObs memory o) internal {
        if (o.above) {
            lte(o.vaultAmpsAfter, o.vaultAmpsBefore, "SP-18: an ask placement raised the vault's AMPS");
            // `Placed.amountPlaced` reports the per-cell *split*, and what each cell loses to liquidity rounding
            // stays in the vault as idle inventory (`VaultPlacementLib.sol:69-72`, `Types.sol:545`), so the
            // vault's AMPS falls by at most `placed`; the campaign of 2026-09-10 showed the residue can be a
            // large fraction of a dust-sized placement (30,833 wei of 281,576).
            lte(
                o.vaultAmpsBefore - o.vaultAmpsAfter,
                o.placed,
                "SP-18: the vault's AMPS fell by more than what was placed"
            );
        } else {
            eq(o.vaultAmpsAfter, o.vaultAmpsBefore, "SP-18: a bid placement moved the vault's AMPS");
        }
    }

    /// @notice SP-19: sidedness holds at placement — a freshly written ask sits at or above the tick, a freshly
    ///         written bid at or below it.
    /// @dev SHOULD-HOLD — plan I9 and G-30 (`VaultPlacementLib.sol:873`, `WrongSide`); fix-log wave-4 finding 2.
    ///      "Freshly written" is exactly "a record this call appended, or whose liquidity this call raised".
    /// @param before The pool's records before the call.
    /// @param afterv The same pool's records after it.
    /// @param tick The pool's tick after the call.
    function property_sidednessAtPlacement(SpecRecord[] memory before, SpecRecord[] memory afterv, int24 tick)
        internal
    {
        for (uint256 i; i < afterv.length; ++i) {
            if (afterv[i].liquidity == 0) continue;
            bool fresh = i >= before.length || afterv[i].liquidity > before[i].liquidity;
            if (!fresh) continue;
            if (afterv[i].above) {
                gte(int256(afterv[i].lowerTick), int256(tick), "SP-19: a freshly placed ask sits below the tick");
            } else {
                lte(int256(afterv[i].upperTick), int256(tick), "SP-19: a freshly placed bid sits above the tick");
            }
        }
    }

    /// @notice SP-20: a placement lands inside the divergence band.
    /// @dev SHOULD-HOLD — G-26 (`VaultPlacementLib.sol:574`) "Checked at entry and exit so a placement cannot be
    ///      sandwiched". Two skips, both mirroring the guard itself:
    ///      * `fairBefore == 0` is the guard's own "no usable input" branch (`_requireConverged` returns without
    ///        checking when `P_mkt`/`P_ref` or the bounded counter-answer probe is zero), so there is no band.
    ///      * A call that did no work — placed nothing and took no cooldown — never reached the gauntlet:
    ///        `deployBonded` and `rollout` return before `VaultPlacementLib.place` when there is nothing idle, no
    ///        answer, or nothing under the threshold, and the pool's tick is then wherever the last trade left it
    ///        (2026-09-10 campaign: a buy 4,084 ticks up a spoke followed by a `deployBonded` with no bonded
    ///        collateral fired this on a placement that never happened). The cooldown is the vault's own record of
    ///        "this call moved inventory" (`VaultPlacementLib.sol:288`, `:467`), which is exactly the set of calls
    ///        whose exit check ran.
    /// @param tick The pool's tick after the call.
    /// @param o The placement observation (`fairBefore`, `placed`, the cooldown stamps).
    function property_placementDivergenceBand(int24 tick, PlaceObs memory o) internal {
        if (o.fairBefore == 0) return;
        if (o.placed == 0 && o.lastPlacementAfter == o.lastPlacementBefore) return;
        int256 d = int256(tick) - int256(o.fairBefore);
        if (d < 0) d = -d;
        lte(d, int256(SpecC.PLACEMENT_DIVERGENCE_TICKS), "SP-20: a placement landed outside the divergence band");
    }

    /// @notice SP-21: a placement that placed nothing charges no cooldown.
    /// @dev SHOULD-HOLD — fix-log wave-3 finding 1 and wave-4 finding 5; `VaultPlacementLib.sol:288`, `:464-466`;
    ///      x-ray I-18.
    /// @param o The placement observation.
    function property_zeroWorkTakesNothing(PlaceObs memory o) internal {
        if (o.placed != 0) return;
        eq(
            uint256(o.lastPlacementAfter),
            uint256(o.lastPlacementBefore),
            "SP-21: a placement that placed nothing still charged the cooldown"
        );
    }

    /// @notice SP-22: `above` is written only when a cell is opened, so a non-empty cell never changes side.
    /// @dev SHOULD-HOLD — `_writeRecords` ("`above` is written only when the cell is opened",
    ///      `VaultPlacementLib.sol:930-943`).
    /// @param before The pool's records before the call.
    /// @param afterv The same pool's records after it.
    function property_aboveChangesOnlyWhenEmpty(SpecRecord[] memory before, SpecRecord[] memory afterv) internal {
        for (uint256 i; i < before.length && i < afterv.length; ++i) {
            if (before[i].liquidity == 0) continue;
            t(afterv[i].above == before[i].above, "SP-22: `above` flipped on a cell that still held liquidity");
        }
    }

    /// @notice SP-23: the high-water buyback burn removes only crossed asks.
    /// @dev SHOULD-HOLD — plan I33; fix-log wave-1 finding 4, wave-3 finding 15, wave-4 finding 2. Every record
    ///      this call took liquidity out of must have been an ask whose whole range sat at or below the high water.
    /// @param before The pool's records before the call.
    /// @param afterv The same pool's records after it.
    /// @param highWater The hook's high-water tick before the call.
    function property_burnbackBurnsOnlyCrossedAsks(
        SpecRecord[] memory before,
        SpecRecord[] memory afterv,
        int24 highWater
    ) internal {
        for (uint256 i; i < before.length && i < afterv.length; ++i) {
            if (afterv[i].liquidity >= before[i].liquidity) continue;
            t(before[i].above, "SP-23: the buyback burn took liquidity out of a bid cell");
            lte(
                int256(before[i].upperTick),
                int256(highWater),
                "SP-23: the buyback burn took liquidity out of an uncrossed ask"
            );
        }
    }

    /// @notice SP-24: `compound` never raises supply, and lowers it by exactly what it reported burning.
    /// @dev SHOULD-HOLD — rev-6/7 amendment to I33; x-ray E-1 enumerates the burn sites.
    /// @param supplyBefore Supply before the call.
    /// @param supplyAfter Supply after it.
    /// @param burned The `burned` figure `compound` returned.
    function property_compoundBurnIsExact(uint256 supplyBefore, uint256 supplyAfter, uint256 burned) internal {
        lte(supplyAfter, supplyBefore, "SP-24: a compound raised totalSupply");
        eq(supplyBefore - supplyAfter, burned, "SP-24: supply did not fall by exactly the reported burn");
    }

    /// @notice SP-25: the creator's slice of a compound is bounded by the fees it collected, and is zero once the
    ///         schedule has decayed.
    /// @dev SHOULD-HOLD — plan I31 rev-6/7; x-ray I-21; fix-log wave-3 finding 4, wave-4 finding 3.
    /// @param creatorBefore The creator's AMPS before the call.
    /// @param creatorAfter The creator's AMPS after it.
    /// @param ampsFees The `ampsFees` figure `compound` returned.
    function property_creatorSlicePerCompound(uint256 creatorBefore, uint256 creatorAfter, uint256 ampsFees) internal {
        gte(creatorAfter, creatorBefore, "SP-25: a compound took AMPS off the creator");
        lte(creatorAfter - creatorBefore, ampsFees, "SP-25: the creator took more AMPS than the compound collected");
        if (vault.creatorBpsAt(block.timestamp) == 0) {
            eq(creatorAfter, creatorBefore, "SP-25: the creator was paid after the fee schedule had decayed to zero");
        }
    }

    /// @notice SP-26: a checkpointing call stamps the checkpoint; `touch` does not.
    /// @dev SHOULD-HOLD — `AmpsVault.sol:1457`, `:1533-1534`; `touch` NatSpec `:915-916`.
    /// @param shouldStamp Whether this entry point recomputes NAV.
    /// @param tsBefore The checkpoint timestamp before the call.
    /// @param tsAfter The checkpoint timestamp after it.
    /// @param blkBefore The checkpoint block number before the call.
    /// @param blkAfter The checkpoint block number after it.
    function property_checkpointIsStamped(
        bool shouldStamp,
        uint32 tsBefore,
        uint32 tsAfter,
        uint32 blkBefore,
        uint32 blkAfter
    ) internal {
        if (shouldStamp) {
            eq(uint256(tsAfter), block.timestamp, "SP-26: a checkpointing call did not stamp the timestamp");
            eq(uint256(blkAfter), block.number, "SP-26: a checkpointing call did not stamp the block number");
        } else {
            eq(uint256(tsAfter), uint256(tsBefore), "SP-26: `touch` moved the checkpoint timestamp");
            eq(uint256(blkAfter), uint256(blkBefore), "SP-26: `touch` moved the checkpoint block number");
        }
    }

    /// @notice SP-27: no registered asset comes to rest as an idle ERC-20 balance on the vault.
    /// @dev SHOULD-HOLD — plan I12; `_sweepClean()` (`AmpsVault.sol:1429`) runs on all eight entry points that
    ///      touch balances and on `_afterPlacement:1460`. Called only after those entry points: `checkpoint` and
    ///      `touch` do not sweep, and `ampsVault_donateERC20` deliberately leaves a balance for them to find.
    function property_sweepCleanHolds() internal {
        uint256 count = vault.assetCount();
        for (uint256 i; i < count; ++i) {
            eq(SpecIERC20(vault.assetAt(i)).balanceOf(address(vault)), 0, "SP-27: an asset rests idle on the vault");
        }
    }

    // ―――――――――――――――――――― Keeper and the pot ――――――――――――――――――

    /// @notice SP-29: the pot charges exactly what it transfers, and never more than the budget left.
    /// @dev SHOULD-HOLD — `BountyPot.pay` NatSpec (`:363-370`) and `_chargeWindow:377-386`; plan I21.
    /// @param potBefore The pot's raw balance before the call.
    /// @param potAfter The pot's raw balance after it.
    /// @param keeperBefore The keeper's raw USDG before the call.
    /// @param keeperAfter The keeper's raw USDG after it.
    /// @param budgetLeftBefore `budgetLeftRaw()` before the call.
    function property_potChargesWhatItTransfers(
        uint256 potBefore,
        uint256 potAfter,
        uint256 keeperBefore,
        uint256 keeperAfter,
        uint256 budgetLeftBefore
    ) internal {
        gte(potBefore, potAfter, "SP-29: the pot's balance rose on a payout");
        gte(keeperAfter, keeperBefore, "SP-29: the keeper lost USDG on a payout");
        eq(potBefore - potAfter, keeperAfter - keeperBefore, "SP-29: the pot's drop is not the keeper's receipt");
        lte(keeperAfter - keeperBefore, budgetLeftBefore, "SP-29: the keeper was paid past the rolling budget");
    }

    /// @notice SP-30: funding or paying the pot changes `totalAssetsUsd18` by zero.
    /// @dev SHOULD-HOLD — plan I21 ("`BountyPot` excluded from `A`"); the vault never reads the pot's balance when
    ///      it checkpoints.
    /// @param aBefore `totalAssetsUsd18()` before the call.
    /// @param aAfter `totalAssetsUsd18()` after it.
    function property_potMovementsDoNotMoveA(uint256 aBefore, uint256 aAfter) internal {
        eq(aAfter, aBefore, "SP-30: a bounty-pot movement moved the vault's A");
    }

    /// @notice SP-31: a dry pot pays nothing and does not stop the keeper path doing its work.
    /// @dev SHOULD-HOLD — plan I21 ("depleted ⇒ unpaid, not reverting"); `BountyPot._quote` ("every cap is a
    ///      `min`"). What a handler can observe without a second world to compare against is the payout leg: with
    ///      an empty pot a keeper call that landed transferred exactly zero.
    /// @param potBefore The pot's raw balance before the call.
    /// @param keeperBefore The keeper's raw USDG before the call.
    /// @param keeperAfter The keeper's raw USDG after it.
    function property_emptyPotDoesNotRevertKeepers(uint256 potBefore, uint256 keeperBefore, uint256 keeperAfter)
        internal
    {
        if (potBefore != 0) return;
        eq(keeperAfter, keeperBefore, "SP-31: an empty pot still paid the keeper");
    }

    // ――――――――――――――――――――――― Trading ―――――――――――――――――――――――

    /// @notice SP-32: the counter asset is conserved across a trade — payer, PoolManager, recipient and router
    ///         deltas sum to zero.
    /// @dev SHOULD-HOLD — the closed-form ERC-20 identity plus plan I13 (the hook calls neither `donate()` nor
    ///      `poolManager.swap()`). Fees taken for the creator are ERC-6909 claims *on* the PoolManager, so they do
    ///      not leave this four-address closure.
    /// @param inflow What the PoolManager gained of the input currency.
    /// @param outflow What the payer and the router lost of it.
    function property_counterAssetConservation(uint256 inflow, uint256 outflow) internal {
        eq(inflow, outflow, "SP-32: the counter asset was not conserved across the trade");
    }

    /// @notice SP-33: the recipient gains exactly the reported output — plus, when the recipient is the caller,
    ///         whatever dust of that asset the router was holding and swept to its caller — and the payer pays at
    ///         most `amountIn`.
    /// @dev SHOULD-HOLD — `AmpsRouter._buyAction:302-310` ("the realised input, not the requested one") and the
    ///      `_sweep` legs at `:186-192`, `:213-221`, `:249-257`: every entry point ends by sweeping its residual
    ///      balance of each asset it touched to `msg.sender`, so a caller who is also the recipient receives the
    ///      reported output *and* any dust of it that an earlier call's rounding left on the router (2026-09-12
    ///      campaign: a dust buy delivered 22,947,131 wei of AMPS above the reported output — exactly the router's
    ///      resting balance). The sweep is the documented GL-39 mechanism, not part of the trade, so it is counted
    ///      separately rather than folded into the bound.
    /// @param o The trade observation.
    function property_tradeAttribution(TradeObs memory o) internal {
        gte(o.recipOutAfter, o.recipOutBefore, "SP-33: the trade recipient lost output currency");
        uint256 swept = o.routerOutBefore > o.routerOutAfter ? o.routerOutBefore - o.routerOutAfter : 0;
        uint256 expected = o.recipient == o.payer ? o.reportedOut + swept : o.reportedOut;
        eq(
            o.recipOutAfter - o.recipOutBefore,
            expected,
            "SP-33: the recipient's gain is not the reported out plus what the router swept to its caller"
        );
        gte(o.payerInBefore, o.payerInAfter, "SP-33: the payer gained input currency on its own trade");
        lte(o.payerInBefore - o.payerInAfter, o.amountIn, "SP-33: the payer paid more than amountIn");
    }

    /// @notice SP-34: a buy never takes more AMPS than the pool's ask ladder held.
    /// @dev EXPLORATORY.
    /// @param ampsOut The AMPS the buy delivered.
    /// @param askInventoryBefore The pool's unfilled ask inventory before the swap.
    function property_swapNeverTakesMoreThanTheLadderHeld(uint256 ampsOut, uint256 askInventoryBefore) internal {
        lte(ampsOut, askInventoryBefore, "SP-34: a buy took more AMPS than the ask ladder held");
    }

    /// @notice SP-35: a swap is not a mint or a burn, and the hook holds no AMPS.
    /// @dev SHOULD-HOLD — x-ray E-1 (a swap is not a supply write site); plan I13.
    /// @param o The trade observation.
    function property_swapDoesNotMoveSupply(TradeObs memory o) internal {
        eq(o.supplyAfter, o.supplyBefore, "SP-35: a swap moved totalSupply");
        // The hook never *acquires* AMPS through a swap; what a donation handler pushed onto it is trapped
        // there (ADV-18), so the bound is the tracked donations, not zero (the 2026-09-10 campaign hit the
        // literal zero with a donate-then-buy sequence).
        lte(o.hookAmps, ghosts.hookDonated[address(amps)], "SP-35: the hook held AMPS beyond what was donated to it");
    }

    /// @notice SP-36: a trade the quoter called executable does not revert.
    /// @dev SHOULD-HOLD — plan I15; G-45; fix-log wave-4 lead (the `int256.min` panic) and finding 1 (rail
    ///      pinning). Asserted on the `catch` arm of the handler that ran the quote in the same call.
    /// @param quotedOut What the quoter said the trade would return.
    /// @param refused Whether the quoter refused the trade.
    /// @param ok Whether the trade landed.
    function property_honestTradingNeverReverts(uint256 quotedOut, bool refused, bool ok) internal {
        if (refused || quotedOut == 0) return;
        t(ok, "SP-36: a trade the quoter called executable reverted");
    }

    /// @notice SP-37: a clean `quoteExactIn` is the realised output to the wei, and a degraded one never overstates.
    /// @dev SHOULD-HOLD — `QuoterSwapLib`'s **Exactness** NatSpec and `AmpsQuoter.quoteExactIn`'s post-swap rail
    ///      model (audit fix, 2026-09-08).
    /// @param quoted The quoted output.
    /// @param realised The realised output.
    /// @param clean Whether the quote came back undegraded.
    function property_quoteExactInMatchesTheSwap(uint256 quoted, uint256 realised, bool clean) internal {
        if (clean) {
            eq(realised, quoted, "SP-37: a clean quoteExactIn is not the realised output");
        } else {
            lte(quoted, realised, "SP-37: a degraded quoteExactIn overstated the output");
        }
    }

    /// @notice SP-38: a rotation returns what `quoteRotation` said it would.
    /// @dev SHOULD-HOLD — `AmpsRouter._rotateAction` ("hop 2 sells the realised delta of hop 1") and
    ///      `AmpsQuoter.quoteRotation`'s NatSpec.
    /// @param quotedOut The quoted output.
    /// @param realisedOut The realised output.
    function property_quoteRotationMatchesTheRotation(uint256 quotedOut, uint256 realisedOut) internal {
        if (quotedOut == 0) return;
        eq(realisedOut, quotedOut, "SP-38: a rotation did not return what quoteRotation promised");
    }

    /// @notice SP-39: both rotation hops charge at least their pool's buy fee and never more than the hard total.
    /// @dev SHOULD-HOLD — plan I16 rev-6/7; fix-log wave-3 finding 3; `Constants.sol:459-461`. The finer half of
    ///      the plan's statement — hop 2's base inside `[buyFeeBps(hop2), ampsFeeBps]` — is not separable from the
    ///      dynamic component through `chargedFeeBps`, which reports base + dyn as one number; GL-75 and GL-76
    ///      fuzz the split itself.
    /// @param hop1Charged `chargedFeeBps(hop1)` after the rotation.
    /// @param hop1Buy `buyFeeBps(hop1)`.
    /// @param hop2Charged `chargedFeeBps(hop2)` after the rotation.
    /// @param hop2Buy `buyFeeBps(hop2)`.
    function property_rotationFeeSchedule(uint16 hop1Charged, uint16 hop1Buy, uint16 hop2Charged, uint16 hop2Buy)
        internal
    {
        gte(uint256(hop1Charged), uint256(hop1Buy), "SP-39: hop 1 charged below its pool's buy fee");
        gte(uint256(hop2Charged), uint256(hop2Buy), "SP-39: hop 2 charged below its pool's buy fee");
        lte(uint256(hop1Charged), uint256(SpecC.TOTAL_FEE_BPS_MAX), "SP-39: hop 1 charged past TOTAL_FEE_BPS_MAX");
        lte(uint256(hop2Charged), uint256(SpecC.TOTAL_FEE_BPS_MAX), "SP-39: hop 2 charged past TOTAL_FEE_BPS_MAX");
    }

    /// @notice SP-40: the rotation exemption is not for sale — a same-pool "rotation" is refused.
    /// @dev SHOULD-HOLD — fix-log wave-3 finding 3 (`test_f03_anEntryToEntryRotationIsRefused`); plan I26 rev-6/7;
    ///      `AmpsHook._isPassThrough`.
    /// @param sameHopLanded Whether `rotate(p, p)` landed.
    function property_rotationExemptionNotForSale(bool sameHopLanded) internal {
        t(!sameHopLanded, "SP-40: a same-pool rotation was accepted at the pass-through fee");
    }

    /// @notice SP-41: two rotations over one pair in one transaction cannot both be pass-through.
    /// @dev SHOULD-HOLD — fix-log wave-3 finding 3
    ///      (`test_f03_aTwoCallRoundTripPaysTheAmpsFeeOnTheSecondPass`). The credit is an EIP-1153 transient slot,
    ///      so an atomic there-and-back must come back short.
    /// @param entryBefore The actor's entry asset before the first rotation.
    /// @param entryAfter The actor's entry asset after the second.
    /// @param creditAfter `hook.rotationCredit(actor)` after both rotations.
    function property_atomicWashPaysTheAmpsFee(uint256 entryBefore, uint256 entryAfter, uint256 creditAfter) internal {
        lte(entryAfter, entryBefore, "SP-41: an atomic two-rotation wash came back with more than it started");
        eq(creditAfter, 0, "SP-41: a rotation credit survived the transaction that earned it");
    }

    // ―――――――――――――――――――――― Round trips ――――――――――――――――――――――

    /// @notice SP-42: buy then sell the whole proceeds back returns no more than it cost.
    /// @dev EXPLORATORY.
    /// @param counterBefore The actor's counter asset before the round trip.
    /// @param counterAfter The same after it.
    /// @param ampsBefore The actor's AMPS before the round trip.
    /// @param ampsAfter The same after it.
    function property_buySellRoundTripNoProfit(
        uint256 counterBefore,
        uint256 counterAfter,
        uint256 ampsBefore,
        uint256 ampsAfter
    ) internal {
        lte(counterAfter, counterBefore, "SP-42: a buy/sell round trip returned more counter than it cost");
        lte(ampsAfter, ampsBefore, "SP-42: a buy/sell round trip left the actor with more AMPS");
    }

    /// @notice SP-43: sell then buy back with the whole proceeds returns no more than it cost.
    /// @dev EXPLORATORY.
    /// @param ampsBefore The actor's AMPS before the round trip.
    /// @param ampsAfter The same after it.
    /// @param counterBefore The actor's counter asset before the round trip.
    /// @param counterAfter The same after it.
    function property_sellBuyRoundTripNoProfit(
        uint256 ampsBefore,
        uint256 ampsAfter,
        uint256 counterBefore,
        uint256 counterAfter
    ) internal {
        lte(ampsAfter, ampsBefore, "SP-43: a sell/buy round trip returned more AMPS than it cost");
        lte(counterAfter, counterBefore, "SP-43: a sell/buy round trip left the actor with more counter asset");
    }

    /// @notice SP-44: a there-and-back rotation returns no more of the entry asset than it started with.
    /// @dev EXPLORATORY.
    /// @param entryBefore The actor's hop-1 counter asset before the pair of rotations.
    /// @param entryAfter The same after them.
    function property_rotateThereAndBackNoProfit(uint256 entryBefore, uint256 entryAfter) internal {
        lte(entryAfter, entryBefore, "SP-44: a there-and-back rotation returned more than it cost");
    }

    /// @notice SP-45: buy then redeem the AMPS returns no more counter asset than the buy cost.
    /// @dev EXPLORATORY. **Asserted only when the redemption-floor arbitrage is not on offer** (2026-09-12
    ///      campaign): a redemption pays pro-rata slices of every asset, so when the pool quotes AMPS below the
    ///      redemption's counter content per share the cycle returns more counter *by design* — the buyer gave up
    ///      the other slices — and the counter-only measure cannot tell that from rounding. The handler compares
    ///      `previewRedeem`'s counter amount with the counter the buy paid and skips when the preview is higher
    ///      (SP-11 proves payout equals preview); what remains under the assertion is rounding.
    /// @param counterBefore The actor's counter asset before the round trip.
    /// @param counterAfter The same after it.
    function property_buyRedeemRoundTripNoProfit(uint256 counterBefore, uint256 counterAfter) internal {
        lte(counterAfter, counterBefore, "SP-45: a buy/redeem round trip returned more counter than it cost");
    }

    /// @notice SP-46: **[C2]** N chained buy → redeem cycles never beat the first cycle's input.
    /// @dev EXPLORATORY. This is the repeated-cycle dust-extraction shape, deliberately kept apart from SP-45 (one
    ///      cycle) and from GL-28 (a preview comparison): the question is whether rounding that is invisible once
    ///      compounds when the output of one cycle is the input of the next. Armed under SP-45's rule, per cycle:
    ///      a cycle whose `previewRedeem` counter amount exceeds what it paid is the floor arbitrage, not rounding,
    ///      and disarms the assertion (2026-09-12 campaign: 0.17% more counter after bonds, a feed walk and a full
    ///      redemption had left the pool quoting below the vault's counter content per share).
    /// @param firstIn What the first cycle put in.
    /// @param counterBefore The actor's counter asset before the first cycle.
    /// @param counterAfter The same after the last one.
    function property_repeatedCycleExtractsNothing(uint256 firstIn, uint256 counterBefore, uint256 counterAfter)
        internal
    {
        firstIn;
        lte(counterAfter, counterBefore, "SP-46: chained buy/redeem cycles extracted value from the vault");
    }

    /// @notice SP-47: bond → claim → redeem returns no more collateral and does not lower NAV/share.
    /// @dev SHOULD-HOLD — x-ray E-2 and plan I27 for the NAV leg; fix-log wave 4 on the inventory burn.
    /// @param collateralBefore The actor's collateral before the cycle.
    /// @param collateralAfter The same after it.
    /// @param navBefore NAV/share before the cycle.
    /// @param navAfter NAV/share after it.
    function property_bondClaimRedeemCycle(
        uint256 collateralBefore,
        uint256 collateralAfter,
        uint256 navBefore,
        uint256 navAfter
    ) internal {
        lte(collateralAfter, collateralBefore, "SP-47: a bond/claim/redeem cycle returned more collateral");
        if (navBefore == 0 || navAfter == 0) return;
        gte(navAfter, navBefore * (SpecC.BPS - 2) / SpecC.BPS, "SP-47: a bond/claim/redeem cycle bled NAV/share");
    }

    /// @notice SP-49: AMPS never comes out of a truncation — a buy that delivered AMPS consumed a real input.
    /// @dev EXPLORATORY.
    /// @param ampsOut The AMPS delivered.
    /// @param realisedIn The input the payer actually parted with.
    function property_noFreeAmpsFromTruncation(uint256 ampsOut, uint256 realisedIn) internal {
        if (ampsOut == 0) return;
        gt(realisedIn, 0, "SP-49: a buy delivered AMPS for a zero realised input");
    }

    // ―――――――――――――――――――― Registry and oracles ―――――――――――――――――

    /// @notice SP-50: a constituent's status moves only along the legal edges.
    /// @dev SHOULD-HOLD — `PoolRegistry.sol:340`, `:362` (`InvalidStatusTransition`).
    /// @param before The status before the call.
    /// @param afterv The status after it.
    function property_statusMovesOnLegalEdgesOnly(SpecStatus before, SpecStatus afterv) internal {
        if (before == afterv) return;
        t(before != SpecStatus.NONE, "SP-50: an unregistered constituent changed status");
        t(
            (before == SpecStatus.ACTIVE && afterv == SpecStatus.RETIRED)
                || (before == SpecStatus.RETIRED && afterv == SpecStatus.ACTIVE),
            "SP-50: a constituent took an illegal status edge"
        );
    }

    /// @notice SP-51: `activeConstituentCount` moves by exactly the edges taken.
    /// @dev SHOULD-HOLD — the Δ-pairs `PoolRegistry.sol:344 ↔ :347` and `:370 ↔ :374`.
    /// @param before The status before the call.
    /// @param afterv The status after it.
    /// @param countBefore `activeConstituentCount()` before the call.
    /// @param countAfter The same after it.
    function property_activeCountDelta(SpecStatus before, SpecStatus afterv, uint16 countBefore, uint16 countAfter)
        internal
    {
        if (before == SpecStatus.ACTIVE && afterv != SpecStatus.ACTIVE) {
            eq(uint256(countAfter) + 1, uint256(countBefore), "SP-51: retiring a name did not lower the active count");
        } else if (before != SpecStatus.ACTIVE && afterv == SpecStatus.ACTIVE) {
            eq(uint256(countAfter), uint256(countBefore) + 1, "SP-51: reinstating did not raise the active count");
        } else {
            eq(uint256(countAfter), uint256(countBefore), "SP-51: the active count moved without a status edge");
        }
    }

    /// @notice SP-52: retirement stamps and zeroes; reinstatement clears the stamp.
    /// @dev SHOULD-HOLD — plan I37; `PoolRegistry.sol:345-346`, `:369-372`.
    /// @param before The status before the call.
    /// @param afterv The status after it.
    /// @param rolloutAfter The name's `rolloutWeightBps` after the call.
    /// @param retiredAtAfter The name's `retiredAt` after the call.
    function property_retireStampsAndZeroes(
        SpecStatus before,
        SpecStatus afterv,
        uint16 rolloutAfter,
        uint32 retiredAtAfter
    ) internal {
        if (before == SpecStatus.ACTIVE && afterv == SpecStatus.RETIRED) {
            eq(uint256(rolloutAfter), 0, "SP-52: a retired name kept a rollout weight");
            neq(uint256(retiredAtAfter), 0, "SP-52: a retired name was not stamped");
        } else if (before == SpecStatus.RETIRED && afterv == SpecStatus.ACTIVE) {
            eq(uint256(retiredAtAfter), 0, "SP-52: a reinstated name kept its retirement stamp");
        }
    }

    /// @notice SP-53: a registry call leaves every constituent it was not about untouched.
    /// @dev EXPLORATORY. One untouched name is sampled per call rather than all thirty: the identity is per-record,
    ///      so a violation on any of them is reachable, and a full walk would not fit a fuzzer block.
    /// @param statusBefore The witness's status before the call.
    /// @param statusAfter The same after it.
    /// @param targetBefore The witness's `targetWeightBps` before the call.
    /// @param targetAfter The same after it.
    /// @param retiredBefore The witness's `retiredAt` before the call.
    /// @param retiredAfter The same after it.
    function property_registryCallIsIsolated(
        SpecStatus statusBefore,
        SpecStatus statusAfter,
        uint16 targetBefore,
        uint16 targetAfter,
        uint32 retiredBefore,
        uint32 retiredAfter
    ) internal {
        t(statusBefore == statusAfter, "SP-53: an untouched constituent changed status");
        eq(uint256(retiredAfter), uint256(retiredBefore), "SP-53: an untouched constituent's stamp moved");
        targetBefore;
        targetAfter; // `setIndexWeights` legitimately rewrites every ACTIVE name's target weight
    }

    /// @notice SP-54: the divergence timer only latches on and off, never from one non-zero time to another.
    /// @dev SHOULD-HOLD — `OracleGate.sol:1388-1395`, where both writes are guarded on the current value.
    /// @param before `divergedSince(pool)` before the call.
    /// @param afterv The same after it.
    function property_divergenceTimerLatches(uint32 before, uint32 afterv) internal {
        if (afterv == before || before == 0 || afterv == 0) return;
        t(false, "SP-54: divergedSince moved from one non-zero stamp to another");
    }

    /// @notice SP-55: a moved accepted answer came from a different round.
    /// @dev SHOULD-HOLD — `_latch` is the only writer (`FeedRegistry.sol:748`), reached only at `:377`.
    /// @param answerBefore The accepted answer before the call.
    /// @param answerAfter The same after it.
    /// @param roundBefore The accepted round before the call.
    /// @param roundAfter The same after it.
    function property_acceptedAnswerAdvancesTheRound(
        uint128 answerBefore,
        uint128 answerAfter,
        uint80 roundBefore,
        uint80 roundAfter
    ) internal {
        if (answerAfter == answerBefore || answerBefore == 0) return;
        neq(uint256(roundAfter), uint256(roundBefore), "SP-55: the accepted answer moved without advancing the round");
    }

    /// @notice SP-56: latching a new round clears the pending candidate.
    /// @dev SHOULD-HOLD — `FeedRegistry.sol:747-751`.
    /// @param roundBefore The accepted round before the call.
    /// @param roundAfter The same after it.
    /// @param pendingAfter The pending round after the call.
    function property_latchClearsPending(uint80 roundBefore, uint80 roundAfter, uint80 pendingAfter) internal {
        if (roundAfter == roundBefore) return;
        eq(uint256(pendingAfter), 0, "SP-56: a latch left a pending candidate behind");
    }

    /// @notice SP-57: a same-transaction refresh cannot talk the bond side into a price it has not confirmed.
    /// @dev SHOULD-HOLD — fix-log wave-1 finding 9 and wave-2 finding 7; x-ray G-36, G-37, X-4, X-7. What is
    ///      observable from outside is the refusal: while the vault reports an unconfirmed NAV, the bond that
    ///      follows the refresh in the same transaction must not land.
    /// @param navUnconfirmed Whether the vault held the NAV back at the moment of the bond.
    /// @param bondLanded Whether the bond succeeded.
    function property_refreshThenBondUsesTheHeldAnswer(bool navUnconfirmed, bool bondLanded) internal {
        if (!navUnconfirmed) return;
        t(!bondLanded, "SP-57: a bond priced off an unconfirmed NAV in the same tx as the refresh");
    }

    // ―――――――――――――――――― Governance and ERC-20 ――――――――――――――――――

    /// @notice SP-58: no governed setter moves supply, an actor's balance or NAV/share.
    /// @dev EXPLORATORY.
    /// @param supplyBefore Supply before the call.
    /// @param supplyAfter Supply after it.
    /// @param actorsBefore Per-actor AMPS before the call.
    /// @param actorsAfter The same after it.
    /// @param navBefore NAV/share before the call.
    /// @param navAfter NAV/share after it.
    function property_governedSetterIsValueNeutral(
        uint256 supplyBefore,
        uint256 supplyAfter,
        uint256[] memory actorsBefore,
        uint256[] memory actorsAfter,
        uint256 navBefore,
        uint256 navAfter
    ) internal {
        eq(supplyAfter, supplyBefore, "SP-58: a governed setter moved totalSupply");
        for (uint256 i; i < actorsBefore.length && i < actorsAfter.length; ++i) {
            eq(actorsAfter[i], actorsBefore[i], "SP-58: a governed setter moved an actor's AMPS balance");
        }
        if (navBefore == 0 || navAfter == 0) return;
        eq(navAfter, navBefore, "SP-58: a governed setter moved NAV/share");
    }

    /// @notice SP-59: a donation bricks nothing and does not enrich the donor.
    /// @dev SHOULD-HOLD — fix-log wave-1 findings 1/3 and wave-3 finding 12
    ///      (`test_collateralDonationCannotBrickTheMarket`).
    /// @param donorBefore The donor's balance of the donated token before the call.
    /// @param donorAfter The same after it.
    /// @param amount What was donated.
    /// @param viewsAnswer Whether every disclosure view still answered afterwards.
    function property_donationBricksNothing(uint256 donorBefore, uint256 donorAfter, uint256 amount, bool viewsAnswer)
        internal
    {
        lte(donorAfter, donorBefore, "SP-59: a donor's balance rose across its own donation");
        eq(donorBefore - donorAfter, amount, "SP-59: a donation moved something other than the amount donated");
        t(viewsAnswer, "SP-59: a donation stopped a disclosure view from answering");
    }

    /// @notice SP-60: a full-amount operation leaves the protocol re-enterable.
    /// @dev EXPLORATORY. After the whole balance has gone through one entry point, the disclosure surface must
    ///      still answer and the redemption floor must still quote — the two preconditions every other entry point
    ///      is built on.
    /// @param viewsAnswer Whether every disclosure view still answered.
    /// @param navBefore NAV/share before the call.
    /// @param navAfter NAV/share after it.
    function property_fullAmountOpsStayReenterable(bool viewsAnswer, uint256 navBefore, uint256 navAfter) internal {
        t(viewsAnswer, "SP-60: a full-amount operation left the disclosure surface unable to answer");
        if (navBefore == 0 || navAfter == 0) return;
        gte(navAfter, navBefore * (SpecC.BPS - 2) / SpecC.BPS, "SP-60: a full-amount operation bled NAV/share");
    }

    /// @notice SP-61: a self-transfer and a zero-value transfer move nothing and do not revert.
    /// @dev SHOULD-HOLD — the ERC-20 zero-value MUST clause and OZ `_update`'s `from == to` path.
    /// @param selfOk Whether the self-transfer landed.
    /// @param zeroOk Whether the zero-value transfer landed.
    /// @param balanceBefore The actor's AMPS before the two calls.
    /// @param balanceAfter The same after them.
    function property_neutralErc20OpsAreNeutral(bool selfOk, bool zeroOk, uint256 balanceBefore, uint256 balanceAfter)
        internal
    {
        t(selfOk, "SP-61: a self-transfer of AMPS reverted");
        t(zeroOk, "SP-61: a zero-value transfer of AMPS reverted");
        eq(balanceAfter, balanceBefore, "SP-61: a neutral ERC-20 operation moved a balance");
    }

    /// @notice SP-62: a transfer moves exactly `amount`, and an allowance is spent by exactly `amount` unless it
    ///         was infinite.
    /// @dev SHOULD-HOLD — the ERC-20 transfer clauses and OZ `_spendAllowance`'s infinite carve-out.
    /// @param fromBefore The sender's balance before.
    /// @param fromAfter The sender's balance after.
    /// @param toBefore The recipient's balance before.
    /// @param toAfter The recipient's balance after.
    /// @param amount The amount transferred.
    function property_transferAccountingIsExact(
        uint256 fromBefore,
        uint256 fromAfter,
        uint256 toBefore,
        uint256 toAfter,
        uint256 amount
    ) internal {
        gte(fromBefore, fromAfter, "SP-62: a sender's balance rose on its own transfer");
        eq(fromBefore - fromAfter, amount, "SP-62: the sender did not part with exactly `amount`");
        gte(toAfter, toBefore, "SP-62: a recipient's balance fell on a transfer into it");
        eq(toAfter - toBefore, amount, "SP-62: the recipient did not receive exactly `amount`");
    }

    /// @notice SP-63: `bond`, `claim` and `redeem` credit `to`, never `msg.sender`, when the two differ.
    /// @dev EXPLORATORY.
    /// @param toGain What the named recipient gained.
    /// @param expected What it should have gained.
    /// @param senderGain What the caller gained of the same thing.
    function property_toParameterCreditsTo(uint256 toGain, uint256 expected, uint256 senderGain) internal {
        eq(toGain, expected, "SP-63: the named recipient was not credited");
        eq(senderGain, 0, "SP-63: the caller was credited instead of the named recipient");
    }

    // ―――――――――――――――― Left as TODO, and why ――――――――――――――――

    // SP-28 property_rolloutWindowChargedOnDrain — TODO: needs `vm.load` on `AmpsVault` storage slot 15 plus a
    // local mirror of `VaultRolloutLib._decayedMoved`, i.e. a second implementation of the decay whose only
    // witness would be the first. `rollout` returns `moved` and nothing else, so nothing short of raw storage
    // separates "the window was charged" from "the window was re-stamped"; a property written off `moved` alone
    // would assert an identity it had itself assumed. LOW priority in the plan, and marked `[-]` rather than left
    // as a brittle assertion.

    // SP-48 property_bookFillsInsideOut — TODO: needs per-cell live AMPS for the swapped pool before *and* after
    // every trade (`liveAmounts` over up to 24 records, twice, on the hot swap path) and a nearest-first ordering
    // that survives a cell converting from ask to bid mid-walk. The gas is affordable only if the swap handlers
    // stop taking their other 24-record readings, and the ordering is exactly the part a wrong implementation
    // would get wrong silently. EXPLORATORY in the plan; marked `[-]`.

    // ――――――――――― Reads that must not be the reason a handler fails ―――――――――――

    /// @dev `previewNavPerShareX18()` or zero. Never reverts.
    /// @return value The NAV/share, or zero when the vault would not answer.
    function _tryNavPerShare() internal view returns (uint256 value) {
        try vault.previewNavPerShareX18() returns (uint256 v) {
            return v;
        } catch {
            return 0;
        }
    }

    /// @dev `totalAssetsUsd18()` or zero. Never reverts.
    /// @return value `A`, or zero when the vault would not answer.
    function _tryTotalAssets() internal view returns (uint256 value) {
        try vault.totalAssetsUsd18() returns (uint256 v) {
            return v;
        } catch {
            return 0;
        }
    }

    /// @dev Whether the whole disclosure surface still answers: NAV/share, `A` and a 1-wei redemption preview.
    ///      This is the SPECIFIC half of GL-26, measured only where a handler has just done something hostile.
    /// @return ok True when every read answered.
    function _disclosureAnswers() internal view returns (bool ok) {
        try vault.previewNavPerShareX18() returns (uint256) {}
        catch {
            return false;
        }
        try vault.totalAssetsUsd18() returns (uint256) {}
        catch {
            return false;
        }
        try vault.previewRedeem(1) returns (address[] memory, uint256[] memory, uint256) {}
        catch {
            return false;
        }
        return true;
    }

    /// @dev The vault checkpoint's two stamps, read in one call so SP-26 costs one `checkpointData()` rather than
    ///      four.
    /// @return timestamp The checkpoint timestamp.
    /// @return blockNumber The checkpoint block number.
    function _checkpointStamp() internal view returns (uint32 timestamp, uint32 blockNumber) {
        try vault.checkpointData() returns (SpecCheckpoint memory cp) {
            return (cp.timestamp, cp.blockNumber);
        } catch {
            return (0, 0);
        }
    }

    /// @dev Every actor's AMPS balance, in `actors` order.
    /// @return balances The balances.
    function _actorAmps() internal view returns (uint256[] memory balances) {
        balances = new uint256[](actors.length);
        for (uint256 i; i < actors.length; ++i) {
            balances[i] = amps.balanceOf(actors[i]);
        }
    }

    /// @dev Every actor's claimable bond total, in `actors` order.
    /// @return totals The totals.
    function _actorClaimable() internal view returns (uint256[] memory totals) {
        totals = new uint256[](actors.length);
        for (uint256 i; i < actors.length; ++i) {
            try bonds.claimableTotal(actors[i]) returns (uint256 v) {
                totals[i] = v;
            } catch {
                totals[i] = 0;
            }
        }
    }
}
