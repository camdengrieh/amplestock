// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IBountyPot} from "../interfaces/IBountyPot.sol";
import {IFeedRegistry} from "../interfaces/IFeedRegistry.sol";
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
import {ConstituentConfig, PlacementRecord, PoolConfig} from "../types/Types.sol";
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
    /// @dev slot 7, the keeper bounty pot.
    uint256 private constant SLOT_BOUNTY_POT = 7;
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

    /// @dev The flat keeper work value and gas allowance, matching {VaultPlacementLib}'s. See that file for why
    ///      both are flat in v1 and what makes the pot's 3x gas cap live again in Phase 4.
    uint256 private constant WORK_VALUE_USD18 = 1e18;

    /// @dev The flat gas allowance reported with it.
    uint256 private constant GAS_ALLOWANCE_USD18 = 1e18;

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
    /// @return moved AMPS wei actually moved.
    function rollout(
        mapping(PoolId => PlacementRecord[]) storage ladder,
        mapping(PoolId => uint32) storage cooldown,
        address poolManager,
        address amps,
        uint16 constituentId
    ) public returns (uint256 moved) {
        address registry = _addr(SLOT_REGISTRY);
        address policy = _addr(SLOT_ROLLOUT_POLICY);
        if (policy == address(0) || registry == address(0)) return 0;

        ConstituentConfig memory constituent = IPoolRegistry(registry).constituent(constituentId);
        if (constituent.token == address(0)) revert UnknownConstituent(constituentId);

        PoolId[2] memory entries = [IPoolRegistry(registry).hubPoolId(), IPoolRegistry(registry).wethPoolId()];
        uint256 entryInventory =
            _askInventory(ladder, poolManager, entries[0]) + _askInventory(ladder, poolManager, entries[1]);

        uint16 rolloutBpsPerDay = uint16(_word(SLOT_PARAMS) >> 216);
        uint16 entryFloorBps = uint16(_word(SLOT_PARAMS) >> 232);
        uint256 budget = _rollWindow(rolloutBpsPerDay);
        uint256 amount = _propose(
            policy, registry, constituent, constituentId, entryInventory, budget, rolloutBpsPerDay, entryFloorBps
        );
        if (amount == 0) return 0;

        // I32, re-checked rather than taken on trust: the daily budget and the entry-pool floor. The third limit —
        // no rolled-out ask below `P_ref` — is `place`'s own ask anchor and needs no check here.
        if (amount > budget) revert RolloutLimitExceeded(bytes32("dailyBudget"), amount, budget);
        uint256 floorRoom = _floorRoom(entryFloorBps, entryInventory);
        if (amount > floorRoom) revert RolloutLimitExceeded(bytes32("entryFloor"), amount, floorRoom);

        // Only *unfilled* ask cells move, so no counter asset is touched (I29, I35). Each source pool pays the
        // full gauntlet in its own right.
        for (uint256 i; i < 2 && moved < amount; ++i) {
            moved += _harvestAsks(ladder, cooldown, poolManager, entries[i], amount - moved);
        }
        if (moved == 0) return 0;

        // The bountied paths merge into cells that already exist and leave the remainder idle rather than
        // revert when the live-cell budget is full (§12 ruling E), which is what `strictBudget == false` says.
        VaultPlacementLib.place(
            ladder,
            cooldown,
            poolManager,
            amps,
            IPoolRegistry(registry).poolIdOf(constituentId),
            true,
            moved,
            bytes32("rollout"),
            false
        );

        _addRolloutMoved(moved);
        _payBounty();
    }

    /// @notice `deployBonded(constituentId)`: places idle bonded collateral as the spoke's bid ladder, four
    ///         halvings below the current price and weighted toward the tick. A no-op below the deploy threshold,
    ///         so it cannot be used to drain the bounty pot a wei at a time (§10 ruling 15).
    /// @param ladder The vault's placement records.
    /// @param cooldown The vault's per-pool placement timestamps.
    /// @param poolManager The Uniswap v4 PoolManager.
    /// @param amps The AMPS token.
    /// @param constituentId The constituent.
    /// @return placed The raw collateral amount committed.
    function deployBonded(
        mapping(PoolId => PlacementRecord[]) storage ladder,
        mapping(PoolId => uint32) storage cooldown,
        address poolManager,
        address amps,
        uint16 constituentId
    ) public returns (uint256 placed) {
        address registry = _addr(SLOT_REGISTRY);
        if (registry == address(0)) return 0;

        ConstituentConfig memory constituent = IPoolRegistry(registry).constituent(constituentId);
        if (constituent.token == address(0)) revert UnknownConstituent(constituentId);

        uint256 idle = IPoolManager(poolManager).balanceOf(address(this), Currency.wrap(constituent.token).toId())
            + IERC20(constituent.token).balanceOf(address(this));
        if (idle == 0) return 0;

        uint256 answerUsd8 = _answer(constituent.token);
        if (answerUsd8 == 0 || constituent.decimals > PriceLib.MAX_COUNTER_DECIMALS) return 0;
        if (PriceLib.counterValueUsd18(idle, constituent.decimals, answerUsd8) < _word(SLOT_DEPLOY_THRESHOLD)) {
            return 0;
        }

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
        _payBounty();
    }

    /// @notice `withdrawRetiredBids(constituentId)`: moves a retired spoke's remaining bid inventory out of its
    ///         positions and into ERC-6909 claims, where `A` still values it and `redeemProRata` still pays it.
    /// @dev Nothing is placed, so the divergence half of the gauntlet does not apply; the gate, the transient lock
    ///      and R1 do, and all three are the vault forwarder's.
    /// @param ladder The vault's placement records.
    /// @param cooldown The vault's per-pool placement timestamps.
    /// @param poolManager The Uniswap v4 PoolManager.
    /// @param constituentId The retired constituent.
    /// @return amountMoved The counter-asset amount moved into claims, in raw units.
    function withdrawRetiredBids(
        mapping(PoolId => PlacementRecord[]) storage ladder,
        mapping(PoolId => uint32) storage cooldown,
        address poolManager,
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
            ++closed;
        }
        if (closed == 0) return 0;
        VaultRedeemLib.subLiveCells(closed);

        (, amountMoved) = abi.decode(
            _unlock(
                poolManager,
                VaultRedeemLib.ACTION_HARVEST,
                abi.encode(IPoolRegistry(registry).poolKey(poolId), lowers, removals)
            ),
            (uint256, uint256)
        );
        cooldown[poolId] = uint32(block.timestamp);
    }

    // -------------------------------------------------------------------------------------------------------------
    // Internals — the harvest side
    // -------------------------------------------------------------------------------------------------------------

    /// @dev The AMPS held by a pool's *unfilled* ask cells: the only inventory rollout may move, because moving a
    ///      filled cell would take a counter asset out of the market that raised it (I29, I35).
    function _askInventory(mapping(PoolId => PlacementRecord[]) storage ladder, address poolManager, PoolId poolId)
        private
        view
        returns (uint256 inventory)
    {
        PlacementRecord[] storage records = ladder[poolId];
        uint256 n = records.length;
        if (n == 0) return 0;
        (, int24 tick) = PoolStateLib.sqrtPriceAndTick(IExtsload(poolManager), poolId);

        for (uint256 i; i < n; ++i) {
            PlacementRecord memory record = records[i];
            if (!record.above || record.liquidity == 0 || record.lowerTick <= tick) continue;
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
    function _harvestAsks(
        mapping(PoolId => PlacementRecord[]) storage ladder,
        mapping(PoolId => uint32) storage cooldown,
        address poolManager,
        PoolId poolId,
        uint256 wanted
    ) private returns (uint256 harvested) {
        PlacementRecord[] storage records = ladder[poolId];
        uint256 n = records.length;
        if (n == 0 || wanted == 0) return 0;

        (PoolKey memory key, int24 tick) = _gauntlet(cooldown, poolManager, poolId);

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
            record.liquidity -= removal;
            if (record.liquidity == 0) ++closed;
            any = true;
        }
        if (!any) return 0;
        VaultRedeemLib.subLiveCells(closed);

        (harvested,) = abi.decode(
            _unlock(poolManager, VaultRedeemLib.ACTION_HARVEST, abi.encode(key, lowers, removals)), (uint256, uint256)
        );
        cooldown[poolId] = uint32(block.timestamp);
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
    function _propose(
        address policy,
        address registry,
        ConstituentConfig memory constituent,
        uint16 constituentId,
        uint256 entryInventory,
        uint256 budget,
        uint16 rolloutBpsPerDay,
        uint16 entryFloorBps
    ) private view returns (uint256 amount) {
        uint16 currentWeightBps;
        try IPoolRegistry(registry).currentWeightBps(constituentId) returns (uint16 weight) {
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
            spokeHasDepth: false
        });

        try IRolloutPolicy(policy).propose(request) returns (IRolloutPolicy.RolloutDecision memory decision) {
            amount = decision.amountAmps;
        } catch {}
        if (amount > entryInventory) amount = entryInventory;
    }

    /// @dev The rolling 24-hour rollout window (slot 15), rolled forward here and charged in {_addRolloutMoved}.
    function _rollWindow(uint16 rolloutBpsPerDay) private returns (uint256 budget) {
        uint256 word = _word(SLOT_ROLLOUT_WINDOW);
        uint256 moved = uint128(word);
        uint32 windowStart = uint32(word >> 128);

        if (windowStart == 0 || block.timestamp >= uint256(windowStart) + Constants.ONE_DAY) {
            moved = 0;
            _setWord(SLOT_ROLLOUT_WINDOW, uint256(block.timestamp) << 128);
        }

        uint256 allowance = FullMath.mulDiv(Constants.POL_SHARES, rolloutBpsPerDay, Constants.BPS);
        budget = allowance > moved ? allowance - moved : 0;
    }

    /// @dev Charges `amount` against the current rollout window.
    function _addRolloutMoved(uint256 amount) private {
        uint256 word = _word(SLOT_ROLLOUT_WINDOW);
        uint256 moved = uint256(uint128(word)) + amount;
        if (moved > type(uint128).max) moved = type(uint128).max;
        _setWord(SLOT_ROLLOUT_WINDOW, (word & ~uint256(type(uint128).max)) | moved);
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

    /// @dev The last accepted answer for `token`, 8 decimals, or zero. Never reverts.
    function _answer(address token) private view returns (uint256 answerUsd8) {
        address feeds = _addr(SLOT_FEED_REGISTRY);
        if (feeds == address(0) || token == address(0)) return 0;
        try IFeedRegistry(feeds).latestAnswer(token) returns (uint256 value, uint32, bool) {
            return value;
        } catch {
            return 0;
        }
    }

    /// @dev The flat keeper bounty. A pot that is empty, capped out or broken pays nothing and does not revert.
    function _payBounty() private {
        address pot = _addr(SLOT_BOUNTY_POT);
        if (pot == address(0)) return;
        try IBountyPot(pot).pay(msg.sender, WORK_VALUE_USD18, GAS_ALLOWANCE_USD18) returns (uint256) {} catch {}
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
