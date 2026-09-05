// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IFeedRegistry} from "../interfaces/IFeedRegistry.sol";
import {IMarketReference} from "../interfaces/IMarketReference.sol";
import {IOracleGate} from "../interfaces/IOracleGate.sol";
import {IPoolRegistry} from "../interfaces/IPoolRegistry.sol";
import {IPositionValuer} from "../interfaces/IPositionValuer.sol";
import {IStockToken} from "../interfaces/IStockToken.sol";
import {PriceLib} from "../lib/PriceLib.sol";
import {Constants} from "../types/Constants.sol";
import {ConstituentConfig, GateSnapshot, GateState, PoolConfig} from "../types/Types.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @title VaultNavLib
/// @notice `AmpsVault`'s read side: the NAV numerator `A` of section 4, the `P_mkt` of section 5, the reference
///         overrides, the inventory disclosure and the section 8 migration predicate.
///
/// @dev **Why a linked library and not vault code.** The vault implements the whole of `IAmpsVault` and does not
///      fit EIP-170 with this arithmetic inlined (45,818 bytes as one contract; see the Phase 2 report). Every
///      function here is a `public` library function, so it is deployed once and reached by `DELEGATECALL`: it
///      runs in the vault's context, holds no storage of its own, and can move no funds. Splitting the *reads*
///      out rather than the writes is deliberate — it keeps `redeemProRata` self-contained, which is what the I14
///      storage-level proof needs.
///
/// @dev **Nothing here is upgradeable.** The library address is fixed in the vault's bytecode at link time, so
///      this is part of the immutable vault for every governance purpose. The pointer-upgradeable pieces
///      (`oracleGate`, `feedRegistry`, `positionValuer`) are passed in as arguments, exactly as they are stored.
///
/// @dev **Rounding is one-directional: down.** Every USD term goes through `PriceLib.counterValueUsd18`, so `A` is
///      never overstated (section 4), and `P_mkt` is read out of a pool with `sqrtPriceX96ToAmpsPriceUsd18`, which
///      also rounds down.
library VaultNavLib {
    using CurrencyLibrary for Currency;

    /// @notice Everything the read side needs from the vault, gathered into one argument so the ABI of these
    ///         functions does not change when a pointer is added.
    /// @param poolManager The Uniswap v4 PoolManager: where the vault's ERC-6909 claims live.
    /// @param registry The pool registry: decimals, pool ids, the hub and the WETH entry pool.
    /// @param feedRegistry The feed registry: the only place a Chainlink answer is read.
    /// @param positionValuer The position valuer: the third NAV term, a zero-position stub in Phase 2.
    /// @param marketReference The truncated-observation source: `AmpsHook` in production, a mock in Phase 2.
    /// @param oracleGate The oracle gate, for the `REF_DIVERGED` and watchdog overrides.
    /// @param pRefPrevX18 The previous checkpoint's `P_ref`, which positions are decomposed at (I7).
    /// @param twapWindow The window `P_mkt` is read over.
    /// @param refDivergenceBps The hub-versus-WETH divergence threshold.
    struct Sources {
        address poolManager;
        address registry;
        address feedRegistry;
        address positionValuer;
        address marketReference;
        address oracleGate;
        uint256 pRefPrevX18;
        uint32 twapWindow;
        uint16 refDivergenceBps;
    }

    /// @notice `A = SUM_j P_j x (ERC-6909 claim_j + idle ERC-20_j + positions_j(sqrtPrice_REF))`, 18-decimal USD.
    /// @dev Every AMPS leg is worth zero (I5) because AMPS is never in `assets`, and the BountyPot's balance is
    ///      outside the sum (I21) because the pot is a different account. A balance the protocol cannot price
    ///      reverts with {IFeedRegistry.FeedNotSet} rather than being silently valued at zero: the last checkpoint
    ///      then stands and every gated consumer refuses on `StaleCheckpoint`, which is the conservative failure.
    /// @param src The vault's pointers and the previous reference price.
    /// @param assets The vault's registered non-AMPS assets.
    /// @param holder The account whose balances are valued.
    /// @param withPositions Whether to add the position term. False when valuing an account that does not own the
    ///        vault's v4 positions, i.e. the standby inside `emergencyMigrate`.
    /// @return usd18 `A`, rounded down.
    function totalAssetsUsd18(Sources memory src, address[] memory assets, address holder, bool withPositions)
        public
        view
        returns (uint256 usd18)
    {
        uint256 length = assets.length;
        for (uint256 i; i < length; ++i) {
            address token = assets[i];
            (uint8 decimals, PoolId poolId, bool hasPool) = assetMeta(src.registry, token);

            uint256 balance = IPoolManager(src.poolManager).balanceOf(holder, Currency.wrap(token).toId())
                + IERC20(token).balanceOf(holder);

            if (withPositions && hasPool && src.positionValuer != address(0) && src.pRefPrevX18 != 0) {
                uint160 sqrtPriceRefX96 = _referenceSqrtPrice(src, token, decimals);
                if (sqrtPriceRefX96 != 0) {
                    (, uint256 amount1) = IPositionValuer(src.positionValuer).valuePool(poolId, sqrtPriceRefX96);
                    balance += amount1;
                }
            }

            if (balance == 0) continue;

            uint256 answerUsd8 = answer(src.feedRegistry, token);
            if (answerUsd8 == 0) revert IFeedRegistry.FeedNotSet(token);

            usd18 += PriceLib.counterValueUsd18(balance, decimals, answerUsd8);
        }
    }

    /// @notice Protocol-held AMPS: the idle balance, the ERC-6909 claim and the AMPS inside the vault's positions.
    /// @dev Disclosure only. It never enters the NAV denominator (I6) and it excludes the AMPS `AmpsBonds` holds
    ///      for vesting (I30), which lives on that contract.
    /// @param src The vault's pointers and the previous reference price.
    /// @param assets The vault's registered non-AMPS assets, whose pools are where AMPS positions sit.
    /// @param ampsToken The AMPS token.
    /// @param holder The account to measure.
    /// @return amount The inventory, in AMPS wei.
    function inventoryAmps(Sources memory src, address[] memory assets, address ampsToken, address holder)
        public
        view
        returns (uint256 amount)
    {
        amount = IERC20(ampsToken).balanceOf(holder)
            + IPoolManager(src.poolManager).balanceOf(holder, Currency.wrap(ampsToken).toId());
        if (src.positionValuer == address(0) || src.pRefPrevX18 == 0) return amount;

        uint256 length = assets.length;
        for (uint256 i; i < length; ++i) {
            (uint8 decimals, PoolId poolId, bool hasPool) = assetMeta(src.registry, assets[i]);
            if (!hasPool) continue;
            uint160 sqrtPriceRefX96 = _referenceSqrtPrice(src, assets[i], decimals);
            if (sqrtPriceRefX96 == 0) continue;
            (uint256 amount0,) = IPositionValuer(src.positionValuer).valuePool(poolId, sqrtPriceRefX96);
            amount += amount0;
        }
    }

    /// @notice `P_mkt`: the `AMPS/USDG` hub's truncated TWAP, converted to USD through `PriceLib` and the hub
    ///         counter's Chainlink answer.
    /// @dev `usable == false` — and a recorded `P_mkt` of zero — whenever the ring does not cover `twapWindow`,
    ///      the pool has never been observed, or the counter has no usable answer. That is section 5's coverage
    ///      override, and it is why a young pool degrades to a NAV-anchored reference instead of bricking the
    ///      permissionless checkpoint.
    /// @param src The vault's pointers.
    /// @return pMktX18 The market price, 18 decimals, or zero.
    /// @return usable Whether the price may be used at all.
    function marketPrice(Sources memory src) public view returns (uint256 pMktX18, bool usable) {
        if (src.marketReference == address(0) || src.registry == address(0)) return (0, false);
        PoolId hub = IPoolRegistry(src.registry).hubPoolId();
        PoolConfig memory config = IPoolRegistry(src.registry).poolConfig(hub);
        if (config.counter == address(0)) return (0, false);
        return _poolPriceUsd18(src, hub, config.counter, config.counterDecimals);
    }

    /// @notice Whether `P_ref` must fall back to NAV outright.
    /// @dev Two independent reasons, either of which pins the reference (section 5): the gate reports
    ///      `REF_DIVERGED` or a tripped layer-A watchdog for the hub, or the vault's own layer-F cross-check finds
    ///      the hub TWAP and `AMPS/WETH x ETH/USD` more than `refDivergenceBps` apart. A gate that reverts is
    ///      treated as silent, and a missing cross-check is not evidence of divergence.
    /// @param src The vault's pointers and `refDivergenceBps`.
    /// @param pMktX18 The market price just computed.
    /// @return overridden Whether `P_ref` must equal `navPerShareX18`.
    function referenceOverridden(Sources memory src, uint256 pMktX18) public view returns (bool overridden) {
        if (src.oracleGate != address(0) && src.registry != address(0)) {
            try IOracleGate(src.oracleGate).snapshotByPool(IPoolRegistry(src.registry).hubPoolId()) returns (
                GateSnapshot memory snap
            ) {
                if (snap.state == GateState.REF_DIVERGED || snap.state == GateState.WATCHDOG || snap.watchdogTripped) {
                    return true;
                }
            } catch {}
        }
        if (pMktX18 == 0 || src.registry == address(0) || src.marketReference == address(0)) return false;

        PoolId wethPool = IPoolRegistry(src.registry).wethPoolId();
        PoolConfig memory config = IPoolRegistry(src.registry).poolConfig(wethPool);
        if (config.counter == address(0)) return false;

        (uint256 crossPrice, bool usable) = _poolPriceUsd18(src, wethPool, config.counter, config.counterDecimals);
        if (!usable) return false;

        uint256 gap = crossPrice > pMktX18 ? crossPrice - pMktX18 : pMktX18 - crossPrice;
        return FullMath.mulDiv(gap, Constants.BPS, pMktX18) > src.refDivergenceBps;
    }

    /// @notice Section 8's on-chain migration predicate.
    /// @dev True when `isBlocked(vault) == true` for at least one registered constituent, or when a bounded
    ///      self-transfer probe fails for at least two. Every probe is capped at
    ///      `Constants.STOCK_TOKEN_PROBE_GAS`, so a hostile beacon implementation cannot grief the evacuation by
    ///      burning gas, and a failed probe is read as evidence rather than as a revert of the caller.
    /// @dev The probe moves 1 wei when the vault holds at least 1 wei and 0 otherwise: a denylisted or paused
    ///      Stock Token reverts on a zero-value transfer exactly as it does on a 1-wei one, while a strict 1-wei
    ///      probe against the vault's habitual zero balance (I12) would fail for insufficient balance on *every*
    ///      healthy token and make the predicate vacuous.
    /// @dev Not `view`: the probe is a real call, made by the vault itself through this library's `DELEGATECALL`.
    /// @param registry The pool registry, for the constituent set.
    /// @param vault The vault being evacuated.
    /// @return met Whether the guardian may migrate.
    function migrationPredicate(address registry, address vault) public returns (bool met) {
        if (registry == address(0)) return false;
        uint16 count = IPoolRegistry(registry).constituentCount();
        uint256 failedProbes;

        for (uint16 id = 1; id <= count; ++id) {
            address token = IPoolRegistry(registry).constituent(id).token;
            if (token == address(0)) continue;

            (bool ok, bytes memory returndata) =
                token.staticcall{gas: Constants.STOCK_TOKEN_PROBE_GAS}(abi.encodeCall(IStockToken.isBlocked, (vault)));
            if (ok && returndata.length >= 32 && abi.decode(returndata, (bool))) return true;

            if (!_selfTransferProbe(token, vault)) {
                unchecked {
                    ++failedProbes;
                }
                if (failedProbes >= 2) return true;
            }
        }
        return false;
    }

    /// @notice The last accepted answer for `token`, 8 decimals, or zero when none exists.
    /// @dev Never reverts: a feed registry that reverts is indistinguishable, for valuation purposes, from one
    ///      with no answer, and the caller decides what to do about it.
    /// @param feeds The feed registry.
    /// @param token The asset.
    /// @return answerUsd8 The answer, or zero.
    function answer(address feeds, address token) public view returns (uint256 answerUsd8) {
        if (feeds == address(0)) return 0;
        try IFeedRegistry(feeds).latestAnswer(token) returns (uint256 value, uint32, bool) {
            return value;
        } catch {
            return 0;
        }
    }

    /// @notice Decimals and pool for one asset, from the registry, with a bounded ERC-20 `decimals()` fallback for
    ///         an asset the registry does not know.
    /// @param registry The pool registry.
    /// @param token The asset.
    /// @return decimals The asset's ERC-20 decimals.
    /// @return poolId The pool the asset trades in, when there is one.
    /// @return hasPool Whether `poolId` is meaningful.
    function assetMeta(address registry, address token)
        public
        view
        returns (uint8 decimals, PoolId poolId, bool hasPool)
    {
        if (registry != address(0)) {
            uint16 id = IPoolRegistry(registry).constituentIdOf(token);
            if (id != 0) {
                ConstituentConfig memory config = IPoolRegistry(registry).constituent(id);
                return (config.decimals, IPoolRegistry(registry).poolIdOf(id), true);
            }
            PoolId hub = IPoolRegistry(registry).hubPoolId();
            PoolConfig memory hubConfig = IPoolRegistry(registry).poolConfig(hub);
            if (hubConfig.counter == token) return (hubConfig.counterDecimals, hub, true);

            PoolId wethPool = IPoolRegistry(registry).wethPoolId();
            PoolConfig memory wethConfig = IPoolRegistry(registry).poolConfig(wethPool);
            if (wethConfig.counter == token) return (wethConfig.counterDecimals, wethPool, true);
        }
        return (_erc20Decimals(token), PoolId.wrap(bytes32(0)), false);
    }

    /// @notice The full asset list the registry knows about: every constituent's Stock Token, plus the two entry
    ///         pools' counter assets (WETH9 and USDG).
    /// @dev Called once, by `AmpsVault.genesis`, to seed the vault's own enumeration. The vault keeps that copy so
    ///      that `redeemProRata` never has to consult the registry (section 7); constituents added later arrive
    ///      through `AmpsVault.initializePool`.
    /// @param registry The pool registry.
    /// @return tokens The assets, with `address(0)` entries where a constituent record is empty.
    function registryAssets(address registry) public view returns (address[] memory tokens) {
        uint16 count = IPoolRegistry(registry).constituentCount();
        tokens = new address[](uint256(count) + 2);
        for (uint16 id = 1; id <= count; ++id) {
            tokens[id - 1] = IPoolRegistry(registry).constituent(id).token;
        }
        tokens[count] = IPoolRegistry(registry).poolConfig(IPoolRegistry(registry).hubPoolId()).counter;
        tokens[uint256(count) + 1] = IPoolRegistry(registry).poolConfig(IPoolRegistry(registry).wethPoolId()).counter;
    }

    // -------------------------------------------------------------------------------------------------------------
    // Internals
    // -------------------------------------------------------------------------------------------------------------

    /// @dev The USD price of AMPS implied by one pool's truncated TWAP, or `(0, false)` when the ring, the pool or
    ///      the counter's answer cannot support one.
    function _poolPriceUsd18(Sources memory src, PoolId poolId, address counter, uint8 counterDecimals)
        private
        view
        returns (uint256 price, bool usable)
    {
        try IMarketReference(src.marketReference).observationCoverage(poolId) returns (uint32 covered) {
            if (covered < src.twapWindow) return (0, false);
        } catch {
            return (0, false);
        }

        int24 tick;
        try IMarketReference(src.marketReference).twapTick(poolId, src.twapWindow) returns (int24 meanTick) {
            tick = meanTick;
        } catch {
            return (0, false);
        }
        if (tick < TickMath.MIN_TICK || tick > TickMath.MAX_TICK) return (0, false);

        uint256 answerUsd8 = answer(src.feedRegistry, counter);
        if (answerUsd8 == 0) return (0, false);

        price = PriceLib.sqrtPriceX96ToAmpsPriceUsd18(PriceLib.tickToSqrtPriceX96(tick), answerUsd8, counterDecimals);
        usable = true;
    }

    /// @dev `sqrtPrice(P_ref / P_j)` from the *previous* checkpoint: the counterfactual price positions are
    ///      decomposed at (I7), never `slot0`. Zero when the asset has no usable answer or the inputs are outside
    ///      the range `PriceLib` accepts, in which case the caller drops the position term rather than valuing it
    ///      at a price it does not trust.
    function _referenceSqrtPrice(Sources memory src, address token, uint8 decimals)
        private
        view
        returns (uint160 sqrtPriceX96)
    {
        uint256 answerUsd8 = answer(src.feedRegistry, token);
        if (answerUsd8 == 0 || decimals > PriceLib.MAX_COUNTER_DECIMALS) return 0;
        if (src.pRefPrevX18 > type(uint256).max / (10 ** uint256(decimals))) return 0;
        if (answerUsd8 > type(uint256).max / 1e28) return 0;
        return PriceLib.ampsPerCounterToSqrtPriceX96(src.pRefPrevX18, answerUsd8, decimals);
    }

    /// @dev A bounded `decimals()` probe. Eighteen is the fallback: every Stock Token and WETH carry it, and an
    ///      asset whose metadata cannot be read is one governance should not have registered.
    function _erc20Decimals(address token) private view returns (uint8 decimals) {
        (bool ok, bytes memory returndata) =
            token.staticcall{gas: Constants.STOCK_TOKEN_PROBE_GAS}(abi.encodeCall(IERC20Metadata.decimals, ()));
        if (ok && returndata.length >= 32) {
            uint256 value = abi.decode(returndata, (uint256));
            if (value <= PriceLib.MAX_COUNTER_DECIMALS) return uint8(value);
        }
        return 18;
    }

    /// @dev One bounded self-transfer probe. False when the balance read or the transfer fails, or when the token
    ///      returns an explicit `false`.
    function _selfTransferProbe(address token, address vault) private returns (bool ok) {
        (bool balanceOk, bytes memory balanceData) =
            token.staticcall{gas: Constants.STOCK_TOKEN_PROBE_GAS}(abi.encodeCall(IERC20.balanceOf, (vault)));
        if (!balanceOk || balanceData.length < 32) return false;
        uint256 amount = abi.decode(balanceData, (uint256)) >= 1 ? 1 : 0;

        (bool transferOk, bytes memory transferData) =
            token.call{gas: Constants.STOCK_TOKEN_PROBE_GAS}(abi.encodeCall(IERC20.transfer, (vault, amount)));
        if (!transferOk) return false;
        if (transferData.length == 0) return true;
        if (transferData.length < 32) return false;
        return abi.decode(transferData, (bool));
    }
}
