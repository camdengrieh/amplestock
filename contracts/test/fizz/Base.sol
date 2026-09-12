// SPDX-License-Identifier: MIT
pragma solidity >=0.6.2 <0.9.0;

import {AmpsHook} from "../../src/hook/AmpsHook.sol";
import {PoolRegistry} from "../../src/registry/PoolRegistry.sol";
import {Amps} from "../../src/token/Amps.sol";
import {Constants} from "../../src/types/Constants.sol";
import {ConstituentStatus, PlacementRecord} from "../../src/types/Types.sol";
import {AmpsVault} from "../../src/vault/AmpsVault.sol";
import {Phase3Fixture} from "../integration/Phase3Fixture.sol";
import {MockAggregator} from "../mocks/MockAggregator.sol";
import {MockStockToken} from "../mocks/MockStockToken.sol";
import {MockUsdg} from "../mocks/MockUsdg.sol";
import {Actor} from "./Actor.sol";
import {Clamp} from "./utils/Clamp.sol";
import {DecimalPrinter} from "./utils/DecimalPrinter.sol";
import {Deployer} from "./utils/Deployer.sol";
import {EnumerableSet} from "./utils/EnumerableSet.sol";
import {Logger} from "./utils/Logger.sol";
import {Math} from "./utils/Math.sol";
import {StringUtils} from "./utils/StringUtils.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {AddressConstants} from "hookmate/constants/AddressConstants.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

/// @notice Base contract with state variables and setup functions.
///
/// @dev **The world is the Phase 3 world.** `Base` inherits `test/integration/Phase3Fixture.sol` rather than
///      re-deploying the protocol: `deployPhase3World()` builds the real `Amps`, `AmpsVault` (+ its four linked
///      libraries), the real `AmpsHook` at a `0x38C0`-shaped CREATE2 address, `PoolRegistry`, `AmpsBonds`,
///      `BountyPot`, `OracleGate` + `FeedRegistry`, the four policies, `LadderPositionValuer`, `AmpsQuoter` and
///      `AmpsRouter` on a local Uniswap v4 stack, and `placeGenesisLadders()` puts the §3.3 genesis ladders in
///      every pool. Every contract instance the handlers drive (`amps`, `vault`, `hook`, `registry`, `bonds`,
///      `pot`, `gate`, `feeds`, `ampsRouter`, `quoter`, `poolManager`, `swapRouter`, `permit2`, `weth`, `usdg`,
///      `stocks`, `stockFeeds`) is therefore declared by the fixture, not here.
///
/// @dev **`vm` comes from forge-std.** The fixture chain descends from forge-std's `Test`, whose `CommonBase`
///      already declares `vm` at the same cheatcode address, so `utils/Hevm.sol` is deliberately *not* imported
///      anywhere in this suite: two declarations of `vm` in one inheritance graph do not compile.
///
/// @dev **Medusa 1.5.1 cheatcode coverage.** Probed directly against the binary in this sandbox:
///      `chainId`, `warp`, `roll`, `prank`, `startPrank`, `stopPrank`, `etch`, `store`, `load`, `label`,
///      `getNonce`, `deal`, `toString` and `assertTrue` are implemented; `getBlockTimestamp`, `getBlockNumber`,
///      `computeCreateAddress`, `assume` and `snapshot` are **not**. The fixture uses the first three of those
///      missing ones on the `setup()` path, so {warpBy}, {advance}, {refreshGateCache} and {_deployCore} are
///      overridden below to read `block.timestamp` / `block.number` and to compute the CREATE address from RLP.
abstract contract Base is StringUtils, Clamp, Deployer, Math, Phase3Fixture {
    using DecimalPrinter for uint256;

    string[] internal ACTOR_LABELS = ["Alice", "Bob", "Charlie"];
    uint256 internal constant BLOCK_INTERVAL = 12 seconds;
    uint256 internal constant INITIAL_ETH_BALANCE = 1000 ether;

    /// @dev Anvil's chain id, which is the branch of {V4TestBase-deployV4} that deploys a *fresh* v4 stack from
    ///      hookmate's artifacts. Medusa's chain runs a different id and would otherwise take the canonical
    ///      mainnet-address branch, pointing `poolManager` at an empty account.
    uint256 internal constant LOCAL_CHAIN_ID = 31_337;

    /// @dev What each actor starts with. Stock collateral is minted on demand inside the bond handlers, exactly as
    ///      `test/invariant/Phase3Handler.sol` does it, so that setup gas does not scale with `spokeCount()`.
    uint256 internal constant ACTOR_WETH = 50e18;
    uint256 internal constant ACTOR_USDG = 200_000e6;
    uint256 internal constant ACTOR_AMPS = 400e18;
    uint256 internal constant POT_USDG = 1_000_000e6;

    /// @dev How many spokes the campaign opens, i.e. `spokeCount() + 2` pools. The launch shape of
    ///      `docs/phase3-state-model.md` §8.2 is 30 spokes / 32 pools, and that is what this campaign runs: the
    ///      index weight vector, `rollout`, the rotation legs and `setIndexWeights`' `n`-dependent bands are all
    ///      only meaningfully reachable at the real width. This constant is the lever to pull if a fuzzer block
    ///      ever stops fitting the constructor.
    uint256 internal constant FIZZ_SPOKES = 30;

    // ―――――――――――――――――――――――――― Ghosts ――――――――――――――――――――――――――

    /// @dev `ghosts.navClass` tags: which class of entry point the handler currently running belongs to, so that
    ///      a NAV-drift property can pick the right bound without every handler carrying its own copy of it.
    ///      Set as the first statement of an unclamped handler; read by SP-17 / SP-58 / GL-32.
    uint8 internal constant NAV_CLASS_NONE = 0;
    uint8 internal constant NAV_CLASS_MANAGEMENT = 1;
    uint8 internal constant NAV_CLASS_PLACEMENT = 2;
    uint8 internal constant NAV_CLASS_BOND = 3;
    uint8 internal constant NAV_CLASS_REDEEM = 4;
    uint8 internal constant NAV_CLASS_SWAP = 5;

    /// @dev How many entries of {Ghosts-ampsHolders} a global property will walk before it downgrades its
    ///      assertion from an equality to the sound one-sided bound. The unclamped handlers take a fuzzer-chosen
    ///      `to`, so the set is open-ended and a property that walked all of it would grow without bound.
    uint256 internal constant GHOST_HOLDER_WALK_MAX = 256;

    /// @dev The rolling window {Ghosts-payRingAmount} covers, as a power of two so the index is a mask.
    uint256 internal constant PAY_RING = 32;

    /// @notice Everything the campaign has to remember that the protocol does not store.
    ///
    /// @dev **Ownership.** This struct is the Global Property Implementer's; the per-contract handlers write into
    ///      it. Fields whose plan row says "the property itself" are maintained inside `Properties.sol` and need no
    ///      handler wiring at all — those are the ones that stay honest even if a handler forgets to update them.
    ///
    /// @dev **Why mappings where `fizz_data/property-plan.md` writes arrays.** A `uint128[]` "per market" or
    ///      "per pool" has to be sized and pushed in `setup()`, and a fuzzer-chosen `to` address has no index at
    ///      all. Keying by the market id / `PoolId` / address instead is the same read at the call site
    ///      (`ghosts.maxTotalIssued[marketId]`) with no initialisation and no bound.
    struct Ghosts {
        // ── the AMPS ledger ────────────────────────────────────────────────────────────────────────────────────
        /// @dev Every account the campaign has ever handed AMPS to, including the whole static closure that
        ///      {Base-setup} seeds. GL-01's sum is taken over exactly this set.
        EnumerableSet.AddressSet ampsHolders;
        /// @dev Every account that has ever been the `to` of a bond, i.e. every owner of a vesting position.
        EnumerableSet.AddressSet bonders;
        uint256 mintedByBonds;
        uint256 burnedTotal;
        uint256 lastBondIssued;
        uint256 bondIssuedTotal;
        // ── the vesting book ───────────────────────────────────────────────────────────────────────────────────
        mapping(address => mapping(uint256 => uint256)) bondPrincipal;
        mapping(address => mapping(uint256 => uint256)) bondClaimed;
        mapping(address => mapping(uint256 => uint256)) lastClaimable;
        mapping(address => mapping(uint256 => uint256)) vestedSeen;
        mapping(address => mapping(uint256 => uint256)) vestSecondsAtPurchase;
        mapping(address => mapping(uint256 => uint256)) principalSeen;
        mapping(address => mapping(uint256 => uint256)) startSeen;
        mapping(address => mapping(uint256 => uint256)) marketIdSeen;
        /// @dev Set by GL-10 the first time it sees a position, which is what lets it compare later observations
        ///      against the first one without any handler having to record the purchase.
        mapping(address => mapping(uint256 => bool)) positionSeen;
        mapping(address => mapping(uint256 => uint256)) maxClaimed;
        mapping(address => uint256) maxPositionCount;
        mapping(uint16 => uint128) maxTotalIssued;
        uint256 maxPerIdClaimGas;
        // ── bond capacity ──────────────────────────────────────────────────────────────────────────────────────
        mapping(uint16 => uint256) supplyAtEpochStart;
        mapping(uint16 => uint256) epochIssuedGhost;
        uint256 supplyAtDayStart;
        uint256 dayIssuedGhost;
        mapping(uint16 => uint16) maxDiscountSeen;
        /// @dev GL-08's own window bookkeeping: the epoch a market was last seen in, and the highest cap that stood
        ///      during it. Governance can *lower* a cap mid-window, so the bound has to be the highest cap the
        ///      window ever carried rather than the one standing now.
        mapping(uint16 => uint32) epochStartSeen;
        mapping(uint16 => uint256) epochCapHigh;
        uint256 dayCapHigh;
        /// @dev GL-16's own latch: the three issuance counters as they stood the first time the market was seen
        ///      closed or detached, so a later observation can prove they did not move while it was shut.
        mapping(uint16 => bool) closedSeen;
        mapping(uint16 => uint128) issuedAtClose;
        mapping(uint16 => uint128) epochIssuedAtClose;
        mapping(uint16 => uint32) lastBondAtClose;
        // ── redemption ─────────────────────────────────────────────────────────────────────────────────────────
        address[] previewTokens;
        uint256[] previewAmounts;
        uint256 previewInventoryBurned;
        address[] lastRedeemTokens;
        uint256[] lastRedeemAmounts;
        // ── placement, compound and the creator slice ──────────────────────────────────────────────────────────
        uint256 lastCompoundBurned;
        uint256 creatorAmpsGain;
        uint256 creatorPaidUsd18;
        uint256 creatorPaidSinceDecay;
        uint256 swapVolumeUsd18;
        uint16 lastCreatorBps;
        uint256 lastPlaced;
        uint256 lastBoughtBackAmps;
        PlacementRecord[] burnedCells;
        uint256 burnedAmpsTotal;
        uint256 boughtBackAmpsTotal;
        /// @dev The pool tick each of a pool's 24 canonical cells was placed against, so GL-43 can test sidedness
        ///      against the placement tick rather than against the live one.
        mapping(bytes32 => int24[24]) tickAtPlacement;
        mapping(bytes32 => bool[24]) tickAtPlacementSet;
        // ── monotone stamps, all maintained by the properties that read them ───────────────────────────────────
        mapping(bytes32 => int24) maxHighWater;
        mapping(bytes32 => bool) maxHighWaterSet;
        /// @dev The pool's `lastPlacementAt` when GL-47 last read its high water. `resetHighWater` is `onlyVault`
        ///      and every caller of it is a placement path, so an unchanged stamp is proof that no reset happened
        ///      between two observations.
        mapping(bytes32 => uint32) hwPlacementStamp;
        mapping(bytes32 => bool) resetThisCall;
        mapping(bytes32 => uint32) maxCoverage;
        mapping(bytes32 => uint256) maxLadderLength;
        mapping(bytes32 => uint32) maxLastPlacementAt;
        uint32 maxCheckpointTimestamp;
        uint32 maxCheckpointBlock;
        uint32 maxGateBlock;
        uint32 maxGateTimestamp;
        uint16 maxConstituentCount;
        uint16 maxMarketCount;
        uint16 maxPoolCount;
        uint256 maxAssetCount;
        uint256 liveCellHigh;
        uint256 maxNavPerShareSeen;
        uint256 maxPRefSeen;
        // ── the bid book of a retired name ─────────────────────────────────────────────────────────────────────
        mapping(uint16 => uint256) bidPlacedRaw;
        mapping(uint16 => uint256) bidWithdrawnRaw;
        // ── the keeper purse ───────────────────────────────────────────────────────────────────────────────────
        uint256 potFundedRaw;
        uint256 potPaidRaw;
        uint256[PAY_RING] payRingAmount;
        uint32[PAY_RING] payRingStamp;
        uint256 payRingHead;
        uint256 worstJobPaidUsd18;
        uint256 worstJobGasCostUsd18;
        // ── actor value accounting ─────────────────────────────────────────────────────────────────────────────
        mapping(address => uint256) actorValueBasis;
        mapping(address => uint256) actorMintedValueUsd18;
        uint256 cumulativeBleedUsd18;
        uint256 navPerShareHigh;
        uint256 navPerShareBefore;
        uint8 navClass;
        // ── the launch latches and the rollout window ──────────────────────────────────────────────────────────
        uint32 genesisTimestampSeen;
        uint256 rolloutMovedInWindow;
        uint32 rolloutWindowStart;
        uint256 polTrancheAmps;
        // ── swap and bond legs the specific properties compare against ─────────────────────────────────────────
        mapping(address => uint256) hookDonated;
        uint16 lastHaircutBps;
        uint256 lastBondCollateralPriceUsd18;
        uint16 expectedHaircutFloorBps;
        uint256 lastBuyRealisedIn;
        uint256 lastBuyAmpsOut;
        bytes32 lastPool;
        address lastCollateral;
        uint256 atomicWashBestKeptBps;
        /// @dev Keyed by a label (`keccak256("redeemFull")`, …): how many times an external call the campaign
        ///      believes can never be refused was in fact refused. Every liveness property reads its own key.
        mapping(bytes32 => uint256) livenessReverts;
    }

    Ghosts internal ghosts;

    using EnumerableSet for EnumerableSet.AddressSet;

    // ―――――――――――――――――――――――――― Actors ――――――――――――――――――――――――――

    address[] internal actors;
    address internal actor;
    /// @dev The governance timelock: every band-checked setter in the system is `onlyTimelock`.
    address internal admin;
    /// @dev The guardian Safe: freezes only.
    address internal guardian;
    /// @dev The keeper the bounty pot pays for `compound` / `rollout` / `deployBonded`.
    address internal keeper;

    /// @dev **The acting modifiers are single-shot `vm.prank`, not `startPrank`/`stopPrank`, and that is load-bearing.**
    ///      Every function that carries one of these makes exactly one external call, and a fuzzer handler reverts as
    ///      a matter of course — a cooldown, a closed market, the hook's outer rail. With `startPrank`, a revert
    ///      inside the body skips the modifier's trailing `stopPrank` and the prank stays armed: the next handler in
    ///      the sequence then fails with *"vm.prank: cannot override an ongoing prank"* and every handler after it
    ///      acts as the wrong account. Observed exactly that way in `test_sequence` before this change (the reverting
    ///      `FeedRegistry.refresh` on an unknown token leaked its prank into the next step). A single-shot prank is
    ///      consumed by the call it precedes and cannot outlive it, and it needs no cleanup path at all.
    modifier asActor() virtual {
        vm.prank(actor);
        _;
    }

    modifier asAdmin() virtual {
        vm.prank(admin);
        _;
    }

    modifier asGuardian() virtual {
        vm.prank(guardian);
        _;
    }

    modifier asKeeper() virtual {
        vm.prank(keeper);
        _;
    }

    // ―――――――――――――――――――――――― Contracts ―――――――――――――――――――――――――

    // Every instance is declared by `Phase3Fixture`. What is cached here is only the pool list, so that a fuzzed
    // seed can be reduced to a valid pool with one modulo.

    /// @notice Every pool the vault has opened: hub (`AMPS/USDG`), `AMPS/WETH`, then one per spoke.
    PoolId[] internal pools;

    /// @notice What `setup()` cost, measured by `setup()` itself. This is the number `medusa.json`'s
    ///         `blockGasLimit` has to clear, because Medusa runs `FuzzTester`'s constructor inside a block.
    /// @dev Measured in the harness rather than by deploying a second `FuzzTester` from a test: this contract's
    ///      runtime is well past EIP-170, and a `CREATE` inside a Foundry test is size-checked.
    uint256 internal setupGasUsed;

    // ―――――――――――――――――――――――――― Setup ―――――――――――――――――――――――――――

    function setup() internal {
        uint256 gasStart = gasleft();

        // Before anything reads `block.chainid`: see {LOCAL_CHAIN_ID}.
        vm.chainId(LOCAL_CHAIN_ID);
        _stubPermit2();

        deployPhase3World();
        require(address(poolManager).code.length != 0, "v4 stack not deployed");

        placeGenesisLadders();
        _cachePools();
        _openBondCapacity();
        fundPot(POT_USDG);
        setupActors();

        // The genesis bid legs were placed one cooldown ago; clear the per-pool cooldown so the first handler call
        // can already place, compound or roll out.
        warpBy(Constants.PLACEMENT_COOLDOWN_SECONDS + 1);

        _seedGhosts();

        setupGasUsed = gasStart - gasleft();
    }

    /// @dev **Permit2 is replaced by a single `STOP`, and every call into it is routed around.**
    ///
    ///      `V4TestBase._deployPermit2` installs Permit2's runtime at its canonical address with `vm.etch`, and code
    ///      installed that way is **not reliably callable in Medusa 1.5.1**. Probed directly against the binary: the
    ///      `etch` itself succeeds and `address.code.length` is correct, but a `CALL` into the result fails as
    ///      `vm error ('stack underflow (0 <=> 2)')` depending on the size of the calldata — with a one-byte `STOP`
    ///      etched at an address, empty calldata and a 36-byte call (`poke(uint256)`) both return normally, while a
    ///      68-byte call (`two(uint256,uint256)`) and a 132-byte call
    ///      (`approve(address,address,uint160,uint48)`) both fail, in either order. On the real world it surfaced as
    ///      `Failed to initialize the test chain … [vm error ('stack underflow (0 <=> 2)')]` on the first
    ///      `permit2.approve` inside `deployToken` — 132 bytes of calldata.
    ///
    ///      So a stub is not enough on its own: the *call* has to go away. {_deployAssets} and {approveStack} are
    ///      overridden to drop the two `permit2.approve` legs, and this function keeps the canonical address
    ///      non-empty so that `_deployPermit2` skips etching 20 kB of Permit2 runtime that nothing can execute
    ///      anyway. One byte of code has no jumps and is never entered. The fixture already uses the same trick for
    ///      `STANDBY`.
    ///
    ///      Nothing this campaign drives needs Permit2: `AmpsRouter` pulls with `IERC20.safeTransferFrom`, the vault
    ///      and the hook settle through the PoolManager's own `sync`/`settle`, and `AmpsBonds` pulls collateral
    ///      through the vault. The consequence to keep in mind is that the ordinary v4 `swapRouter` path, which
    ///      pulls through Permit2, is dead here — no handler uses it, but `Phase3Fixture.buyAmps` / `sellAmps` /
    ///      `rotate` would have to deal with this first.
    function _stubPermit2() private {
        address at = AddressConstants.getPermit2Address();
        if (at.code.length == 0) vm.etch(at, hex"00");
    }

    function setupActors() internal {
        admin = TIMELOCK;
        guardian = GUARDIAN;
        keeper = KEEPER;
        vm.label(admin, "Timelock");
        vm.label(guardian, "Guardian");
        vm.label(keeper, "Keeper");

        for (uint256 i; i < ACTOR_LABELS.length; i++) {
            address _actor = address(new Actor{value: INITIAL_ETH_BALANCE}());
            actors.push(_actor);
            if (ACTOR_LABELS.length > i) {
                vm.label(_actor, ACTOR_LABELS[i]);
            }
            _seedActor(_actor);
        }
        actor = actors[0];
    }

    /// @dev Entry-pool counter assets, AMPS, and every approval the three routes into the protocol need: Permit2
    ///      and the ordinary v4 router (the ladder-facing path), the vault (which is what pulls bond collateral),
    ///      the protocol router and the bond shell.
    function _seedActor(address who) internal {
        fund(address(weth), who, ACTOR_WETH);
        fund(address(usdg), who, ACTOR_USDG);
        _giveAmps(who, ACTOR_AMPS);
        approveAll(address(weth), who);
        approveAll(address(usdg), who);
        approveAll(address(amps), who);
    }

    /// @dev AMPS comes out of the **auction tranche** the `MockGenesisHolder` holds, exactly as a bidder's AMPS
    ///      would: `totalSupply` is untouched, and the POL tranche — which genesis has already placed as ask
    ///      ladders — is left alone. Pulling from the vault instead would fail outright at the launch shape,
    ///      where `placeGenesisLadders()` places the whole 9,000 AMPS of POL.
    function _giveAmps(address who, uint256 amount) internal {
        uint256 available = amps.balanceOf(address(genesisHolder));
        if (available < amount) amount = available;
        if (amount == 0) return;
        genesisHolder.send(address(amps), who, amount);
    }

    /// @dev {Phase3Fixture-approveStack} (Permit2, the v4 router, the vault) plus the two protocol-side spenders.
    function approveAll(address token, address who) internal {
        approveStack(token, who);
        vm.startPrank(who);
        IERC20(token).approve(address(ampsRouter), type(uint256).max);
        IERC20(token).approve(address(bonds), type(uint256).max);
        vm.stopPrank();
    }

    function _cachePools() private {
        PoolId[] memory ids = allPools();
        for (uint256 i; i < ids.length; ++i) {
            pools.push(ids[i]);
        }
    }

    /// @dev Opens the bond side wide enough to be reachable: every market's epoch cap and the global daily cap at
    ///      their hard maxima, and `deployThresholdUsd18` at its floor so a single bond's collateral is already
    ///      worth deploying. This is what `Phase3Fixture.seedSpokeBids` does before it bonds.
    function _openBondCapacity() private {
        vm.startPrank(TIMELOCK);
        bonds.setDailyCapBps(Constants.BOND_DAILY_CAP_BPS_MAX);
        for (uint256 i; i < marketIds.length; ++i) {
            bonds.setCapBpsPerEpoch(marketIds[i], Constants.BOND_CAP_BPS_PER_EPOCH_MAX);
        }
        vault.setDeployThresholdUsd18(Constants.DEPLOY_THRESHOLD_USD18_MIN);
        vm.stopPrank();
    }

    // ―――――――――――――――――――――― Ghost helpers ―――――――――――――――――――――――

    /// @notice Records what the ghosts have to start from: the static AMPS closure, the actors' opening USD basis,
    ///         the launch latches and the high-water marks the drift properties measure against.
    /// @dev Called at the end of {setup}. Everything here is a *starting* value — the running updates live in the
    ///      handlers (for the fields a handler is the only witness of) and in `Properties.sol` (for the fields
    ///      whose plan row says "the property itself").
    function _seedGhosts() internal {
        address[] memory closure = new address[](27);
        uint256 k;
        closure[k++] = address(this);
        closure[k++] = address(vault);
        closure[k++] = address(bonds);
        closure[k++] = address(hook);
        closure[k++] = address(ampsRouter);
        closure[k++] = address(swapRouter);
        closure[k++] = address(poolManager);
        closure[k++] = address(genesisHolder);
        closure[k++] = address(teamVesting);
        closure[k++] = address(quoter);
        closure[k++] = address(valuer);
        closure[k++] = address(pot);
        closure[k++] = address(gate);
        closure[k++] = address(feeds);
        closure[k++] = address(registry);
        closure[k++] = address(bondPolicy);
        closure[k++] = address(feePolicy);
        closure[k++] = address(ladderPolicy);
        closure[k++] = address(rolloutPolicy);
        closure[k++] = address(permit2);
        closure[k++] = address(amps);
        closure[k++] = CREATOR;
        closure[k++] = TEAM;
        closure[k++] = STANDBY;
        closure[k++] = TIMELOCK;
        closure[k++] = GUARDIAN;
        closure[k++] = KEEPER;
        for (uint256 i; i < closure.length; ++i) {
            if (closure[i] != address(0)) ghosts.ampsHolders.add(closure[i]);
        }

        for (uint256 i; i < actors.length; ++i) {
            ghosts.ampsHolders.add(actors[i]);
            ghosts.bonders.add(actors[i]);
            ghosts.actorValueBasis[actors[i]] = actorValueUsd18(actors[i]);
        }

        ghosts.genesisTimestampSeen = vault.genesisTimestamp();
        ghosts.polTrancheAmps = Constants.POL_SHARES;
        ghosts.lastCreatorBps = vault.creatorBpsAt(block.timestamp);
        ghosts.navPerShareHigh = vault.navPerShareX18();
        ghosts.maxNavPerShareSeen = ghosts.navPerShareHigh;
        ghosts.maxPRefSeen = vault.pRefX18();
        ghosts.potFundedRaw = POT_USDG;
    }

    /// @notice Records `who` as an account that may hold AMPS, so GL-01's closure stays closed.
    /// @dev Every handler that takes a fuzzer-chosen `to` must call this on the success arm; the unclamped
    ///      entry points accept an arbitrary address, so the fixed actor list is not a closed holder set.
    /// @param who The account.
    function noteAmpsHolder(address who) internal {
        if (who != address(0)) ghosts.ampsHolders.add(who);
    }

    /// @notice Records `who` as an owner of at least one vesting position.
    /// @param who The account.
    function noteBonder(address who) internal {
        if (who != address(0)) {
            ghosts.bonders.add(who);
            ghosts.ampsHolders.add(who);
        }
    }

    /// @notice The index of `poolId` in {pools}, or `pools.length` when it is not one of them.
    /// @param poolId The pool.
    /// @return index The index.
    function poolIndexOf(PoolId poolId) internal view returns (uint256 index) {
        for (uint256 i; i < pools.length; ++i) {
            if (PoolId.unwrap(pools[i]) == PoolId.unwrap(poolId)) return i;
        }
        return pools.length;
    }

    /// @notice What one account is worth in 18-decimal USD: everything the vault would value plus its AMPS at the
    ///         last checkpointed NAV/share.
    /// @dev The cached `navPerShareX18()` rather than `previewNavPerShareX18()` on purpose — the preview walks all
    ///      32 pools, and this is read on the hot path of GL-31.
    /// @param who The account.
    /// @return value The value.
    function actorValueUsd18(address who) internal view returns (uint256 value) {
        try vault.assetsUsd18Of(who) returns (uint256 assets) {
            value = assets;
        } catch {
            value = 0;
        }
        value += amps.balanceOf(who) * vault.navPerShareX18() / Constants.WAD;
    }

    // ―――――――――――――――――――― Shape of the world ――――――――――――――――――――

    /// @notice How many spokes this campaign opens. See {FIZZ_SPOKES}.
    /// @return count The spoke count.
    function spokeCount() internal view virtual override returns (uint256 count) {
        return FIZZ_SPOKES;
    }

    // ――――――――――― Medusa-safe overrides of the fixture ―――――――――――

    /// @notice The fixture's assets, deployed without ever calling into Permit2.
    /// @dev The only difference from `Phase3Fixture._deployAssets` is the WETH stand-in: the fixture builds it with
    ///      `V4TestBase.deployToken`, whose `_approveStack` calls `permit2.approve(...)`, and that call is the one
    ///      Medusa cannot execute (see {_stubPermit2}). `_deployWethNoPermit2` does the same three ERC-20 approvals
    ///      and stops there. Everything else below is the fixture's body.
    function _deployAssets() internal virtual override {
        weth = _deployWethNoPermit2();
        usdg = new MockUsdg("Global Dollar", "USDG", 6);
        wethFeed = new MockAggregator("ETH / USD", 8, int256(uint256(WETH_USD8)));
        usdgFeed = new MockAggregator("USDG / USD", 8, int256(uint256(USDG_USD8)));

        uint256 n = spokeCount();
        for (uint256 i; i < n; ++i) {
            string memory symbol = string.concat("STK", vm.toString(i));
            MockStockToken token = new MockStockToken(symbol, symbol);
            uint128 priceUsd8 = stockPriceUsd8(i);
            stocks.push(token);
            stockUsd8.push(priceUsd8);
            stockFeeds.push(new MockAggregator(string.concat(symbol, " / USD"), 8, int256(uint256(priceUsd8))));
            vm.label(address(token), symbol);
        }
        vm.label(address(weth), "WETH");
        vm.label(address(usdg), "USDG");
    }

    /// @dev `V4TestBase.deployToken` minus the `permit2.approve` leg.
    function _deployWethNoPermit2() private returns (MockERC20 token) {
        token = new MockERC20("Wrapped Ether", "WETH", 18);
        token.mint(address(this), 10_000_000e18);
        token.approve(address(permit2), type(uint256).max);
        token.approve(address(swapRouter), type(uint256).max);
        token.approve(address(poolManager), type(uint256).max);
    }

    /// @notice The fixture's per-owner approvals, without the Permit2 leg.
    /// @param token The token.
    /// @param who The owner.
    /// @dev The three ERC-20 `approve` calls are kept verbatim — an ERC-20 allowance *naming* Permit2 as the spender
    ///      is an ordinary token call and is fine; what cannot run under Medusa is a call *into* Permit2's etched
    ///      code. Consequence: the ordinary v4 `swapRouter` path, which pulls through Permit2, is dead in this
    ///      harness. Every trade here goes through `AmpsRouter`, which pulls with `IERC20.safeTransferFrom`.
    function approveStack(address token, address who) internal virtual override {
        vm.prank(who);
        IERC20(token).approve(address(permit2), type(uint256).max);
        vm.prank(who);
        IERC20(token).approve(address(swapRouter), type(uint256).max);
        vm.prank(who);
        IERC20(token).approve(address(vault), type(uint256).max);
    }

    /// @notice Warps `dt` seconds forward, produces a block per second with it and republishes every feed.
    /// @param dt Seconds to warp.
    /// @dev `vm.getBlockTimestamp()` / `vm.getBlockNumber()` are unimplemented in Medusa 1.5.1. Nothing in this
    ///      suite calls {warpBy} from inside a loop, so reading the two block fields directly is safe here: the
    ///      hoisting hazard the fixture documents needs a loop to bite.
    function warpBy(uint256 dt) internal virtual override {
        vm.warp(block.timestamp + dt);
        vm.roll(block.number + dt + 1);
        refreshFeeds();
    }

    /// @notice Advances the clock by `dt` seconds and one block, then republishes the feeds.
    /// @param dt Seconds to advance.
    function advance(uint256 dt) internal virtual override {
        vm.warp(block.timestamp + dt);
        vm.roll(block.number + 1);
        refreshFeeds();
    }

    /// @notice Forces one gate-cache refresh in `poolId` without moving its price.
    /// @param poolId The pool.
    function refreshGateCache(PoolId poolId) internal virtual override {
        vm.warp(block.timestamp + hook.gateCacheSeconds() + 1);
        vm.roll(block.number + 1);
        refreshFeeds();
        _pokeAfterSwap(poolId, true);
    }

    /// @notice Deploys `Amps`, `AmpsVault`, the mined `AmpsHook` and `PoolRegistry`.
    /// @dev Byte-for-byte the fixture's `_deployCore`, with `vm.computeCreateAddress` — unimplemented in Medusa
    ///      1.5.1 — replaced by the local RLP {computeCreate}. `vm.getNonce` *is* implemented, so the nonce the
    ///      prediction is built on is still the chain's own.
    function _deployCore() internal virtual override {
        address predictedVault = computeCreate(address(this), vm.getNonce(address(this)) + 1);
        amps = new Amps{salt: _mineAmpsSaltFor(predictedVault)}(predictedVault);
        vault = new AmpsVault(address(amps), address(poolManager), TIMELOCK, GUARDIAN);
        require(address(vault) == predictedVault, "vault address prediction");

        address predictedRegistry = computeCreate(address(this), vm.getNonce(address(this)) + 1);
        bytes memory args = abi.encode(poolManager, address(amps), address(vault), predictedRegistry, TIMELOCK);
        (address mined, bytes32 hookSalt) = HookMiner.find(address(this), HOOK_FLAGS, type(AmpsHook).creationCode, args);
        hook = new AmpsHook{salt: hookSalt}(poolManager, address(amps), address(vault), predictedRegistry, TIMELOCK);
        require(address(hook) == mined, "hook address mismatch");

        registry =
            new PoolRegistry(address(vault), address(hook), TIMELOCK, address(amps), address(weth), address(usdg));
        require(address(registry) == predictedRegistry, "registry address prediction");

        vm.label(address(amps), "AMPS");
        vm.label(address(vault), "AmpsVault");
        vm.label(address(hook), "AmpsHook");
        vm.label(address(registry), "PoolRegistry");
    }

    /// @dev The fixture's `_mineAmpsSalt` is `private`; this is the same search, and it is the reason `_deployCore`
    ///      can be overridden without widening anything else. The 1e6-iteration bound is never approached: the
    ///      ceiling is the lowest of `spokeCount() + 2` pseudorandom addresses, so ~`spokeCount()` keccaks suffice.
    function _mineAmpsSaltFor(address predictedVault) internal view returns (bytes32 salt) {
        bytes32 initHash = keccak256(abi.encodePacked(type(Amps).creationCode, abi.encode(predictedVault)));
        uint160 ceiling =
            uint160(address(weth)) < uint160(address(usdg)) ? uint160(address(weth)) : uint160(address(usdg));
        for (uint256 i; i < stocks.length; ++i) {
            if (uint160(address(stocks[i])) < ceiling) ceiling = uint160(address(stocks[i]));
        }
        for (uint256 i; i < 1 << 22; ++i) {
            salt = bytes32(i);
            uint160 candidate =
                uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, initHash))));
            if (candidate < ceiling && candidate > 0xffff) return salt;
        }
        revert("no AMPS salt below every counter");
    }

    /// @notice The CREATE address of `deployer`'s `nonce`-th deployment, from the RLP encoding of the pair.
    /// @dev The local stand-in for `vm.computeCreateAddress`, which Medusa 1.5.1 does not implement. Same shape as
    ///      forge-std's pre-cheatcode `StdUtils.computeCreateAddress`.
    /// @param deployer The deploying account.
    /// @param nonce Its nonce at the time of the CREATE.
    /// @return created The address.
    function computeCreate(address deployer, uint256 nonce) internal pure returns (address created) {
        // The RLP list header is 0xc0 + payload length; the address is a 20-byte string (0x94 + 20).
        if (nonce == 0x00) {
            return _last20(keccak256(abi.encodePacked(bytes1(0xd6), bytes1(0x94), deployer, bytes1(0x80))));
        }
        if (nonce <= 0x7f) {
            return _last20(keccak256(abi.encodePacked(bytes1(0xd6), bytes1(0x94), deployer, uint8(nonce))));
        }
        if (nonce <= type(uint8).max) {
            return
                _last20(keccak256(abi.encodePacked(bytes1(0xd7), bytes1(0x94), deployer, bytes1(0x81), uint8(nonce))));
        }
        if (nonce <= type(uint16).max) {
            return
                _last20(keccak256(abi.encodePacked(bytes1(0xd8), bytes1(0x94), deployer, bytes1(0x82), uint16(nonce))));
        }
        if (nonce <= type(uint24).max) {
            return
                _last20(keccak256(abi.encodePacked(bytes1(0xd9), bytes1(0x94), deployer, bytes1(0x83), uint24(nonce))));
        }
        return _last20(keccak256(abi.encodePacked(bytes1(0xda), bytes1(0x94), deployer, bytes1(0x84), uint32(nonce))));
    }

    function _last20(bytes32 word) private pure returns (address addr) {
        return address(uint160(uint256(word)));
    }

    // ――――――――――――――――――――――――― Helpers ――――――――――――――――――――――――――

    // Maps an arbitrary address to an actor address
    function toActor(address addy) internal view returns (address) {
        return actors[uint256(uint160(addy)) % actors.length];
    }

    // Maps an arbitrary address to an actor address that is different from the current actor
    function toActorNotCurrent(address addy) internal view returns (address) {
        address _actor = actors[uint256(uint160(addy)) % actors.length];
        if (_actor == actor) {
            _actor = actors[(uint256(uint160(addy)) + 1) % actors.length];
        }
        return _actor;
    }

    // Sums the native token balances of all actors
    function sumActorsBalances() internal view returns (uint256 sumOfBalances) {
        for (uint256 i; i < actors.length; i++) {
            sumOfBalances += actors[i].balance;
        }
    }

    // Sums the ERC-20 token balances of all actors for a given token
    function sumActorsERC20Balances(address _token) internal view returns (uint256 sumOfBalances) {
        for (uint256 i; i < actors.length; i++) {
            bytes memory data = abi.encodeWithSignature("balanceOf(address)", actors[i]);
            (bool success, bytes memory result) = _token.staticcall(data);
            require(success, "sumActorsERC20Balances: failed to get balance");
            sumOfBalances += abi.decode(result, (uint256));
        }
    }

    function skipBlocks(uint256 blocks) internal {
        vm.roll(block.number + blocks);
        vm.warp(block.timestamp + blocks * BLOCK_INTERVAL);
    }

    function skipTime(uint256 time) internal {
        uint256 blocks = (time + BLOCK_INTERVAL - 1) / BLOCK_INTERVAL;
        vm.roll(block.number + blocks);
        vm.warp(block.timestamp + time);
    }

    // ―――――――――――――― Helpers the handlers share ――――――――――――――――――

    /// @notice The pool a fuzzed seed selects.
    /// @param seed The seed.
    /// @return poolId The pool.
    function poolFrom(uint256 seed) internal view returns (PoolId poolId) {
        return pools[seed % pools.length];
    }

    /// @notice A spoke pool a fuzzed seed selects, i.e. one that can be a rotation leg.
    /// @param seed The seed.
    /// @return poolId The pool.
    function spokeFrom(uint256 seed) internal view returns (PoolId poolId) {
        return spokePools[seed % spokePools.length];
    }

    /// @notice The pool's counter asset.
    /// @param poolId The pool.
    /// @return counter The token.
    function counterOf(PoolId poolId) internal view returns (address counter) {
        return registry.poolConfig(poolId).counter;
    }

    /// @notice One trading "unit" of a pool's counter asset: small enough that a single step stays inside the
    ///         hook's outer rail, which is what makes a clamped swap land rather than revert.
    /// @dev The sizes `test/invariant/Phase3Handler.sol` settled on.
    /// @param poolId The pool.
    /// @return unit The unit.
    function counterUnit(PoolId poolId) internal view returns (uint256 unit) {
        uint8 decimals = registry.poolConfig(poolId).counterDecimals;
        if (decimals == 6) return 1e5;
        if (PoolId.unwrap(poolId) == PoolId.unwrap(wethPool)) return 1e13;
        return 1e14;
    }

    /// @notice Mints `amount` of `token` to the current actor and re-approves every spender.
    /// @param token The token.
    /// @param amount The amount.
    function fundActor(address token, uint256 amount) internal {
        (bool ok,) = token.call(abi.encodeWithSignature("mint(address,uint256)", actor, amount));
        ok;
        approveAll(token, actor);
    }

    /// @notice The constituent id a fuzzed seed selects.
    /// @param seed The seed.
    /// @return id The id.
    function constituentFrom(uint256 seed) internal view returns (uint16 id) {
        return constituentIds[seed % constituentIds.length];
    }

    /// @notice The bond market id a fuzzed seed selects.
    /// @param seed The seed.
    /// @return id The id.
    function marketFrom(uint256 seed) internal view returns (uint16 id) {
        return marketIds[seed % marketIds.length];
    }

    /// @notice The ids of every `ACTIVE` constituent, which is the domain `PoolRegistry.setIndexWeights` scores a
    ///         weight vector over.
    /// @return ids The ids.
    function activeConstituents() internal view returns (uint16[] memory ids) {
        uint256 n;
        for (uint256 i; i < constituentIds.length; ++i) {
            if (registry.constituent(constituentIds[i]).status == ConstituentStatus.ACTIVE) ++n;
        }
        ids = new uint16[](n);
        uint256 k;
        for (uint256 i; i < constituentIds.length; ++i) {
            if (registry.constituent(constituentIds[i]).status == ConstituentStatus.ACTIVE) {
                ids[k++] = constituentIds[i];
            }
        }
    }

    /// @notice Every token the `FeedRegistry` has a feed for: the two entry counters and every stock.
    /// @return tokens The tokens.
    function feedTokens() internal view returns (address[] memory tokens) {
        tokens = new address[](2 + stocks.length);
        tokens[0] = address(weth);
        tokens[1] = address(usdg);
        for (uint256 i; i < stocks.length; ++i) {
            tokens[2 + i] = address(stocks[i]);
        }
    }
}
