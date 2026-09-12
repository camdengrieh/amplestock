// SPDX-License-Identifier: MIT
pragma solidity >=0.6.2 <0.9.0;

import "../Base.sol";
import {Properties} from "../Properties.sol";

/// @notice Handles the interaction with `OracleGate`: the permissionless stamps and the guardian's freezes, plus the
///         environment actions that are what actually make the gate's states reachable.
///
/// @dev **Two dispatchers, not one.** {oracleGate_secondary} is the gate's own selected surface — four
///      permissionless pokes and four guardian freeze/unfreeze calls. {env_secondary} is the world around it: the
///      clock, the Chainlink answers, the Stock Tokens' display multipliers and the issuer-side oracle pause. They
///      are separated because the environment actions are the *precondition* for the gate ever leaving `OK`:
///      `DEGRADED` needs a stale or paused feed, `DIVERGED` needs a moved answer, and the layer-A watchdog needs a
///      clock that ran. Keeping them in their own dispatcher gives each one a quarter of that dispatcher's calls
///      instead of an eighth of a combined one.
///
/// @dev **Roles.** `poke`, `pokePool`, `pokePools` and `pokeConstituent` are permissionless and are called as the
///      actor. `freezeConstituent` and `freezeProtocol` are `onlyGuardian`; `unfreezeConstituent` and
///      `unfreezeProtocol` are guardian-or-timelock and are called as the guardian. The Stock Tokens are owned by
///      this contract (it deployed them), so the multiplier and pause pokes need no prank.
///
/// @dev **SP-58's NAV leg is deliberately not asserted here.** A freeze or an unfreeze changes which price source
///      the NAV walk is allowed to read, so NAV/share moving across one of these calls is the design working, not a
///      value transfer. The supply and per-actor legs — the ones that would catch an actual transfer — are still
///      asserted, by passing a zero NAV pair, which the property reads as "no comparable basis".
abstract contract OracleGateHandler is Properties {
    // ――――――――――――――――――――――――― Clamped ――――――――――――――――――――――――――

    /// @notice The gate's own secondary surface.
    /// @param selector Chooses the action.
    /// @param seed Chooses the pool, constituent or freeze window.
    function oracleGate_secondary(uint8 selector, uint256 seed) public {
        ghosts.navClass = NAV_CLASS_MANAGEMENT;
        snapshotBefore();

        PoolId witness = poolFrom(seed);
        uint256 supplyBefore = amps.totalSupply();
        uint256[] memory actorsBefore = _actorAmps();
        uint32 divergedBefore = _divergedSince(witness);

        selector = uint8(selector % 8);
        if (selector == 0) _oracleGate_poke();
        else if (selector == 1) _oracleGate_pokePool(seed);
        else if (selector == 2) _oracleGate_pokePools();
        else if (selector == 3) _oracleGate_pokeConstituent(seed);
        else if (selector == 4) _oracleGate_freezeConstituent(seed, seed);
        else if (selector == 5) _oracleGate_unfreezeConstituent(seed);
        else if (selector == 6) _oracleGate_freezeProtocol(seed);
        else _oracleGate_unfreezeProtocol();

        snapshotAfter();

        // SP-01, SP-54 and the value-transfer half of SP-58.
        property_mintAttribution(supplyBefore, amps.totalSupply(), 0);
        property_divergenceTimerLatches(divergedBefore, _divergedSince(witness));
        property_governedSetterIsValueNeutral(supplyBefore, amps.totalSupply(), actorsBefore, _actorAmps(), 0, 0);
    }

    /// @notice The environment: the clock, the feeds, the display multipliers and the issuer's beacon switch. Every
    ///         gate state below `OK` is reached through one of these.
    /// @param selector Chooses the action.
    /// @param aSeed First seed: the interval, or the constituent.
    /// @param bSeed Second seed: the size of the move.
    function env_secondary(uint8 selector, uint256 aSeed, uint256 bSeed) public {
        snapshotBefore();
        uint256 supplyBefore = amps.totalSupply();

        selector = uint8(selector % 4);
        if (selector == 0) _env_warp(aSeed);
        else if (selector == 1) _env_moveFeed(aSeed, bSeed);
        else if (selector == 2) _env_stepMultiplier(aSeed, bSeed);
        else _env_pauseIssuerOracle(aSeed, bSeed % 2 == 0);

        snapshotAfter();
        _noteNarrowTypeHighs();

        // SP-01: nothing in the environment is a mint site.
        property_mintAttribution(supplyBefore, amps.totalSupply(), 0);
    }

    /// @notice Many compounding upward feed steps in one call, so the narrow-type boundaries GL-62 is about are
    ///         reachable inside a bounded fuzzer campaign rather than only after thousands of single steps.
    /// @dev New in this pass — see the "Handlers to add" table of `fizz_data/property-plan.md`.
    /// @param iSeed Chooses the stock.
    /// @param stepsSeed Chooses how many steps, 2 to 12.
    function env_walkFeedToExtreme(uint256 iSeed, uint256 stepsSeed) public {
        uint256 i = iSeed % stocks.length;
        uint256 steps = clampBetween(stepsSeed, 2, 12);
        uint256 supplyBefore = amps.totalSupply();

        for (uint256 s; s < steps; ++s) {
            uint128 current = stockUsd8[i];
            // +19.99%, which is the largest single move `_env_moveFeed` can make, applied over and over.
            uint256 moved = uint256(current) * (Constants.BPS + 1999) / Constants.BPS;
            if (moved > type(uint128).max / 2) break;
            if (moved == current) moved = current + 1;
            setStockPrice(i, uint128(moved));
            advance(Constants.ONE_HOUR);
        }

        _noteNarrowTypeHighs();

        // SP-01.
        property_mintAttribution(supplyBefore, amps.totalSupply(), 0);
    }

    // ―――――――――――――――――――――――― Unclamped ―――――――――――――――――――――――――

    /// @dev Layer A's stamp. Permissionless.
    function _oracleGate_poke() internal asActor {
        gate.poke();
    }

    /// @dev Layer A plus one pool's divergence timer.
    function _oracleGate_pokePool(uint256 poolSeed) internal asActor {
        gate.pokePool(poolFrom(poolSeed));
    }

    /// @dev Layer A plus every pool's divergence timer in one call — the unbounded-gas shape the single-pool
    ///      variant exists to avoid.
    function _oracleGate_pokePools() internal asActor {
        gate.pokePools(pools);
    }

    /// @dev Layer A, one pool's divergence and one name's corporate-action freeze.
    function _oracleGate_pokeConstituent(uint256 idSeed) internal asActor {
        gate.pokeConstituent(constituentFrom(idSeed));
    }

    /// @dev A guardian freeze on one name, inside `[now + 1, now + GUARDIAN_FREEZE_MAX_SECONDS]`.
    function _oracleGate_freezeConstituent(uint256 idSeed, uint256 untilSeed) internal asGuardian {
        gate.freezeConstituent(
            constituentFrom(idSeed),
            uint32(
                clampBetween(untilSeed, block.timestamp + 1, block.timestamp + Constants.GUARDIAN_FREEZE_MAX_SECONDS)
            )
        );
    }

    /// @dev Lifts one name's freeze.
    function _oracleGate_unfreezeConstituent(uint256 idSeed) internal asGuardian {
        gate.unfreezeConstituent(constituentFrom(idSeed));
    }

    /// @dev A guardian freeze on the whole protocol, inside the same window.
    function _oracleGate_freezeProtocol(uint256 untilSeed) internal asGuardian {
        gate.freezeProtocol(
            uint32(
                clampBetween(untilSeed, block.timestamp + 1, block.timestamp + Constants.GUARDIAN_FREEZE_MAX_SECONDS)
            )
        );
    }

    /// @dev Lifts the protocol freeze.
    function _oracleGate_unfreezeProtocol() internal asGuardian {
        gate.unfreezeProtocol();
    }

    /// @dev Moves the clock forward up to three hours, produces blocks with it and republishes every aggregator, so
    ///      the layer-A watchdog sees a chain that kept running and the feeds stay inside their heartbeat. Without
    ///      this the fuzzer's own block delays leave every feed stale within one sequence.
    function _env_warp(uint256 dtSeed) internal {
        warpBy(clampBetween(dtSeed, 1, 3 * uint256(Constants.ONE_HOUR)));
    }

    /// @dev Repoints one Chainlink answer by up to +/-10%, permanently: {Phase3Fixture-refreshFeeds} republishes the
    ///      new value from then on, so a move stays moved and the divergence timer can actually arm.
    function _env_moveFeed(uint256 iSeed, uint256 bpsSeed) internal {
        uint256 i = iSeed % stocks.length;
        uint256 bps = clampBetween(bpsSeed, 1, 2000);
        uint128 current = stockUsd8[i];
        uint128 moved = bps < 1000
            ? uint128(uint256(current) * (Constants.BPS - bps) / Constants.BPS)
            : uint128(uint256(current) * (Constants.BPS + bps - 1000) / Constants.BPS);
        if (moved == 0) moved = 1;

        setStockPrice(i, moved);
    }

    /// @dev Steps one Stock Token's display multiplier: a dividend reinvestment, or a split. Value-neutral on
    ///      chain, which is exactly why it is the corporate-action window's trigger rather than a price move.
    function _env_stepMultiplier(uint256 iSeed, uint256 bpsSeed) internal {
        uint256 i = iSeed % stocks.length;
        uint256 bps = clampBetween(bpsSeed, 1, 5000);
        uint256 current = stocks[i].uiMultiplier();

        stocks[i].setUIMultiplier(current + current * bps / Constants.BPS);
    }

    /// @dev Switches one issuer's beacon off and on, which is the `DEGRADED` path that no amount of warping
    ///      reaches: the answer is fresh, the issuer says it is unavailable.
    function _env_pauseIssuerOracle(uint256 iSeed, bool paused) internal {
        stocks[iSeed % stocks.length].setOraclePaused(paused);
    }

    // ―――――――――――――――― Reads that must not revert ――――――――――――――――

    /// @dev `gate.divergedSince`, or zero.
    function _divergedSince(PoolId poolId) private view returns (uint32 since) {
        try gate.divergedSince(poolId) returns (uint32 v) {
            return v;
        } catch {
            return 0;
        }
    }

    /// @dev The two narrow-type high-water marks GL-62 measures against.
    function _noteNarrowTypeHighs() private {
        uint256 nav = _tryNavPerShare();
        if (nav > ghosts.maxNavPerShareSeen) ghosts.maxNavPerShareSeen = nav;
        try vault.pRefX18() returns (uint256 p) {
            if (p > ghosts.maxPRefSeen) ghosts.maxPRefSeen = p;
        } catch {}
    }
}
