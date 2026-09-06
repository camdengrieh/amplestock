// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IAmps} from "../interfaces/IAmps.sol";
import {IAmpsHook} from "../interfaces/IAmpsHook.sol";
import {IAmpsStaking} from "../interfaces/IAmpsStaking.sol";
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
    /// @dev slot 6, the xAMPS staking vault.
    uint256 private constant SLOT_STAKING = 6;
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

    /// @dev The keeper work value every bountied job reports, in 18-decimal USD, and the gas allowance it reports
    ///      alongside it. Both are flat in v1, which is what the plan's keeper row asks for: `tip` $0.05 plus a
    ///      2% chip on the work value is $0.07 a job, and `BountyPot` applies the `chost` dust guard (which is a
    ///      floor on the *work value*, so $1 is the smallest value that can be paid for at all), the daily ceiling
    ///      and the pot's own balance on top. The 3x gas cap is inert while both numbers are flat — 3 x $1 is far
    ///      above $0.07 — and becomes live in Phase 4, when `apps/keeper` reports its measured gas instead.
    uint256 private constant WORK_VALUE_USD18 = 1e18;

    /// @dev The flat gas allowance reported with it. See {WORK_VALUE_USD18}.
    uint256 private constant GAS_ALLOWANCE_USD18 = 1e18;

    /// @dev `keccak256("amplestocks.vault.PLACEMENT_STAGE")`, the base of the transient staging buffer. Four
    ///      words per placed cell, `Constants.GRID_CELLS` cells. See {_stage}.
    uint256 private constant STAGE_SLOT = 0x1f0c2fd9a7dcb43f4a1ee6b30a17c0ba2d3c0e8f6b5a49382716c5d4e3f2a190;

    // -------------------------------------------------------------------------------------------------------------
    // Types
    // -------------------------------------------------------------------------------------------------------------

    /// @notice The vault's parameters and pointers, gathered from storage once per entry point.
    /// @param registry The pool registry.
    /// @param staking The xAMPS staking vault.
    /// @param bountyPot The keeper bounty pot.
    /// @param marketReference The truncated-observation source and high-water mark: `AmpsHook` in production.
    /// @param oracleGate The oracle gate.
    /// @param feedRegistry The feed registry.
    /// @param ladderPolicy The ladder shape policy; zero means `LadderLib`'s own weights.
    /// @param rolloutPolicy The rollout schedule; zero makes `rollout` a no-op.
    /// @param creator The creator-fee recipient.
    /// @param genesisTimestamp When `genesis()` ran, for the creator schedule.
    /// @param burnBps Share of the AMPS-side fees burned.
    /// @param stakerBps Share of the AMPS-side fees streamed to xAMPS.
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
        address staking;
        address bountyPot;
        address marketReference;
        address oracleGate;
        address feedRegistry;
        address ladderPolicy;
        address rolloutPolicy;
        address creator;
        uint32 genesisTimestamp;
        uint16 burnBps;
        uint16 stakerBps;
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

    /// @notice The AMPS-side split of one `compound`, §3.6 step 5.
    /// @param creatorPaid AMPS transferred to the creator.
    /// @param stakerPaid AMPS streamed to xAMPS.
    /// @param burnCut AMPS burned out of the fee split.
    /// @param relaid AMPS re-placed as asks above the market.
    struct Split {
        uint256 creatorPaid;
        uint256 stakerPaid;
        uint256 burnCut;
        uint256 relaid;
    }

    // -------------------------------------------------------------------------------------------------------------
    // Events — mirrors of {IAmpsVault}'s, emitted from the vault's own address by the `DELEGATECALL`
    // -------------------------------------------------------------------------------------------------------------

    /// @dev Mirrors `IAmpsVault.Placement`.
    event Placement(PoolId indexed poolId, bool above, uint8 buckets, uint256 amount, int24 anchorTick);

    /// @dev Mirrors `IAmpsVault.Compound`.
    event Compound(
        PoolId indexed poolId, uint256 ampsFees, uint256 creatorPaid, uint256 stakerPaid, uint256 burned, uint256 relaid
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
        cooldown[poolId] = uint32(block.timestamp);
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
    /// @param ladder The vault's placement records.
    /// @param cooldown The vault's per-pool placement timestamps.
    /// @param poolManager The Uniswap v4 PoolManager.
    /// @param amps The AMPS token.
    /// @param poolId The pool.
    /// @return ampsFees AMPS-side fees collected.
    /// @return burned AMPS burned: the `burnBps` slice plus the whole high-water buyback.
    function compound(
        mapping(PoolId => PlacementRecord[]) storage ladder,
        mapping(PoolId => uint32) storage cooldown,
        address poolManager,
        address amps,
        PoolId poolId
    ) public returns (uint256 ampsFees, uint256 burned) {
        Ctx memory ctx = _ctx();
        Pool memory pool = _gauntletEntry(ctx, cooldown, poolManager, poolId);

        // 3. Collect. AMPS-side fees come out as ERC-20 so the splits below are plain transfers; counter-side fees
        //    become ERC-6909 claims, which `A` already values.
        uint256 counter;
        (ampsFees, counter) =
            abi.decode(_unlock(poolManager, VaultRedeemLib.ACTION_COMPOUND, abi.encode(pool.key)), (uint256, uint256));

        // 4. The buyback burn, *before* any new ask is placed, so freshly re-laddered AMPS can never be mistaken
        //    for bought-back inventory (§3.5's ordering rule).
        (uint256 boughtBack, uint256 freedCounter) = _burnback(ladder, pool, poolManager);
        if (boughtBack != 0) {
            IAmps(amps).burn(address(this), boughtBack);
            emit Burn(boughtBack, bytes32("buyback"));
            burned = boughtBack;
        }
        counter += freedCounter;

        // 5. The AMPS-side split, in order: creator, stakers, burn, and what is left is re-laddered.
        Split memory split;
        if (ampsFees != 0) {
            split = _split(ctx, amps, ampsFees);
            burned += split.burnCut;
        }

        // 6. Re-ladder as asks strictly above the current tick, and 7. re-add the counter side as bids strictly
        //    below it. Both merge into the grid by cell.
        if (split.relaid != 0) {
            _placeLadder(
                ladder,
                ctx,
                pool,
                poolManager,
                amps,
                true,
                split.relaid,
                pool.tick,
                ctx.ladderDoublings,
                "compound",
                false
            );
        }
        if (counter != 0) {
            _placeLadder(
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
        _resetHighWater(ctx, poolId);
        _armSurge(ctx, poolId, "compound");
        _requireConverged(ctx, poolManager, poolId, pool.config);
        cooldown[poolId] = uint32(block.timestamp);

        emit Compound(poolId, ampsFees, split.creatorPaid, split.stakerPaid, burned, split.relaid);
        _payBounty(ctx);
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
            (uint256 ampsFees, uint256 counterFees) = _executeCollect(ladder, poolManager, abi.decode(data, (PoolKey)));
            return abi.encode(ampsFees, counterFees);
        }
        // ACTION_BURNBACK and ACTION_HARVEST are the same mechanics — remove named cells whole, keep the AMPS as
        // an idle ERC-20 balance and the counter as claims — and differ only in why the caller asked. They keep
        // separate discriminators because §3.9 gives them separate names and the indexer decodes on them.
        (PoolKey memory key, int24[] memory lowers, uint128[] memory removals) =
            abi.decode(data, (PoolKey, int24[], uint128[]));
        (uint256 out0, uint256 out1) = _executeHarvest(poolManager, key, lowers, removals);
        return abi.encode(out0, out1);
    }

    // -------------------------------------------------------------------------------------------------------------
    // Internals — the gauntlet (§3.8)
    // -------------------------------------------------------------------------------------------------------------

    /// @dev Steps 2, 3 and 6 of the gauntlet, plus the pool resolution every caller needs. Step 1 (the transient
    ///      lock and `_requireHealthy`), step 7 (R1) and step 9 (`_sweepClean`) belong to the vault's forwarder;
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
        uint256 answerUsd8 = _answer(ctx, config.counter);
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
        uint256 available = IPoolManager(poolManager).balanceOf(address(this), currency.toId())
            + IERC20(token).balanceOf(address(this));
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
        emit Placement(pool.key.toId(), above, result.cells, placed, anchorTick);
        _armSurge(ctx, pool.key.toId(), reason);
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
            if (_cellIsEmpty(records, lower)) {
                if (live >= Constants.MAX_LIVE_CELLS) {
                    if (strictBudget) {
                        revert CellBudgetExceeded(PoolId.unwrap(p.key.toId()), live, Constants.MAX_LIVE_CELLS);
                    }
                    continue;
                }
                ++live;
            }

            (uint128 liquidity, int256 delta0, int256 delta1) =
                _placeCell(poolManager, p, lower, width, amount, sqrtPriceX96);
            if (liquidity == 0) continue;

            owed0 += delta0;
            owed1 += delta1;
            if (result.cells == 0 || lower < result.lowestTick) result.lowestTick = lower;
            if (lower + width > result.highestTick) result.highestTick = lower + width;
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
    function _executeCollect(
        mapping(PoolId => PlacementRecord[]) storage ladder,
        address poolManager,
        PoolKey memory key
    ) private returns (uint256 ampsFees, uint256 counterFees) {
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
        if (fees1 > 0) {
            counterFees = uint256(fees1);
            IPoolManager(poolManager).mint(address(this), key.currency1.toId(), counterFees);
        }
    }

    /// @dev §3.5, the buyback burn. A cell whose upper bound the hook's high-water mark has crossed since the last
    ///      reset was fully sold as an ask, so AMPS sitting in it now is inventory the vault bought back on the way
    ///      down and must burn (I33). The current tick decides how much:
    ///
    ///      * `tick >= upper` — pure counter, nothing was bought back, nothing to do;
    ///      * `tick <  upper` — the cell holds AMPS. It is withdrawn whole: the AMPS is burned and never
    ///        re-placed, and the counter side (if the cell is straddled) comes back as an ERC-6909 claim.
    ///
    ///      **Deviation from ruling 8, deliberate.** The ruling re-places the counter side over
    ///      `[lower, alignDown(tick)]`, which is *not* a cell of the canonical grid — it is a fraction of one. That
    ///      range would be invisible to `LadderPositionValuer`, which enumerates whole cells (§4), so `A` would
    ///      drop by its whole value and the R1 post-condition would revert the very `compound` that created it, and
    ///      it would break I39. The counter is therefore held as a claim — §3.5's own fallback for a degenerate
    ///      range — and re-enters the ladder in step 7 of the same `compound`, as a proper grid bid ladder below
    ///      the tick. Nothing leaves the pool's economy; only the prices it bids at are re-derived.
    function _burnback(mapping(PoolId => PlacementRecord[]) storage ladder, Pool memory pool, address poolManager)
        private
        returns (uint256 burnedAmps, uint256 freedCounter)
    {
        PoolId poolId = pool.key.toId();
        int24 highWater = _highWater(poolId);
        if (highWater == type(int24).min) return (0, 0);

        PlacementRecord[] storage records = ladder[poolId];
        uint256 n = records.length;
        if (n == 0) return (0, 0);

        uint128[] memory removals = new uint128[](n);
        uint32 closed;
        for (uint256 i; i < n; ++i) {
            PlacementRecord storage record = records[i];
            if (record.liquidity == 0 || record.upperTick > highWater || pool.tick >= record.upperTick) continue;
            removals[i] = record.liquidity;
            record.liquidity = 0;
            record.above = false;
            ++closed;
        }
        if (closed == 0) return (0, 0);
        VaultRedeemLib.subLiveCells(closed);

        (burnedAmps, freedCounter) = abi.decode(
            _unlock(poolManager, VaultRedeemLib.ACTION_BURNBACK, abi.encode(pool.key, _lowers(records), removals)),
            (uint256, uint256)
        );
    }

    /// @dev ACTION_BURNBACK and ACTION_HARVEST: remove named cells whole, keep the AMPS as an idle ERC-20 balance
    ///      (to burn, or to re-place elsewhere) and the counter as ERC-6909 claims.
    function _executeHarvest(address poolManager, PoolKey memory key, int24[] memory lowers, uint128[] memory removals)
        private
        returns (uint256 out0, uint256 out1)
    {
        int24 width = LadderLib.doublingTicks(key.tickSpacing);
        int256 delta0;
        int256 delta1;

        for (uint256 i; i < removals.length; ++i) {
            if (removals[i] == 0) continue;
            (BalanceDelta callerDelta,) = IPoolManager(poolManager)
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
        }

        if (delta0 > 0) {
            out0 = uint256(delta0);
            IPoolManager(poolManager).take(key.currency0, address(this), out0);
        }
        if (delta1 > 0) {
            out1 = uint256(delta1);
            IPoolManager(poolManager).mint(address(this), key.currency1.toId(), out1);
        }
    }

    /// @dev §3.6 step 5, in order and to the wei: creator, then stakers, then the burn, and what is left is
    ///      re-laddered. The creator slice is the only transfer of protocol-held AMPS to a non-pool address (I31)
    ///      and is zero for good from `genesis + CREATOR_DECAY_SECONDS`.
    function _split(Ctx memory ctx, address amps, uint256 ampsFees) private returns (Split memory split) {
        uint256 sellFeeBps = _sellFeeBps(ctx);
        uint256 creatorBps = _creatorBps(ctx);
        if (creatorBps > sellFeeBps) creatorBps = sellFeeBps;

        if (creatorBps != 0 && ctx.creator != address(0)) {
            split.creatorPaid = FullMath.mulDiv(ampsFees, creatorBps, sellFeeBps);
            if (split.creatorPaid != 0) IERC20(amps).safeTransfer(ctx.creator, split.creatorPaid);
        }

        uint256 afterCreator = ampsFees - split.creatorPaid;
        if (ctx.staking != address(0)) {
            split.stakerPaid = FullMath.mulDiv(afterCreator, ctx.stakerBps, Constants.BPS);
            if (split.stakerPaid != 0) {
                IERC20(amps).safeTransfer(ctx.staking, split.stakerPaid);
                IAmpsStaking(ctx.staking).notifyReward(split.stakerPaid);
            }
        }

        split.burnCut = FullMath.mulDiv(afterCreator - split.stakerPaid, ctx.burnBps, Constants.BPS);
        if (split.burnCut != 0) {
            IAmps(amps).burn(address(this), split.burnCut);
            emit Burn(split.burnCut, bytes32("compound"));
        }

        split.relaid = afterCreator - split.stakerPaid - split.burnCut;
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
        try IMarketReference(marketRef).highWaterTick(poolId) returns (int24 highWater) {
            return highWater;
        } catch {
            return type(int24).min;
        }
    }

    /// @dev Resets the high-water mark after a compound, so the next window starts clean (§3.5).
    function _resetHighWater(Ctx memory ctx, PoolId poolId) private {
        if (ctx.marketReference == address(0)) return;
        try IAmpsHook(ctx.marketReference).resetHighWater(poolId) returns (int24) {} catch {}
    }

    /// @dev Arms the surge fee after a placement, so it cannot be sandwiched at the pre-placement fee. A hook that
    ///      refuses is treated as absent rather than as a reason to abandon the placement, exactly as a gate that
    ///      reverts is: the vault is immutable and the market reference is a pointer.
    function _armSurge(Ctx memory ctx, PoolId poolId, bytes32 reason) private {
        if (ctx.marketReference == address(0)) return;
        try IAmpsHook(ctx.marketReference).armSurge(poolId, Constants.SURGE_MAX_BPS, reason) {} catch {}
    }

    /// @dev The live sell fee, from the hook. The launch value stands in when the hook cannot answer, so the
    ///      creator's share of the fees is never divided by zero.
    function _sellFeeBps(Ctx memory ctx) private view returns (uint256 bps) {
        if (ctx.marketReference != address(0)) {
            try IAmpsHook(ctx.marketReference).sellFeeBps() returns (uint16 value) {
                if (value != 0) return value;
            } catch {}
        }
        return Constants.SELL_FEE_BPS_DEFAULT;
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

    /// @dev The last accepted answer for `token`, 8 decimals, or zero. Never reverts.
    function _answer(Ctx memory ctx, address token) private view returns (uint256 answerUsd8) {
        if (ctx.feedRegistry == address(0) || token == address(0)) return 0;
        try IFeedRegistry(ctx.feedRegistry).latestAnswer(token) returns (uint256 value, uint32, bool) {
            return value;
        } catch {
            return 0;
        }
    }

    /// @dev `tickOf(P_ref / P_counter)`: the anchor no ask may be placed below (I32).
    function _referenceTick(Ctx memory ctx, Pool memory pool) private view returns (int24 tick) {
        uint256 answerUsd8 = _answer(ctx, pool.config.counter);
        if (ctx.pRefX18 == 0 || answerUsd8 == 0 || pool.config.counterDecimals > PriceLib.MAX_COUNTER_DECIMALS) {
            return pool.tick;
        }
        return PriceLib.fairTick(ctx.pRefX18, answerUsd8, pool.config.counterDecimals, pool.config.tickSpacing);
    }

    /// @dev The flat keeper bounty. A pot that is empty, capped out or broken pays nothing and does not revert.
    function _payBounty(Ctx memory ctx) private {
        if (ctx.bountyPot == address(0)) return;
        try IBountyPot(ctx.bountyPot).pay(msg.sender, WORK_VALUE_USD18, GAS_ALLOWANCE_USD18) returns (uint256) {}
            catch {}
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
            try ILadderPolicy(policy).weights(tiltX18, buckets) returns (uint256[] memory proposed) {
                if (proposed.length == buckets) {
                    uint256 sum;
                    for (uint256 i; i < buckets; ++i) {
                        sum += proposed[i];
                    }
                    if (sum == Constants.WAD) return proposed;
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
        ctx.staking = address(uint160(_word(SLOT_STAKING)));
        ctx.bountyPot = address(uint160(_word(SLOT_BOUNTY_POT)));
        ctx.marketReference = address(uint160(_word(SLOT_MARKET_REFERENCE)));
        ctx.oracleGate = address(uint160(_word(SLOT_ORACLE_GATE)));
        ctx.feedRegistry = address(uint160(_word(SLOT_FEED_REGISTRY)));
        ctx.ladderPolicy = address(uint160(_word(SLOT_LADDER_POLICY)));
        ctx.rolloutPolicy = address(uint160(_word(SLOT_ROLLOUT_POLICY)));

        ctx.creator = address(uint160(creatorWord));
        ctx.genesisTimestamp = uint32(creatorWord >> 160);

        ctx.burnBps = uint16(params >> 16);
        ctx.stakerBps = uint16(params >> 32);
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
