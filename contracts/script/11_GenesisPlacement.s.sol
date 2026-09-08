// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IAmpsGenesis} from "../src/interfaces/IAmpsGenesis.sol";
import {IAmpsVault} from "../src/interfaces/IAmpsVault.sol";
import {IOracleGate} from "../src/interfaces/IOracleGate.sol";
import {IPoolRegistry} from "../src/interfaces/IPoolRegistry.sol";
import {LadderLib} from "../src/lib/LadderLib.sol";
import {Constants} from "../src/types/Constants.sol";
import {ConstituentStatus, GateState, PoolConfig} from "../src/types/Types.sol";
import {Gov} from "./lib/Gov.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Script} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {console2} from "forge-std/console2.sol";

/// @title GenesisPlacement
/// @notice Runs the §3.3 launch ladders: the ask ladder in all 32 pools and, after the 60-second per-pool
///         cooldown, the seed bids in the two entry pools.
///
///         The launch vector (`docs/phase3-state-model.md` §3.3, plan revision 7):
///
///         | Where | What | Cells |
///         |---|---|---|
///         | `AMPS/USDG`, `AMPS/WETH` | 3,150 AMPS of asks each, 10 doublings, tilt 1.25 | `m = 0..9` |
///         | `AMPS/USDG`, `AMPS/WETH` | the auction proceeds held in each pool's counter, 4 halvings | `m = -1..-4` |
///         | 30 spokes | 90 AMPS each (1% of the 9,000 POL tranche), 10 doublings | `m = 0..9` |
///
///         6,300 + 2,700 = 9,000 AMPS of POL, 10,000 through the auctions, 1,000 to the team's `VestingWallet`,
///         `S0` = 20,000. Every ask is anchored at `P_ref`, which revision 7 seeds at the auctions' clearing
///         price `P0` rather than at $1.00, and every pool opened at `P0` too (§12 ruling C), so the ladders sit
///         on the grid origin exactly as they did at the old fixed launch price.
///
/// @dev **Genesis itself is no longer here.** Revision 7 splits it in two — `AmpsVault.genesisMint` in
///      `06a_GenesisAuction` before the auctions, `AmpsVault.genesisPlace` inside `AmpsGenesis.settle()` in
///      `06b_GenesisSettle` after them — and `05_Registry` opens the 32 pools at `P0` in between. This script is
///      what runs last, and it refuses outright if `genesisPlace` has not happened.
///
/// @dev **Two phases, because of the cooldown.** `VaultPlacementLib` enforces a 60-second per-pool placement
///      cooldown, and an entry pool needs two placements — its asks and its bids. The script therefore runs in
///      two passes and {nextPhase} works out from chain state which one is due: phase 1 is every ask ladder,
///      phase 2 is the two entry-pool bid ladders. Re-running a completed phase is a no-op, so `--resume` is just
///      "run it again". {cooldownRemaining} says how long phase 2 has to wait, read off the ladder records' own
///      `placedAt` — the vault's private cooldown map has no getter, but every placement stamps the records it
///      touches, so the newest `placedAt` in a pool *is* its last placement.
///
/// @dev **The grid is checked, not assumed.** {assertLayout} recomputes each record's cell index
///      `m = (lowerTick - gridBaseTick) / doublingTicks(tickSpacing)` and asserts that the asks are
///      `ladderDoublings` contiguous one-cell ranges anchored at the grid origin and the seed bids are
///      `seedHalvings` contiguous cells at `m = -1..-4` — which only comes out because the vault snapped each
///      pool's opening price down onto its own grid origin (§12 ruling C). A pool that opened off-grid would put
///      the seed bids a whole doubling low, and this is what catches it. See {assertLayout}'s own note for why
///      the ask block may legitimately start at `m = 1` rather than `m = 0` for a minority of pools.
///
/// @dev **Who signs what: everything here is a governed call.** `AmpsVault.place` is
///      `msg.sender == timelock || msg.sender == registry` — the `locked` modifier is not the whole guard, which
///      is easy to misread from the signature — so all 34 placements are governed. They go through
///      `script/lib/Gov.sol`: a direct call when the timelock is an address the operator controls, `schedule` +
///      `execute` when it is a `TimelockController`.
///
/// @dev **Usage.**
/// ```
///   # phase 1: genesis + every ask ladder
///   forge script script/11_GenesisPlacement.s.sol --broadcast --rpc-url $RPC --libraries ...
///
///   # ...wait out the 60-second cooldown, then phase 2: the entry-pool seed bids
///   forge script script/11_GenesisPlacement.s.sol --broadcast --rpc-url $RPC --libraries ...
/// ```
contract GenesisPlacement is Script {
    using stdJson for string;

    // -----------------------------------------------------------------------------------------------------------
    // Constants
    // -----------------------------------------------------------------------------------------------------------

    /// @notice The core deployment addresses.
    string internal constant DEPLOYMENTS_PATH = "./script/config/deployments.json";

    /// @notice Every ask ladder.
    uint8 internal constant PHASE_ASKS = 1;

    /// @notice The two entry-pool seed bid ladders, 60 seconds later.
    uint8 internal constant PHASE_ENTRY_BIDS = 2;

    /// @notice Nothing left to do.
    uint8 internal constant PHASE_DONE = 0;

    /// @notice Ask inventory per entry pool: half of the 6,300 AMPS that stay in the entry pools.
    uint256 internal constant ENTRY_ASK_AMPS = 3150e18;

    /// @notice Seed ask per spoke: 1% of the 9,000 AMPS POL tranche.
    uint256 internal constant SPOKE_SEED_AMPS = 90e18;

    /// @notice How far the vault's reference may sit from the adapter's `P0` before the run refuses. They are
    ///         written by the same transaction, so the only slack is the NAV floor `genesisPlace` applies.
    uint16 internal constant ANCHOR_TOLERANCE_BPS = 100;

    // -----------------------------------------------------------------------------------------------------------
    // Types
    // -----------------------------------------------------------------------------------------------------------

    /// @notice Everything the ladders need.
    /// @param timelock The 7-day timelock: the only caller of `place`.
    /// @param vault `AmpsVault`.
    /// @param genesis The `AmpsGenesis` adapter, or zero on the fallback path. Used only to cross-check `P0`.
    /// @param seedTokens The two entry counters, normally `[WETH, USDG]`.
    /// @param seedAmounts An explicit bid size per counter, or zero — the usual case — to bid whatever the vault
    ///        actually holds of it in ERC-6909 claims, which is what `genesisPlace` settled the proceeds into.
    struct Params {
        address timelock;
        address vault;
        address genesis;
        address[] seedTokens;
        uint256[] seedAmounts;
    }

    /// @notice What one run did.
    /// @param phase The phase it ran.
    /// @param p0X18 The vault's reference price, i.e. the auctions' clearing price `P0`.
    /// @param navPerShareX18 NAV/share, which is `raised / S0` at launch and below `P0` by the disclosed premium.
    /// @param askPools How many ask ladders it placed.
    /// @param bidPools How many bid ladders it placed.
    /// @param liveCells The vault's live-cell count afterwards.
    struct Report {
        uint8 phase;
        uint256 p0X18;
        uint256 navPerShareX18;
        uint16 askPools;
        uint16 bidPools;
        uint32 liveCells;
    }

    // -----------------------------------------------------------------------------------------------------------
    // Errors
    // -----------------------------------------------------------------------------------------------------------

    /// @notice A required address is zero.
    error MissingAddress(string what);

    /// @notice The gate is not `GREEN`, so `place` would revert `GateNotHealthy`. Bootstrap step 4 of
    ///         `docs/phase2-state-model.md` §9.1 has not completed.
    error GateNotGreen(GateState actual);

    /// @notice The vault has no gate pointer at all. Registration runs ungated on purpose, but placement must not.
    error GateUnset();

    /// @notice `AmpsVault.genesisPlace` has not run, so there is no `P_ref` to anchor a ladder at and no
    ///         inventory to place. `06b_GenesisSettle` (or the timelock's fallback call) comes first.
    error GenesisNotPlaced();

    /// @notice The vault's reference price is not the adapter's clearing price within {ANCHOR_TOLERANCE_BPS}, so
    ///         the pools and the ladders would not be anchored at the same `P0`.
    /// @param pRefX18 What the vault holds.
    /// @param p0X18 What the adapter settled at.
    error AnchorMismatch(uint256 pRefX18, uint256 p0X18);

    /// @notice Phase 2 was asked for before the per-pool cooldown elapsed.
    /// @param poolId The pool.
    /// @param secondsRemaining How much longer to wait.
    error CooldownNotElapsed(PoolId poolId, uint256 secondsRemaining);

    /// @notice Placing the next ladder would take the vault past `Constants.MAX_LIVE_CELLS`, whose whole purpose
    ///         is to keep `redeemProRata` inside one block (§12 ruling E). Nothing is placed.
    /// @param live The current count.
    /// @param wanted How many cells the next ladder needs.
    error CellBudgetExhausted(uint32 live, uint256 wanted);

    /// @notice A pool's ladder does not sit where §3.3 says it should.
    /// @param poolId The pool.
    /// @param cellIndex The offending cell index `m`.
    error LayoutMismatch(PoolId poolId, int256 cellIndex);

    // -----------------------------------------------------------------------------------------------------------
    // Entry points
    // -----------------------------------------------------------------------------------------------------------

    /// @notice Runs whichever phase is due and asserts the result.
    function run() external {
        Params memory p = loadParams();
        uint8 phase = nextPhase(p.vault);
        if (phase == PHASE_DONE) {
            console2.log("genesis and both ladder passes are already complete");
            assertLayout(p.vault);
            return;
        }
        Report memory report = execute(p, phase);
        console2.log("phase %s: %s ask ladders, %s bid ladders", report.phase, report.askPools, report.bidPools);
        console2.log("P0 %s, navPerShare %s, live cells %s", report.p0X18, report.navPerShareX18, report.liveCells);
        if (nextPhase(p.vault) == PHASE_DONE) assertLayout(p.vault);
    }

    /// @notice Runs one phase.
    /// @dev Phase 1 is the ask ladder in every registered pool that has none. Phase 2 is the two entry-pool bid
    ///      ladders, and refuses until the 60-second cooldown has elapsed on both. Both refuse before
    ///      `AmpsVault.genesisPlace`.
    /// @param p The parameters.
    /// @param phase {PHASE_ASKS} or {PHASE_ENTRY_BIDS}.
    /// @return report What it did.
    function execute(Params memory p, uint8 phase) public returns (Report memory report) {
        if (p.vault == address(0)) revert MissingAddress("vault");
        if (p.timelock == address(0)) revert MissingAddress("timelock");

        IAmpsVault vault = IAmpsVault(p.vault);
        IPoolRegistry registry = IPoolRegistry(vault.registry());
        report.phase = phase;

        if (!vault.initialized()) revert GenesisNotPlaced();
        assertGateGreen(p.vault);
        assertAnchor(p);

        Gov.Ctx memory ctx = Gov.load(p.timelock);
        Gov.describe(ctx);

        report.navPerShareX18 = vault.navPerShareX18();
        report.p0X18 = vault.pRefX18();

        if (phase == PHASE_ASKS) {
            report.askPools = _placeAsks(ctx, p, vault, registry);
        } else {
            report.bidPools = _placeEntryBids(ctx, p, vault, registry);
        }

        report.liveCells = vault.liveCells();
    }

    /// @notice Which phase is due, from chain state alone.
    /// @param vaultAddress `AmpsVault`.
    /// @return phase {PHASE_ASKS}, {PHASE_ENTRY_BIDS} or {PHASE_DONE}.
    function nextPhase(address vaultAddress) public view returns (uint8 phase) {
        IAmpsVault vault = IAmpsVault(vaultAddress);
        if (!vault.initialized()) return PHASE_ASKS;

        IPoolRegistry registry = IPoolRegistry(vault.registry());
        PoolId[] memory pools = allPools(vaultAddress);
        for (uint256 i; i < pools.length; ++i) {
            if (_countSide(vault, pools[i], true) == 0) return PHASE_ASKS;
        }
        PoolId[2] memory entries = [registry.hubPoolId(), registry.wethPoolId()];
        for (uint256 i; i < 2; ++i) {
            if (_countSide(vault, entries[i], false) == 0) return PHASE_ENTRY_BIDS;
        }
        phase = PHASE_DONE;
    }

    /// @notice How much longer phase 2 must wait on `poolId`'s 60-second placement cooldown.
    /// @dev Derived from the newest `placedAt` across the pool's ladder records: every placement stamps the
    ///      records it touches, and the vault's own cooldown map is private with no getter.
    /// @param vaultAddress `AmpsVault`.
    /// @param poolId The pool.
    /// @return secondsRemaining Zero when the pool is placeable now.
    function cooldownRemaining(address vaultAddress, PoolId poolId) public view returns (uint256 secondsRemaining) {
        uint32 last = lastPlacementAt(vaultAddress, poolId);
        if (last == 0) return 0;
        uint256 ready = uint256(last) + Constants.PLACEMENT_COOLDOWN_SECONDS;
        secondsRemaining = block.timestamp >= ready ? 0 : ready - block.timestamp;
    }

    /// @notice The newest `placedAt` across `poolId`'s ladder, i.e. when the pool was last placed into.
    /// @param vaultAddress `AmpsVault`.
    /// @param poolId The pool.
    /// @return at The timestamp, or 0 when the pool has never been placed into.
    function lastPlacementAt(address vaultAddress, PoolId poolId) public view returns (uint32 at) {
        IAmpsVault vault = IAmpsVault(vaultAddress);
        uint256 n = vault.ladderLength(poolId);
        for (uint256 i; i < n; ++i) {
            (,,,,,, uint32 placedAt,,,) = vault.ladderAt(poolId, i);
            if (placedAt > at) at = placedAt;
        }
    }

    // -----------------------------------------------------------------------------------------------------------
    // Assertions
    // -----------------------------------------------------------------------------------------------------------

    /// @notice Asserts the §3.3 cell layout across every registered pool: `ladderDoublings` consecutive ask cells
    ///         starting at the grid origin, and in the two entry pools `seedHalvings` bid cells at `m = -1..-4`.
    ///
    /// @dev **Why the ask block may start at `m = 1` rather than `m = 0`.** §3.3 reads "genesis asks occupy
    ///      `m = 0..9`", and that is what happens whenever `P_ref` still equals the price the pool opened at. It
    ///      does not always: valuing a freshly placed ask ladder at the reference price picks up a sliver of
    ///      counter-side value on the cell the price sits in, so each placement lifts NAV/share — measured at the
    ///      launch vector, about 2 bps across all 32 ladders — and `P_ref` follows it. `VaultPlacementLib._cells`
    ///      then starts the ladder at `ceilDiv(fairTick(P_ref) - gridBase, D)`, which is 1 rather than 0 for a
    ///      pool whose exact fair tick happens to sit within that couple of ticks below a spacing boundary. That
    ///      is invariant I32 doing its job — no ask is ever placed below `P_ref` — so this check asserts the
    ///      shape §3.3 is really specifying (ten contiguous one-cell asks anchored at the origin, four contiguous
    ///      bids under it) and admits the one-cell shift, rather than asserting a coincidence.
    ///
    /// @param vaultAddress `AmpsVault`.
    function assertLayout(address vaultAddress) public view {
        IAmpsVault vault = IAmpsVault(vaultAddress);
        PoolId[] memory pools = allPools(vaultAddress);
        for (uint256 i; i < pools.length; ++i) {
            _assertPoolLayout(vault, pools[i]);
        }
    }

    /// @notice The vault's gate must be wired and `GREEN` before any placement
    ///         (`docs/phase2-state-model.md` §9.1 step 4). Pool registration deliberately runs with no gate; the
    ///         ladders deliberately do not.
    /// @param vaultAddress `AmpsVault`.
    function assertGateGreen(address vaultAddress) public view {
        address gate = IAmpsVault(vaultAddress).oracleGate();
        if (gate == address(0)) revert GateUnset();
        GateState state = IOracleGate(gate).state(0);
        if (state != GateState.GREEN) revert GateNotGreen(state);
    }

    /// @notice The vault's reference must be the price the auctions cleared at, so that the ask ladders anchor
    ///         where `05_Registry` opened the pools. Skipped when no adapter is configured (the founders'-seed
    ///         fallback) or when it never settled.
    /// @param p The parameters.
    function assertAnchor(Params memory p) public view {
        if (p.genesis == address(0)) return;
        IAmpsGenesis adapter = IAmpsGenesis(p.genesis);
        if (!adapter.settled()) return;
        uint256 p0 = adapter.p0X18();
        if (p0 == 0) return; // nothing graduated: the fallback path set `P_ref` to $1.00 instead.

        uint256 pRef = IAmpsVault(p.vault).pRefX18();
        uint256 gap = pRef > p0 ? pRef - p0 : p0 - pRef;
        if (gap * Constants.BPS > p0 * ANCHOR_TOLERANCE_BPS) revert AnchorMismatch(pRef, p0);
    }

    /// @notice Every pool the registry knows: the two entry pools first, then each active constituent's spoke.
    /// @param vaultAddress `AmpsVault`.
    /// @return pools The pool ids.
    function allPools(address vaultAddress) public view returns (PoolId[] memory pools) {
        IPoolRegistry registry = IPoolRegistry(IAmpsVault(vaultAddress).registry());
        uint16 count = registry.constituentCount();
        PoolId[] memory buffer = new PoolId[](uint256(count) + 2);
        uint256 found;

        PoolId hub = registry.hubPoolId();
        PoolId weth = registry.wethPoolId();
        if (PoolId.unwrap(hub) != bytes32(0)) buffer[found++] = hub;
        if (PoolId.unwrap(weth) != bytes32(0)) buffer[found++] = weth;
        for (uint16 id = 1; id <= count; ++id) {
            if (registry.constituent(id).status != ConstituentStatus.ACTIVE) continue;
            buffer[found++] = registry.poolIdOf(id);
        }

        pools = new PoolId[](found);
        for (uint256 i; i < found; ++i) {
            pools[i] = buffer[i];
        }
    }

    // -----------------------------------------------------------------------------------------------------------
    // Config
    // -----------------------------------------------------------------------------------------------------------

    /// @notice The parameters, from `script/config/deployments.json` with the environment winning. Both bid
    ///         sizes default to **zero**, which means "bid whatever the vault holds": under revision 7 the seed
    ///         bids are the auction proceeds, and nobody knows their size until the auctions clear.
    ///
    /// @dev **`AMPS_BID_*`, not `AMPS_SEED_*`.** Before revision 7 the two were the same number — the founders'
    ///      seed went in as backing and came straight back out as the entry pools' bids — so one pair of
    ///      variables served both. They are different quantities now: `AMPS_SEED_WETH` / `AMPS_SEED_USDG` are
    ///      `06b_GenesisSettle`'s founders'-seed fallback, used only when no auction graduated, while the bids
    ///      here are whatever the auctions actually raised. An operator who exports the fallback seed and then
    ///      runs this script would otherwise ask the vault to bid a sum it never received.
    /// @return p The parameters.
    function loadParams() public view returns (Params memory p) {
        string memory json = vm.readFile(DEPLOYMENTS_PATH);
        p.timelock = _address(json, ".core.timelock", "AMPS_TIMELOCK");
        p.vault = _address(json, ".core.vault", "AMPS_VAULT");
        p.genesis = _address(json, ".core.genesis", "AMPS_GENESIS");

        p.seedTokens = new address[](2);
        p.seedAmounts = new uint256[](2);
        p.seedTokens[0] = _address(json, ".core.weth9", "AMPS_WETH9");
        p.seedAmounts[0] = vm.envOr("AMPS_BID_WETH", uint256(0));
        p.seedTokens[1] = _address(json, ".core.usdg", "AMPS_USDG");
        p.seedAmounts[1] = vm.envOr("AMPS_BID_USDG", uint256(0));
    }

    // -----------------------------------------------------------------------------------------------------------
    // Internals
    // -----------------------------------------------------------------------------------------------------------

    /// @dev The contiguous block one side of a pool's ladder occupies, in grid-cell indices.
    /// @param low The lowest cell index seen.
    /// @param high The highest.
    /// @param count How many live records were seen.
    struct Extent {
        int256 low;
        int256 high;
        uint256 count;
    }

    /// @dev {assertLayout} for one pool. Split out so the ten-field `ladderAt` tuple gets its own stack frame.
    function _assertPoolLayout(IAmpsVault vault, PoolId poolId) private view {
        PoolConfig memory config = IPoolRegistry(vault.registry()).poolConfig(poolId);
        int24 width = LadderLib.doublingTicks(config.tickSpacing);

        Extent memory asks = Extent({low: type(int256).max, high: type(int256).min, count: 0});
        Extent memory bids = Extent({low: type(int256).max, high: type(int256).min, count: 0});

        uint256 n = vault.ladderLength(poolId);
        for (uint256 j; j < n; ++j) {
            (int256 m, bool above, bool live, bool onGrid) = _cellOf(vault, poolId, j, config.gridBaseTick, width);
            if (!live) continue;
            if (!onGrid) revert LayoutMismatch(poolId, m);
            Extent memory side = above ? asks : bids;
            if (m < side.low) side.low = m;
            if (m > side.high) side.high = m;
            ++side.count;
        }

        // Asks: `ladderDoublings` contiguous cells anchored at the grid origin, or one cell above it.
        int256 doublings = int256(uint256(vault.ladderDoublings()));
        if (asks.count != 0) {
            if (asks.low < 0 || asks.low > 1) revert LayoutMismatch(poolId, asks.low);
            if (int256(asks.count) != doublings || asks.high != asks.low + doublings - 1) {
                revert LayoutMismatch(poolId, asks.high);
            }
        }
        // Bids: `seedHalvings` contiguous cells immediately below the origin.
        int256 halvings = int256(uint256(vault.seedHalvings()));
        if (bids.count != 0) {
            if (bids.high != -1 || bids.low != -halvings || int256(bids.count) != halvings) {
                revert LayoutMismatch(poolId, bids.low);
            }
        }
    }

    /// @dev One ladder record reduced to what the layout check needs: its cell index, its side, whether it is
    ///      live, and whether it is exactly one cell of the pool's canonical grid (I39).
    function _cellOf(IAmpsVault vault, PoolId poolId, uint256 index, int24 gridBaseTick, int24 width)
        private
        view
        returns (int256 m, bool above, bool live, bool onGrid)
    {
        (int24 lowerTick, int24 upperTick, uint128 liquidity,,, bool recordAbove,,,,) = vault.ladderAt(poolId, index);
        int256 offset = int256(lowerTick) - int256(gridBaseTick);
        m = offset / int256(width);
        above = recordAbove;
        live = liquidity != 0;
        onGrid = offset % int256(width) == 0 && upperTick - lowerTick == width;
    }

    /// @dev The ask ladder in every pool that has none: 3,150 AMPS in each entry pool, 90 in each spoke.
    function _placeAsks(Gov.Ctx memory ctx, Params memory p, IAmpsVault vault, IPoolRegistry registry)
        private
        returns (uint16 placed)
    {
        PoolId hub = registry.hubPoolId();
        PoolId weth = registry.wethPoolId();
        PoolId[] memory pools = allPools(p.vault);
        uint256 buckets = uint256(vault.ladderDoublings());

        // `AmpsVault.place` is `msg.sender == timelock || msg.sender == registry` — the `locked` modifier is not
        // the whole guard — so every ladder placement is a governed call, exactly like `genesis()` above.
        Gov.begin(ctx);
        for (uint256 i; i < pools.length; ++i) {
            PoolId poolId = pools[i];
            if (_countSide(vault, poolId, true) != 0) continue;

            bool isEntry = PoolId.unwrap(poolId) == PoolId.unwrap(hub) || PoolId.unwrap(poolId) == PoolId.unwrap(weth);
            uint256 amount = isEntry ? ENTRY_ASK_AMPS : SPOKE_SEED_AMPS;

            uint32 live = vault.liveCells();
            if (uint256(live) + buckets > Constants.MAX_LIVE_CELLS) {
                Gov.end(ctx);
                revert CellBudgetExhausted(live, buckets);
            }

            Gov.send(ctx, p.vault, abi.encodeCall(IAmpsVault.place, (poolId, true, amount)));
            ++placed;
        }
        Gov.end(ctx);
    }

    /// @dev The two entry-pool seed bid ladders, once the cooldown allows.
    function _placeEntryBids(Gov.Ctx memory ctx, Params memory p, IAmpsVault vault, IPoolRegistry registry)
        private
        returns (uint16 placed)
    {
        PoolId[2] memory pools = [registry.hubPoolId(), registry.wethPoolId()];
        address[2] memory counters = [registry.poolConfig(pools[0]).counter, registry.poolConfig(pools[1]).counter];

        for (uint256 i; i < 2; ++i) {
            if (_countSide(vault, pools[i], false) != 0) continue;
            uint256 wait = cooldownRemaining(p.vault, pools[i]);
            if (wait != 0) revert CooldownNotElapsed(pools[i], wait);
        }

        Gov.begin(ctx);
        for (uint256 i; i < 2; ++i) {
            if (_countSide(vault, pools[i], false) != 0) continue;
            uint256 amount = _bidAmountOf(p, counters[i]);
            if (amount == 0) continue;

            uint32 live = vault.liveCells();
            uint256 buckets = uint256(vault.seedHalvings());
            if (uint256(live) + buckets > Constants.MAX_LIVE_CELLS) {
                Gov.end(ctx);
                revert CellBudgetExhausted(live, buckets);
            }

            Gov.send(ctx, p.vault, abi.encodeCall(IAmpsVault.place, (pools[i], false, amount)));
            ++placed;
        }
        Gov.end(ctx);
    }

    /// @dev How much of `token` to lay as seed bids: the configured override when there is one, otherwise
    ///      **whatever the vault actually holds** of it as an ERC-6909 claim.
    ///
    ///      The second branch is the normal one under revision 7. The bid ladders are laid out of the auction
    ///      proceeds, whose size nobody knows until the auctions clear: `AmpsGenesis.settle()` hands the vault
    ///      exactly what it swept and `genesisPlace` settles it into claims, so the claim balance *is* the
    ///      proceeds. The override exists for the fallback founders'-seed launch and for a re-run that wants to
    ///      hold part of the proceeds back.
    function _bidAmountOf(Params memory p, address token) private view returns (uint256 amount) {
        for (uint256 i; i < p.seedTokens.length; ++i) {
            if (p.seedTokens[i] == token && p.seedAmounts[i] != 0) return p.seedAmounts[i];
        }
        address manager = IAmpsVault(p.vault).poolManager();
        return IPoolManager(manager).balanceOf(p.vault, Currency.wrap(token).toId());
    }

    /// @dev How many live cells `poolId` holds on one side.
    function _countSide(IAmpsVault vault, PoolId poolId, bool above) private view returns (uint256 count) {
        uint256 n = vault.ladderLength(poolId);
        for (uint256 i; i < n; ++i) {
            (,, uint128 liquidity,,, bool recordAbove,,,,) = vault.ladderAt(poolId, i);
            if (liquidity != 0 && recordAbove == above) ++count;
        }
    }

    function _address(string memory json, string memory path, string memory envName)
        private
        view
        returns (address value)
    {
        value = vm.envOr(envName, json.readAddress(path));
    }
}
