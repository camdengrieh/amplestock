// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IFeedRegistry} from "../interfaces/IFeedRegistry.sol";
import {IMarketReference} from "../interfaces/IMarketReference.sol";
import {IOracleGate} from "../interfaces/IOracleGate.sol";
import {IPoolRegistry} from "../interfaces/IPoolRegistry.sol";
import {IRolloutPolicy} from "../interfaces/IRolloutPolicy.sol";
import {LadderLib} from "../lib/LadderLib.sol";
import {PoolStateLib} from "../lib/PoolStateLib.sol";
import {PriceLib} from "../lib/PriceLib.sol";
import {Constants} from "../types/Constants.sol";
import {
    PlacementCooldown,
    PlacementDiverged,
    RolloutLimitExceeded,
    UnknownConstituent,
    UnknownPool
} from "../types/Errors.sol";
import {ConstituentConfig, ConstituentStatus, PlacementRecord, PoolConfig} from "../types/Types.sol";
import {VaultPlacementLib} from "./VaultPlacementLib.sol";
import {VaultRedeemLib} from "./VaultRedeemLib.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IExtsload} from "@uniswap/v4-core/src/interfaces/IExtsload.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @title VaultRolloutLib
/// @notice The three placement paths that move inventory *between* pools rather than into one: `rollout`,
///         `deployBonded` and `withdrawRetiredBids`. `docs/phase3-state-model.md` §3.7.
///
/// @dev **Why a fourth library, when §7 names three.** `VaultPlacementLib` with these three functions inlined is
///      30,237 bytes under the vault profile (`via_ir`, 200 runs) — 5,661 over EIP-170. They cost 8,371 bytes
///      between them, almost all of it ABI machinery the rest of the placement path does not use: the
///      `IRolloutPolicy` request/decision round trip, `IPoolRegistry.constituent`'s thirteen-field decoder, and a
///      second amount/liquidity direction (`amount0ForLiquidity`) that only the harvest side needs. Splitting them
///      out leaves both libraries comfortably inside the limit and adds one more `--libraries` argument to the
///      deploy script and to `foundry.toml`. Nothing else about §3 changes; this file is the same code, in a
///      second deployment.
///
/// @dev **The placements themselves go back through {VaultPlacementLib-place}**, which is the *only* place a
///      position is opened. Rollout therefore cannot place a cheaper ask than a governance placement would, and
///      "no rolled-out ask below `P_ref`" (I32's third limit) is not a check here at all — it is the anchor
///      `place` already uses for every ask, snapped up onto the grid.
///
/// @dev Runs by `DELEGATECALL` in `AmpsVault`'s context, exactly like the other three libraries, and reads the
///      vault's parameter word and pointer set by slot for the same reason. See {VaultPlacementLib}'s header.
library VaultRolloutLib {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;

    /// @dev slot 0 [128..255] `pRefX18`.
    uint256 private constant SLOT_CHECKPOINT0 = 0;
    /// @dev slot 1 [0..127] `pMktX18`.
    uint256 private constant SLOT_CHECKPOINT1 = 1;
    /// @dev slot 2, the governed numeric set.
    uint256 private constant SLOT_PARAMS = 2;
    /// @dev slot 4, the pool registry.
    uint256 private constant SLOT_REGISTRY = 4;
    /// @dev slot 8, the market reference (`AmpsHook` in production), which owns the high-water mark.
    uint256 private constant SLOT_MARKET_REFERENCE = 8;
    /// @dev slot 9, the oracle gate.
    uint256 private constant SLOT_ORACLE_GATE = 9;
    /// @dev slot 10, the feed registry.
    uint256 private constant SLOT_FEED_REGISTRY = 10;
    /// @dev slot 13, the rollout policy.
    uint256 private constant SLOT_ROLLOUT_POLICY = 13;
    /// @dev slot 15 [0..127] `rolloutMoved24h`, [128..159] `rolloutWindowStart`.
    uint256 private constant SLOT_ROLLOUT_WINDOW = 15;
    /// @dev slot 20, `deployThresholdUsd18`.
    uint256 private constant SLOT_DEPLOY_THRESHOLD = 20;

    // -------------------------------------------------------------------------------------------------------------
    // Events — mirrors of {IAmpsVault}'s, emitted from the vault's own address by the `DELEGATECALL`
    // -------------------------------------------------------------------------------------------------------------

    /// @dev Mirrors `IAmpsVault.Rollout`.
    event Rollout(uint16 indexed constituentId, PoolId indexed poolId, uint256 movedAmps, uint256 placedAmps);

    // -------------------------------------------------------------------------------------------------------------
    // Entry points
    // -------------------------------------------------------------------------------------------------------------

    /// @notice `rollout(constituentId)`: moves unfilled entry-pool asks into one spoke, inside all three of I32's
    ///         limits, which the vault re-checks for itself after the schedule has proposed.
    /// @param ladder The vault's placement records.
    /// @param cooldown The vault's per-pool placement timestamps.
    /// @param poolManager The Uniswap v4 PoolManager.
    /// @param amps The AMPS token.
    /// @param constituentId The destination constituent.
    /// @param gasStart `gasleft()` as `AmpsVault.rollout` was entered, for the measured gas allowance.
    /// @return moved AMPS wei actually moved.
    function rollout(
        mapping(PoolId => PlacementRecord[]) storage ladder,
        mapping(PoolId => uint32) storage cooldown,
        address poolManager,
        address amps,
        uint16 constituentId,
        uint256 gasStart
    ) public returns (uint256 moved) {
        address registry = _addr(SLOT_REGISTRY);
        address policy = _addr(SLOT_ROLLOUT_POLICY);
        if (policy == address(0) || registry == address(0)) return 0;

        ConstituentConfig memory constituent = IPoolRegistry(registry).constituent(constituentId);
        if (constituent.token == address(0)) revert UnknownConstituent(constituentId);

        PoolId destination = IPoolRegistry(registry).poolIdOf(constituentId);
        PoolId[2] memory entries = [IPoolRegistry(registry).hubPoolId(), IPoolRegistry(registry).wethPoolId()];
        uint256 entryInventory =
            _askInventory(ladder, poolManager, entries[0]) + _askInventory(ladder, poolManager, entries[1]);

        uint16 rolloutBpsPerDay = uint16(_word(SLOT_PARAMS) >> 216);
        uint16 entryFloorBps = uint16(_word(SLOT_PARAMS) >> 232);
        uint256 budget = _rollWindow(rolloutBpsPerDay);
        uint256 amount = _propose(
            policy,
            registry,
            constituent,
            constituentId,
            entryInventory,
            budget,
            rolloutBpsPerDay,
            entryFloorBps,
            _hasBidDepth(ladder[destination])
        );
        if (amount == 0) return 0;

        // I32, re-checked rather than taken on trust: the daily budget and the entry-pool floor. The third limit —
        // no rolled-out ask below `P_ref` — is `place`'s own ask anchor and needs no check here.
        if (amount > budget) revert RolloutLimitExceeded(bytes32("dailyBudget"), amount, budget);
        uint256 floorRoom = _floorRoom(entryFloorBps, entryInventory);
        if (amount > floorRoom) revert RolloutLimitExceeded(bytes32("entryFloor"), amount, floorRoom);

        // Only *unfilled* ask cells move, so no counter asset is touched (I29, I35). Each source pool pays the
        // full gauntlet in its own right, but **not** its cooldown: that is written once, below, after the
        // re-placement has had its chance at the same pools.
        uint256[2] memory movedFrom;
        for (uint256 i; i < 2 && moved < amount; ++i) {
            movedFrom[i] = _harvestAsks(ladder, cooldown, poolManager, amps, entries[i], amount - moved);
            moved += movedFrom[i];
        }
        if (moved == 0) return 0;

        // The bountied paths merge into cells that already exist and leave the remainder idle rather than
        // revert when the live-cell budget is full (§12 ruling E), which is what `strictBudget == false` says.
        uint256 placed =
            VaultPlacementLib.place(ladder, cooldown, poolManager, amps, destination, true, moved, "rollout", false);

        // Whatever the destination could not take goes **back into the entry pools it came from**, in the same
        // call, as asks at the same reference anchor {VaultPlacementLib-place} uses for every ask. The objection
        // that used to stand here — that a second placement would take the source pools' cooldown twice in one
        // transaction — is answered by moving that write out of {_harvestAsks}: the cooldown is taken once, after
        // this loop, so the pools are in exactly the state they would have been in had the harvest been smaller.
        // The re-placement is itself `strictBudget == false` and may place nothing (a full live-cell budget frees
        // no room for a cell the harvest emptied), in which case the inventory stays idle in the vault, where `A`
        // still values it (I5) and the next `compound` or `place` re-ladders it. Either way the gap is reported:
        // `Rollout` carries both `moved` and `placed`, and their difference is what did not reach the spoke.
        uint256 returned;
        for (uint256 i; i < 2 && placed + returned < moved; ++i) {
            if (movedFrom[i] == 0) continue;
            returned += VaultPlacementLib.place(
                ladder, cooldown, poolManager, amps, entries[i], true, moved - placed - returned, "rollback", false
            );
        }

        // **The 24-hour window is charged on what actually left the entry pools** (audit fix, 2026-09-07, corrected
        // 2026-09-09).
        //
        // Charging it on `placed` was exactly backwards. The window is I32's rate limit on *draining the entry
        // pools*, and inventory leaves them on the harvest, whether or not the destination takes it. With a full
        // live-cell budget `place(strictBudget = false)` places nothing at all, so nothing was charged, and the
        // same call could be repeated every `PLACEMENT_COOLDOWN_SECONDS`: the entry pools could be emptied to
        // `entryFloorBps` at one full daily allowance per sixty seconds while the window stayed at zero.
        //
        // But the charge belongs *after* the rollback, not before it. The loop above puts whatever the destination
        // refused straight back into the same entry pools, so on a full live-cell budget the harvest and the
        // rollback cancelled exactly and the whole day's allowance was consumed with zero net movement — a
        // permissionless call, costing only gas, that denied rollout for a day. `moved - returned` is the realised
        // drain, it is what I32 rate-limits, and it is bounded above by `moved <= amount <= budget`, so charging
        // it here can no more overrun the allowance than charging `moved` could.
        uint256 drained = moved - returned;
        if (drained != 0) _addRolloutMoved(drained);

        // The source pools' cooldowns, written once and last: the harvest took them, the re-placement was the
        // same keeper's same call, and everything after this is rate-limited by them as usual.
        for (uint256 i; i < 2; ++i) {
            if (movedFrom[i] != 0) cooldown[entries[i]] = uint32(block.timestamp);
        }

        emit Rollout(constituentId, destination, moved, placed);

        // **The bounty stays on `placed`**: the work the keeper created is inventory that reached the spoke, and
        // paying for a harvest the destination refused is what made the drain above worth a keeper's gas. What
        // went back into the entry pools is not new work either — it is the call undoing its own harvest.
        // A schedule that proposes nothing returns above, having paid nothing.
        // Two hops: the vault's forwarder called into this library, which calls into `VaultPlacementLib`, so the
        // EIP-150 reserve has compounded twice by the time the measurement is taken (§12.4, audit fix 2026-09-08).
        VaultPlacementLib.payBounty(VaultPlacementLib.ampsValueUsd18(placed), gasStart, 2);
    }

    /// @notice `deployBonded(constituentId)`: places idle bonded collateral as the spoke's bid ladder, four
    ///         halvings below the current price and weighted toward the tick. A no-op below the deploy threshold,
    ///         so it cannot be used to drain the bounty pot a wei at a time (§10 ruling 15).
    ///
    /// @dev **Only an `ACTIVE` constituent is deployed into.** Any other status is a silent no-op, matching the
    ///      "nothing is due" convention the rest of this file uses rather than reverting a permissionless call.
    ///      Without the check, `retireConstituent` followed by `withdrawRetiredBids` — which is precisely the pair
    ///      that empties a retired spoke's bids into claims — left that stock idle and deployable, so anyone could
    ///      call `deployBonded` and re-place the whole book as bids in the retired pool, for a bounty, as often as
    ///      the registry withdrew it. `IPoolRegistry.constituent` overlays `FROZEN` on a name whose guardian
    ///      freeze is still running, so the same line refuses a frozen name for the length of its freeze (§3.8's
    ///      "no bonds, no rollout, no placements") and lets it deploy again once the freeze lapses.
    /// @param ladder The vault's placement records.
    /// @param cooldown The vault's per-pool placement timestamps.
    /// @param poolManager The Uniswap v4 PoolManager.
    /// @param amps The AMPS token.
    /// @param constituentId The constituent.
    /// @param gasStart `gasleft()` as `AmpsVault.deployBonded` was entered, for the measured gas allowance.
    /// @return placed The raw collateral amount committed.
    function deployBonded(
        mapping(PoolId => PlacementRecord[]) storage ladder,
        mapping(PoolId => uint32) storage cooldown,
        address poolManager,
        address amps,
        uint16 constituentId,
        uint256 gasStart
    ) public returns (uint256 placed) {
        address registry = _addr(SLOT_REGISTRY);
        if (registry == address(0)) return 0;

        ConstituentConfig memory constituent = IPoolRegistry(registry).constituent(constituentId);
        if (constituent.token == address(0)) revert UnknownConstituent(constituentId);
        if (constituent.status != ConstituentStatus.ACTIVE) return 0;

        uint256 idle = IPoolManager(poolManager).balanceOf(address(this), Currency.wrap(constituent.token).toId())
            + _probeBalance(constituent.token);
        if (idle == 0) return 0;

        uint256 answerUsd8 = _answer(constituent.token);
        if (answerUsd8 == 0 || constituent.decimals > PriceLib.MAX_COUNTER_DECIMALS) return 0;
        uint256 idleUsd18 = PriceLib.counterValueUsd18(idle, constituent.decimals, answerUsd8);
        if (idleUsd18 < _word(SLOT_DEPLOY_THRESHOLD)) return 0;

        placed = VaultPlacementLib.place(
            ladder,
            cooldown,
            poolManager,
            amps,
            IPoolRegistry(registry).poolIdOf(constituentId),
            false,
            idle,
            bytes32("bonded"),
            false
        );

        // The work value is the collateral actually placed, at the same feed price the deploy threshold was
        // tested against, so the guard and the bounty can never disagree about what the job was worth (§12.4).
        VaultPlacementLib.payBounty(
            placed == idle ? idleUsd18 : PriceLib.counterValueUsd18(placed, constituent.decimals, answerUsd8),
            gasStart,
            2
        );
    }

    /// @notice `withdrawRetiredBids(constituentId)`: moves a retired spoke's remaining bid inventory out of its
    ///         positions and into ERC-6909 claims, where `A` still values it and `redeemProRata` still pays it.
    /// @dev Nothing is placed, so the divergence half of the gauntlet does not apply; the gate, the transient lock
    ///      and R1 do, and all three are the vault forwarder's.
    /// @dev **The bids' accrued fees are fees** (audit fix, 2026-09-08). A retired spoke's cells have been earning
    ///      in both currencies since the last `compound`, and the removal frees principal *and* fees in one delta;
    ///      minting the sum as claims quietly turned the creator's slice and the AMPS-side burn into vault
    ///      inventory. The two halves come back apart from {VaultPlacementLib-splitHarvestFees} and only the
    ///      principal is reported as `amountMoved`.
    /// @param ladder The vault's placement records.
    /// @param cooldown The vault's per-pool placement timestamps.
    /// @param poolManager The Uniswap v4 PoolManager.
    /// @param amps The AMPS token, for the fee split's burn.
    /// @param constituentId The retired constituent.
    /// @return amountMoved The counter-asset principal moved into claims, in raw units.
    function withdrawRetiredBids(
        mapping(PoolId => PlacementRecord[]) storage ladder,
        mapping(PoolId => uint32) storage cooldown,
        address poolManager,
        address amps,
        uint16 constituentId
    ) public returns (uint256 amountMoved) {
        address registry = _addr(SLOT_REGISTRY);
        if (registry == address(0)) return 0;

        PoolId poolId = IPoolRegistry(registry).poolIdOf(constituentId);
        if (!IPoolRegistry(registry).poolConfig(poolId).registered) revert UnknownPool(PoolId.unwrap(poolId));

        PlacementRecord[] storage records = ladder[poolId];
        uint256 n = records.length;
        if (n == 0) return 0;

        uint128[] memory removals = new uint128[](n);
        int24[] memory lowers = new int24[](n);
        uint32 closed;
        for (uint256 i; i < n; ++i) {
            lowers[i] = records[i].lowerTick;
            if (records[i].above || records[i].liquidity == 0) continue;
            removals[i] = records[i].liquidity;
            records[i].liquidity = 0;
            // The gross-placed counter leaves with the liquidity it described, so the record is not write-only.
            records[i].amount = 0;
            ++closed;
        }
        if (closed == 0) return 0;
        VaultRedeemLib.subLiveCells(closed);

        PoolKey memory key = IPoolRegistry(registry).poolKey(poolId);
        uint256 fees0;
        uint256 fees1;
        (, amountMoved, fees0, fees1) = abi.decode(
            _unlock(poolManager, VaultRedeemLib.ACTION_HARVEST, abi.encode(key, lowers, removals)),
            (uint256, uint256, uint256, uint256)
        );
        VaultPlacementLib.splitHarvestFees(poolManager, amps, poolId, key.currency1, fees0, fees1);
        cooldown[poolId] = uint32(block.timestamp);
    }

    // -------------------------------------------------------------------------------------------------------------
    // Internals — the harvest side
    // -------------------------------------------------------------------------------------------------------------

    /// @dev The AMPS held by a pool's *unfilled, movable* ask cells: the only inventory rollout may move, because
    ///      moving a filled cell would take a counter asset out of the market that raised it (I29, I35).
    ///
    /// @dev **The high-water clause is {_harvestAsks}'s, and this must apply it too** (audit fix, 2026-09-09).
    ///      The harvest skips a cell whose upper bound the mark has crossed — AMPS the vault sold on the way up
    ///      and bought back on the way down, which belongs to the burn and not to a spoke's ask ladder — but this
    ///      count included them, so the I32 entry floor and the schedule's inventory input were both inflated by
    ///      the bought-back amount. The two numbers are what `rollout` compares against each other: an inflated
    ///      inventory makes `_floorRoom` grant room that the tradeable depth does not have, so the depth actually
    ///      quotable in the entry pools could sit *below* the governed floor while the check said it did not. One
    ///      selection, used by both, is the only way those two can agree. When the mark cannot be read nothing is
    ///      skipped, which is the same "nothing counts as bought back" default `_burnback` and `_harvestAsks` take.
    function _askInventory(mapping(PoolId => PlacementRecord[]) storage ladder, address poolManager, PoolId poolId)
        private
        view
        returns (uint256 inventory)
    {
        PlacementRecord[] storage records = ladder[poolId];
        uint256 n = records.length;
        if (n == 0) return 0;
        (, int24 tick) = PoolStateLib.sqrtPriceAndTick(IExtsload(poolManager), poolId);
        int24 highWater = _highWater(poolId);

        for (uint256 i; i < n; ++i) {
            PlacementRecord memory record = records[i];
            if (!record.above || record.liquidity == 0 || record.lowerTick <= tick) continue;
            if (highWater != type(int24).min && record.upperTick <= highWater) continue;
            inventory += LadderLib.amount0ForLiquidity(
                TickMath.getSqrtPriceAtTick(record.lowerTick),
                TickMath.getSqrtPriceAtTick(record.upperTick),
                record.liquidity
            );
        }
    }

    /// @dev Withdraws up to `wanted` AMPS from one source pool's unfilled ask cells, highest cell first so the
    ///      depth nearest the price survives longest. The source pays the gate, the cooldown and the divergence
    ///      check in its own right (§3.7: "Both pools pay the full gauntlet").
    ///
    /// @dev **It does not write the cooldown.** {rollout} does, once, after it has had the chance to put the
    ///      unplaced remainder back into these same pools; taking the cooldown here would have made that
    ///      re-placement revert on the very pool the inventory came out of.
    ///
    /// @dev **A cell the buyback owns is not rollout's to move** (audit fix, 2026-09-08). This selection is
    ///      `VaultPlacementLib._burnback`'s geometry minus its high-water clause, and every unfilled ask cell
    ///      satisfies `tick <= lowerTick` by construction — so a cell whose upper bound the mark had crossed, i.e.
    ///      AMPS the vault sold on the way up and bought back on the way down, was eligible here. A `rollout`
    ///      ordered before the next `compound` moved exactly that inventory into a spoke's **ask** ladder to be
    ///      sold a second time instead of burned (I33), and it is permissionless, so the ordering is anybody's to
    ///      choose. Cells under the mark are therefore skipped and left for the burn; when the mark cannot be read
    ///      nothing is skipped, which is the same "nothing counts as bought back" default `_burnback` takes.
    function _harvestAsks(
        mapping(PoolId => PlacementRecord[]) storage ladder,
        mapping(PoolId => uint32) storage cooldown,
        address poolManager,
        address amps,
        PoolId poolId,
        uint256 wanted
    ) private returns (uint256 harvested) {
        PlacementRecord[] storage records = ladder[poolId];
        uint256 n = records.length;
        if (n == 0 || wanted == 0) return 0;

        (PoolKey memory key, int24 tick) = _gauntlet(cooldown, poolManager, poolId);
        int24 highWater = _highWater(poolId);

        uint128[] memory removals = new uint128[](n);
        int24[] memory lowers = new int24[](n);
        uint256 remaining = wanted;
        uint32 closed;
        bool any;

        for (uint256 i; i < n; ++i) {
            lowers[i] = records[i].lowerTick;
        }
        for (uint256 j = n; j != 0 && remaining != 0; --j) {
            PlacementRecord storage record = records[j - 1];
            if (!record.above || record.liquidity == 0 || record.lowerTick <= tick) continue;
            // The buyback's own cells, left for the burn: see the note above.
            if (highWater != type(int24).min && record.upperTick <= highWater) continue;

            uint160 sqrtLower = TickMath.getSqrtPriceAtTick(record.lowerTick);
            uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(record.upperTick);
            uint256 held = LadderLib.amount0ForLiquidity(sqrtLower, sqrtUpper, record.liquidity);
            if (held == 0) continue;

            uint128 removal;
            if (held <= remaining) {
                removal = record.liquidity;
                remaining -= held;
            } else {
                removal = LadderLib.liquidityForAmount0Above(sqrtLower, sqrtUpper, remaining);
                if (removal == 0) continue;
                if (removal > record.liquidity) removal = record.liquidity;
                remaining = 0;
            }
            removals[j - 1] = removal;
            // The gross-placed AMPS follows the liquidity out, pro rata, so `PlacementRecord.amount` describes
            // what the cell still holds rather than everything ever put into it (audit fix, 2026-09-08).
            record.amount -= _shareOf(record.amount, removal, record.liquidity);
            record.liquidity -= removal;
            if (record.liquidity == 0) ++closed;
            any = true;
        }
        if (!any) return 0;
        VaultRedeemLib.subLiveCells(closed);

        uint256 fees0;
        uint256 fees1;
        (harvested,, fees0, fees1) = abi.decode(
            _unlock(poolManager, VaultRedeemLib.ACTION_HARVEST, abi.encode(key, lowers, removals)),
            (uint256, uint256, uint256, uint256)
        );

        // The harvested cells' accrued fees never become rollout inventory: the creator's slice and the burn take
        // them here, exactly as `compound` would (audit fix, 2026-09-08). Only principal is returned, so `moved`
        // is what the entry pools actually gave up and the daily window is charged on that alone.
        VaultPlacementLib.splitHarvestFees(poolManager, amps, poolId, key.currency1, fees0, fees1);
    }

    /// @dev `amount x part / whole`, saturated at `amount`, for pro-rating a record's disclosure field as its
    ///      liquidity leaves. A zero `whole` cannot be reached from the caller (a record with no liquidity is
    ///      skipped) and answers zero rather than dividing.
    function _shareOf(uint128 amount, uint128 part, uint128 whole) private pure returns (uint128 share) {
        if (amount == 0 || whole == 0) return 0;
        if (part >= whole) return amount;
        share = uint128(FullMath.mulDiv(amount, part, whole));
    }

    /// @dev The pool's high-water tick from the market reference, or `type(int24).min` when it cannot answer — in
    ///      which case nothing counts as bought back, which is the safe default and the one `_burnback` takes.
    function _highWater(PoolId poolId) private view returns (int24 tick) {
        address marketRef = _addr(SLOT_MARKET_REFERENCE);
        if (marketRef == address(0)) return type(int24).min;
        try IMarketReference(marketRef).highWaterTick{gas: Constants.STOCK_TOKEN_PROBE_GAS}(poolId) returns (
            int24 highWater
        ) {
            return highWater;
        } catch {
            return type(int24).min;
        }
    }

    /// @dev The source side of §3.8: gate, cooldown and divergence, then the key and the live tick.
    function _gauntlet(mapping(PoolId => uint32) storage cooldown, address poolManager, PoolId poolId)
        private
        view
        returns (PoolKey memory key, int24 tick)
    {
        address gate = _addr(SLOT_ORACLE_GATE);
        if (gate != address(0)) IOracleGate(gate).checkPlacement(poolId);

        uint32 last = cooldown[poolId];
        if (last != 0 && block.timestamp < uint256(last) + Constants.PLACEMENT_COOLDOWN_SECONDS) {
            revert PlacementCooldown(PoolId.unwrap(poolId), last + Constants.PLACEMENT_COOLDOWN_SECONDS);
        }

        address registry = _addr(SLOT_REGISTRY);
        PoolConfig memory config = IPoolRegistry(registry).poolConfig(poolId);
        if (!config.registered) revert UnknownPool(PoolId.unwrap(poolId));
        key = IPoolRegistry(registry).poolKey(poolId);
        (, tick) = PoolStateLib.sqrtPriceAndTick(IExtsload(poolManager), poolId);

        uint256 priceUsd18 = uint128(_word(SLOT_CHECKPOINT1));
        if (priceUsd18 == 0) priceUsd18 = _word(SLOT_CHECKPOINT0) >> 128;
        uint256 answerUsd8 = _answer(config.counter);
        if (priceUsd18 == 0 || answerUsd8 == 0 || config.counterDecimals > PriceLib.MAX_COUNTER_DECIMALS) {
            return (key, tick);
        }

        int24 fair = PriceLib.fairTick(priceUsd18, answerUsd8, config.counterDecimals, config.tickSpacing);
        int24 deviation = tick > fair ? tick - fair : fair - tick;
        if (deviation > Constants.PLACEMENT_DIVERGENCE_TICKS) {
            revert PlacementDiverged(PoolId.unwrap(poolId), tick, fair, Constants.PLACEMENT_DIVERGENCE_TICKS);
        }
    }

    // -------------------------------------------------------------------------------------------------------------
    // Internals — the schedule and its window
    // -------------------------------------------------------------------------------------------------------------

    /// @dev Asks the schedule how much is due. A policy that reverts proposes nothing, which is a no-op rather
    ///      than a revert: an unpaid keeper call then costs the caller gas and nothing else.
    /// @param spokeHasDepth Whether the destination already has stock-side depth, from {_hasBidDepth}.
    function _propose(
        address policy,
        address registry,
        ConstituentConfig memory constituent,
        uint16 constituentId,
        uint256 entryInventory,
        uint256 budget,
        uint16 rolloutBpsPerDay,
        uint16 entryFloorBps,
        bool spokeHasDepth
    ) private view returns (uint256 amount) {
        uint16 currentWeightBps;
        try IPoolRegistry(registry).currentWeightBps{gas: Constants.COMPOSITE_READ_GAS}(constituentId) returns (
            uint16 weight
        ) {
            currentWeightBps = weight;
        } catch {}

        uint256 allowance = FullMath.mulDiv(Constants.POL_SHARES, rolloutBpsPerDay, Constants.BPS);
        IRolloutPolicy.RolloutRequest memory request = IRolloutPolicy.RolloutRequest({
            polTrancheAmps: Constants.POL_SHARES,
            entryInventoryAmps: entryInventory,
            movedLast24hAmps: allowance - budget,
            rolloutBpsPerDay: rolloutBpsPerDay,
            entryFloorBps: entryFloorBps,
            targetWeightBps: constituent.targetWeightBps,
            currentWeightBps: currentWeightBps,
            rolloutWeightBps: constituent.rolloutWeightBps,
            spokeHasDepth: spokeHasDepth
        });

        try IRolloutPolicy(policy).propose{gas: Constants.MARKET_REFERENCE_WRITE_GAS}(request) returns (
            IRolloutPolicy.RolloutDecision memory decision
        ) {
            amount = decision.amountAmps;
        } catch {}
        if (amount > entryInventory) amount = entryInventory;
    }

    /// @dev Whether the destination spoke already has counter-asset depth, which is the last field of
    ///      `IRolloutPolicy.RolloutRequest` and the one the schedule halves a spoke's share for when it is false.
    ///      It was hard-coded `false`, so **every** spoke was permanently treated as depthless and the whole
    ///      `DEPTHLESS_DISCOUNT_X18` branch of the launch schedule was unreachable: rollout ran at half rate into
    ///      spokes that bonds and buys had already given a bid side, which is exactly the case §5 prefers.
    ///
    ///      Depth is read from the vault's own records rather than from a balance, because a bid *record* with
    ///      liquidity is what a rolled-out ask will actually trade against: a live cell (`liquidity != 0`) placed
    ///      on the counter side (`!above`). Bonded stock still sitting as an ERC-6909 claim is not depth until
    ///      `deployBonded` has laddered it, and a bid the burnback has emptied stops counting the moment it does,
    ///      because that path zeroes the liquidity.
    function _hasBidDepth(PlacementRecord[] storage records) private view returns (bool hasDepth) {
        uint256 n = records.length;
        for (uint256 i; i < n; ++i) {
            if (records[i].liquidity != 0 && !records[i].above) return true;
        }
        return false;
    }

    /// @dev What is left of the rolling 24-hour rollout allowance (slot 15).
    ///
    /// @dev **Rolling, not tumbling** (audit fix, 2026-09-09). The window used to zero `moved` outright the first
    ///      time a rollout arrived after `windowStart + ONE_DAY` and re-stamp the start at that instant, so a
    ///      keeper who moved the whole allowance a second before the edge and the whole allowance again a second
    ///      after it moved `2 x rolloutBpsPerDay` — 360 AMPS at the launch parameters — inside a rolling interval
    ///      of about zero length. Nothing left the vault that I32 forbids in the *tumbling* accounting, which is
    ///      the point: the limit did not limit what it says it limits, and halving the time to drain the entry
    ///      pools to `entryFloorBps` is the thing it exists to prevent. `moved` now decays linearly toward zero
    ///      over `ONE_DAY` from the last charge and the start advances on every charge, so there is no edge left
    ///      to straddle: the budget released between two rollouts is exactly the elapsed fraction of one day's
    ///      allowance, whenever they happen.
    function _rollWindow(uint16 rolloutBpsPerDay) private view returns (uint256 budget) {
        uint256 allowance = FullMath.mulDiv(Constants.POL_SHARES, rolloutBpsPerDay, Constants.BPS);
        uint256 moved = _decayedMoved();
        budget = allowance > moved ? allowance - moved : 0;
    }

    /// @dev The window's charge, decayed to now: `moved x (ONE_DAY - min(elapsed, ONE_DAY)) / ONE_DAY`.
    function _decayedMoved() private view returns (uint256 moved) {
        uint256 word = _word(SLOT_ROLLOUT_WINDOW);
        moved = uint128(word);
        if (moved == 0) return 0;
        uint32 windowStart = uint32(word >> 128);
        if (windowStart == 0 || block.timestamp <= windowStart) return moved;
        uint256 elapsed = block.timestamp - windowStart;
        if (elapsed >= Constants.ONE_DAY) return 0;
        return FullMath.mulDiv(moved, Constants.ONE_DAY - elapsed, Constants.ONE_DAY);
    }

    /// @dev Charges `amount` against the rolling window and re-stamps it, so the decay above runs from this charge.
    function _addRolloutMoved(uint256 amount) private {
        uint256 moved = _decayedMoved() + amount;
        if (moved > type(uint128).max) moved = type(uint128).max;
        uint256 word = _word(SLOT_ROLLOUT_WINDOW);
        // Everything above bit 159 is left exactly as it was: this slot is the window's and nothing else's, but
        // the mask is what makes that true rather than assumed.
        word &= ~uint256(type(uint128).max);
        word &= ~(uint256(type(uint32).max) << 128);
        _setWord(SLOT_ROLLOUT_WINDOW, word | (uint256(uint32(block.timestamp)) << 128) | moved);
    }

    /// @dev How much of the entry pools' inventory may move without taking them below `entryFloorBps`.
    function _floorRoom(uint16 entryFloorBps, uint256 entryInventory) private pure returns (uint256 room) {
        uint256 floor = FullMath.mulDiv(Constants.POL_SHARES, entryFloorBps, Constants.BPS);
        room = entryInventory > floor ? entryInventory - floor : 0;
    }

    // -------------------------------------------------------------------------------------------------------------
    // Internals — plumbing
    // -------------------------------------------------------------------------------------------------------------

    /// @dev Sets the transient discriminator, unlocks, clears it.
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

    /// @dev The last accepted answer for `token`, 8 decimals, or zero. Never reverts, **and never panics either**
    ///      (audit lead, 2026-09-09): a bounded `staticcall` whose first word is read by hand, which is the shape
    ///      every other pointer read in the vault already uses. A typed `try` decodes a *successful* call's
    ///      returndata in this frame, so a feed registry replaced with one that answers fewer than three words —
    ///      or with a non-canonical `bool` in the third — `Panic`ked past the `catch` and bricked `deployBonded`
    ///      and every bounty valuation instead of degrading them to "no answer". `latestAnswer` is a composite
    ///      read (an aggregator probe plus up to two historical rounds), so the budget is the generous
    ///      {COMPOSITE_READ_GAS} the rest of the placement path gives it.
    function _answer(address token) private view returns (uint256 answerUsd8) {
        address feeds = _addr(SLOT_FEED_REGISTRY);
        if (feeds == address(0) || token == address(0)) return 0;
        (bool ok, bytes memory returndata) =
            feeds.staticcall{gas: Constants.COMPOSITE_READ_GAS}(abi.encodeCall(IFeedRegistry.latestAnswer, (token)));
        if (!ok || returndata.length < 96) return 0;
        assembly ("memory-safe") {
            answerUsd8 := mload(add(returndata, 0x20))
        }
    }

    /// @dev The vault's own ERC-20 balance of `token`, or zero when the token cannot be asked: a bounded,
    ///      hand-decoded `staticcall`, exactly as `VaultPlacementLib._probeBalance` and `VaultRedeemLib` use.
    ///
    /// @dev **The finding this closes** (audit fix, 2026-09-07). `deployBonded` read the constituent's balance
    ///      with a typed `IERC20.balanceOf`, so a Stock Token whose `balanceOf` reverts — the same third-party
    ///      failure mode `sweepClean`, `evacuate` and `_payOut` are already hardened against — bricked the whole
    ///      bonded-collateral deployment for that name for as long as the issuer chose. Unreadable reads as zero,
    ///      which leaves `idle` at whatever the vault holds as an ERC-6909 claim and, below the deploy threshold,
    ///      makes the call the same silent no-op every other "nothing is due" branch here is.
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

    /// @dev One address-holding slot of the vault's storage.
    function _addr(uint256 slot) private view returns (address value) {
        return address(uint160(_word(slot)));
    }
}
