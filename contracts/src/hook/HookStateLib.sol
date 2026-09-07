// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {PoolClass, Session} from "../types/Types.sol";

/// @title HookStateLib
/// @notice The three packed words `AmpsHook` keeps per pool, and nothing else.
///
/// @dev **Why a library.** `docs/phase3-state-model.md` §1.2 fixes the bit layout of the CONFIG, DYNAMIC and ARMED
///      words, and `beforeSwap` is budgeted at exactly three cold `SLOAD`s. Keeping the shifts in one place means
///      the hot path and the `poolState()` view cannot drift apart, and it makes the packing directly fuzzable
///      (`test/unit/AmpsHook.t.sol`) without a pool, a PoolManager or a swap.
///
/// @dev **Layouts** (bit ranges are inclusive, low bits first, exactly as §1.2 gives them):
///
///      ```
///      CONFIG _cfg                          DYNAMIC _dyn                        ARMED _arm
///      [  0.. 15] uint16 buyFeeBps          [  0.. 23] int24  lastTick          [  0.. 15] uint16 surgeBps
///      [ 16.. 31] uint16 constituentId      [ 24.. 55] uint32 lastUpdate        [ 16.. 47] uint32 surgeArmedAt
///      [ 32.. 39] uint8  poolClass          [ 56.. 79] int24  fairTick          [ 48.. 63] uint16 captureFeeBps
///      [ 40.. 63] int24  tickSpacing        [ 80..103] int24  innerBandTicks    [ 64.. 95] uint32 captureArmedAt
///      [ 64.. 87] int24  maxTickMovePerBlock[104..127] int24  outerRailTicks    [ 96..159] uint64 uiMultiplierX18
///      [ 88.. 95] uint8  counterDecimals    [128..143] uint16 dynCapBps         [160..223] uint64 varianceX12
///      [ 96..119] int24  gridBaseTick       [144..151] uint8  session           [224..255] uint32 lastCorporateCheck
///      [120..127] bool   initialized        [152..159] uint8  gateFlags
///                                           [160..167] uint8  fVolBps
///                                           [168..199] uint32 gateRefreshedAt
///                                           [200..231] uint32 gateAttemptedAt
///      ```
///
/// @dev **`gateAttemptedAt` is the one field §1.2 does not name.** §1.2 leaves DYNAMIC `[200..255]` free and §1.5
///      step 6 refreshes the gate cache "at most once per `_gateCacheSeconds`", while §1.4 step 6 substitutes the
///      most conservative values once the cache is older than `GATE_CACHE_MAX_AGE`. Those two rules need two
///      timestamps, not one: if a failing refresh advanced `gateRefreshedAt` the cache would never look stale, and
///      if it advanced nothing the hook would re-attempt a failing external call on every single swap. So
///      `gateRefreshedAt` records the last **successful** refresh (what `beforeSwap` ages) and `gateAttemptedAt`
///      the last attempt of any kind (what rate-limits the call). No other field moved.
library HookStateLib {
    /// @dev `gateFlags` bit 0: the gate reported anything other than `GateState.GREEN`.
    uint8 internal constant FLAG_DEGRADED = 1;

    /// @dev `gateFlags` bit 1: a corporate action is in force on this pool's constituent.
    uint8 internal constant FLAG_CORPORATE_FREEZE = 2;

    /// @dev `gateFlags` bit 2: the last gate-cache refresh failed and the values below it are the previous ones.
    uint8 internal constant FLAG_REFRESH_FAILED = 4;

    /// @dev `gateFlags` bit 3: a `uiMultiplier()` step larger than `DIVIDEND_STEP_BPS_MAX` was observed.
    uint8 internal constant FLAG_CA_ARMED = 8;

    uint256 private constant MASK_8 = 0xff;
    uint256 private constant MASK_16 = 0xffff;
    uint256 private constant MASK_24 = 0xffffff;
    uint256 private constant MASK_32 = 0xffffffff;
    uint256 private constant MASK_64 = 0xffffffffffffffff;

    /// @notice The CONFIG word: everything written once at `afterInitialize` and thereafter only by governance.
    struct Config {
        uint16 buyFeeBps;
        uint16 constituentId;
        PoolClass poolClass;
        int24 tickSpacing;
        int24 maxTickMovePerBlock;
        uint8 counterDecimals;
        int24 gridBaseTick;
        bool initialized;
    }

    /// @notice The DYNAMIC word: the post-swap tick, the cached gate view and the pre-computed `f_vol`.
    struct Dynamic {
        int24 lastTick;
        uint32 lastUpdate;
        int24 fairTick;
        int24 innerBandTicks;
        int24 outerRailTicks;
        uint16 dynCapBps;
        Session session;
        uint8 gateFlags;
        uint8 fVolBps;
        uint32 gateRefreshedAt;
        uint32 gateAttemptedAt;
    }

    /// @notice The ARMED word: the two decaying fees, the multiplier cache and the EWMA variance.
    ///
    /// @dev **`varianceX12` is the one field whose unit is not its name's.** `IFeePolicy.FeeInput.varianceX18` is
    ///      `EWMA(d^2) x 1e18` with `d` the raw tick change of one swap (§12.1 ruling H), and at the 100 bp cap
    ///      that is `141^2 x 1e18` ~ 2e22 - which does not fit the 64 bits §1.2 gives this field. The store is
    ///      therefore **X12** (`EWMA(d^2) x 1e12`, so up to 1.8e7 ticks^2 before it saturates, against a maximum
    ///      reachable `d^2` of ~3.1e12), and `AmpsHook` multiplies by `VARIANCE_SCALE_TO_X18 = 1e6` on the way
    ///      into `FeeInput` and into `f_vol`. Widening the packed field was the alternative and does not fit: the
    ///      ARMED word is full and DYNAMIC has 24 free bits, so the value would have to straddle two words.
    struct Armed {
        uint16 surgeBps;
        uint32 surgeArmedAt;
        uint16 captureFeeBps;
        uint32 captureArmedAt;
        uint64 uiMultiplierX18;
        uint64 varianceX12;
        uint32 lastCorporateCheck;
    }

    /// @notice Packs a {Config} into its storage word.
    /// @param c The config.
    /// @return word The packed word.
    function packConfig(Config memory c) internal pure returns (uint256 word) {
        word = uint256(c.buyFeeBps) | (uint256(c.constituentId) << 16) | (uint256(uint8(c.poolClass)) << 32)
            | (uint256(uint24(c.tickSpacing)) << 40) | (uint256(uint24(c.maxTickMovePerBlock)) << 64)
            | (uint256(c.counterDecimals) << 88) | (uint256(uint24(c.gridBaseTick)) << 96)
            | (uint256(c.initialized ? 1 : 0) << 120);
    }

    /// @notice Unpacks a CONFIG storage word.
    /// @param word The packed word.
    /// @return c The config.
    function unpackConfig(uint256 word) internal pure returns (Config memory c) {
        c.buyFeeBps = uint16(word & MASK_16);
        c.constituentId = uint16((word >> 16) & MASK_16);
        c.poolClass = PoolClass(uint8((word >> 32) & MASK_8));
        c.tickSpacing = int24(uint24((word >> 40) & MASK_24));
        c.maxTickMovePerBlock = int24(uint24((word >> 64) & MASK_24));
        c.counterDecimals = uint8((word >> 88) & MASK_8);
        c.gridBaseTick = int24(uint24((word >> 96) & MASK_24));
        c.initialized = ((word >> 120) & MASK_8) != 0;
    }

    /// @notice `true` when the pool's CONFIG word has been written by `afterInitialize`.
    /// @dev One shift instead of a full unpack, for the `beforeSwap` guard.
    /// @param word The packed CONFIG word.
    /// @return yes Whether the pool is known to the hook.
    function isInitialized(uint256 word) internal pure returns (bool yes) {
        yes = ((word >> 120) & MASK_8) != 0;
    }

    /// @notice The grid origin out of a CONFIG word, without unpacking the rest.
    /// @dev `PoolRegistry._openPool` reads this back through `IAmpsHook.gridBaseTick` on the line after
    ///      `initializePool`, so it must be cheap and it must never revert.
    /// @param word The packed CONFIG word.
    /// @return tick The grid origin, or 0 for a pool the hook has never initialised.
    function gridBaseTick(uint256 word) internal pure returns (int24 tick) {
        tick = int24(uint24((word >> 96) & MASK_24));
    }

    /// @notice Packs a {Dynamic} into its storage word.
    /// @param d The dynamic state.
    /// @return word The packed word.
    function packDynamic(Dynamic memory d) internal pure returns (uint256 word) {
        word = uint256(uint24(d.lastTick)) | (uint256(d.lastUpdate) << 24) | (uint256(uint24(d.fairTick)) << 56)
            | (uint256(uint24(d.innerBandTicks)) << 80) | (uint256(uint24(d.outerRailTicks)) << 104)
            | (uint256(d.dynCapBps) << 128) | (uint256(uint8(d.session)) << 144) | (uint256(d.gateFlags) << 152)
            | (uint256(d.fVolBps) << 160) | (uint256(d.gateRefreshedAt) << 168) | (uint256(d.gateAttemptedAt) << 200);
    }

    /// @notice Unpacks a DYNAMIC storage word.
    /// @param word The packed word.
    /// @return d The dynamic state.
    function unpackDynamic(uint256 word) internal pure returns (Dynamic memory d) {
        d.lastTick = int24(uint24(word & MASK_24));
        d.lastUpdate = uint32((word >> 24) & MASK_32);
        d.fairTick = int24(uint24((word >> 56) & MASK_24));
        d.innerBandTicks = int24(uint24((word >> 80) & MASK_24));
        d.outerRailTicks = int24(uint24((word >> 104) & MASK_24));
        d.dynCapBps = uint16((word >> 128) & MASK_16);
        d.session = Session(uint8((word >> 144) & MASK_8));
        d.gateFlags = uint8((word >> 152) & MASK_8);
        d.fVolBps = uint8((word >> 160) & MASK_8);
        d.gateRefreshedAt = uint32((word >> 168) & MASK_32);
        d.gateAttemptedAt = uint32((word >> 200) & MASK_32);
    }

    /// @notice Packs an {Armed} into its storage word.
    /// @param a The armed state.
    /// @return word The packed word.
    function packArmed(Armed memory a) internal pure returns (uint256 word) {
        word = uint256(a.surgeBps) | (uint256(a.surgeArmedAt) << 16) | (uint256(a.captureFeeBps) << 48)
            | (uint256(a.captureArmedAt) << 64) | (uint256(a.uiMultiplierX18) << 96) | (uint256(a.varianceX12) << 160)
            | (uint256(a.lastCorporateCheck) << 224);
    }

    /// @notice Unpacks an ARMED storage word.
    /// @param word The packed word.
    /// @return a The armed state.
    function unpackArmed(uint256 word) internal pure returns (Armed memory a) {
        a.surgeBps = uint16(word & MASK_16);
        a.surgeArmedAt = uint32((word >> 16) & MASK_32);
        a.captureFeeBps = uint16((word >> 48) & MASK_16);
        a.captureArmedAt = uint32((word >> 64) & MASK_32);
        a.uiMultiplierX18 = uint64((word >> 96) & MASK_64);
        a.varianceX12 = uint64((word >> 160) & MASK_64);
        a.lastCorporateCheck = uint32((word >> 224) & MASK_32);
    }

    /// @notice Whether a flag bit is set in a `gateFlags` byte.
    /// @param gateFlags The byte.
    /// @param flag One of the `FLAG_*` constants.
    /// @return set Whether it is set.
    function hasFlag(uint8 gateFlags, uint8 flag) internal pure returns (bool set) {
        set = (gateFlags & flag) != 0;
    }

    /// @notice Sets or clears a flag bit in a `gateFlags` byte.
    /// @param gateFlags The byte.
    /// @param flag One of the `FLAG_*` constants.
    /// @param on Whether to set it.
    /// @return updated The updated byte.
    function withFlag(uint8 gateFlags, uint8 flag, bool on) internal pure returns (uint8 updated) {
        updated = on ? gateFlags | flag : gateFlags & ~flag;
    }
}
