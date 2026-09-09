// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IAmps} from "../interfaces/IAmps.sol";
import {IAmpsHook} from "../interfaces/IAmpsHook.sol";
import {IBountyPot} from "../interfaces/IBountyPot.sol";
import {IFeedRegistry} from "../interfaces/IFeedRegistry.sol";
import {ILadderPolicy} from "../interfaces/ILadderPolicy.sol";
import {IMarketReference} from "../interfaces/IMarketReference.sol";
import {IOracleGate} from "../interfaces/IOracleGate.sol";
import {IPoolRegistry} from "../interfaces/IPoolRegistry.sol";
import {IRolloutPolicy} from "../interfaces/IRolloutPolicy.sol";
import {LadderLib} from "../lib/LadderLib.sol";
import {PoolStateLib} from "../lib/PoolStateLib.sol";
import {PriceLib} from "../lib/PriceLib.sol";
import {Constants} from "../types/Constants.sol";
import {
    CellBudgetExceeded,
    HighWaterResetFailed,
    InsufficientInventory,
    OffGrid,
    PlacementCooldown,
    PlacementDiverged,
    RolloutLimitExceeded,
    UnknownConstituent,
    UnknownPool,
    WrongSide
} from "../types/Errors.sol";
import {ConstituentConfig, PlaceParams, Placed, PlacementRecord, PoolConfig} from "../types/Types.sol";
import {VaultRedeemLib} from "./VaultRedeemLib.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IExtsload} from "@uniswap/v4-core/src/interfaces/IExtsload.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

/// @title VaultPlacementLib
/// @notice The whole Phase 3 placement engine: genesis ladders, `compound`, rollout, bonded-stock deployment,
///         retired-bid withdrawal, the buyback burn and the §3.8 gauntlet. `docs/phase3-state-model.md` §3.
///
/// @dev **A linked `public` library, not a separate contract** (§3.1, §10 ruling 1). Every function here runs by
///      `DELEGATECALL` in `AmpsVault`'s context, so the PoolManager sees the *vault* as the position owner — which
///      is what keeps `beforeAddLiquidity(sender == vault)`, POL-only, I9, I35 and the custody boundary true. A
///      `Placer` contract reached by `CALL` would own the positions instead and break all four. The library
///      address is fixed in the vault's bytecode at link time; it holds no storage of its own, is not upgradeable,
///      and is part of the immutable vault for every governance purpose.
///
/// @dev **How it reads the vault.** Public library functions may take `storage` pointers, which is how the two
///      mappings that matter (`ladderAt`, `_lastPlacementAt`) arrive. Everything else — the governed parameter
///      word, the pointer set, the rollout window, the checkpoint — is read straight out of the vault's storage
///      **by slot**, because a `DELEGATECALL` shares it. That is deliberate: passing twenty-odd fields through a
///      memory struct the vault has to build costs the vault several hundred bytes of EIP-170 headroom it does not
///      have, and the layout those slots refer to is pinned field-for-field by `test/unit/VaultLayout.t.sol` and
///      documented in `docs/phase2-state-model.md` §1.1. {context} exposes the result so
///      `test/unit/VaultPlacement.t.sol` can assert it against the vault's own getters, and the two cannot drift.
///
/// @dev **The gauntlet is here, not in the policy** (§3.8). Gate, cooldown, divergence at entry *and* exit,
///      sidedness (I9), grid membership (I39) and the inventory bound are all re-derived from the pool's own
///      state; the ladder policy contributes the weight vector and nothing else. The two checks the library cannot
///      run itself — the transient lock and the R1 post-condition, which need the vault's NAV — are the vault
///      forwarder's, before and after.
///
/// @dev **What `Placed.amountPlaced` reports.** The per-cell split is exact — `LadderLib.split` carries the
///      flooring residue into the last element, so the cells sum to the requested inventory to the wei — but the
///      liquidity each cell buys rounds **down**, so what the PoolManager actually charges is a few wei less.
///      `amountPlaced` (and `PlacementRecord.amount`) report the *split*, which is what makes a ladder auditable
///      cell by cell against `ILadderPolicy`'s own vector; the settlement is the accumulated `modifyLiquidity`
///      delta, which is exact, and the difference stays with the vault as idle inventory rather than
///      disappearing.
///
/// @dev **Never `swap`, never `donate`.** Every conversion between AMPS and a counter asset happens because a
///      counterparty traded against a ladder. This file calls `modifyLiquidity`, `sync`, `settle`, `take`, `mint`
///      and `burn` on the PoolManager, and nothing else.
library VaultPlacementLib {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using SafeERC20 for IERC20;

    // -------------------------------------------------------------------------------------------------------------
    // The vault's storage, by slot (`docs/phase2-state-model.md` §1.1 and §11.5 of the Phase 3 model)
    // -------------------------------------------------------------------------------------------------------------

    /// @dev slot 0 [128..255] `pRefX18`.
    uint256 private constant SLOT_CHECKPOINT0 = 0;
    /// @dev slot 1 [0..127] `pMktX18`.
    uint256 private constant SLOT_CHECKPOINT1 = 1;
    /// @dev slot 2, the whole governed numeric set.
    uint256 private constant SLOT_PARAMS = 2;
    /// @dev slot 3 [0..159] `creator`, [160..191] `genesisTimestamp`.
    uint256 private constant SLOT_CREATOR = 3;
    /// @dev slot 4, the pool registry.
    uint256 private constant SLOT_REGISTRY = 4;
    /// @dev slot 7, the keeper bounty pot.
    uint256 private constant SLOT_BOUNTY_POT = 7;
    /// @dev slot 8, the market reference (`AmpsHook` in production).
    uint256 private constant SLOT_MARKET_REFERENCE = 8;
    /// @dev slot 9, the oracle gate.
    uint256 private constant SLOT_ORACLE_GATE = 9;
    /// @dev slot 10, the feed registry.
    uint256 private constant SLOT_FEED_REGISTRY = 10;
    /// @dev slot 12, the ladder policy.
    uint256 private constant SLOT_LADDER_POLICY = 12;
    /// @dev slot 13, the rollout policy.
    uint256 private constant SLOT_ROLLOUT_POLICY = 13;
    /// @dev slot 15 [0..127] `rolloutMoved24h`, [128..159] `rolloutWindowStart`.
    uint256 private constant SLOT_ROLLOUT_WINDOW = 15;
    /// @dev slot 20, `deployThresholdUsd18`.
    uint256 private constant SLOT_DEPLOY_THRESHOLD = 20;

    /// @dev `keccak256("amplestocks.vault.PLACEMENT_STAGE")`, the base of the transient staging buffer. Four
    ///      words per placed cell, `Constants.GRID_CELLS` cells. See {_stage}.
    ///
    ///      **Derived, not transcribed.** The literal that stood here was not the hash of the string the comment
    ///      names — it was an invented constant, so nothing tied the buffer's base to the namespace the rest of
    ///      the vault's transient slots are derived from, and the next slot anyone derived from that string would
    ///      silently have landed somewhere else. Taking it from `Constants` makes the two impossible to drift,
    ///      exactly as `VaultRedeemLib.LIVE_CELLS_SLOT` does; `test/unit/VaultPlacement.t.sol` pins the value.
    uint256 private constant STAGE_SLOT = uint256(Constants.PLACEMENT_STAGE_SLOT);

    // -------------------------------------------------------------------------------------------------------------
    // Types
    // -------------------------------------------------------------------------------------------------------------

    /// @notice The vault's parameters and pointers, gathered from storage once per entry point.
    /// @param registry The pool registry.
    /// @param bountyPot The keeper bounty pot.
    /// @param marketReference The truncated-observation source and high-water mark: `AmpsHook` in production.
    /// @param oracleGate The oracle gate.
    /// @param feedRegistry The feed registry.
    /// @param ladderPolicy The ladder shape policy; zero means `LadderLib`'s own weights.
    /// @param rolloutPolicy The rollout schedule; zero makes `rollout` a no-op.
    /// @param creator The creator-fee recipient.
    /// @param genesisTimestamp When `genesis()` ran, for the creator schedule.
    /// @param rolloutBpsPerDay Daily rollout budget, in bps of the POL tranche.
    /// @param entryFloorBps Entry-pool inventory floor, in bps of the POL tranche.
    /// @param tiltX18 The ladder tilt in force.
    /// @param ladderDoublings Ask-ladder bucket count.
    /// @param seedHalvings Seed bid-ladder bucket count.
    /// @param bondBidHalvings Bonded bid-ladder bucket count.
    /// @param deployThresholdUsd18 The idle-collateral floor `deployBonded` refuses below.
    /// @param pRefX18 The checkpointed reference price.
    /// @param pMktX18 The checkpointed market price.
    struct Ctx {
        address registry;
        address bountyPot;
        address marketReference;
        address oracleGate;
        address feedRegistry;
        address ladderPolicy;
        address rolloutPolicy;
        address creator;
        uint32 genesisTimestamp;
        uint16 rolloutBpsPerDay;
        uint16 entryFloorBps;
        uint64 tiltX18;
        uint8 ladderDoublings;
        uint8 seedHalvings;
        uint8 bondBidHalvings;
        uint256 deployThresholdUsd18;
        uint256 pRefX18;
        uint256 pMktX18;
    }

    /// @notice One pool, resolved: everything the gauntlet and the ladder arithmetic need.
    /// @param key The pool key.
    /// @param config The registry's record for the pool.
    /// @param tick `slot0.tick`, captured at entry.
    struct Pool {
        PoolKey key;
        PoolConfig config;
        int24 tick;
    }

    // -------------------------------------------------------------------------------------------------------------
    // Events — mirrors of {IAmpsVault}'s, emitted from the vault's own address by the `DELEGATECALL`
    // -------------------------------------------------------------------------------------------------------------

    /// @dev Mirrors `IAmpsVault.Placement`.
    event Placement(
        PoolId indexed poolId,
        bool above,
        uint8 buckets,
        uint256 amount,
        int24 anchorTick,
        bytes32 reason,
        int24 lowerTick,
        int24 upperTick
    );

    /// @dev Mirrors `IAmpsVault.Compound`.
    event Compound(
        PoolId indexed poolId,
        uint256 ampsFees,
        uint256 counterFees,
        uint256 creatorAmps,
        uint256 creatorCounter,
        uint256 burned
    );

    /// @dev Mirrors `IAmpsVault.Burn`.
    event Burn(uint256 amount, bytes32 reason);

    // -------------------------------------------------------------------------------------------------------------
    // Entry points — one per vault forwarder
    // -------------------------------------------------------------------------------------------------------------

    /// @notice Places one ladder into one pool. Backs `AmpsVault.place`, which is timelock-or-registry (ruling 11).
    /// @dev Asks are anchored at `tickOf(P_ref / P_counter)` and snapped **up** onto the grid, so an ask is never
    ///      placed below the protocol's own reference price; bids are anchored at the current tick and snapped
    ///      **down**. Genesis placement runs through here (§3.3).
    /// @param ladder The vault's placement records (slot 18).
    /// @param cooldown The vault's per-pool placement timestamps (slot 19).
    /// @param poolManager The Uniswap v4 PoolManager.
    /// @param amps The AMPS token.
    /// @param poolId The pool.
    /// @param above True for an ask ladder.
    /// @param amount The inventory to place.
    /// @param reason A short identifier for the event and the surge that follows.
    /// @param strictBudget True for the governance path, which **reverts** `CellBudgetExceeded` rather than
    ///        quietly placing less; false for the permissionless bountied paths, which merge into cells that
    ///        already exist and leave the remainder idle (§12 ruling E).
    /// @return placed The amount actually committed.
    function place(
        mapping(PoolId => PlacementRecord[]) storage ladder,
        mapping(PoolId => uint32) storage cooldown,
        address poolManager,
        address amps,
        PoolId poolId,
        bool above,
        uint256 amount,
        bytes32 reason,
        bool strictBudget
    ) public returns (uint256 placed) {
        Ctx memory ctx = _ctx();
        Pool memory pool = _gauntletEntry(ctx, cooldown, poolManager, poolId);
        _collectAndSplit(ladder, ctx, poolManager, amps, pool.key);

        // **The buyback settles before an ask placement, not after it** (audit fix, 2026-09-08; §3.5's ordering
        // rule). {_placeLadder} resets the pool's high-water mark on every ask placement, because an ask laid
        // under a mark older than itself would satisfy the burn predicate from the moment it opened. But the reset
        // also *discards* the window, so a `place`, a `rollout` or a `deployBonded` that landed before the next
        // `compound` erased the record that the price had crossed a cell on the way up — and the AMPS the vault
        // bought back on the way down stayed in the ladder to be sold a second time instead of being burned (I33).
        // `compound` settles the window itself at step 4; every other ask placement settles it here, so the rule
        // is the same everywhere: burn back, then place, then reset. The counter the burn frees stays as an
        // ERC-6909 claim, which `A` values and the placement below may spend.
        if (above) {
            (uint256 boughtBack,,) = _burnback(ladder, ctx, pool, poolManager, amps);
            if (boughtBack != 0) {
                IAmps(amps).burn(address(this), boughtBack);
                emit Burn(boughtBack, bytes32("buyback"));
            }
        }

        uint8 buckets;
        int24 anchor;
        if (above) {
            buckets = ctx.ladderDoublings;
            anchor = _referenceTick(ctx, pool);
        } else {
            buckets = pool.config.constituentId == 0 ? ctx.seedHalvings : ctx.bondBidHalvings;
            anchor = pool.tick;
        }

        placed =
            _placeLadder(ladder, ctx, pool, poolManager, amps, above, amount, anchor, buckets, reason, strictBudget);

        _requireConverged(ctx, poolManager, poolId, pool.config);

        // **The cooldown is the placement's, not the call's** (audit fix, 2026-09-07). Writing it unconditionally
        // meant a call that placed *nothing* — trivially reachable, and permissionlessly, because `rollout` and
        // `deployBonded` both reach here with `strictBudget == false` and a full live-cell budget places zero —
        // still denied the pool to a real `compound` or a governance `place` for `PLACEMENT_COOLDOWN_SECONDS`.
        // The cooldown exists to rate-limit *placements*; a no-op is not one, so it costs the pool nothing. It is
        // the same rule §3.6 step 8 applies to a zero-work `compound`.
        if (placed != 0) cooldown[poolId] = uint32(block.timestamp);
    }

    /// @notice The pool price every Amplestocks pool is opened at: the sqrt price of the greatest spacing-aligned
    ///         tick at or below the intended one (§12 ruling C).
    ///
    /// @dev **Why the vault aligns the opening price rather than trusting the caller.** The canonical grid's
    ///      origin is `alignUp(openingTick)`, and §3.3's cell indices — genesis asks at `m = 0..9`, seed bids at
    ///      `m = -1..-4` — only come out when the pool opens *exactly* on that origin. Off it the cell containing
    ///      the opening price is neither a pure-AMPS range nor a pure-counter one, so I9 forfeits it and the seed
    ///      bids fall a whole doubling lower than the launch parameters intend.
    ///
    ///      `PriceLib.ampsPerCounterToSqrtPriceX96` cannot land on a tick boundary — the target is one value in
    ///      2^96 — so the alignment has to be an explicit snap, and it belongs here rather than in `PoolRegistry`
    ///      because the vault is what the grid invariants are asserted against and it must hold for every pool
    ///      ever opened, including ones a future registry opens.
    ///
    /// @dev **Down, not to the nearest, and the reason is R1.** `LadderPositionValuer` decomposes every position
    ///      at `sqrtPrice(P_ref / P_counter)` (I7), not at the pool's price. Snapping *up* would put the grid
    ///      origin — and therefore the top seed-bid cell's upper bound — above the reference, so the valuer would
    ///      split that cell and write its AMPS half off at zero (I5); at genesis that is ~0.5% of the largest bid
    ///      bucket, about 7 bp of `A`, and the seed placement would revert on the 2 bp bleed bound. Snapping down
    ///      puts every bid cell strictly below the reference, where it is valued as pure counter.
    ///
    ///      The residue of the same asymmetry lands on the first *ask* cell, which straddles the reference by at
    ///      most one tick spacing and is credited with a phantom counter side worth up to ~10 bp of `A` at the
    ///      genesis vector. It is an over-statement, so it cannot trip R1, it is strictly smaller than what any
    ///      ordinary market move produces under the same I7 rule, and it decays as `P_ref` tracks the pool.
    /// @param sqrtPriceX96 The intended opening price.
    /// @param tickSpacing The pool's tick spacing.
    /// @return aligned The sqrt price of the greatest aligned tick at or below it.
    function alignedOpeningPrice(uint160 sqrtPriceX96, int24 tickSpacing) public pure returns (uint160 aligned) {
        return
            PriceLib.tickToSqrtPriceX96(
                PriceLib.alignTick(PriceLib.sqrtPriceX96ToTick(sqrtPriceX96), tickSpacing, false)
            );
    }

    /// @notice `compound(poolId)` in full: §3.6, steps 3 to 8.
    ///
    /// @dev **The split, since plan revision 6.** The hook charges `ampsFeeBps` on every net buy *and* every net
    ///      sell, so a pool's accrued fees arrive in both currencies and each of them is `ampsFeeBps` of the
    ///      volume that produced it. The creator therefore takes the same fraction of **each** currency —
    ///      `creatorBps(t) / ampsFeeBps`, which is exactly `creatorBps` of the trade volume — and everything else
    ///      splits by side:
    ///
    ///        * **AMPS side**: every wei left after the creator's slice is burned (`Burn("compound")`). Nothing is
    ///          re-laddered, so `compound` never places an ask and can never sell AMPS the protocol bought back.
    ///        * **Counter side**: the creator's slice is paid in kind inside the collect's own unlock; the rest is
    ///          re-placed as bids under the market, together with whatever counter the buyback freed.
    ///
    ///      The buyback burn is unchanged and is the second `Burn` this call can emit.
    ///
    /// @param ladder The vault's placement records.
    /// @param cooldown The vault's per-pool placement timestamps.
    /// @param poolManager The Uniswap v4 PoolManager.
    /// @param amps The AMPS token.
    /// @param poolId The pool.
    /// @param gasStart `gasleft()` as `AmpsVault.compound` was entered, for the measured gas allowance.
    /// @return ampsFees AMPS-side fees collected.
    /// @return burned AMPS burned: the whole AMPS-side fee remainder plus the whole high-water buyback.
    function compound(
        mapping(PoolId => PlacementRecord[]) storage ladder,
        mapping(PoolId => uint32) storage cooldown,
        address poolManager,
        address amps,
        PoolId poolId,
        uint256 gasStart
    ) public returns (uint256 ampsFees, uint256 burned) {
        Ctx memory ctx = _ctx();
        Pool memory pool = _gauntletEntry(ctx, cooldown, poolManager, poolId);
        (uint256 creatorBps, uint256 feeBps) = _creatorSlice(ctx, poolId);

        // 3. Collect, and pay the creator's counter-side slice in kind inside the same unlock. AMPS-side fees come
        //    out as ERC-20 so the burn and the creator's transfer below are plain calls; whatever counter is left
        //    after the creator's slice becomes an ERC-6909 claim, which `A` already values.
        uint256 counterFees;
        uint256 creatorCounter;
        (ampsFees, counterFees, creatorCounter) = _collect(ctx, poolManager, pool.key, creatorBps, feeBps);
        uint256 counter = counterFees - creatorCounter;

        // The measured work value, accumulated as the call earns it (§12.4 ruling W). The counter side is taken
        // here, before the burnback frees any inventory into the same claim: freed inventory is value the vault
        // already owned and moving it is not work the keeper created. The creator's slice is not work either — it
        // leaves the protocol — so what is counted is the counter this call actually re-places.
        uint256 workValueUsd18 = _counterValueUsd18(ctx, pool.config, counter);

        // 4. The buyback burn, first, so nothing this call places can be mistaken for bought-back inventory
        //    (§3.5's ordering rule).
        uint256 boughtBack;
        {
            uint256 freedCounter;
            uint256 feeBurn;
            (boughtBack, freedCounter, feeBurn) = _burnback(ladder, ctx, pool, poolManager, amps);
            if (boughtBack != 0) {
                IAmps(amps).burn(address(this), boughtBack);
                emit Burn(boughtBack, bytes32("buyback"));
                burned = boughtBack;
            }
            // Fees the removed cells had accrued and step 3 had not already collected are fees, not principal:
            // they went through the creator slice and the burn inside {_burnback}, never into the ladder.
            burned += feeBurn;
            counter += freedCounter;
        }

        // 5. The AMPS-side split: the creator's slice, and then every wei that is left is burned.
        uint256 creatorAmps;
        if (ampsFees != 0) {
            uint256 burnCut;
            (creatorAmps, burnCut) = _split(ctx.creator, amps, ampsFees, creatorBps, feeBps);
            burned += burnCut;
        }

        // The AMPS side of the work value is what this call took out of the float: the fee burn and the buyback.
        workValueUsd18 += ampsValueUsd18(burned);

        // 7. Re-add the counter side as bids strictly below the current tick, merging into the grid by cell.
        //
        //    Step 6 — re-laddering the fee AMPS as asks above the reference — is gone in revision 6: the AMPS-side
        //    fees are burned instead. That is what makes I10 ("ask inventory is genesis POL less sales and rollout
        //    moves") an equality rather than an inequality, and it removes the one path on which `compound` could
        //    re-sell AMPS the protocol had just bought back.
        uint256 placed;
        if (counter != 0) {
            placed = _placeLadder(
                ladder,
                ctx,
                pool,
                poolManager,
                amps,
                false,
                counter,
                pool.tick,
                pool.config.constituentId == 0 ? ctx.seedHalvings : ctx.bondBidHalvings,
                "compound",
                false
            );
        }

        // 8. Reset the mark and arm the surge, then the exit half of the divergence check.
        //
        //    All three side effects are gated on the call having *done* something. A `compound` that collected no
        //    fee, bought nothing back and placed nothing changed no position, so there is nothing to protect from
        //    a sandwich and nothing to date: arming the maximum surge would let anyone tax the pool at
        //    `SURGE_MAX_BPS` for free once a minute, resetting the mark would erase an excursion the *next*
        //    compound needs in order to recognise its own bought-back inventory, and taking the 60-second cooldown
        //    would let the same call deny a real `compound` (or a governance `place`) on that pool. The exit
        //    divergence check is **not** gated: it costs the caller nothing and is what proves the pool was not
        //    left mid-manipulation.
        //
        //    **The three are gated on three different facts** (audit fix, 2026-09-08). `burned != 0` used to gate
        //    the mark reset and the surge together, and it is satisfied by a *fee-only* burn — the AMPS side of
        //    one dust sell, which anybody can produce for the price of a swap. So an unprivileged caller could
        //    pin the pool's dynamic fee at `SURGE_MAX_BPS` and erase the pending buyback window once a block,
        //    because the 60-second cooldown was written only when something had been *placed* and a fee-only
        //    compound places nothing. Each effect now follows the fact it is actually about:
        //
        //      * the **mark** is the buyback's own bookkeeping, so it is reset only when inventory really was
        //        withdrawn and burned (`boughtBack != 0`). A fee burn withdraws nothing and discards no window;
        //      * the **surge** exists so a placement cannot be sandwiched at the pre-placement fee, so it is
        //        armed only when this call actually placed something (`placed != 0`);
        //      * the **cooldown** rate-limits the whole engine per pool, so it is taken whenever the call did any
        //        work at all — placed, or burned anything for any reason. That is what bounds the repetition of
        //        every effect above to once per `PLACEMENT_COOLDOWN_SECONDS`, the rate a legitimate compound runs
        //        at. A call that collected nothing, bought nothing back and placed nothing still costs the pool
        //        nothing: all three conditions are false and the pool is left exactly as it was.
        if (boughtBack != 0) _resetHighWater(ctx, poolId);
        if (placed != 0) _armSurge(ctx, poolId, "compound");
        if (placed != 0 || burned != 0) cooldown[poolId] = uint32(block.timestamp);
        _requireConverged(ctx, poolManager, poolId, pool.config);

        emit Compound(poolId, ampsFees, counterFees, creatorAmps, creatorCounter, burned);

        // A `compound` on a pool with no accrued fees and no crossed cell is worth exactly zero, so the pot's
        // `chost` dust guard refuses it and it is paid exactly zero.
        payBounty(workValueUsd18, gasStart, 1);
    }

    // -------------------------------------------------------------------------------------------------------------
    // The unlock callback's Phase 3 half (§3.9)
    // -------------------------------------------------------------------------------------------------------------

    /// @notice Executes one of the §3.9 actions inside the PoolManager's `unlock`.
    /// @dev Called only by `AmpsVault.unlockCallback`, which has already checked that the caller is the PoolManager
    ///      and that the transient discriminator is one the vault set immediately before unlocking.
    /// @param ladder The vault's placement records.
    /// @param poolManager The Uniswap v4 PoolManager.
    /// @param action The §3.9 action.
    /// @param data The action's ABI-encoded payload.
    /// @return result The action's ABI-encoded answer.
    function unlockAction(
        mapping(PoolId => PlacementRecord[]) storage ladder,
        address poolManager,
        uint256 action,
        bytes calldata data
    ) public returns (bytes memory result) {
        if (action == VaultRedeemLib.ACTION_PLACE) {
            (PlaceParams memory params, bool strictBudget) = abi.decode(data, (PlaceParams, bool));
            return abi.encode(_executePlace(ladder, poolManager, params, strictBudget));
        }
        if (action == VaultRedeemLib.ACTION_COMPOUND) {
            (PoolKey memory collectKey, address creator, uint256 creatorBps, uint256 feeBps) =
                abi.decode(data, (PoolKey, address, uint256, uint256));
            (uint256 ampsFees, uint256 counterFees, uint256 creatorCounter) =
                _executeCollect(ladder, poolManager, collectKey, creator, creatorBps, feeBps);
            return abi.encode(ampsFees, counterFees, creatorCounter);
        }
        // ACTION_BURNBACK and ACTION_HARVEST are the same mechanics — remove named cells whole, keep the AMPS as
        // an idle ERC-20 balance and the counter as claims — and differ only in why the caller asked. They keep
        // separate discriminators because §3.9 gives them separate names and the indexer decodes on them.
        (PoolKey memory key, int24[] memory lowers, uint128[] memory removals) =
            abi.decode(data, (PoolKey, int24[], uint128[]));
        (uint256 principal0, uint256 principal1, uint256 fees0, uint256 fees1) =
            _executeHarvest(poolManager, key, lowers, removals);
        return abi.encode(principal0, principal1, fees0, fees1);
    }

    // -------------------------------------------------------------------------------------------------------------
    // Internals — the gauntlet (§3.8)
    // -------------------------------------------------------------------------------------------------------------

    /// @dev Steps 2, 3 and 6 of the gauntlet, plus the pool resolution every caller needs. Step 1 (the transient
    ///      lock and `_requirePlaceable`), step 7 (R1) and step 9 (`_sweepClean`) belong to the vault's forwarder;
    ///      steps 4 and 5 (sidedness and the grid) are per bucket and live in {_executePlace}.
    function _gauntletEntry(
        Ctx memory ctx,
        mapping(PoolId => uint32) storage cooldown,
        address poolManager,
        PoolId poolId
    ) private view returns (Pool memory pool) {
        // 2. The gate. `REF_DIVERGED` is permitted and has already forced `pRefX18 == navPerShareX18` at the last
        //    checkpoint, which is what "forces the NAV anchor" means in a vault that anchors on the checkpoint.
        if (ctx.oracleGate != address(0)) IOracleGate(ctx.oracleGate).checkPlacement(poolId);

        // 6. The 60-second per-pool cooldown.
        uint32 last = cooldown[poolId];
        if (last != 0 && block.timestamp < uint256(last) + Constants.PLACEMENT_COOLDOWN_SECONDS) {
            revert PlacementCooldown(PoolId.unwrap(poolId), last + Constants.PLACEMENT_COOLDOWN_SECONDS);
        }

        pool.config = IPoolRegistry(ctx.registry).poolConfig(poolId);
        if (!pool.config.registered) revert UnknownPool(PoolId.unwrap(poolId));
        pool.key = IPoolRegistry(ctx.registry).poolKey(poolId);
        (, pool.tick) = PoolStateLib.sqrtPriceAndTick(IExtsload(poolManager), poolId);

        // 3. Divergence, at entry.
        _requireConverged(ctx, poolManager, poolId, pool.config);
    }

    /// @dev Gauntlet step 3: `|slot0.tick - tickOf(P_mkt / P_i)| <= PLACEMENT_DIVERGENCE_TICKS`, checked at the
    ///      entry *and* the exit of every placement so it cannot be sandwiched into a manipulated tick. The fair
    ///      tick is measured against the checkpointed `P_mkt` — the hub's 30-minute truncated TWAP — rather than
    ///      against the pool's own price, which is what makes it a check at all. When there is no usable `P_mkt`
    ///      (a pool younger than the TWAP window, a counter with no answer) the reference price stands in, and
    ///      when neither exists the check is skipped rather than making genesis unreachable.
    function _requireConverged(Ctx memory ctx, address poolManager, PoolId poolId, PoolConfig memory config)
        private
        view
    {
        uint256 priceUsd18 = ctx.pMktX18 != 0 ? ctx.pMktX18 : ctx.pRefX18;
        uint256 answerUsd8 = _answer(ctx.feedRegistry, config.counter);
        if (priceUsd18 == 0 || answerUsd8 == 0 || config.counterDecimals > PriceLib.MAX_COUNTER_DECIMALS) return;

        int24 fair = PriceLib.fairTick(priceUsd18, answerUsd8, config.counterDecimals, config.tickSpacing);
        (, int24 tick) = PoolStateLib.sqrtPriceAndTick(IExtsload(poolManager), poolId);
        int24 deviation = tick > fair ? tick - fair : fair - tick;
        if (deviation > Constants.PLACEMENT_DIVERGENCE_TICKS) {
            revert PlacementDiverged(PoolId.unwrap(poolId), tick, fair, Constants.PLACEMENT_DIVERGENCE_TICKS);
        }
    }

    // -------------------------------------------------------------------------------------------------------------
    // Internals — the ladder
    // -------------------------------------------------------------------------------------------------------------

    /// @dev Builds one ladder on the pool's canonical grid, hands it to the unlock and records what came back.
    ///
    /// @dev **Every ask placement resets the high-water mark** (§3.5's ordering rule, in the one place that can
    ///      enforce it). The mark is what {_burnback} calls "this cell was sold as an ask"; an ask placed while a
    ///      stale excursion's mark still stands would satisfy `upper <= highWater` from the moment it is opened
    ///      and be burned as bought-back inventory on the next `compound`, having never been sold. Doing it here
    ///      rather than only at the end of `compound` covers `place` and `rollout` too, which is what makes the
    ///      rule unconditional: *no* ask exists under a mark older than itself.
    function _placeLadder(
        mapping(PoolId => PlacementRecord[]) storage ladder,
        Ctx memory ctx,
        Pool memory pool,
        address poolManager,
        address amps,
        bool above,
        uint256 amount,
        int24 anchorTick,
        uint8 buckets,
        bytes32 reason,
        bool strictBudget
    ) private returns (uint256 placed) {
        if (amount == 0 || buckets == 0) return 0;

        Currency currency = above ? pool.key.currency0 : pool.key.currency1;
        address token = above ? amps : Currency.unwrap(pool.key.currency1);
        uint256 available = IPoolManager(poolManager).balanceOf(address(this), currency.toId()) + _probeBalance(token);
        if (amount > available) revert InsufficientInventory(amount, available);

        PlaceParams memory params = PlaceParams({
            key: pool.key,
            poolClass: pool.config.poolClass,
            above: above,
            amount: amount,
            anchorTick: anchorTick,
            currentTick: pool.tick,
            gridBaseTick: pool.config.gridBaseTick,
            buckets: buckets,
            tiltX18: ctx.tiltX18 == 0 ? Constants.LADDER_TILT_X18_DEFAULT : ctx.tiltX18,
            reason: reason
        });

        Placed memory result =
            abi.decode(_unlock(poolManager, VaultRedeemLib.ACTION_PLACE, abi.encode(params, strictBudget)), (Placed));
        if (result.cells == 0) return 0;

        _writeRecords(ladder, pool.key.toId(), params, result);
        placed = result.amountPlaced;
        emit Placement(
            pool.key.toId(), above, result.cells, placed, anchorTick, reason, result.lowestTick, result.highestTick
        );
        // §3.5's ordering rule, and it is a **hard** requirement on the ask side (audit fix, 2026-09-07). See
        // {HighWaterResetFailed}: an ask that keeps a mark older than itself is burned as inventory it never was.
        //
        // **Both effects are the ask side's alone** (audit fix, 2026-09-08). The surge used to be armed for any
        // committed cell, bids included, which handed `compound`'s step-7 bid re-ladder — reachable with one wei
        // of counter fee — the power to arm `SURGE_MAX_BPS`, the exact hole step 8's gating was written to close.
        // A bid is laid *below* the tick out of value the pool already holds: it cannot be sandwiched at the
        // pre-placement fee the way an ask can, it is not a burn candidate under §3.5's predicate, and it has no
        // business touching the mark. `compound` arms its own surge for the bids it places, once, under its own
        // cooldown, and the ask side keeps the hard reset.
        if (above) {
            if (!_resetHighWater(ctx, pool.key.toId())) revert HighWaterResetFailed(PoolId.unwrap(pool.key.toId()));
            _armSurge(ctx, pool.key.toId(), reason);
        }
    }

    /// @dev The whole of the ACTION_PLACE branch: cell selection, sidedness (I9), grid membership (I39), the
    ///      weight split, `modifyLiquidity` per cell and one settlement of the accumulated delta.
    function _executePlace(
        mapping(PoolId => PlacementRecord[]) storage ladder,
        address poolManager,
        PlaceParams memory p,
        bool strictBudget
    ) private returns (Placed memory result) {
        int24 width = LadderLib.doublingTicks(p.key.tickSpacing);
        (uint160 sqrtPriceX96,) = PoolStateLib.sqrtPriceAndTick(IExtsload(poolManager), p.key.toId());
        (int256 firstCell, uint256 count) = _cells(p, width, sqrtPriceX96);
        if (count == 0) return result;

        uint256[] memory amounts = LadderLib.split(p.amount, _weights(p.tiltX18, uint8(count)));
        PlacementRecord[] storage records = ladder[p.key.toId()];
        uint32 live = VaultRedeemLib.liveCellCount();
        int256 owed0;
        int256 owed1;

        for (uint256 k; k < count; ++k) {
            // Ask cells rise with `k`, bid cells fall with `k`; the weight vector always runs with price, so the
            // cell nearest the anchor is the smallest ask and the largest bid.
            int24 lower = int24(
                int256(p.gridBaseTick) + (p.above ? firstCell + int256(k) : firstCell - int256(k)) * int256(width)
            );
            uint256 amount = p.above ? amounts[k] : amounts[count - 1 - k];
            if (amount == 0) continue;

            // §12 ruling E. A cell that already holds liquidity is free to merge into; opening a new one spends
            // budget, and the budget is what bounds the gas of `redeemProRata`. Governance refuses to place at
            // all rather than silently placing less; the bountied paths merge what they can and leave the rest
            // idle, so a full vault degrades into "compound keeps working" rather than "compound reverts".
            bool opensCell = _cellIsEmpty(records, lower);
            if (opensCell && live >= Constants.MAX_LIVE_CELLS) {
                if (strictBudget) {
                    revert CellBudgetExceeded(PoolId.unwrap(p.key.toId()), live, Constants.MAX_LIVE_CELLS);
                }
                continue;
            }

            (uint128 liquidity, int256 delta0, int256 delta1) =
                _placeCell(poolManager, p, lower, width, amount, sqrtPriceX96);
            // The budget is spent on cells that actually opened (audit fix, 2026-09-08): `++live` used to run
            // before the placement, so a bucket whose amount could not buy one unit of liquidity over its range
            // consumed a slot it never used. On the strict governance path that turned into a `CellBudgetExceeded`
            // with real headroom left; on the bountied paths a caller could walk the ladder's dust cells to pin
            // the count. Nothing else moves: the *refusal* above still happens before any state changes.
            if (liquidity == 0) continue;
            if (opensCell) ++live;

            owed0 += delta0;
            owed1 += delta1;
            // Both bounds are *seeded* by the first cell rather than grown from zero: every Amplestocks tick is
            // negative (AMPS is currency0 and one AMPS is worth far less than one counter unit), so a
            // `highestTick` left at its zero value would be reported by `Placement` as the ladder's top for every
            // placement, and no comparison against it would ever be true.
            if (result.cells == 0 || lower < result.lowestTick) result.lowestTick = lower;
            if (result.cells == 0 || lower + width > result.highestTick) result.highestTick = lower + width;
            _stage(result.cells, lower, lower + width, liquidity, amount);
            result.cells += 1;
            result.liquidityAdded += liquidity;
            result.amountPlaced += amount;
        }

        // One settlement for the whole ladder: ERC-6909 claims first, then any idle ERC-20 the vault still holds.
        _settle(poolManager, p.key.currency0, owed0);
        _settle(poolManager, p.key.currency1, owed1);
    }

    /// @dev Whether the pool holds no liquidity in the cell starting at `lower`, i.e. whether placing there would
    ///      open a *new* live cell. Used identically here and in {_writeRecords}, on the same unchanged storage,
    ///      so the budget decision and the count can never disagree.
    function _cellIsEmpty(PlacementRecord[] storage records, int24 lower) private view returns (bool empty) {
        uint256 n = records.length;
        for (uint256 i; i < n; ++i) {
            if (records[i].lowerTick == lower) return records[i].liquidity == 0;
        }
        return true;
    }

    /// @dev One cell: the two per-bucket gauntlet checks, the amount-to-liquidity conversion and the add. A
    ///      zero-liquidity answer means the amount could not buy one unit of liquidity over that range; the cell
    ///      is skipped and the inventory stays with the vault rather than disappearing.
    function _placeCell(
        address poolManager,
        PlaceParams memory p,
        int24 lower,
        int24 width,
        uint256 amount,
        uint160 sqrtPriceX96
    ) private returns (uint128 liquidity, int256 delta0, int256 delta1) {
        int24 upper = lower + width;
        _requireOnGrid(p, lower, upper, width);
        _requireSide(p, lower, upper, sqrtPriceX96);

        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(lower);
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(upper);
        liquidity = p.above
            ? LadderLib.liquidityForAmount0Above(sqrtLower, sqrtUpper, amount)
            : LadderLib.liquidityForAmount1Below(sqrtLower, sqrtUpper, amount);
        if (liquidity == 0) return (0, 0, 0);

        (BalanceDelta callerDelta,) = IPoolManager(poolManager)
            .modifyLiquidity(
                p.key,
                ModifyLiquidityParams({
                    tickLower: lower,
                    tickUpper: upper,
                    liquidityDelta: int256(uint256(liquidity)),
                    salt: Constants.POSITION_SALT
                }),
                ""
            );
        delta0 = int256(callerDelta.amount0());
        delta1 = int256(callerDelta.amount1());
    }

    /// @dev The cells a ladder occupies: the index of the cell nearest the anchor, and how many.
    ///
    ///      Asks run **up** from the anchor snapped up, and never start at or below the current tick, so every ask
    ///      position is AMPS-only (I9). Bids run **down** from the anchor snapped down, and every bid cell's upper
    ///      bound is at or below the current tick, so every bid position is counter-only.
    ///
    ///      The count is clipped to the grid's own bounds rather than reverting. A pool that has run most of the
    ///      way up its ladder still compounds — it simply has fewer cells left to place into, and the weights
    ///      renormalise over the cells that remain, so I34 holds for the placement that actually happens. Reverting
    ///      instead would let a successful pool's own price growth brick its `compound`.
    function _cells(PlaceParams memory p, int24 width, uint160 sqrtPriceX96)
        private
        pure
        returns (int256 first, uint256 count)
    {
        int256 base = int256(p.gridBaseTick);
        int256 w = int256(width);
        if (p.above) {
            int256 fromAnchor = _ceilDiv(int256(p.anchorTick) - base, w);
            // Exact v4 terms (§12 ruling C): a cell is a pure-AMPS range as soon as its lower bound's sqrt price
            // is at or above the pool's, so a pool sitting exactly on a grid boundary may place into the cell
            // that starts there. Only a price strictly inside a cell forfeits it.
            int256 fromTick = TickMath.getSqrtPriceAtTick(p.currentTick) == sqrtPriceX96
                ? _ceilDiv(int256(p.currentTick) - base, w)
                : _floorDiv(int256(p.currentTick) - base, w) + 1;
            first = fromAnchor > fromTick ? fromAnchor : fromTick;
            if (first < Constants.GRID_MIN_M) first = Constants.GRID_MIN_M;
            if (first >= Constants.GRID_MAX_M) return (first, 0);
            count = uint256(int256(Constants.GRID_MAX_M) - first);
        } else {
            int256 fromAnchor = _floorDiv(int256(p.anchorTick) - base, w) - 1;
            int256 fromTick = _floorDiv(int256(p.currentTick) - base, w) - 1;
            first = fromAnchor < fromTick ? fromAnchor : fromTick;
            if (first >= Constants.GRID_MAX_M) first = int256(Constants.GRID_MAX_M) - 1;
            if (first < Constants.GRID_MIN_M) return (first, 0);
            count = uint256(first - Constants.GRID_MIN_M + 1);
        }
        if (count > p.buckets) count = p.buckets;
        if (count > LadderLib.MAX_BUCKETS) count = LadderLib.MAX_BUCKETS;
    }

    /// @dev Gauntlet step 5, I39: the bucket is exactly one cell of the pool's canonical doubling grid.
    function _requireOnGrid(PlaceParams memory p, int24 lower, int24 upper, int24 width) private pure {
        int256 offset = int256(lower) - int256(p.gridBaseTick);
        int256 cell = offset / int256(width);
        if (
            offset % int256(width) != 0 || upper - lower != width || lower < TickMath.MIN_TICK
                || upper > TickMath.MAX_TICK || cell < Constants.GRID_MIN_M || cell >= Constants.GRID_MAX_M
        ) {
            revert OffGrid(PoolId.unwrap(p.key.toId()), lower, p.gridBaseTick, width);
        }
    }

    /// @dev Gauntlet step 4, I9, unconditional, in **exact v4 terms** (§12 ruling C).
    ///
    ///      v4 decomposes a position by comparing `slot0.tick` with the range, and `slot0.tick` is the greatest
    ///      tick whose sqrt price is at or below `slot0.sqrtPriceX96`. So:
    ///
    ///        * an ask holds only AMPS iff `sqrtPriceX96 <= sqrtPriceAtTick(lowerTick)` — at equality the range
    ///          `[sqrtPriceX96, sqrtLower]` v4 would price the counter side over is degenerate, so `amount1` is
    ///          exactly zero;
    ///        * a bid holds only the counter iff `sqrtPriceX96 >= sqrtPriceAtTick(upperTick)`.
    ///
    ///      Comparing ticks instead (`lower > currentTick`) is strictly narrower and would forfeit the cell a
    ///      grid-aligned pool opens exactly on — which is the cell §3.3 puts the first genesis ask in.
    function _requireSide(PlaceParams memory p, int24 lower, int24 upper, uint160 sqrtPriceX96) private pure {
        if (p.above) {
            if (sqrtPriceX96 > TickMath.getSqrtPriceAtTick(lower)) {
                revert WrongSide(PoolId.unwrap(p.key.toId()), true, lower, p.currentTick);
            }
        } else if (sqrtPriceX96 < TickMath.getSqrtPriceAtTick(upper)) {
            revert WrongSide(PoolId.unwrap(p.key.toId()), false, upper, p.currentTick);
        }
    }

    // -------------------------------------------------------------------------------------------------------------
    // Internals — records
    // -------------------------------------------------------------------------------------------------------------

    /// @dev Merges the staged cells into the pool's records **by cell** (§3.2): two placements over the same range
    ///      are one position at the PoolManager, so appending a second record for that range would double-count.
    function _writeRecords(
        mapping(PoolId => PlacementRecord[]) storage ladder,
        PoolId poolId,
        PlaceParams memory p,
        Placed memory result
    ) private {
        PlacementRecord[] storage records = ladder[poolId];
        int24 width = LadderLib.doublingTicks(p.key.tickSpacing);
        uint32 opened;

        for (uint256 s; s < result.cells; ++s) {
            (int24 lower, int24 upper, uint128 liquidity, uint256 amount) = _staged(s);
            uint8 index =
                uint8(uint256((int256(lower) - int256(p.gridBaseTick)) / int256(width) - Constants.GRID_MIN_M));

            uint256 n = records.length;
            uint256 at = n;
            for (uint256 i; i < n; ++i) {
                if (records[i].lowerTick == lower) {
                    at = i;
                    break;
                }
            }

            if (at == n) {
                // The grid bounds the record count at `GRID_CELLS` by construction; the check is here so a future
                // placement kind cannot quietly turn `redeemProRata`'s bounded loop into an unbounded one.
                if (n >= Constants.GRID_CELLS) revert OffGrid(PoolId.unwrap(poolId), lower, p.gridBaseTick, width);
                ++opened;
                records.push(
                    PlacementRecord({
                        lowerTick: lower,
                        upperTick: upper,
                        liquidity: liquidity,
                        bucketIndex: index,
                        buckets: result.cells,
                        above: p.above,
                        placedAt: uint32(block.timestamp),
                        amount: _toUint128(amount),
                        tiltX18: p.tiltX18,
                        anchorTick: p.anchorTick
                    })
                );
            } else {
                PlacementRecord storage record = records[at];
                if (record.liquidity == 0) ++opened;
                record.liquidity += liquidity;
                record.amount = _toUint128(uint256(record.amount) + amount);
                record.bucketIndex = index;
                record.buckets = result.cells;
                record.above = p.above;
                record.placedAt = uint32(block.timestamp);
                record.tiltX18 = p.tiltX18;
                record.anchorTick = p.anchorTick;
            }
        }

        VaultRedeemLib.addLiveCells(opened);
    }

    /// @dev The lower ticks of a pool's records, in record order.
    function _lowers(PlacementRecord[] storage records) private view returns (int24[] memory lowers) {
        uint256 n = records.length;
        lowers = new int24[](n);
        for (uint256 i; i < n; ++i) {
            lowers[i] = records[i].lowerTick;
        }
    }

    // -------------------------------------------------------------------------------------------------------------
    // Internals — compound's pieces
    // -------------------------------------------------------------------------------------------------------------

    /// @dev ACTION_COMPOUND: `modifyLiquidity(0)` over every record realises `feesAccrued` without moving
    ///      principal. AMPS comes out as ERC-20 so the splits are plain transfers; the counter side becomes a
    ///      claim. Fees earned while no position was in range were never credited by v4 and are not ours to claim
    ///      (§10 ruling 13).
    ///
    /// @dev **The creator's counter-side slice is paid as an ERC-6909 claim, and no token code runs inside the
    ///      unlock** (audit fix, 2026-09-08). The fee is charged in both currencies since revision 6, so the
    ///      creator is owed `creatorBps / ampsFeeBps` of the counter as well as of the AMPS — and the counter is a
    ///      Stock Token or WETH, not AMPS, so paying it *in kind* would mean an ERC-20 `transfer` to an address
    ///      the protocol does not control, from inside the vault's own `unlock`.
    ///
    ///      That is the one place such a transfer must never happen, and a gas cap does not make it safe. A
    ///      `try pm.take{gas: ...}` catches a revert, but a token whose `transfer` returns *normally* having
    ///      opened its own PoolManager delta — a re-entrant `sync`, a `settle` of its own, any touch of the
    ///      manager during the unlock — leaves that delta unsettled, and the unlock then fails with
    ///      `CurrencyNotSettled` **outside** the `catch`, beyond the reach of any fallback. Since the whole point
    ///      of the bounded `take` was that a hostile issuer must not be able to stop a `compound`, and it can, the
    ///      `take` is gone: the whole positive delta is minted as claims and the creator's slice moves by
    ///      `pm.transfer`, an ERC-6909 book entry no token can refuse, block or re-enter. The creator burns the
    ///      claim for the token whenever the token allows it, exactly as they did on the old fallback path.
    ///
    ///      The AMPS side needs no such treatment: `_split` transfers AMPS — the protocol's own token, with no
    ///      hooks and no denylist — and it runs *after* the unlock has closed, so nothing it touches can open a
    ///      delta inside one.
    ///
    ///      **The slice is of the *fees* and of nothing else.** It is computed and paid before the buyback frees
    ///      any counter into the same claim balance, so inventory the vault bought back — which is not fee income
    ///      — can never be paid out under the creator's schedule.
    /// @param ladder The vault's placement records.
    /// @param poolManager The Uniswap v4 PoolManager.
    /// @param key The pool.
    /// @param creator The creator-fee recipient, or zero when there is nothing to pay.
    /// @param creatorBps The creator's points of the volume, already clamped to `feeBps`.
    /// @param feeBps The live `ampsFeeBps`, the divisor that turns collected fees back into volume.
    /// @return ampsFees AMPS-side fees realised, gross.
    /// @return counterFees Counter-side fees realised, gross.
    /// @return creatorCounter The part of `counterFees` the creator was paid.
    function _executeCollect(
        mapping(PoolId => PlacementRecord[]) storage ladder,
        address poolManager,
        PoolKey memory key,
        address creator,
        uint256 creatorBps,
        uint256 feeBps
    ) private returns (uint256 ampsFees, uint256 counterFees, uint256 creatorCounter) {
        PlacementRecord[] storage records = ladder[key.toId()];
        uint256 n = records.length;
        int256 fees0;
        int256 fees1;

        for (uint256 i; i < n; ++i) {
            if (records[i].liquidity == 0) continue;
            (, BalanceDelta feesAccrued) = IPoolManager(poolManager)
                .modifyLiquidity(
                    key,
                    ModifyLiquidityParams({
                        tickLower: records[i].lowerTick,
                        tickUpper: records[i].upperTick,
                        liquidityDelta: 0,
                        salt: Constants.POSITION_SALT
                    }),
                    ""
                );
            fees0 += int256(feesAccrued.amount0());
            fees1 += int256(feesAccrued.amount1());
        }

        if (fees0 > 0) {
            ampsFees = uint256(fees0);
            IPoolManager(poolManager).take(key.currency0, address(this), ampsFees);
        }
        if (fees1 <= 0) return (ampsFees, 0, 0);

        counterFees = uint256(fees1);
        IPoolManager pm = IPoolManager(poolManager);
        uint256 id = key.currency1.toId();

        if (creator != address(0) && creatorBps != 0) {
            creatorCounter = FullMath.mulDiv(counterFees, creatorBps, feeBps);
        }
        // The whole positive delta becomes a claim, and the creator's slice is handed over as one: an ERC-6909
        // balance the PoolManager owes them, which they burn for the token whenever the token allows it.
        pm.mint(address(this), id, counterFees);
        if (creatorCounter != 0) pm.transfer(creator, id, creatorCounter);
    }

    /// @dev Realises and splits a pool's accrued fees **before** a placement is allowed to merge into one of its
    ///      live cells, and a no-op on a pool that has no records yet.
    ///
    /// @dev **The finding this closes** (audit fix, 2026-09-07). `modifyLiquidity` returns
    ///      `callerDelta = principalDelta + feesAccrued`, so adding liquidity to a range that already holds some
    ///      *nets that range's unclaimed fees into the settlement*: {_settle} paid the difference, and the AMPS
    ///      side of those fees went straight back into the ladder without ever passing the creator slice and the
    ///      burn of §3.6 step 5. `compound` was unaffected — it collects everything first, which is why the split
    ///      exists on that path at all — but `place`, `rollout` and `deployBonded` all merge by cell
    ///      (§3.2) and all reached `modifyLiquidity` with fees outstanding, so any pool that had traded since its
    ///      last `compound` quietly recycled its own AMPS-side fees at the next placement. Collecting first fixes
    ///      both halves at once: the creator's slice and the burn are taken exactly as `compound` takes them, and
    ///      every `callerDelta` the placement then sees is principal and nothing else.
    ///
    ///      The counter side becomes an ERC-6909 claim, exactly as it does inside `compound`; `A` values it and
    ///      the placement itself may spend it. The AMPS side leaves nothing behind: since revision 6 every wei of
    ///      it after the creator's slice is burned here and now, so a placement can no longer inherit fee AMPS as
    ///      free inventory — which is precisely the recycling this function exists to stop.
    function _collectAndSplit(
        mapping(PoolId => PlacementRecord[]) storage ladder,
        Ctx memory ctx,
        address poolManager,
        address amps,
        PoolKey memory key
    ) private {
        if (ladder[key.toId()].length == 0) return;
        (uint256 creatorBps, uint256 feeBps) = _creatorSlice(ctx, key.toId());
        (uint256 ampsFees,,) = _collect(ctx, poolManager, key, creatorBps, feeBps);
        if (ampsFees != 0) _split(ctx.creator, amps, ampsFees, creatorBps, feeBps);
    }

    /// @dev §3.5, the buyback burn. A cell whose upper bound the hook's high-water mark has crossed since the last
    ///      reset was fully sold as an ask, so AMPS sitting in it now is inventory the vault bought back on the way
    ///      down and must burn (I33). A cell qualifies only when **both** are true:
    ///
    ///      * `upper <= highWater` — the mark crossed the whole cell, so it really was sold as an ask; and
    ///      * `tick <= lower` — the price has come **all the way back through** it, so what the cell holds now is
    ///        AMPS and nothing else (a position whose lower bound is at or above `slot0.tick` is a pure-`amount0`
    ///        range in v4's own decomposition), and `freedCounter` is therefore accrued fees rather than
    ///        somebody's proceeds.
    ///
    ///      Everything else is left alone: `tick >= upper` is pure counter and nothing was bought back, and
    ///      `lower < tick < upper` is a cell the price has only *partly* re-crossed.
    ///
    ///      **Why the second condition is `tick <= lower` and not `tick < upper`** (the finding this closes). The
    ///      old predicate skipped only `tick >= upper`, so it took two kinds of cell it had no business taking:
    ///
    ///        1. *Every bid this library places.* Step 7 lays bids strictly **below** the tick and step 8 only then
    ///           resets the mark, so a fresh bid cell satisfies `upper <= highWater` from birth. One tick of
    ///           downward drift into the top bid cell made it "crossed", and the next permissionless `compound`
    ///           withdrew the whole cell, burned its AMPS and re-laid the counter a full doubling lower — a
    ///           one-way ratchet of the bid ladder available once every `PLACEMENT_COOLDOWN_SECONDS`.
    ///        2. *A partially bought-back ask.* A cell the price has re-entered but not re-crossed still holds the
    ///           counter a real trade paid for it; removing it whole re-prices that trade's proceeds.
    ///
    ///      The companion half of the fix is in {_placeLadder}: the mark is reset after **every** ask placement,
    ///      not only at the end of `compound`, so no ask can inherit a stale excursion's high-water mark and be
    ///      burned as inventory it never was.
    ///
    ///      **Deviation from ruling 8 and from §3.5's `lower < tick < upper` row, deliberate.** The ruling removes
    ///      the straddled cell too and re-places its counter side over `[lower, alignDown(tick)]`, which is *not* a
    ///      cell of the canonical grid — it is a fraction of one. That range would be invisible to
    ///      `LadderPositionValuer`, which enumerates whole cells (§4), so `A` would drop by its whole value and the
    ///      R1 post-condition would revert the very `compound` that created it, and it would break I39. Straddled
    ///      cells are therefore not touched at all; they are burned by a later `compound`, once the price has
    ///      finished coming back through them. Whatever counter the burn *does* free (fees, and the last tick's
    ///      worth of a cell the price sits exactly on the floor of) is held as a claim — §3.5's own fallback for a
    ///      degenerate range — and re-enters the ladder in step 7 of the same `compound` as a proper grid bid.
    ///      Nothing leaves the pool's economy; only the prices it bids at are re-derived.
    function _burnback(
        mapping(PoolId => PlacementRecord[]) storage ladder,
        Ctx memory ctx,
        Pool memory pool,
        address poolManager,
        address amps
    ) private returns (uint256 burnedAmps, uint256 freedCounter, uint256 feeBurn) {
        PoolId poolId = pool.key.toId();
        int24 highWater = _highWater(poolId);
        if (highWater == type(int24).min) return (0, 0, 0);

        PlacementRecord[] storage records = ladder[poolId];
        uint256 n = records.length;
        if (n == 0) return (0, 0, 0);

        uint128[] memory removals = new uint128[](n);
        uint32 closed;
        for (uint256 i; i < n; ++i) {
            PlacementRecord storage record = records[i];
            // `record.above` is the third clause and it is not redundant (audit fix, 2026-09-08). A *bid* cell the
            // price has fallen entirely below satisfies both geometric clauses — its upper bound is under a mark
            // set while the price was higher, and the tick is under its lower bound — so the predicate admitted
            // every filled bid in the book. Those cells are the counter side of the ladder, and removing them
            // whole re-prices a real trade's proceeds: the burn is NAV-dilutive whenever the fill happened above
            // NAV/share, and valued counterfactually at the checkpoint's reference it can breach the 2 bp R1
            // bound and revert the very `compound` that made it. Only an ask can have been *sold* as one, and
            // only what was sold can have been bought back.
            if (!record.above || record.liquidity == 0 || record.upperTick > highWater || pool.tick > record.lowerTick) continue;
            removals[i] = record.liquidity;
            record.liquidity = 0;
            // The gross-placed counter goes with the liquidity it described: see {_writeRecords}.
            record.amount = 0;
            record.above = false;
            ++closed;
        }
        if (closed == 0) return (0, 0, 0);
        VaultRedeemLib.subLiveCells(closed);

        uint256 fees0;
        uint256 fees1;
        (burnedAmps, freedCounter, fees0, fees1) = abi.decode(
            _unlock(poolManager, VaultRedeemLib.ACTION_BURNBACK, abi.encode(pool.key, _lowers(records), removals)),
            (uint256, uint256, uint256, uint256)
        );

        // The removed cells' own accrued fees are fees, not principal (audit fix, 2026-09-08): they take the
        // creator slice and the burn, never the ladder. On the `compound` path step 3 has already collected them
        // and both numbers are zero; on the `place` path this is the only chance they get.
        uint256 remainder;
        (remainder, feeBurn) = _routeFees(ctx, poolManager, amps, poolId, pool.key.currency1, fees0, fees1);
        freedCounter += remainder;
    }

    /// @dev ACTION_BURNBACK and ACTION_HARVEST: remove named cells whole, keep the AMPS as an idle ERC-20 balance
    ///      (to burn, or to re-place elsewhere) and the counter as ERC-6909 claims.
    ///
    /// @dev **Principal and fees come back separately** (audit fix, 2026-09-08). `modifyLiquidity` returns
    ///      `callerDelta = principalDelta + feesAccrued`, and this function used to report only the sum, so every
    ///      caller treated a removed cell's unclaimed fees as principal: `VaultRolloutLib._harvestAsks` re-laddered
    ///      the entry pools' accrued AMPS fees into a spoke's *asks* to be sold again, `withdrawRetiredBids` minted
    ///      the counter-side fees as plain claims, and neither passed the creator slice or the mandatory burn that
    ///      `_collectAndSplit` enforces on the `place` path — so `moved` could exceed the rollout allowance the
    ///      code believes it cannot. The two are reported apart and every caller routes the fee half through
    ///      {_routeFees}; nothing folds a fee into a principal again.
    /// @return principal0 The AMPS the removed positions held, net of fees, now an idle ERC-20 balance.
    /// @return principal1 The counter the removed positions held, net of fees, now an ERC-6909 claim.
    /// @return fees0 The AMPS-side fees those positions had accrued.
    /// @return fees1 The counter-side fees those positions had accrued.
    function _executeHarvest(address poolManager, PoolKey memory key, int24[] memory lowers, uint128[] memory removals)
        private
        returns (uint256 principal0, uint256 principal1, uint256 fees0, uint256 fees1)
    {
        int24 width = LadderLib.doublingTicks(key.tickSpacing);
        int256 delta0;
        int256 delta1;
        int256 fee0;
        int256 fee1;

        for (uint256 i; i < removals.length; ++i) {
            if (removals[i] == 0) continue;
            (BalanceDelta callerDelta, BalanceDelta feesAccrued) = IPoolManager(poolManager)
                .modifyLiquidity(
                    key,
                    ModifyLiquidityParams({
                        tickLower: lowers[i],
                        tickUpper: lowers[i] + width,
                        liquidityDelta: -int256(uint256(removals[i])),
                        salt: Constants.POSITION_SALT
                    }),
                    ""
                );
            delta0 += int256(callerDelta.amount0());
            delta1 += int256(callerDelta.amount1());
            fee0 += int256(feesAccrued.amount0());
            fee1 += int256(feesAccrued.amount1());
        }

        // Everything the removal freed is taken or minted in one go, exactly as before — the split below is
        // bookkeeping over the same total, so a fee can never be paid out twice or left inside the pool.
        if (delta0 > 0) IPoolManager(poolManager).take(key.currency0, address(this), uint256(delta0));
        if (delta1 > 0) IPoolManager(poolManager).mint(address(this), key.currency1.toId(), uint256(delta1));

        (principal0, fees0) = _apportion(delta0, fee0);
        (principal1, fees1) = _apportion(delta1, fee1);
    }

    /// @dev Splits one currency's realised delta into principal and fees. `feesAccrued` is v4's own number and is
    ///      part of `callerDelta`, so the fee share is clamped to what actually came out: a negative total (the
    ///      vault owed more than it freed, which a removal cannot produce but the type allows) yields nothing, and
    ///      a fee larger than the total is capped at it so `principal + fees` is always exactly what was freed.
    function _apportion(int256 total, int256 fees) private pure returns (uint256 principal, uint256 feePart) {
        if (total <= 0) return (0, 0);
        uint256 freed = uint256(total);
        feePart = fees > 0 ? uint256(fees) : 0;
        if (feePart > freed) feePart = freed;
        principal = freed - feePart;
    }

    /// @dev §3.6 step 5, to the wei: the creator's slice, and then the whole remainder is burned. The creator
    ///      slice is the only transfer of protocol-held AMPS to a non-pool address (I31) and is zero for good from
    ///      `genesis + CREATOR_DECAY_SECONDS`; everything else the pool earned in AMPS leaves the supply.
    ///
    /// @dev **Why the burn is unconditional since revision 6.** The AMPS-side fee is AMPS the protocol already
    ///      owns coming back out of its own ladder. Re-laddering it sold the same inventory twice — the ask ladder
    ///      is finite by I10 and re-laid fees quietly grew it — and streaming a share of it to stakers paid a
    ///      second constituency out of the float. Burning the remainder makes the AMPS side of every trade
    ///      unambiguously deflationary: `totalSupply` falls by `ampsFees - creatorAmps` at every compound and by
    ///      the whole buyback on top, and no governed parameter can dilute either number.
    /// @param creator The creator-fee recipient, or zero.
    /// @param amps The AMPS token.
    /// @param ampsFees The AMPS-side fees collected.
    /// @param creatorBps The creator's points of the volume, already clamped to `feeBps`.
    /// @param feeBps The live `ampsFeeBps`, the divisor that turns collected fees back into volume.
    /// @return creatorPaid AMPS transferred to the creator.
    /// @return burnCut AMPS burned: the whole remainder.
    function _split(address creator, address amps, uint256 ampsFees, uint256 creatorBps, uint256 feeBps)
        private
        returns (uint256 creatorPaid, uint256 burnCut)
    {
        if (creator != address(0) && creatorBps != 0) {
            creatorPaid = FullMath.mulDiv(ampsFees, creatorBps, feeBps);
            if (creatorPaid != 0) IERC20(amps).safeTransfer(creator, creatorPaid);
        }

        burnCut = ampsFees - creatorPaid;
        if (burnCut != 0) {
            IAmps(amps).burn(address(this), burnCut);
            emit Burn(burnCut, bytes32("compound"));
        }
    }

    /// @notice Routes fees a *harvest* realised — a burnback's, a rollout's, a retired-bid withdrawal's — through
    ///         exactly the split `compound` applies: the creator's slice of each currency, the whole AMPS-side
    ///         remainder burned, and the counter-side remainder left as a claim for the ladder.
    ///
    /// @dev Public because {VaultRolloutLib} needs it and links against this library already; it runs in the
    ///      vault's context by `DELEGATECALL` like everything else here, so it reads the vault's own creator,
    ///      genesis timestamp and pointers out of storage rather than being handed them.
    /// @dev **What the counter remainder does not do.** It is not re-placed here. `compound` folds it into the bid
    ///      ladder of the same call (§3.6 step 7); on the rollout paths it stays an ERC-6909 claim, where `A`
    ///      values it (I5) and the next `compound` or governance `place` lays it as a proper grid bid. Fees never
    ///      become ask inventory on any path, which is the property that was broken.
    /// @param poolManager The Uniswap v4 PoolManager.
    /// @param amps The AMPS token.
    /// @param poolId The pool the fees were earned in.
    /// @param counter The pool's `currency1`.
    /// @param fees0 The AMPS-side fees realised.
    /// @param fees1 The counter-side fees realised, already held as claims.
    /// @return counterRemainder The counter left after the creator's slice.
    /// @return ampsBurned The AMPS burned: the whole AMPS-side remainder.
    function splitHarvestFees(
        address poolManager,
        address amps,
        PoolId poolId,
        Currency counter,
        uint256 fees0,
        uint256 fees1
    ) public returns (uint256 counterRemainder, uint256 ampsBurned) {
        return _routeFees(_ctx(), poolManager, amps, poolId, counter, fees0, fees1);
    }

    /// @dev The split itself. The AMPS side is an ERC-20 balance by the time it gets here, so the creator's slice
    ///      is a plain transfer and the rest is burned; the counter side is already an ERC-6909 claim, so the
    ///      creator's slice of it moves by `pm.transfer` — never `take`, for the reason {_executeCollect} gives.
    function _routeFees(
        Ctx memory ctx,
        address poolManager,
        address amps,
        PoolId poolId,
        Currency counter,
        uint256 fees0,
        uint256 fees1
    ) private returns (uint256 counterRemainder, uint256 ampsBurned) {
        counterRemainder = fees1;
        if (fees0 == 0 && fees1 == 0) return (0, 0);

        (uint256 creatorBps, uint256 feeBps) = _creatorSlice(ctx, poolId);
        if (fees0 != 0) (, ampsBurned) = _split(ctx.creator, amps, fees0, creatorBps, feeBps);
        if (fees1 == 0 || creatorBps == 0 || ctx.creator == address(0)) return (counterRemainder, ampsBurned);

        uint256 creatorCounter = FullMath.mulDiv(fees1, creatorBps, feeBps);
        if (creatorCounter == 0) return (counterRemainder, ampsBurned);
        counterRemainder = fees1 - creatorCounter;
        IPoolManager(poolManager).transfer(ctx.creator, counter.toId(), creatorCounter);
    }

    /// @dev Realises a pool's accrued fees inside one `unlock`, and pays the creator's counter-side slice from
    ///      inside it. See {_executeCollect} for what happens on the far side of the unlock.
    /// @return ampsFees AMPS-side fees, gross, now an idle ERC-20 balance on the vault.
    /// @return counterFees Counter-side fees, gross.
    /// @return creatorCounter The part of `counterFees` the creator was paid, in kind or as a claim.
    function _collect(Ctx memory ctx, address poolManager, PoolKey memory key, uint256 creatorBps, uint256 feeBps)
        private
        returns (uint256 ampsFees, uint256 counterFees, uint256 creatorCounter)
    {
        return abi.decode(
            _unlock(
                poolManager,
                VaultRedeemLib.ACTION_COMPOUND,
                abi.encode(key, creatorBps == 0 ? address(0) : ctx.creator, creatorBps, feeBps)
            ),
            (uint256, uint256, uint256)
        );
    }

    /// @dev The creator's share of **one currency's** collected fees, as the fraction `creatorBps / ampsFeeBps`.
    ///
    /// @dev **What the divisor is.** The hook charges `ampsFeeBps` on every net buy and every net sell, so the
    ///      fees a pool accrues in a currency are `ampsFeeBps` of the volume that produced them, and
    ///      `fees x creatorBps / ampsFeeBps` is therefore `creatorBps` of that volume — which is exactly what
    ///      `CREATOR_FEE_BPS` promises and what I31 is asserted against. Reading the divisor from the live hook
    ///      rather than from `AMPS_FEE_BPS_DEFAULT` is what keeps that identity true across a governed fee
    ///      change: raise the fee and the same creator points come out of a larger collection, cut it and out of
    ///      a smaller one.
    ///
    /// @dev **The divisor is not the live base fee alone** (audit fix, 2026-09-08). Fees accrue continuously and
    ///      are divided *at collect time*, so the live rate is not the rate the volume paid, and both directions
    ///      of the mismatch paid the creator out of the unconditional burn:
    ///
    ///        * a governed **cut** retroactively multiplied the creator's share of every in-flight wei by
    ///          `oldFee / newFee` — at the 100 bp band floor that is 5x, i.e. 100% of *both* currencies, and the
    ///          counter leg leaves NAV rather than being burned. The floor `max(fee, AMPS_FEE_BPS_DEFAULT)` is
    ///          back for exactly this: the launch base is the most a cut can pretend the volume paid;
    ///        * a **raised dynamic** component meant the pool collected `base + dyn` and the slice was still
    ///          divided by `base`, inflating the payout by up to 1.6x (GREEN), 3x (degraded) or 5x (the escalation
    ///          cap). So the divisor is additionally bounded below by the rate actually being charged, read from
    ///          the hook's own {IAmpsHook-quoteFee}: the dynamic part enlarges the divisor by exactly what it
    ///          enlarged the collection, and is therefore never creator-eligible. The creator is paid
    ///          `creatorBps` of *volume* and nothing more, in either currency.
    ///
    ///      Both bounds move the payout one way only — down — so the identity I31 is asserted against holds as an
    ///      inequality where it cannot hold as an equality, and what the creator does not take is burned.
    ///
    /// @dev A hook that cannot be read leaves the floor in charge, which is the conservative answer: the launch
    ///      base is the largest divisor a broken pointer can be talked out of, and the clamp
    ///      `creatorBps <= feeBps` still makes the quotient a true fraction of one currency's fees.
    /// @param ctx The gathered pointers.
    /// @param poolId The pool whose charged rate bounds the divisor.
    /// @return creatorBps The creator's points at `block.timestamp`, clamped to `feeBps`; zero when there is no
    ///         creator or the schedule has run out.
    /// @return feeBps The divisor: `max(liveAmpsFeeBps, AMPS_FEE_BPS_DEFAULT, chargedBps)`, never zero.
    function _creatorSlice(Ctx memory ctx, PoolId poolId) private view returns (uint256 creatorBps, uint256 feeBps) {
        feeBps = _ampsFeeBps(ctx);
        if (feeBps < Constants.AMPS_FEE_BPS_DEFAULT) feeBps = Constants.AMPS_FEE_BPS_DEFAULT;
        uint256 chargedBps = _chargedFeeBps(ctx, poolId);
        if (chargedBps > feeBps) feeBps = chargedBps;
        if (ctx.creator == address(0)) return (0, feeBps);
        creatorBps = _creatorBps(ctx);
        if (creatorBps > feeBps) creatorBps = feeBps;
    }

    /// @dev The total rate the hook is charging a sell in `poolId` right now — base plus the clamped dynamic part
    ///      — in bps, or zero when the hook cannot answer. Bounded and never a reason to revert, like every other
    ///      read of the market reference here; the generous budget is `quoteFee`'s own, which makes a `staticcall`
    ///      of its own into the fee policy.
    function _chargedFeeBps(Ctx memory ctx, PoolId poolId) private view returns (uint256 bps) {
        uint256 pips =
            _probeWord(ctx.marketReference, abi.encodeCall(IAmpsHook.quoteFee, (poolId, true, true, 0, false)), 128);
        return uint24(pips) / Constants.PIPS_PER_BPS;
    }

    // -------------------------------------------------------------------------------------------------------------
    // Internals — PoolManager plumbing
    // -------------------------------------------------------------------------------------------------------------

    /// @dev Sets the transient discriminator, unlocks, clears it. The PoolManager calls back into
    ///      `AmpsVault.unlockCallback`, which routes straight back here through {unlockAction}.
    function _unlock(address poolManager, uint256 action, bytes memory data) private returns (bytes memory result) {
        uint256 slot = VaultRedeemLib.UNLOCK_ACTION;
        assembly ("memory-safe") {
            tstore(slot, action)
        }
        result = IPoolManager(poolManager).unlock(data);
        assembly ("memory-safe") {
            tstore(slot, 0)
        }
    }

    /// @dev The vault's own ERC-20 balance of `token`, or zero when the token cannot be asked.
    ///
    /// @dev **A bounded, hand-decoded `staticcall`, not `IERC20.balanceOf`** (audit fix, 2026-09-07). The counter
    ///      side of a spoke pool is a third-party Stock Token, and a typed read of its balance is a call into code
    ///      the protocol does not control on the *placement* path: an issuer whose `balanceOf` reverts, returns
    ///      fewer than 32 bytes or consumes everything it is handed bricked every placement into that pool —
    ///      `compound`'s bid re-ladder, `deployBonded`, and the seed ask — for as long as it chose to. Unreadable
    ///      is read as **zero**, which is the safe direction: the inventory bound in {_placeLadder} then counts
    ///      only what the vault holds as an ERC-6909 claim, so a placement can be refused for want of inventory
    ///      but can never commit inventory that is not there. It is the same probe `VaultRedeemLib._probeBalance`
    ///      and `VaultNavLib` use, at the same `Constants.STOCK_TOKEN_PROBE_GAS` budget.
    /// @param token The asset.
    /// @return held The answer, or zero.
    function _probeBalance(address token) private view returns (uint256 held) {
        (bool ok, bytes memory returndata) =
            token.staticcall{gas: Constants.STOCK_TOKEN_PROBE_GAS}(abi.encodeCall(IERC20.balanceOf, (address(this))));
        if (!ok || returndata.length < 32) return 0;
        assembly ("memory-safe") {
            held := mload(add(returndata, 0x20))
        }
    }

    /// @dev Settles one currency's accumulated delta: a positive one becomes an ERC-6909 claim, a negative one is
    ///      paid from claims first and from any idle ERC-20 balance second. AMPS is never `take`n to an EOA.
    function _settle(address poolManager, Currency currency, int256 delta) private {
        if (delta == 0) return;
        IPoolManager pm = IPoolManager(poolManager);
        uint256 id = currency.toId();

        if (delta > 0) {
            pm.mint(address(this), id, uint256(delta));
            return;
        }

        uint256 owed = uint256(-delta);
        uint256 claim = pm.balanceOf(address(this), id);
        uint256 fromClaim = owed < claim ? owed : claim;
        if (fromClaim != 0) pm.burn(address(this), id, fromClaim);
        uint256 rest = owed - fromClaim;
        if (rest != 0) {
            pm.sync(currency);
            IERC20(Currency.unwrap(currency)).safeTransfer(address(pm), rest);
            pm.settle();
        }
    }

    // -------------------------------------------------------------------------------------------------------------
    // Internals — the hook, the gate, the feeds and the pot
    // -------------------------------------------------------------------------------------------------------------

    /// @dev The pool's high-water tick since the vault's last reset, or `type(int24).min` when the market
    ///      reference cannot answer — in which case nothing counts as bought back, which is the safe default.
    function _highWater(PoolId poolId) private view returns (int24 tick) {
        address marketRef = address(uint160(_word(SLOT_MARKET_REFERENCE)));
        if (marketRef == address(0)) return type(int24).min;
        try IMarketReference(marketRef).highWaterTick{gas: Constants.STOCK_TOKEN_PROBE_GAS}(poolId) returns (
            int24 highWater
        ) {
            return highWater;
        } catch {
            return type(int24).min;
        }
    }

    /// @dev Resets the high-water mark, so the next buyback window starts clean (§3.5), and **reports whether it
    ///      actually happened**.
    ///
    /// @dev **A bounded, hand-decoded call, not a typed `try`** (audit fix, 2026-09-07). The market reference is a
    ///      governance pointer, and a typed `try` cannot tell a real answer from three impostors: a target with no
    ///      code at all (the typed call's own `extcodesize` screen turns that into a caught revert that looks
    ///      exactly like a refusal), a target that returns fewer than 32 bytes, and one that burns every wei of
    ///      gas it is handed. All three left the mark standing while {_placeLadder} carried on and laid asks
    ///      *above* the tick — cells that satisfy `tick <= lowerTick` from birth and, under a stale
    ///      `upperTick <= highWater`, are burned as bought-back inventory by the next `compound`. The call is
    ///      therefore capped at `Constants.MARKET_REFERENCE_WRITE_GAS` and its answer is measured: success is a
    ///      call that returned and returned at least the one word `resetHighWater`'s `int24` is encoded in.
    ///
    ///      An **absent** reference (`address(0)`) is a success, not a failure: with no market reference
    ///      {_highWater} reports `type(int24).min`, no cell can ever satisfy the burn predicate, and there is no
    ///      stale mark to protect an ask from. {_placeLadder} turns a `false` here into a revert on the ask side
    ///      and ignores it on the bid side; `compound`'s step 8 is best-effort, because a compound that placed no
    ///      ask created nothing that a stale mark could burn.
    function _resetHighWater(Ctx memory ctx, PoolId poolId) private returns (bool ok) {
        if (ctx.marketReference == address(0)) return true;
        bytes memory returndata;
        (ok, returndata) = ctx.marketReference.call{gas: Constants.MARKET_REFERENCE_WRITE_GAS}(
            abi.encodeCall(IAmpsHook.resetHighWater, (poolId))
        );
        return ok && returndata.length >= 32;
    }

    /// @dev Arms the surge fee after a placement, so it cannot be sandwiched at the pre-placement fee. A hook that
    ///      refuses is treated as absent rather than as a reason to abandon the placement, exactly as a gate that
    ///      reverts is: the vault is immutable and the market reference is a pointer.
    function _armSurge(Ctx memory ctx, PoolId poolId, bytes32 reason) private {
        if (ctx.marketReference == address(0)) return;
        try IAmpsHook(ctx.marketReference).armSurge{gas: Constants.MARKET_REFERENCE_WRITE_GAS}(
            poolId, Constants.SURGE_MAX_BPS, reason
        ) {}
            catch {}
    }

    /// @dev The live AMPS fee, from the hook: bounded, and never a reason to revert. The launch value stands in
    ///      when the hook cannot answer — and a hook that answers zero counts as no answer — so the divisor of
    ///      the creator's share is never zero. {_creatorSlice} is its only caller.
    function _ampsFeeBps(Ctx memory ctx) private view returns (uint256 bps) {
        // Hand-decoded and masked rather than a typed `try` (audit lead on the typed pointer reads, 2026-09-08):
        // Solidity decodes a *successful* call's returndata in this frame, so a hook answering with a word wider
        // than `uint16` — legal ABI — panicked past the `catch` and took the placement with it. Masking cannot.
        uint256 word = _probeWord(ctx.marketReference, abi.encodeCall(IAmpsHook.ampsFeeBps, ()), 32);
        uint256 value = uint16(word);
        return value != 0 ? value : Constants.AMPS_FEE_BPS_DEFAULT;
    }

    /// @dev `creatorBps(t) = CREATOR_FEE_BPS x max(0, 1 - (t - genesis) / CREATOR_DECAY_SECONDS)`: the immutable
    ///      schedule, monotone non-increasing and exactly zero from day 30 (I31). Identical to
    ///      `AmpsVault.creatorBpsAt`, which is what the dApp reads.
    function _creatorBps(Ctx memory ctx) private view returns (uint256 bps) {
        if (ctx.genesisTimestamp == 0 || block.timestamp <= ctx.genesisTimestamp) return Constants.CREATOR_FEE_BPS;
        uint256 elapsed = block.timestamp - ctx.genesisTimestamp;
        if (elapsed >= Constants.CREATOR_DECAY_SECONDS) return 0;
        return (uint256(Constants.CREATOR_FEE_BPS) * (Constants.CREATOR_DECAY_SECONDS - elapsed))
            / Constants.CREATOR_DECAY_SECONDS;
    }

    /// @dev The last accepted answer for `token` from `feeds`, 8 decimals, or zero. Never reverts, and never
    ///      panics on a malformed answer either: one bounded `staticcall` whose first word is read by hand, which
    ///      is the shape the rest of the vault uses for every pointer read (audit lead, 2026-09-08). One function
    ///      rather than two because the only difference between the old pair was where the registry came from.
    function _answer(address feeds, address token) private view returns (uint256 answerUsd8) {
        if (token == address(0)) return 0;
        answerUsd8 = _probeWord(feeds, abi.encodeCall(IFeedRegistry.latestAnswer, (token)), 96);
    }

    /// @dev One bounded `staticcall` on a pointer, answered only when at least `minLength` bytes came back, with
    ///      the first word returned raw. Zero covers every way a pointer can be wrong: absent, codeless,
    ///      reverting, out of gas, or too short to be the answer it claims.
    function _probeWord(address target, bytes memory payload, uint256 minLength) private view returns (uint256 word) {
        if (target == address(0)) return 0;
        (bool ok, bytes memory returndata) = target.staticcall{gas: Constants.COMPOSITE_READ_GAS}(payload);
        if (!ok || returndata.length < minLength) return 0;
        assembly ("memory-safe") {
            word := mload(add(returndata, 0x20))
        }
    }

    /// @dev `tickOf(P_ref / P_counter)`: the anchor no ask may be placed below (I32).
    ///
    /// @dev **Aligned down, deliberately, and the audit's stricter reading is the one thing that cannot be
    ///      granted here** (2026-09-07, re-audit finding on the anchor's rounding).
    ///
    ///      The finding is real as stated: `PriceLib.fairTick`'s four-argument form floors onto the tick spacing,
    ///      {_cells} then ceils onto the doubling grid, and the two roundings point in opposite directions, so the
    ///      first ask cell's lower bound can sit up to `tickSpacing - 1` ticks — 0.6 % of price at spacing 60 —
    ///      below the exact reference. What the finding does not price is what removing it costs, and the cost is
    ///      not a rounding: it is the whole first cell.
    ///
    ///      A pool's grid origin is `alignDown(openingTick)` and its opening tick *is* its reference tick
    ///      (§12 ruling C, {alignedOpeningPrice}), so at genesis the exact reference sits strictly **inside** cell
    ///      `m = 0` — at `base + 35` in the hub, `base + 55` in the WETH pool. Anchoring at `alignUp` (or, which
    ///      is the same thing, at the unrounded tick) makes `_ceilDiv` return `1` instead of `0`, so the ask
    ///      ladder starts one whole **doubling** above the reference: no protocol-owned ask exists between `P_ref`
    ///      and `2 x P_ref`, at genesis and after every `compound` that re-ladders at the reference. The pool
    ///      would have no sell-side depth at the price it trades at — a buy would walk an empty range, be refused
    ///      by the hook's rail, and the launch shape of §3.3 (asks at `m = 0..9`) would be gone.
    ///
    ///      The grid cannot be moved to escape the choice. Snapping the *opening* up instead would put cell
    ///      `m = -1`'s upper bound above the reference, and `LadderPositionValuer` writes the AMPS half of a
    ///      straddled **bid** off at zero (I5), which is ~7 bp of `A` — a hard R1 revert on the genesis seed bids
    ///      ({alignedOpeningPrice} documents exactly this). One side of the origin cell must straddle: the design
    ///      picks the ask side, where the mis-valuation is an *over*-statement that cannot trip R1, over the bid
    ///      side, where it is an under-statement that does.
    ///
    ///      So the invariant is held in the form §3.7 states it — `lowerTick >= tickOf(P_ref / P_counter)` with
    ///      `tickOf` the aligned-down `PriceLib.fairTick`, which is what `VaultRollout.t.sol`'s I32 test asserts —
    ///      and the residue is bounded, disclosed and one-sided: at most `tickSpacing - 1` ticks of the *first*
    ///      cell's range lies under the reference, and only the inventory sold in that sliver is affected.
    ///      `PriceLib.fairTick`'s five-argument form exists so the stricter reading is one argument away should
    ///      the orchestrator rule for it after weighing the cost above.
    function _referenceTick(Ctx memory ctx, Pool memory pool) private view returns (int24 tick) {
        uint256 answerUsd8 = _answer(ctx.feedRegistry, pool.config.counter);
        if (ctx.pRefX18 == 0 || answerUsd8 == 0 || pool.config.counterDecimals > PriceLib.MAX_COUNTER_DECIMALS) {
            return pool.tick;
        }
        return PriceLib.fairTick(ctx.pRefX18, answerUsd8, pool.config.counterDecimals, pool.config.tickSpacing);
    }

    /// @notice Pays one bountied job's keeper, with the work value the job **measured** and the gas the call
    ///         actually burned. Shared with {VaultRolloutLib}, which links against this library already.
    ///
    /// @dev **Why this is measured and not flat, and what it fixes.** Until this slice both numbers were the
    ///      hardcoded `$1`, which made two of `BountyPot`'s four guards dead letters. The `chost` dust guard is a
    ///      floor on the *work value* and refuses when `workValueUsd18 < chostUsd18`; at the launch `chost` of $1
    ///      a flat `$1` never satisfies `<`, so a `compound()` on a pool with **zero** accrued fees was paid the
    ///      full tip and a spam campaign was bounded only by the 60-second cooldown and the daily ceiling. The 3x
    ///      gas cap was equally inert: `3 x $1 = $3` sits far above the `$0.05 + 2% x $1 = $0.07` a job could
    ///      earn, so it never bound anything. With both inputs measured, an empty `compound` earns exactly zero
    ///      (`reason = "chost"`), and on a $5k book the cap is what sizes an ordinary payment.
    ///
    /// @dev **What "work value" means, per job** (`docs/phase3-state-model.md` §12.4):
    ///      * `compound` — the AMPS-side fees collected plus the AMPS bought back, valued at `P_ref`, plus the
    ///        counter-side fees at their feed price.
    ///      * `rollout` — the inventory actually moved, at `P_ref`.
    ///      * `deployBonded` — the collateral placed, at its feed price (the same number the deploy threshold is
    ///        tested against, so the two can never disagree).
    ///      Every one of them is a number the vault derived from its own state inside the same call. Nothing is
    ///      taken from the caller, which is what keeps the pot un-drainable by an argument.
    ///
    /// @dev **What the gas allowance means.** `gasStart` is `gasleft()` at the first statement of the vault's
    ///      forwarder; the delta to here is what the job burned, plus `Constants.KEEPER_GAS_OVERHEAD` for the
    ///      intrinsic cost and the payment itself. It is priced at `block.basefee` clamped into
    ///      `[KEEPER_BASEFEE_FLOOR_WEI, KEEPER_BASEFEE_CAP_WEI]` and at the ETH/USD answer the feed registry holds
    ///      for the `AMPS/WETH` entry pool's counter — the same feed `A` values the vault's WETH bids with, so no
    ///      new oracle, no new governance parameter and no new pointer. An ETH price the registry cannot answer
    ///      leaves the allowance at zero, which makes the gas cap bind at zero and the job unpaid: the pot never
    ///      pays for a job it cannot price, and an unpaid job still does its work (I21's degradation, not a stop).
    /// @param workValueUsd18 The measured work value, 18-decimal USD.
    /// @param gasStart `gasleft()` as the forwarder entered.
    /// @param hops How many nested message calls separate this frame from the one `gasStart` was taken in: 1 for
    ///        `compound`, which reaches here by an internal jump inside this library, and 2 for the jobs that come
    ///        through {VaultRolloutLib}. See {_gasUsed}.
    function payBounty(uint256 workValueUsd18, uint256 gasStart, uint256 hops) public {
        address pot = address(uint160(_word(SLOT_BOUNTY_POT)));
        if (pot == address(0)) return;

        // A pot that is empty, capped out or broken pays nothing and does not revert.
        try IBountyPot(pot).pay(msg.sender, workValueUsd18, _gasCostUsd18(_gasUsed(gasStart, hops))) returns (
            uint256
        ) {}
            catch {}
    }

    /// @dev The gas this job actually burned, from `gasStart` to here, plus the fixed overhead and under the hard
    ///      ceiling.
    ///
    /// @dev **The `gasleft() / 63` term is EIP-150, and leaving it out is a real overstatement.** Every message
    ///      call forwards at most 63/64 of the caller's remaining gas, so `gasleft()` in this frame is 63/64 of
    ///      what was available when the vault delegated into the library: the naive `gasStart - gasleft()` charges
    ///      the job for 1/64 of the *caller's gas limit* on top of the gas it spent. That is not a rounding error
    ///      — under Foundry's 2^30 default limit it is 16.8M gas, eight times a real `compound` — and on chain it
    ///      would let a keeper inflate the pot's own 3x ceiling simply by sending the job with a large gas limit.
    ///      `available = gasleft() * 64 / 63`, so adding back `gasleft() / 63` recovers the true consumption.
    ///
    /// @dev **And the reserve compounds with the hops** (audit fix, 2026-09-08). After `h` nested calls
    ///      `remaining = available x (63/64)^h`, so what has to be added back is
    ///      `remaining x (64^h - 63^h) / 63^h`: `remaining / 63` for one hop, `remaining x 127 / 3969` for two.
    ///      `compound` reaches this frame by an internal jump — one hop from the vault's forwarder — but `rollout`,
    ///      `deployBonded` and `withdrawRetiredBids` go through a second live `DELEGATECALL` frame in
    ///      {VaultRolloutLib}, and charging them a single reserve overstated the gas by about `txGasLimit / 64`.
    ///      That term is the *caller's* to choose, which is what made it exploitable: at a 30M limit it lifted the
    ///      pot's 3x gas cap from $7.03 to $11.12, and past the daily ceiling at larger limits.
    ///      `Constants.KEEPER_GAS_MAX` remains the belt: no measurement of any shape may report more gas than the
    ///      worst job can plausibly burn.
    /// @param gasStart `gasleft()` as the vault's forwarder was entered.
    /// @param hops The number of nested message calls between that frame and this one.
    function _gasUsed(uint256 gasStart, uint256 hops) private view returns (uint256 gasUsed) {
        uint256 remaining = gasleft();
        uint256 spent = gasStart > remaining ? gasStart - remaining : 0;
        uint256 reserved = hops <= 1 ? remaining / 63 : (remaining * 127) / 3969;
        gasUsed = (spent > reserved ? spent - reserved : 0) + Constants.KEEPER_GAS_OVERHEAD;
        if (gasUsed > Constants.KEEPER_GAS_MAX) gasUsed = Constants.KEEPER_GAS_MAX;
    }

    /// @dev `gasUsed x min(basefee, cap) x ETH/USD`, in 18-decimal USD, or zero when ETH cannot be priced.
    ///      Never reverts: every read is bounded and every failure is "no allowance".
    function _gasCostUsd18(uint256 gasUsed) private view returns (uint256 usd18) {
        address registry = address(uint160(_word(SLOT_REGISTRY)));
        if (registry == address(0)) return 0;

        PoolId wethPool;
        try IPoolRegistry(registry).wethPoolId() returns (PoolId poolId) {
            wethPool = poolId;
        } catch {
            return 0;
        }
        if (PoolId.unwrap(wethPool) == bytes32(0)) return 0;

        address weth;
        try IPoolRegistry(registry).poolConfig(wethPool) returns (PoolConfig memory config) {
            weth = config.counter;
        } catch {
            return 0;
        }

        uint256 ethUsd8 = _answer(address(uint160(_word(SLOT_FEED_REGISTRY))), weth);
        if (ethUsd8 == 0) return 0;

        uint256 basefee = block.basefee;
        if (basefee < Constants.KEEPER_BASEFEE_FLOOR_WEI) basefee = Constants.KEEPER_BASEFEE_FLOOR_WEI;
        if (basefee > Constants.KEEPER_BASEFEE_CAP_WEI) basefee = Constants.KEEPER_BASEFEE_CAP_WEI;
        // `gasUsed x basefee` is at most ~3.5e16 at a 35M-gas call and the 1 gwei cap, so the product with an
        // 8-decimal answer cannot come near overflowing a word.
        return (gasUsed * basefee * ethUsd8) / 1e8;
    }

    /// @dev The USD value of a counter-asset amount at the feed's last accepted answer, or zero when the feed
    ///      cannot answer or the asset's decimals are outside `PriceLib`'s domain.
    function _counterValueUsd18(Ctx memory ctx, PoolConfig memory config, uint256 amountRaw)
        private
        view
        returns (uint256 usd18)
    {
        if (amountRaw == 0 || config.counterDecimals > PriceLib.MAX_COUNTER_DECIMALS) return 0;
        uint256 answerUsd8 = _answer(ctx.feedRegistry, config.counter);
        if (answerUsd8 == 0) return 0;
        return PriceLib.counterValueUsd18(amountRaw, config.counterDecimals, answerUsd8);
    }

    /// @notice The USD value of an amount of AMPS at the vault's checkpointed reference price.
    /// @dev Shared with {VaultRolloutLib}. Zero when there is no reference yet, which is the safe direction: an
    ///      unpriceable job is worth nothing to the pot rather than worth guessing at.
    /// @param amountAmps AMPS wei.
    /// @return usd18 The value in 18-decimal USD.
    function ampsValueUsd18(uint256 amountAmps) public view returns (uint256 usd18) {
        if (amountAmps == 0) return 0;
        uint256 pRefX18 = _word(SLOT_CHECKPOINT0) >> 128;
        if (pRefX18 == 0) return 0;
        return FullMath.mulDiv(amountAmps, pRefX18, Constants.WAD);
    }

    /// @dev The bucket weights. The *shape* is the pointer-upgradeable policy's to choose; the *bounds* are the
    ///      canonical grid's and are not negotiable (§3.2), which is why only the weight vector is asked for — a
    ///      policy cannot move a bucket, only re-weight one. A policy that reverts, answers with the wrong length
    ///      or answers with a vector that does not sum to 1e18 leaves `LadderLib` in charge.
    function _weights(uint64 tiltX18, uint8 buckets) private view returns (uint256[] memory weightsX18) {
        if (buckets < LadderLib.MIN_BUCKETS) {
            weightsX18 = new uint256[](buckets);
            if (buckets == 1) weightsX18[0] = Constants.WAD;
            return weightsX18;
        }

        address policy = address(uint160(_word(SLOT_LADDER_POLICY)));
        if (policy != address(0)) {
            try ILadderPolicy(policy).weights{gas: Constants.MARKET_REFERENCE_WRITE_GAS}(tiltX18, buckets) returns (
                uint256[] memory proposed
            ) {
                if (proposed.length == buckets) {
                    // **Summed outside checked arithmetic, with an explicit guard** (audit fix, 2026-09-08). This
                    // body runs in *this* frame, not the callee's, so a `sum` that overflowed here reverted the
                    // whole placement — the one thing the `try` exists to prevent — and a pointer-upgradeable
                    // policy could therefore brick `compound`, `rollout` and every genesis ladder with a vector of
                    // two enormous numbers. An overflow is simply a vector that does not sum to `WAD`, which is
                    // already the answer for every other malformed vector: `LadderLib` takes over.
                    uint256 sum;
                    bool overflowed;
                    unchecked {
                        for (uint256 i; i < buckets; ++i) {
                            uint256 next = sum + proposed[i];
                            if (next < sum) {
                                overflowed = true;
                                break;
                            }
                            sum = next;
                        }
                    }
                    if (!overflowed && sum == Constants.WAD) return proposed;
                }
            } catch {}
        }
        return LadderLib.weights(tiltX18, buckets);
    }

    // -------------------------------------------------------------------------------------------------------------
    // Internals — the vault's storage, read by slot
    // -------------------------------------------------------------------------------------------------------------

    /// @dev The vault's parameter word, pointer set and checkpoint, gathered in one place. See the file header for
    ///      why this is read by slot rather than passed in.
    function _ctx() private view returns (Ctx memory ctx) {
        uint256 params = _word(SLOT_PARAMS);
        uint256 creatorWord = _word(SLOT_CREATOR);

        ctx.registry = address(uint160(_word(SLOT_REGISTRY)));
        ctx.bountyPot = address(uint160(_word(SLOT_BOUNTY_POT)));
        ctx.marketReference = address(uint160(_word(SLOT_MARKET_REFERENCE)));
        ctx.oracleGate = address(uint160(_word(SLOT_ORACLE_GATE)));
        ctx.feedRegistry = address(uint160(_word(SLOT_FEED_REGISTRY)));
        ctx.ladderPolicy = address(uint160(_word(SLOT_LADDER_POLICY)));
        ctx.rolloutPolicy = address(uint160(_word(SLOT_ROLLOUT_POLICY)));

        ctx.creator = address(uint160(creatorWord));
        ctx.genesisTimestamp = uint32(creatorWord >> 160);

        ctx.tiltX18 = uint64(params >> 112);
        ctx.ladderDoublings = uint8(params >> 176);
        ctx.seedHalvings = uint8(params >> 184);
        ctx.bondBidHalvings = uint8(params >> 192);
        ctx.rolloutBpsPerDay = uint16(params >> 216);
        ctx.entryFloorBps = uint16(params >> 232);

        ctx.deployThresholdUsd18 = _word(SLOT_DEPLOY_THRESHOLD);
        ctx.pRefX18 = _word(SLOT_CHECKPOINT0) >> 128;
        ctx.pMktX18 = uint128(_word(SLOT_CHECKPOINT1));
    }

    /// @dev One raw word of the vault's storage.
    function _word(uint256 slot) private view returns (uint256 value) {
        assembly ("memory-safe") {
            value := sload(slot)
        }
    }

    /// @dev Writes one raw word of the vault's storage.
    function _setWord(uint256 slot, uint256 value) private {
        assembly ("memory-safe") {
            sstore(slot, value)
        }
    }

    // -------------------------------------------------------------------------------------------------------------
    // Internals — arithmetic and the transient staging buffer
    // -------------------------------------------------------------------------------------------------------------
    //
    // `_executePlace` runs inside the PoolManager's `unlock`, so what it did has to reach `_writeRecords` — which
    // runs after the unlock returns — without a storage write per cell and without widening `Placed`, whose shape
    // §11.1 fixes. EIP-1153 transient storage is the right size of hammer: cleared at the end of the transaction,
    // 100 gas a slot, written and read inside one external call. Four words per cell, `GRID_CELLS` cells. Two
    // placements in one `compound` (asks then bids) reuse the buffer, and each writes every slot it later reads.

    /// @dev Records one placed cell for {_writeRecords}.
    function _stage(uint8 index, int24 lower, int24 upper, uint128 liquidity, uint256 amount) private {
        uint256 base = STAGE_SLOT + uint256(index) * 4;
        assembly ("memory-safe") {
            tstore(base, lower)
            tstore(add(base, 1), upper)
            tstore(add(base, 2), liquidity)
            tstore(add(base, 3), amount)
        }
    }

    /// @dev Reads back one staged cell.
    function _staged(uint256 index) private view returns (int24 lower, int24 upper, uint128 liquidity, uint256 amount) {
        uint256 base = STAGE_SLOT + index * 4;
        uint256 a;
        uint256 b;
        uint256 c;
        uint256 d;
        assembly ("memory-safe") {
            a := tload(base)
            b := tload(add(base, 1))
            c := tload(add(base, 2))
            d := tload(add(base, 3))
        }
        return (int24(int256(a)), int24(int256(b)), uint128(c), d);
    }

    /// @dev `floor(a / b)` for a positive `b`. Solidity truncates toward zero, which is not the same thing for a
    ///      negative dividend, and every grid index below the origin is one.
    function _floorDiv(int256 a, int256 b) private pure returns (int256 q) {
        q = a / b;
        if (a % b != 0 && (a < 0) != (b < 0)) q -= 1;
    }

    /// @dev `ceil(a / b)` for a positive `b`.
    function _ceilDiv(int256 a, int256 b) private pure returns (int256 q) {
        q = a / b;
        if (a % b != 0 && (a < 0) == (b < 0)) q += 1;
    }

    /// @dev Narrows to the width {PlacementRecord} stores amounts in. Saturating rather than reverting: `amount`
    ///      is a disclosure field, and a placement must never fail because a cumulative counter would wrap.
    function _toUint128(uint256 value) private pure returns (uint128 narrowed) {
        return value > type(uint128).max ? type(uint128).max : uint128(value);
    }
}
