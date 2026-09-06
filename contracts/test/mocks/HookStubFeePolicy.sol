// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IFeePolicy} from "../../src/interfaces/IFeePolicy.sol";
import {Constants} from "../../src/types/Constants.sol";
import {PoolClass, Session} from "../../src/types/Types.sol";

/// @title HookStubFeePolicy
/// @notice The pure fee law `AmpsHook` points at in the hook suites, plus the fault switches those suites need.
///
/// @dev **Deliberately not `is IFeePolicy`.** `IFeePolicy.quoteFee` is declared `pure`, and an implementation may
///      only make a mutability *stricter*, so a conforming policy can never read a settable coefficient. The hook
///      calls its policy through `abi.encodeCall(IFeePolicy.quoteFee, ...)` on a plain `staticcall`, so selector
///      compatibility is all that is required — and dropping the inheritance is what lets this stub expose
///      `setKVolX18`, `setReverts` and the rest. The real `src/policy/FeePolicy.sol` implements the interface.
///
/// @dev **The law implemented here is §1.4 step 5 and §5 of `docs/phase3-state-model.md`:**
///      `f_dev = K_DEV_BPS * dev^2 / 1e4` inside the band, a quadratic ramp to `F_WALL_BPS` between band and
///      rail, `refuse` beyond it, and `f_dev == 0` on a swap that is not deviation-increasing;
///      `f_vol = min(K_VOL_X18 * varianceX18 / 1e36, F_VOL_CAP_BPS)`; `f_div` only in the direction that takes
///      stock out; `f_session` 0/5/10/25 bp; a surge on a 60-second half-life and a capture on a 300-second one.
contract HookStubFeePolicy {
    /// @notice `k_vol`. Settable because the landed `uint64 varianceX18` cannot carry a value large enough for
    ///         the launch coefficient to produce a non-zero `f_vol`; see `test/unit/AmpsHookFee.t.sol`.
    uint256 public kVolX18 = Constants.K_VOL_X18;

    /// @notice `k_dev`, the in-band deviation coefficient.
    uint16 public kDevBps = Constants.K_DEV_BPS;

    /// @notice The fee at the rail, where the ramp tops out.
    uint16 public fWallBps = Constants.F_WALL_BPS;

    /// @notice When set, every entry point reverts. Fault injection for I15.
    bool public reverts;

    /// @notice When set, every entry point returns one byte instead of an ABI-encoded value.
    bool public returnsGarbage;

    /// @notice When set, every entry point burns gas until its allowance runs out.
    bool public burnsGas;

    /// @notice When non-zero, {innerBandTicks} answers this instead of the session table.
    int24 public bandOverride;

    /// @notice When non-zero, {outerRailTicks} answers this instead of the class rule.
    int24 public railOverride;

    /// @notice Forces `dynBps` to this value, whatever the law would have said. `type(uint16).max` disables it.
    uint16 public dynOverride = type(uint16).max;

    function setKVolX18(uint256 value) external {
        kVolX18 = value;
    }

    function setKDevBps(uint16 value) external {
        kDevBps = value;
    }

    function setReverts(bool value) external {
        reverts = value;
    }

    function setReturnsGarbage(bool value) external {
        returnsGarbage = value;
    }

    function setBurnsGas(bool value) external {
        burnsGas = value;
    }

    function setBandOverride(int24 value) external {
        bandOverride = value;
    }

    function setRailOverride(int24 value) external {
        railOverride = value;
    }

    function setDynOverride(uint16 value) external {
        dynOverride = value;
    }

    /// @notice The whole dynamic fee law, with the same selector as `IFeePolicy.quoteFee`.
    /// @param input The swap, the pool and the armed state, exactly as the hook assembles it.
    /// @return quote The fee decomposition. Only `dynBps` is read by the hook; the base fee, the rotation credit
    ///         and the rail are the hook's own (§1.4).
    function quoteFee(IFeePolicy.FeeInput calldata input) external view returns (IFeePolicy.FeeQuote memory quote) {
        _fault();

        uint256 dyn = fVol(input.varianceX18);
        dyn += fDev(input.devTicks, input.innerBandTicks, input.outerRailTicks, input.deviationIncreasing);
        if (input.captureDirectionTakesStock) dyn += captureDecay(input.captureFeeBps, input.captureElapsed);
        dyn += fSession(input.poolClass, input.session);
        dyn += surgeDecay(input.surgeBps, input.surgeElapsed);

        if (dynOverride != type(uint16).max) dyn = dynOverride;
        if (dyn > input.dynCapBps) dyn = input.dynCapBps;

        quote.dynBps = uint16(dyn);
        quote.baseBps = input.zeroForOne ? input.sellFeeBps : input.buyFeeBps;
        quote.refuse = input.deviationIncreasing && input.devTicks > input.outerRailTicks;
        quote.feePips = uint24(uint256(quote.baseBps) + dyn) * Constants.PIPS_PER_BPS;
    }

    /// @notice `f_vol = min(k_vol * varianceX18 / 1e36, F_VOL_CAP_BPS)`.
    /// @param varianceX18 The EWMA variance.
    /// @return bps The volatility component.
    function fVol(uint128 varianceX18) public view returns (uint256 bps) {
        bps = (kVolX18 * uint256(varianceX18)) / 1e36;
        if (bps > Constants.F_VOL_CAP_BPS) bps = Constants.F_VOL_CAP_BPS;
    }

    /// @notice `f_dev`: quadratic inside the band, a quadratic ramp to `F_WALL_BPS` between band and rail, and
    ///         nothing at all on a swap that reduces the deviation.
    /// @param devTicks The deviation.
    /// @param bandTicks The inner band half-width.
    /// @param railTicks The outer rail half-width.
    /// @param increasing Whether the swap increases the deviation.
    /// @return bps The deviation component.
    function fDev(int24 devTicks, int24 bandTicks, int24 railTicks, bool increasing) public view returns (uint256 bps) {
        if (!increasing || devTicks <= 0) return 0;
        uint256 dev = uint256(uint24(devTicks));
        uint256 band = bandTicks <= 0 ? 1 : uint256(uint24(bandTicks));
        uint256 rail = railTicks <= 0 ? band + 1 : uint256(uint24(railTicks));

        uint256 inner = (uint256(kDevBps) * band * band) / Constants.BPS;
        if (dev <= band) return (uint256(kDevBps) * dev * dev) / Constants.BPS;
        if (dev >= rail) return fWallBps;

        uint256 span = rail - band;
        uint256 over = dev - band;
        return inner + ((fWallBps - inner) * over * over) / (span * span);
    }

    /// @notice `f_session`: stock legs only, 0/5/10/25 bp by session.
    /// @param poolClass The pool's class.
    /// @param session The equity session.
    /// @return bps The session component.
    function fSession(PoolClass poolClass, Session session) public pure returns (uint256 bps) {
        if (poolClass == PoolClass.ENTRY) return 0;
        if (session == Session.PRE_POST) return Constants.F_SESSION_PRE_POST_BPS;
        if (session == Session.OVERNIGHT) return Constants.F_SESSION_OVERNIGHT_BPS;
        if (session == Session.CLOSED) return Constants.F_SESSION_CLOSED_BPS;
        return Constants.F_SESSION_REGULAR_BPS;
    }

    /// @notice The inner band half-width, monotone non-decreasing in closedness (I19).
    /// @param poolClass The pool's class.
    /// @param session The equity session.
    /// @param closedHours How long the market has been closed.
    /// @return ticks The half-width.
    function innerBandTicks(PoolClass poolClass, Session session, uint16 closedHours)
        external
        view
        returns (int24 ticks)
    {
        _fault();
        if (bandOverride != 0) return bandOverride;
        // Entry-pool legs trade 24/7, so their band never widens with the equity calendar.
        if (poolClass == PoolClass.ENTRY) return Constants.INNER_BAND_REGULAR_TICKS;
        if (session == Session.PRE_POST) return Constants.INNER_BAND_PRE_POST_TICKS;
        if (session == Session.OVERNIGHT) return Constants.INNER_BAND_OVERNIGHT_TICKS;
        if (session == Session.CLOSED) {
            int256 widened = int256(Constants.INNER_BAND_CLOSED_TICKS)
                + int256(Constants.INNER_BAND_CLOSED_TICKS_PER_HOUR) * int256(uint256(closedHours));
            return widened > Constants.INNER_BAND_MAX_TICKS ? Constants.INNER_BAND_MAX_TICKS : int24(widened);
        }
        return Constants.INNER_BAND_REGULAR_TICKS;
    }

    /// @notice The outer rail half-width: a flat 2,000 ticks for entry pools, `max(3 x band, 800)` for spokes.
    /// @param poolClass The pool's class.
    /// @param innerBand The band the rail is derived from.
    /// @return ticks The half-width.
    function outerRailTicks(PoolClass poolClass, int24 innerBand) external view returns (int24 ticks) {
        _fault();
        if (railOverride != 0) return railOverride;
        if (poolClass == PoolClass.ENTRY) return Constants.OUTER_RAIL_ENTRY_TICKS;
        int24 scaled = innerBand * Constants.OUTER_RAIL_BAND_MULTIPLE;
        return scaled < Constants.OUTER_RAIL_MIN_TICKS ? Constants.OUTER_RAIL_MIN_TICKS : scaled;
    }

    /// @notice Halving decay on the surge's 60-second half-life, zero at eight of them.
    /// @param armedBps The surge as armed.
    /// @param elapsed Seconds since it was armed.
    /// @return bps What is left of it.
    function surgeDecay(uint16 armedBps, uint32 elapsed) public pure returns (uint16 bps) {
        return _decay(armedBps, elapsed, Constants.SURGE_HALF_LIFE);
    }

    /// @notice The same shape on the dividend capture's 300-second half-life.
    /// @param armedBps The capture fee as armed.
    /// @param elapsed Seconds since it was armed.
    /// @return bps What is left of it.
    function captureDecay(uint16 armedBps, uint32 elapsed) public pure returns (uint16 bps) {
        return _decay(armedBps, elapsed, Constants.DIVIDEND_CAPTURE_HALF_LIFE);
    }

    function F_MIN_BPS() external pure returns (uint16) {
        return Constants.F_MIN_BPS;
    }

    function DYN_CAP_NORMAL_BPS() external pure returns (uint16) {
        return Constants.DYN_CAP_NORMAL_BPS;
    }

    function DYN_CAP_DEGRADED_BPS() external pure returns (uint16) {
        return Constants.DYN_CAP_DEGRADED_BPS;
    }

    function DYN_CAP_ESCALATION_BPS() external pure returns (uint16) {
        return Constants.DYN_CAP_ESCALATION_BPS;
    }

    function SURGE_MAX_BPS() external pure returns (uint16) {
        return Constants.SURGE_MAX_BPS;
    }

    function F_VOL_CAP_BPS() external pure returns (uint16) {
        return Constants.F_VOL_CAP_BPS;
    }

    function TOTAL_FEE_BPS_MAX() external pure returns (uint16) {
        return Constants.TOTAL_FEE_BPS_MAX;
    }

    function FROZEN_FEE_FLOOR_BPS() external pure returns (uint16) {
        return Constants.FROZEN_FEE_FLOOR_BPS;
    }

    function K_VOL_X18() external view returns (uint256) {
        return kVolX18;
    }

    function K_DEV_BPS() external view returns (uint16) {
        return kDevBps;
    }

    function F_WALL_BPS() external view returns (uint16) {
        return fWallBps;
    }

    function LAMBDA_X18() external pure returns (uint64) {
        return Constants.LAMBDA_X18;
    }

    function version() external pure returns (bytes32) {
        return "HookStubFeePolicy.v1";
    }

    /// @dev Halving decay with linear interpolation inside the current half-life; zero past eight of them.
    function _decay(uint16 armedBps, uint32 elapsed, uint32 halfLife) private pure returns (uint16 bps) {
        if (armedBps == 0 || halfLife == 0) return 0;
        uint256 halves = elapsed / halfLife;
        if (halves >= 8) return 0;
        uint256 value = uint256(armedBps) >> halves;
        uint256 next = value >> 1;
        uint256 fraction = elapsed % halfLife;
        return uint16(value - ((value - next) * fraction) / halfLife);
    }

    /// @dev The three fault modes, in the order a hook meets them: a plain revert, an out-of-gas, and a return
    ///      too short to decode. The third is the one `try`/`catch` cannot survive.
    function _fault() private view {
        require(!reverts, "HookStubFeePolicy: reverting");
        if (burnsGas) {
            uint256 acc;
            for (uint256 i = 0; i < 1_000_000; ++i) {
                acc = uint256(keccak256(abi.encode(acc, i)));
            }
        }
        if (returnsGarbage) {
            assembly ("memory-safe") {
                return(0, 1)
            }
        }
    }
}
