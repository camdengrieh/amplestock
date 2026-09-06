// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IAmpsVault} from "../src/interfaces/IAmpsVault.sol";
import {IOracleGate} from "../src/interfaces/IOracleGate.sol";
import {IPoolRegistry} from "../src/interfaces/IPoolRegistry.sol";
import {LadderLib} from "../src/lib/LadderLib.sol";
import {Constants} from "../src/types/Constants.sol";
import {ConstituentStatus, GateState, PoolConfig} from "../src/types/Types.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Script} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {console2} from "forge-std/console2.sol";

/// @title GenesisPlacement
/// @notice Runs `AmpsVault.genesis()` and then the §3.3 launch ladders: the ask ladder in all 32 pools and,
///         after the 60-second per-pool cooldown, the seed bids in the two entry pools.
///
///         The launch vector (`docs/phase3-state-model.md` §3.3, plan "Launch parameters"):
///
///         | Where | What | Cells |
///         |---|---|---|
///         | `AMPS/USDG`, `AMPS/WETH` | 1,662.5 AMPS of asks each, 10 doublings, tilt 1.25 | `m = 0..9` |
///         | `AMPS/USDG`, `AMPS/WETH` | $2,500 of counter each as seed bids, 4 halvings | `m = -1..-4` |
///         | 30 spokes | 47.5 AMPS each (1% of the 4,750 POL tranche), 10 doublings | `m = 0..9` |
///
///         3,325 + 1,425 = 4,750 AMPS of POL, 250 to the team's `VestingWallet`, `S0` = 5,000.
///
/// @dev **Two phases, because of the cooldown.** `VaultPlacementLib` enforces a 60-second per-pool placement
///      cooldown, and an entry pool needs two placements — its asks and its bids. The script therefore runs in
///      two passes and {nextPhase} works out from chain state which one is due: phase 1 is `genesis()` plus every
///      ask ladder, phase 2 is the two entry-pool bid ladders. Re-running a completed phase is a no-op, so
///      `--resume` is just "run it again". {cooldownRemaining} says how long phase 2 has to wait, read off the
///      ladder records' own `placedAt` — the vault's private cooldown map has no getter, but every placement
///      stamps the records it touches, so the newest `placedAt` in a pool *is* its last placement.
///
/// @dev **The grid is checked, not assumed.** {assertLayout} recomputes each record's cell index
///      `m = (lowerTick - gridBaseTick) / doublingTicks(tickSpacing)` and asserts that the asks are
///      `ladderDoublings` contiguous one-cell ranges anchored at the grid origin and the seed bids are
///      `seedHalvings` contiguous cells at `m = -1..-4` — which only comes out because the vault snapped each
///      pool's opening price down onto its own grid origin (§12 ruling C). A pool that opened off-grid would put
///      the seed bids a whole doubling low, and this is what catches it. See {assertLayout}'s own note for why
///      the ask block may legitimately start at `m = 1` rather than `m = 0` for a minority of pools.
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

    /// @notice `genesis()` plus every ask ladder.
    uint8 internal constant PHASE_GENESIS_AND_ASKS = 1;

    /// @notice The two entry-pool seed bid ladders, 60 seconds later.
    uint8 internal constant PHASE_ENTRY_BIDS = 2;

    /// @notice Nothing left to do.
    uint8 internal constant PHASE_DONE = 0;

    /// @notice Ask inventory per entry pool: half of the 3,325 AMPS that stay in the entry pools.
    uint256 internal constant ENTRY_ASK_AMPS = 1662.5e18;

    /// @notice Seed ask per spoke: 1% of the 4,750 AMPS POL tranche.
    uint256 internal constant SPOKE_SEED_AMPS = 47.5e18;

    /// @notice How far NAV/share may sit from the $1.00 launch price before the run refuses. The seed is $5,000
    ///         of ETH and USDG against `S0` = 5,000 AMPS, so the only slack is the feeds' own rounding.
    uint16 internal constant NAV_TOLERANCE_BPS = 100;

    // -----------------------------------------------------------------------------------------------------------
    // Types
    // -----------------------------------------------------------------------------------------------------------

    /// @notice Everything genesis and the ladders need.
    /// @param timelock The 7-day timelock: the only caller of `genesis` and of `place`.
    /// @param vault `AmpsVault`.
    /// @param teamVestingWallet The OZ `VestingWallet` the 250 AMPS team tranche is minted to.
    /// @param creator The creator-fee recipient recorded at genesis.
    /// @param seedTokens The founders' seed assets, normally `[WETH, USDG]`.
    /// @param seedAmounts Their amounts, parallel to `seedTokens`: $2,500 of each.
    struct Params {
        address timelock;
        address vault;
        address teamVestingWallet;
        address creator;
        address[] seedTokens;
        uint256[] seedAmounts;
    }

    /// @notice What one run did.
    /// @param phase The phase it ran.
    /// @param genesisRan Whether it minted `S0` this run.
    /// @param navPerShareX18 NAV/share after genesis.
    /// @param askPools How many ask ladders it placed.
    /// @param bidPools How many bid ladders it placed.
    /// @param liveCells The vault's live-cell count afterwards.
    struct Report {
        uint8 phase;
        bool genesisRan;
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

    /// @notice The gate is not `GREEN`, so `genesis()` would revert `GateNotHealthy`. Bootstrap step 4 of
    ///         `docs/phase2-state-model.md` §9.1 has not completed.
    error GateNotGreen(GateState actual);

    /// @notice The vault has no gate pointer at all. Registration runs ungated on purpose, but genesis must not.
    error GateUnset();

    /// @notice NAV/share after genesis is not the $1.00 launch price within {NAV_TOLERANCE_BPS}.
    error NavOffLaunchPrice(uint256 navPerShareX18);

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
        console2.log("navPerShare %s, live cells %s", report.navPerShareX18, report.liveCells);
        if (nextPhase(p.vault) == PHASE_DONE) assertLayout(p.vault);
    }

    /// @notice Runs one phase.
    /// @dev Phase 1 is `genesis()` — skipped when it has already run — followed by the ask ladder in every
    ///      registered pool that has none. Phase 2 is the two entry-pool bid ladders, and refuses until the
    ///      60-second cooldown has elapsed on both.
    /// @param p The parameters.
    /// @param phase {PHASE_GENESIS_AND_ASKS} or {PHASE_ENTRY_BIDS}.
    /// @return report What it did.
    function execute(Params memory p, uint8 phase) public returns (Report memory report) {
        if (p.vault == address(0)) revert MissingAddress("vault");
        if (p.timelock == address(0)) revert MissingAddress("timelock");

        IAmpsVault vault = IAmpsVault(p.vault);
        IPoolRegistry registry = IPoolRegistry(vault.registry());
        report.phase = phase;

        assertGateGreen(p.vault);

        if (phase == PHASE_GENESIS_AND_ASKS) {
            if (!vault.initialized()) {
                _genesis(p);
                report.genesisRan = true;
            }
            report.navPerShareX18 = vault.navPerShareX18();
            _assertLaunchPrice(report.navPerShareX18);
            report.askPools = _placeAsks(p, vault, registry);
        } else {
            report.navPerShareX18 = vault.navPerShareX18();
            report.bidPools = _placeEntryBids(p, vault, registry);
        }

        report.liveCells = vault.liveCells();
    }

    /// @notice Which phase is due, from chain state alone.
    /// @param vaultAddress `AmpsVault`.
    /// @return phase {PHASE_GENESIS_AND_ASKS}, {PHASE_ENTRY_BIDS} or {PHASE_DONE}.
    function nextPhase(address vaultAddress) public view returns (uint8 phase) {
        IAmpsVault vault = IAmpsVault(vaultAddress);
        if (!vault.initialized()) return PHASE_GENESIS_AND_ASKS;

        IPoolRegistry registry = IPoolRegistry(vault.registry());
        PoolId[] memory pools = allPools(vaultAddress);
        for (uint256 i; i < pools.length; ++i) {
            if (_countSide(vault, pools[i], true) == 0) return PHASE_GENESIS_AND_ASKS;
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

    /// @notice The vault's gate must be wired and `GREEN` before genesis (`docs/phase2-state-model.md` §9.1
    ///         step 4). Pool registration deliberately runs with no gate; genesis deliberately does not.
    /// @param vaultAddress `AmpsVault`.
    function assertGateGreen(address vaultAddress) public view {
        address gate = IAmpsVault(vaultAddress).oracleGate();
        if (gate == address(0)) revert GateUnset();
        GateState state = IOracleGate(gate).state(0);
        if (state != GateState.GREEN) revert GateNotGreen(state);
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

    /// @notice The parameters, from `script/config/deployments.json` with the environment winning. The seed is
    ///         the confirmed 50/50 split: $2,500 of ETH and $2,500 of USDG.
    /// @return p The parameters.
    function loadParams() public view returns (Params memory p) {
        string memory json = vm.readFile(DEPLOYMENTS_PATH);
        p.timelock = _address(json, ".core.timelock", "AMPS_TIMELOCK");
        p.vault = _address(json, ".core.vault", "AMPS_VAULT");
        p.teamVestingWallet = _address(json, ".core.teamVestingWallet", "AMPS_TEAM_VESTING");
        p.creator = _address(json, ".core.creator", "AMPS_CREATOR");

        p.seedTokens = new address[](2);
        p.seedAmounts = new uint256[](2);
        p.seedTokens[0] = _address(json, ".core.weth9", "AMPS_WETH9");
        p.seedAmounts[0] = vm.envOr("AMPS_SEED_WETH", uint256(1e18));
        p.seedTokens[1] = _address(json, ".core.usdg", "AMPS_USDG");
        p.seedAmounts[1] = vm.envOr("AMPS_SEED_USDG", uint256(2500e6));
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

    /// @dev `genesis()` itself: approve the seed assets out of the timelock, mint `S0`, split 250/4,750.
    function _genesis(Params memory p) private {
        if (p.teamVestingWallet == address(0)) revert MissingAddress("teamVestingWallet");
        if (p.creator == address(0)) revert MissingAddress("creator");

        vm.startBroadcast(p.timelock);
        for (uint256 i; i < p.seedTokens.length; ++i) {
            IERC20(p.seedTokens[i]).approve(p.vault, p.seedAmounts[i]);
        }
        IAmpsVault(p.vault)
            .genesis(
                IAmpsVault.GenesisParams({
                    teamVestingWallet: p.teamVestingWallet,
                    creator: p.creator,
                    teamShares: Constants.TEAM_SHARES,
                    polShares: Constants.POL_SHARES,
                    seedTokens: p.seedTokens,
                    seedAmounts: p.seedAmounts
                })
            );
        vm.stopBroadcast();
        console2.log("genesis complete: S0 minted, creator %s", p.creator);
    }

    /// @dev The ask ladder in every pool that has none: 1,662.5 AMPS in each entry pool, 47.5 in each spoke.
    function _placeAsks(Params memory p, IAmpsVault vault, IPoolRegistry registry) private returns (uint16 placed) {
        PoolId hub = registry.hubPoolId();
        PoolId weth = registry.wethPoolId();
        PoolId[] memory pools = allPools(p.vault);
        uint256 buckets = uint256(vault.ladderDoublings());

        vm.startBroadcast(p.timelock);
        for (uint256 i; i < pools.length; ++i) {
            PoolId poolId = pools[i];
            if (_countSide(vault, poolId, true) != 0) continue;

            bool isEntry = PoolId.unwrap(poolId) == PoolId.unwrap(hub) || PoolId.unwrap(poolId) == PoolId.unwrap(weth);
            uint256 amount = isEntry ? ENTRY_ASK_AMPS : SPOKE_SEED_AMPS;

            uint32 live = vault.liveCells();
            if (uint256(live) + buckets > Constants.MAX_LIVE_CELLS) {
                vm.stopBroadcast();
                revert CellBudgetExhausted(live, buckets);
            }

            vault.place(poolId, true, amount);
            ++placed;
        }
        vm.stopBroadcast();
    }

    /// @dev The two entry-pool seed bid ladders, once the cooldown allows.
    function _placeEntryBids(Params memory p, IAmpsVault vault, IPoolRegistry registry)
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

        vm.startBroadcast(p.timelock);
        for (uint256 i; i < 2; ++i) {
            if (_countSide(vault, pools[i], false) != 0) continue;
            uint256 amount = _seedAmountOf(p, counters[i]);
            if (amount == 0) continue;

            uint32 live = vault.liveCells();
            uint256 buckets = uint256(vault.seedHalvings());
            if (uint256(live) + buckets > Constants.MAX_LIVE_CELLS) {
                vm.stopBroadcast();
                revert CellBudgetExhausted(live, buckets);
            }

            vault.place(pools[i], false, amount);
            ++placed;
        }
        vm.stopBroadcast();
    }

    /// @dev The seed amount configured for `token`, i.e. what genesis settled into the vault's claims.
    function _seedAmountOf(Params memory p, address token) private pure returns (uint256 amount) {
        for (uint256 i; i < p.seedTokens.length; ++i) {
            if (p.seedTokens[i] == token) return p.seedAmounts[i];
        }
    }

    /// @dev How many live cells `poolId` holds on one side.
    function _countSide(IAmpsVault vault, PoolId poolId, bool above) private view returns (uint256 count) {
        uint256 n = vault.ladderLength(poolId);
        for (uint256 i; i < n; ++i) {
            (,, uint128 liquidity,,, bool recordAbove,,,,) = vault.ladderAt(poolId, i);
            if (liquidity != 0 && recordAbove == above) ++count;
        }
    }

    /// @dev NAV/share must be the $1.00 launch price: $5,000 of seed against `S0` = 5,000 AMPS.
    function _assertLaunchPrice(uint256 navPerShareX18) private pure {
        uint256 low = Constants.WAD - (Constants.WAD * NAV_TOLERANCE_BPS) / Constants.BPS;
        uint256 high = Constants.WAD + (Constants.WAD * NAV_TOLERANCE_BPS) / Constants.BPS;
        if (navPerShareX18 < low || navPerShareX18 > high) revert NavOffLaunchPrice(navPerShareX18);
    }

    function _address(string memory json, string memory path, string memory envName)
        private
        view
        returns (address value)
    {
        value = vm.envOr(envName, json.readAddress(path));
    }
}
