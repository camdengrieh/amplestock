// SPDX-License-Identifier: MIT
pragma solidity >=0.6.2 <0.9.0;

import {IFeedRegistry as SnapFeeds} from "../../src/interfaces/IFeedRegistry.sol";
import {
    BondMarket as SnapMarket,
    Checkpoint as SnapCheckpoint,
    ConstituentConfig as SnapConstituent,
    GateState as SnapGateState,
    HookPoolState as SnapHookState,
    PlacementRecord as SnapRecord,
    VestingPosition as SnapPosition
} from "../../src/types/Types.sol";
import {Base} from "./Base.sol";
import {IERC20 as SnapIERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager as SnapPM} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency as SnapCurrency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId as SnapPoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @notice Used to take snapshots of the state before and after a function call.
///
/// @dev **Every read here is defensive.** A snapshot runs on both arms of a handler, including the arm where the
///      world is degraded — a paused issuer beacon, a stale feed, a frozen gate, a collateral whose `balanceOf`
///      reverts. `_takeSnapshot` must never be the reason a handler reverts, or the campaign loses the very state
///      the property was going to inspect. Every external read is either a `try`/`catch` or a raw `staticcall`
///      whose failure leaves the field at zero.
///
/// @dev **The snapshot is banded, not exhaustive** (`fizz_data/property-plan.md`, Snapshot State Plan: "take the
///      ladder legs *lazily* — only the pool the handler touched — and keep only counts in the GLOBAL
///      properties"). At the launch shape `previewNavPerShareX18()` and `totalAssetsUsd18()` each walk 32 pools at
///      ~150k gas a pool, so reading them on both arms of every handler would cost ~20M gas per call and drop the
///      campaign from ~230 calls/s to ~25. A handler therefore declares what it needs:
///
///      ```solidity
///      function ampsVault_compound(bytes32 poolId) public asKeeper {
///          setSnapshotPool(PoolId.wrap(poolId));
///          snapshotFlags = SNAP_NAV | SNAP_LADDER;
///          snapshotBefore();
///          ...
///          snapshotAfter();
///      }
///      ```
///
///      With no flags set the snapshot is the cheap core: supply, the actor's and the shell's AMPS, the cached
///      checkpoint words, the pot, the counters. `SNAP_*` adds a band at a time.
///
/// @dev **Per-pool, per-asset and per-id legs are fixed-size arrays**, not dynamic ones: a storage array that is
///      resized on every snapshot costs more than the read it stores, and a fixed array's unwritten slots cost
///      nothing at all. The bounds are the launch shape plus headroom; a leg past the bound is simply not taken.
abstract contract Snapshots is Base {
    // ―――――――――――――――――――――――― Snapshot bands ――――――――――――――――――――

    /// @dev Adds `A`, both NAV/share readings and `navUnconfirmed`. ~10M gas — only where a NAV delta is asserted.
    uint256 internal constant SNAP_NAV = 1;
    /// @dev Adds the ladder of {snapshotPool} only: length, the 24 cells' ticks, sidedness and liquidity.
    uint256 internal constant SNAP_LADDER = 2;
    /// @dev Adds every pool's ladder. Only `redeemProRata` needs it — it removes liquidity from all 32 pools.
    uint256 internal constant SNAP_ALL_LADDERS = 4;
    /// @dev Adds the registered-asset legs: the vault's holding, the hook's, and the recipient's balance + claim.
    uint256 internal constant SNAP_ASSETS = 8;
    /// @dev Adds the bond book: the actor's positions, the markets' counters and the daily issuance.
    uint256 internal constant SNAP_BONDS = 16;
    /// @dev Adds the oracle legs: the gate's state and freezes, the feed answers, the registry's constituents.
    uint256 internal constant SNAP_GATE = 32;
    /// @dev Adds the hook's per-pool view: ticks, fees, coverage, surge and the rotation credit.
    uint256 internal constant SNAP_HOOK = 64;

    /// @dev The launch shape (`Constants.LAUNCH_POOLS`) is 32 pools; a wider `FIZZ_SPOKES` simply stops being
    ///      snapshotted past the bound rather than reverting.
    uint256 internal constant SNAP_MAX_POOLS = 32;
    uint256 internal constant SNAP_MAX_ASSETS = 34;
    uint256 internal constant SNAP_MAX_IDS = 34;
    uint256 internal constant SNAP_MAX_POSITIONS = 16;
    uint256 internal constant SNAP_CELLS = 24;

    // ―――――――――――――――――――――― What this step is about ―――――――――――――――

    /// @notice Which bands {snapshotBefore} / {snapshotAfter} take. Set it before `snapshotBefore()`.
    uint256 internal snapshotFlags;

    /// @notice The pool this step is about; the per-pool legs are taken for it and nothing else.
    SnapPoolId internal snapshotPool;

    /// @notice `snapshotPool`'s index in {Base-pools}, or `pools.length` when it is not one of them.
    uint256 internal snapshotPoolIndex;

    /// @notice The counter asset this step is about — the leg SP-42..SP-47 measure their round trip on.
    address internal probeToken;

    /// @notice The collateral this step bonds, for the SP-04 / SP-05 legs.
    address internal snapshotCollateral;

    /// @notice The recipient this step pays, for the SP-11 / SP-33 legs. Defaults to the current actor.
    address internal snapshotRecipient;

    // ―――――――――――――――――――――――――― The state ―――――――――――――――――――――――――

    struct State {
        // ── the AMPS ledger ────────────────────────────────────────────────────────────────────────────────────
        uint256 ampsTotalSupply;
        uint256 actorAmps;
        uint256[3] actorsAmps;
        uint256 bondsAmps;
        uint256 recipientAmps;
        uint256 vaultIdleAmps;
        uint256 vaultHeldAmps;
        // ── the probe leg ──────────────────────────────────────────────────────────────────────────────────────
        address probeToken;
        uint256 actorProbe;
        address collateral;
        uint256 actorCollateral;
        uint256 collateralPriceUsd18;
        // ── the counter legs of a swap ─────────────────────────────────────────────────────────────────────────
        address counter;
        uint256 payerCounter;
        uint256 pmCounter;
        uint256 recipCounter;
        uint256 routerCounter;
        uint256 routerEth;
        // ── the registered assets ──────────────────────────────────────────────────────────────────────────────
        uint256 assetCount;
        uint256[SNAP_MAX_ASSETS] assetHeld;
        uint256[SNAP_MAX_ASSETS] recipTokenBal;
        uint256[SNAP_MAX_ASSETS] recipClaim;
        uint256[SNAP_MAX_ASSETS] hookIdle;
        uint256[SNAP_MAX_ASSETS] hookClaim;
        // ── NAV and the checkpoint ─────────────────────────────────────────────────────────────────────────────
        uint256 totalAssetsUsd18;
        uint256 navPerShareX18;
        uint128 checkpointNavPerShareX18;
        uint128 pRefX18;
        uint128 pMktX18;
        uint32 checkpointTimestamp;
        uint32 checkpointBlock;
        bool navUnconfirmed;
        uint16 redeemFeeBps;
        // ── the ladder ─────────────────────────────────────────────────────────────────────────────────────────
        uint32 liveCells;
        uint256 snapshotPoolIndex;
        bytes32 snapshotPool;
        uint256[SNAP_MAX_POOLS] ladderLength;
        uint32[SNAP_MAX_POOLS] lastPlacementAt;
        int24[SNAP_CELLS][SNAP_MAX_POOLS] lower;
        int24[SNAP_CELLS][SNAP_MAX_POOLS] upper;
        bool[SNAP_CELLS][SNAP_MAX_POOLS] above;
        uint128[SNAP_CELLS][SNAP_MAX_POOLS] liquidity;
        uint256[SNAP_CELLS] cellAmps;
        // ── the hook's per-pool view, for {snapshotPool} ───────────────────────────────────────────────────────
        int24 tick;
        int24 fairTick;
        int24 highWater;
        int24 lastTruncatedTick;
        uint160 sqrtPrice;
        uint16 surgeBps;
        uint16 chargedFeeBps;
        uint32 observationCoverage;
        uint16 ampsFeeBps;
        uint16 buyFeeBps;
        uint256 rotationCredit;
        // ── the bond book ──────────────────────────────────────────────────────────────────────────────────────
        uint256[3] positionCount;
        uint256[3] claimableTotal;
        uint128[SNAP_MAX_POSITIONS] principal;
        uint128[SNAP_MAX_POSITIONS] claimed;
        uint32[SNAP_MAX_POSITIONS] start;
        uint32[SNAP_MAX_POSITIONS] vestSeconds;
        uint256 positionsCaptured;
        uint128[SNAP_MAX_IDS] marketTotalIssued;
        uint128[SNAP_MAX_IDS] marketIssuedThisEpoch;
        uint32[SNAP_MAX_IDS] marketLastBondAt;
        uint32[SNAP_MAX_IDS] marketEpochStart;
        uint256 dailyIssued;
        // ── the registry ───────────────────────────────────────────────────────────────────────────────────────
        uint8[SNAP_MAX_IDS] status;
        uint16[SNAP_MAX_IDS] rolloutWeightBps;
        uint16[SNAP_MAX_IDS] targetWeightBps;
        uint32[SNAP_MAX_IDS] retiredAt;
        uint16 activeCount;
        // ── the oracle ─────────────────────────────────────────────────────────────────────────────────────────
        uint128[SNAP_MAX_ASSETS] acceptedAnswer;
        uint32[SNAP_MAX_ASSETS] acceptedUpdatedAt;
        uint80[SNAP_MAX_ASSETS] acceptedRoundId;
        uint80[SNAP_MAX_ASSETS] pendingRoundId;
        uint32 divergedSince;
        uint8 gateState;
        uint32 protocolFreezeUntil;
        uint32[SNAP_MAX_IDS] constituentFreezeUntil;
        uint32 gateBlock;
        uint32 gateTimestamp;
        // ── the keeper purse and the creator ───────────────────────────────────────────────────────────────────
        uint256 potBalance;
        uint256 potSpent;
        uint256 potBudgetLeftRaw;
        uint32 potWindowStart;
        uint256 keeperUsdg;
        uint256 creatorAmps;
        uint256 creatorCounterClaim;
        // ── actor value ────────────────────────────────────────────────────────────────────────────────────────
        uint256[3] actorValue;
    }

    State internal stateBefore;
    State internal stateAfter;

    // ―――――――――――――――――――――――― Taking one ―――――――――――――――――――――――――

    function snapshotBefore() internal {
        _takeSnapshot(stateBefore);
    }

    function snapshotAfter() internal {
        _takeSnapshot(stateAfter);
    }

    /// @notice Names the pool the next snapshot's per-pool legs are about.
    /// @param poolId The pool.
    function setSnapshotPool(SnapPoolId poolId) internal {
        snapshotPool = poolId;
        snapshotPoolIndex = poolIndexOf(poolId);
    }

    /// @notice Names the counter asset the next snapshot's probe leg is about.
    /// @param token The token.
    function setProbeToken(address token) internal {
        probeToken = token;
    }

    /// @notice Clears the band selection back to the cheap core. Call it at the end of a handler that widened it,
    ///         so the next handler does not silently pay for a band it never asked for.
    function resetSnapshotBands() internal {
        snapshotFlags = 0;
    }

    function _takeSnapshot(State storage state) private {
        address recipient = snapshotRecipient == address(0) ? actor : snapshotRecipient;

        // ── core: always taken, all of it cheap ────────────────────────────────────────────────────────────────
        state.ampsTotalSupply = amps.totalSupply();
        state.actorAmps = amps.balanceOf(actor);
        state.bondsAmps = amps.balanceOf(address(bonds));
        state.recipientAmps = amps.balanceOf(recipient);
        state.vaultIdleAmps = amps.balanceOf(address(vault));
        state.vaultHeldAmps = state.vaultIdleAmps + _claim(address(vault), address(amps));
        for (uint256 i; i < 3 && i < actors.length; ++i) {
            state.actorsAmps[i] = amps.balanceOf(actors[i]);
        }

        state.probeToken = probeToken;
        state.actorProbe = probeToken == address(0) ? 0 : _balanceOf(probeToken, actor);
        state.collateral = snapshotCollateral;
        state.actorCollateral = snapshotCollateral == address(0) ? 0 : _balanceOf(snapshotCollateral, actor);
        state.collateralPriceUsd18 = snapshotCollateral == address(0) ? 0 : _priceUsd18(snapshotCollateral);

        state.snapshotPool = SnapPoolId.unwrap(snapshotPool);
        state.snapshotPoolIndex = snapshotPoolIndex;
        state.liveCells = vault.liveCells();
        state.redeemFeeBps = vault.redeemFeeBps();

        SnapCheckpoint memory cp = vault.checkpointData();
        state.checkpointNavPerShareX18 = cp.navPerShareX18;
        state.pRefX18 = cp.pRefX18;
        state.pMktX18 = cp.pMktX18;
        state.checkpointTimestamp = cp.timestamp;
        state.checkpointBlock = cp.blockNumber;

        state.potBalance = pot.balance();
        state.potSpent = pot.spentLast24h();
        state.potWindowStart = pot.windowStart();
        try pot.budgetLeftRaw() returns (uint256 left) {
            state.potBudgetLeftRaw = left;
        } catch {
            state.potBudgetLeftRaw = 0;
        }
        state.keeperUsdg = _balanceOf(address(usdg), keeper);
        state.creatorAmps = amps.balanceOf(vault.creator());
        state.routerEth = address(ampsRouter).balance;

        if (state.snapshotPool != bytes32(0) && state.snapshotPoolIndex < pools.length) {
            address counter = counterOf(snapshotPool);
            state.counter = counter;
            state.payerCounter = _balanceOf(counter, actor);
            state.pmCounter = _balanceOf(counter, address(poolManager));
            state.recipCounter = _balanceOf(counter, recipient);
            state.routerCounter = _balanceOf(counter, address(ampsRouter));
            state.creatorCounterClaim = _claim(vault.creator(), counter);
        }

        uint256 flags = snapshotFlags;

        // ── SNAP_NAV: the 32-pool walk ─────────────────────────────────────────────────────────────────────────
        if (flags & SNAP_NAV != 0) {
            try vault.totalAssetsUsd18() returns (uint256 a) {
                state.totalAssetsUsd18 = a;
            } catch {
                state.totalAssetsUsd18 = 0;
            }
            try vault.previewNavPerShareX18() returns (uint256 nav) {
                state.navPerShareX18 = nav;
            } catch {
                state.navPerShareX18 = 0;
            }
            state.navUnconfirmed = vault.navUnconfirmed();
            for (uint256 i; i < 3 && i < actors.length; ++i) {
                state.actorValue[i] = actorValueUsd18(actors[i]);
            }
        }

        // ── SNAP_LADDER / SNAP_ALL_LADDERS ─────────────────────────────────────────────────────────────────────
        if (flags & SNAP_ALL_LADDERS != 0) {
            uint256 n = pools.length < SNAP_MAX_POOLS ? pools.length : SNAP_MAX_POOLS;
            for (uint256 p; p < n; ++p) {
                _takeLadder(state, pools[p], p);
            }
        } else if (flags & SNAP_LADDER != 0 && state.snapshotPoolIndex < SNAP_MAX_POOLS) {
            _takeLadder(state, snapshotPool, state.snapshotPoolIndex);
            _takeCellAmps(state, snapshotPool);
        }

        // ── SNAP_ASSETS ────────────────────────────────────────────────────────────────────────────────────────
        if (flags & SNAP_ASSETS != 0) {
            uint256 count = vault.assetCount();
            state.assetCount = count;
            if (count > SNAP_MAX_ASSETS) count = SNAP_MAX_ASSETS;
            for (uint256 i; i < count; ++i) {
                address token = vault.assetAt(i);
                state.assetHeld[i] = _balanceOf(token, address(vault)) + _claim(address(vault), token);
                state.recipTokenBal[i] = _balanceOf(token, recipient);
                state.recipClaim[i] = _claim(recipient, token);
                state.hookIdle[i] = _balanceOf(token, address(hook));
                state.hookClaim[i] = _claim(address(hook), token);
            }
        }

        // ── SNAP_HOOK ──────────────────────────────────────────────────────────────────────────────────────────
        if (flags & SNAP_HOOK != 0 && state.snapshotPoolIndex < pools.length) {
            state.ampsFeeBps = hook.ampsFeeBps();
            state.tick = _tickOrZero(snapshotPool);
            state.sqrtPrice = _sqrtOrZero(snapshotPool);
            try hook.fairTick(snapshotPool) returns (int24 v) {
                state.fairTick = v;
            } catch {}
            try hook.highWaterTick(snapshotPool) returns (int24 v) {
                state.highWater = v;
            } catch {}
            try hook.lastTruncatedTick(snapshotPool) returns (int24 v) {
                state.lastTruncatedTick = v;
            } catch {}
            try hook.observationCoverage(snapshotPool) returns (uint32 v) {
                state.observationCoverage = v;
            } catch {}
            try hook.chargedFeeBps(snapshotPool) returns (uint16 v) {
                state.chargedFeeBps = v;
            } catch {}
            try hook.buyFeeBps(snapshotPool) returns (uint16 v) {
                state.buyFeeBps = v;
            } catch {}
            try hook.poolState(snapshotPool) returns (SnapHookState memory s) {
                state.surgeBps = s.surgeBps;
            } catch {}
            try hook.rotationCredit(actor) returns (uint256 v) {
                state.rotationCredit = v;
            } catch {}
            state.lastPlacementAt[state.snapshotPoolIndex] = vault.lastPlacementAt(snapshotPool);
        }

        // ── SNAP_BONDS ─────────────────────────────────────────────────────────────────────────────────────────
        if (flags & SNAP_BONDS != 0) {
            for (uint256 i; i < 3 && i < actors.length; ++i) {
                state.positionCount[i] = bonds.positionCount(actors[i]);
                try bonds.claimableTotal(actors[i]) returns (uint256 v) {
                    state.claimableTotal[i] = v;
                } catch {}
            }
            uint256 own = bonds.positionCount(actor);
            uint256 captured = own < SNAP_MAX_POSITIONS ? own : SNAP_MAX_POSITIONS;
            state.positionsCaptured = captured;
            for (uint256 j; j < captured; ++j) {
                SnapPosition memory record = bonds.position(actor, j);
                state.principal[j] = record.principal;
                state.claimed[j] = record.claimed;
                state.start[j] = record.start;
                state.vestSeconds[j] = record.vestSeconds;
            }
            uint256 markets = marketIds.length < SNAP_MAX_IDS ? marketIds.length : SNAP_MAX_IDS;
            for (uint256 m; m < markets; ++m) {
                try bonds.market(marketIds[m]) returns (SnapMarket memory record) {
                    state.marketTotalIssued[m] = record.totalIssued;
                    state.marketIssuedThisEpoch[m] = record.issuedThisEpoch;
                    state.marketLastBondAt[m] = record.lastBondAt;
                    state.marketEpochStart[m] = record.epochStart;
                } catch {}
            }
            (state.dailyIssued,) = bonds.dailyIssuance();
        }

        // ── SNAP_GATE ──────────────────────────────────────────────────────────────────────────────────────────
        if (flags & SNAP_GATE != 0) {
            state.activeCount = registry.activeConstituentCount();
            state.protocolFreezeUntil = gate.protocolFreezeUntil();
            (state.gateBlock, state.gateTimestamp,) = gate.watchdog();
            if (state.snapshotPoolIndex < pools.length) {
                try gate.stateByPool(snapshotPool) returns (SnapGateState s) {
                    state.gateState = uint8(s);
                } catch {}
                try gate.divergedSince(snapshotPool) returns (uint32 v) {
                    state.divergedSince = v;
                } catch {}
            }
            uint256 ids = constituentIds.length < SNAP_MAX_IDS ? constituentIds.length : SNAP_MAX_IDS;
            for (uint256 i; i < ids; ++i) {
                SnapConstituent memory cfg = registry.constituent(constituentIds[i]);
                state.status[i] = uint8(cfg.status);
                state.rolloutWeightBps[i] = cfg.rolloutWeightBps;
                state.targetWeightBps[i] = cfg.targetWeightBps;
                state.retiredAt[i] = cfg.retiredAt;
                state.constituentFreezeUntil[i] = gate.constituentFreezeUntil(constituentIds[i]);
            }
            address[] memory tokens = feedTokens();
            uint256 n = tokens.length < SNAP_MAX_ASSETS ? tokens.length : SNAP_MAX_ASSETS;
            for (uint256 i; i < n; ++i) {
                try feeds.acceptedAnswer(tokens[i]) returns (SnapFeeds.Accepted memory answer) {
                    state.acceptedAnswer[i] = answer.answerUsd8;
                    state.acceptedUpdatedAt[i] = answer.updatedAt;
                    state.acceptedRoundId[i] = answer.roundId;
                } catch {}
                try feeds.pendingAnswer(tokens[i]) returns (SnapFeeds.Pending memory answer) {
                    state.pendingRoundId[i] = answer.roundId;
                } catch {}
            }
        }
    }

    /// @dev One pool's ladder into slot `index`. Never reverts: a pool with no records writes nothing.
    function _takeLadder(State storage state, SnapPoolId poolId, uint256 index) private {
        uint256 n = vault.ladderLength(poolId);
        state.ladderLength[index] = n;
        state.lastPlacementAt[index] = vault.lastPlacementAt(poolId);
        if (n > SNAP_CELLS) n = SNAP_CELLS;
        for (uint256 i; i < n; ++i) {
            (int24 lowerTick, int24 upperTick, uint128 liquidity,,, bool above,,,,) = vault.ladderAt(poolId, i);
            state.lower[index][i] = lowerTick;
            state.upper[index][i] = upperTick;
            state.liquidity[index][i] = liquidity;
            state.above[index][i] = above;
        }
    }

    /// @dev The AMPS each of {snapshotPool}'s live cells holds at its own range, i.e. its unfilled ask inventory.
    function _takeCellAmps(State storage state, SnapPoolId poolId) private {
        SnapRecord[] memory records = ladderOf(poolId);
        uint256 n = records.length < SNAP_CELLS ? records.length : SNAP_CELLS;
        for (uint256 i; i < n; ++i) {
            state.cellAmps[i] = records[i].above ? askAmpsIn(records[i]) : 0;
        }
    }

    // ―――――――――――――――――――― Reads that cannot revert ―――――――――――――――

    /// @dev `IERC20.balanceOf` through a raw `staticcall`: a paused issuer beacon or a hostile collateral must not
    ///      be able to make a snapshot revert.
    function _balanceOf(address token, address who) internal view returns (uint256 amount) {
        if (token == address(0)) return 0;
        (bool ok, bytes memory data) = token.staticcall(abi.encodeWithSelector(SnapIERC20.balanceOf.selector, who));
        if (ok && data.length >= 32) return abi.decode(data, (uint256));
        return 0;
    }

    /// @dev The ERC-6909 claim `who` holds of `token` at the PoolManager.
    function _claim(address who, address token) internal view returns (uint256 amount) {
        if (token == address(0) || who == address(0)) return 0;
        try SnapPM(address(poolManager)).balanceOf(who, SnapCurrency.wrap(token).toId()) returns (uint256 v) {
            return v;
        } catch {
            return 0;
        }
    }

    /// @dev The feed registry's 18-decimal answer, or zero when it cannot price the token.
    function _priceUsd18(address token) internal view returns (uint256 price) {
        try feeds.priceUsd18(token) returns (uint256 v) {
            return v;
        } catch {
            return 0;
        }
    }

    /// @dev The pool's live tick. `getSlot0` is an `extsload` and answers for any pool, initialised or not.
    function _tickOrZero(SnapPoolId poolId) internal view returns (int24 tick) {
        return tickOf(poolId);
    }

    /// @dev The pool's live sqrt price.
    function _sqrtOrZero(SnapPoolId poolId) internal view returns (uint160 sqrtPriceX96) {
        return sqrtPriceOf(poolId);
    }
}
