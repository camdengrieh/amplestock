// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IExtsload} from "@uniswap/v4-core/src/interfaces/IExtsload.sol";
import {IExttload} from "@uniswap/v4-core/src/interfaces/IExttload.sol";
import {FixedPoint128} from "@uniswap/v4-core/src/libraries/FixedPoint128.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @title PoolStateLib
/// @notice Amplestocks' own reader for Uniswap v4 `PoolManager` state, through the MIT `IExtsload` / `IExttload`
///         interfaces and slot arithmetic derived here from first principles.
///
/// @dev **Why this library exists at all.** `StateLibrary` and `TransientStateLibrary` do exactly this job, and
///      both files are MIT — but they import `Position.sol`, `Lock.sol`, `NonzeroDeltaCount.sol` and
///      `CurrencyReserves.sol`, every one of which is **BUSL-1.1**. Importing either from `contracts/src/**` puts
///      BUSL source in the production import graph and fails `scripts/licence-gate.py` (Decision 3). Everything
///      below is therefore written from scratch against *facts about the deployed contract's storage layout*,
///      which are not copyrightable expression; no BUSL code is imported, copied or ported. The test suite
///      (`test/unit/PoolStateLib.t.sol`, exempt from the gate because it never ships) differentially checks every
///      function here against the Uniswap libraries on a live local pool, which is what keeps the derivation
///      honest across dependency bumps.
///
/// @dev **Deriving the pools-mapping slot.** `PoolManager is IPoolManager, ProtocolFees, NoDelegateCall,
///      ERC6909Claims, Extsload, Exttload`. Solidity allocates state variables in C3-linearised order, most-base
///      first, and interfaces contribute nothing:
///
///      ```
///      Owned.owner                      -> slot 0     (ProtocolFees is Owned)
///      ProtocolFees.protocolFeesAccrued -> slot 1
///      ProtocolFees.protocolFeeController -> slot 2
///      NoDelegateCall                   -> immutables only, no slot
///      ERC6909.isOperator               -> slot 3     (ERC6909Claims is ERC6909)
///      ERC6909.balanceOf                -> slot 4
///      ERC6909.allowance                -> slot 5
///      Extsload / Exttload              -> no storage
///      PoolManager._pools               -> slot 6
///      ```
///
///      which matches `StateLibrary.POOLS_SLOT == 6`. {test_poolsMappingLivesAtSlotSix} re-derives it against a
///      live manager, without reading the BUSL source: exactly one candidate mapping slot hashes to a word whose
///      low 160 bits are the pool's live `sqrtPriceX96`, and it is 6.
///
/// @dev **`Pool.State` is seven consecutive slots** from `poolStateSlot(id)`:
///
///      ```
///      +0  slot0  sqrtPriceX96 [0..159] | tick [160..183] | protocolFee [184..207] | lpFee [208..231]
///      +1  feeGrowthGlobal0X128  uint256
///      +2  feeGrowthGlobal1X128  uint256
///      +3  liquidity             uint128, low 128 bits
///      +4  ticks       mapping base
///      +5  tickBitmap  mapping base
///      +6  positions   mapping base
///      ```
///
///      `TickInfo` is three words from `tickInfoSlot`: `+0` packs `liquidityGross [0..127]` with
///      `liquidityNet [128..255]` (recovered with `sar(128, word)`, an arithmetic shift because it is signed),
///      `+1` is `feeGrowthOutside0X128` and `+2` is `feeGrowthOutside1X128`. `Position.State` is three words from
///      `positionSlot`: `liquidity` (uint128, low bits), `feeGrowthInside0LastX128`, `feeGrowthInside1LastX128`.
///
/// @dev **Reads are batched wherever the manager allows it.** `extsload(bytes32,uint256)` fetches consecutive
///      slots in one staticcall and `extsload(bytes32[])` fetches sparse ones — the whole 24-cell ladder grid of a
///      pool is a single call through {positionLiquidityAtSlots}. Cold `SLOAD` dominates, so batching mainly saves
///      the ~2.6k of repeated call overhead, but it also makes every read of a multi-word struct atomic.
///
/// @dev **Nothing here reverts on unknown input.** An uninitialised pool, an unset tick and an empty position all
///      read as zero words and are returned as zeros, which is what `LadderPositionValuer` and the NAV path need:
///      a valuation must degrade to "worth nothing", never to a revert.
library PoolStateLib {
    // -------------------------------------------------------------------------------------------------------------
    // Layout constants
    // -------------------------------------------------------------------------------------------------------------

    /// @notice Slot of `PoolManager._pools`, the `mapping(PoolId => Pool.State)`. Derived in the library notes.
    bytes32 internal constant POOLS_SLOT = bytes32(uint256(6));

    /// @notice `Pool.State` offset of `feeGrowthGlobal0X128`; `feeGrowthGlobal1X128` is the next word.
    uint256 internal constant FEE_GROWTH_GLOBAL0_OFFSET = 1;

    /// @notice `Pool.State` offset of `liquidity` (uint128 in the low bits of its own word).
    uint256 internal constant LIQUIDITY_OFFSET = 3;

    /// @notice `Pool.State` offset of the `mapping(int24 => TickInfo) ticks` base slot.
    uint256 internal constant TICKS_OFFSET = 4;

    /// @notice `Pool.State` offset of the `mapping(int16 => uint256) tickBitmap` base slot.
    uint256 internal constant TICK_BITMAP_OFFSET = 5;

    /// @notice `Pool.State` offset of the `mapping(bytes32 => Position.State) positions` base slot.
    uint256 internal constant POSITIONS_OFFSET = 6;

    /// @notice Transient slot of the manager's unlock flag: `bytes32(uint256(keccak256("Unlocked")) - 1)`.
    /// @dev Hard-coded so no hashing happens on a read; {test_transientSlotsMatchTheirPreimages} re-derives it.
    bytes32 internal constant IS_UNLOCKED_SLOT = 0xc090fc4683624cfc3884e9d8de5eca132f2d0ec062aff75d43c0465d5ceeab23;

    /// @notice Transient slot of the open-delta counter: `bytes32(uint256(keccak256("NonzeroDeltaCount")) - 1)`.
    bytes32 internal constant NONZERO_DELTA_COUNT_SLOT =
        0x7d4b3164c6e45b97e7d87b7125a44c5828d005af88f9d751cfd78729c5d99a0b;

    /// @dev Low 128 bits, for narrowing a packed word to a `uint128` in assembly.
    uint256 private constant MASK_128 = 0xffffffffffffffffffffffffffffffff;

    /// @dev Low 160 bits, for recovering `sqrtPriceX96` out of `slot0`. Written with a leading zero byte so solc
    ///      reads it as a number rather than an address literal, and as a literal because inline assembly only
    ///      accepts direct number constants.
    uint256 private constant MASK_160 = 0x00ffffffffffffffffffffffffffffffffffffffff;

    /// @dev Low 24 bits, for the two fee fields of `slot0`.
    uint256 private constant MASK_24 = 0xffffff;

    // -------------------------------------------------------------------------------------------------------------
    // Slot arithmetic
    // -------------------------------------------------------------------------------------------------------------

    /// @notice Slot of `pools[id]`, i.e. of that pool's `slot0`.
    /// @param id The pool id.
    /// @return slot The first of the pool's seven `Pool.State` slots.
    function poolStateSlot(PoolId id) internal pure returns (bytes32 slot) {
        slot = _hashPair(PoolId.unwrap(id), POOLS_SLOT);
    }

    /// @notice Slot of `pools[id].ticks[tick]`, the first of that tick's three words.
    /// @dev The mapping key is `int24` but Solidity hashes mapping keys padded to 32 bytes, sign-extended for
    ///      signed types — hence `int256(tick)`, which is what makes negative ticks work.
    /// @param id The pool id.
    /// @param tick The tick.
    /// @return slot The tick's first word.
    function tickInfoSlot(PoolId id, int24 tick) internal pure returns (bytes32 slot) {
        bytes32 ticksBase = bytes32(uint256(poolStateSlot(id)) + TICKS_OFFSET);
        slot = _hashPair(bytes32(uint256(int256(tick))), ticksBase);
    }

    /// @notice Slot of `pools[id].tickBitmap[wordPos]`.
    /// @param id The pool id.
    /// @param wordPos The bitmap word position, `tick / tickSpacing >> 8`.
    /// @return slot The bitmap word's slot.
    function tickBitmapSlot(PoolId id, int16 wordPos) internal pure returns (bytes32 slot) {
        bytes32 bitmapBase = bytes32(uint256(poolStateSlot(id)) + TICK_BITMAP_OFFSET);
        slot = _hashPair(bytes32(uint256(int256(wordPos))), bitmapBase);
    }

    /// @notice Base slot of `pools[id].positions`, the mapping every position slot hangs off.
    /// @dev Exposed so a caller enumerating many positions in one pool (the ladder grid) derives it once.
    /// @param id The pool id.
    /// @return base The positions mapping's base slot.
    function positionsBaseSlot(PoolId id) internal pure returns (bytes32 base) {
        base = bytes32(uint256(poolStateSlot(id)) + POSITIONS_OFFSET);
    }

    /// @notice Slot of `pools[id].positions[key]` given a pre-derived positions base slot.
    /// @param base The value of {positionsBaseSlot} for the pool.
    /// @param key The position key, from {positionKey}.
    /// @return slot The position's first word.
    function positionSlotIn(bytes32 base, bytes32 key) internal pure returns (bytes32 slot) {
        slot = _hashPair(key, base);
    }

    /// @notice Slot of `pools[id].positions[key]`.
    /// @param id The pool id.
    /// @param key The position key, from {positionKey}.
    /// @return slot The position's first word.
    function positionSlot(PoolId id, bytes32 key) internal pure returns (bytes32 slot) {
        slot = positionSlotIn(positionsBaseSlot(id), key);
    }

    /// @notice Slot of the position `(owner, lower, upper, salt)` in `id`.
    /// @param id The pool id.
    /// @param owner The position owner, as the manager sees it (the vault, not a NFT position manager).
    /// @param lower The lower tick.
    /// @param upper The upper tick.
    /// @param salt The position salt. Amplestocks always uses `bytes32(0)` (ruling 12).
    /// @return slot The position's first word.
    function positionSlot(PoolId id, address owner, int24 lower, int24 upper, bytes32 salt)
        internal
        pure
        returns (bytes32 slot)
    {
        slot = positionSlot(id, positionKey(owner, lower, upper, salt));
    }

    /// @notice The v4 position key: `keccak256(abi.encodePacked(owner, tickLower, tickUpper, salt))`, 58 bytes.
    /// @dev Written in assembly to hash the 58 packed bytes without allocating: the four fields are laid out
    ///      end-to-end in scratch space above the free memory pointer (writing there is memory-safe — the memory
    ///      is unallocated and the pointer is not moved) and the scratch is zeroed afterwards. `abi.encodePacked`
    ///      of the same four values is byte-identical; {testFuzz_positionKeyMatchesV4} pins that against both
    ///      `abi.encodePacked` and v4's own `Position.calculatePositionKey`.
    /// @param owner The position owner (20 bytes).
    /// @param lower The lower tick (3 bytes, two's complement).
    /// @param upper The upper tick (3 bytes, two's complement).
    /// @param salt The salt (32 bytes).
    /// @return key The position key.
    function positionKey(address owner, int24 lower, int24 upper, bytes32 salt) internal pure returns (bytes32 key) {
        assembly ("memory-safe") {
            let fmp := mload(0x40)
            mstore(add(fmp, 0x26), salt) // [0x26, 0x46)
            mstore(add(fmp, 0x06), upper) // [0x23, 0x26) after the low 3 bytes land
            mstore(add(fmp, 0x03), lower) // [0x20, 0x23)
            mstore(fmp, owner) // [0x0c, 0x20)
            key := keccak256(add(fmp, 0x0c), 0x3a)

            // Leave the scratch as we found it: later `abi.encode`s and `keccak256`s reuse this region.
            mstore(add(fmp, 0x26), 0)
            mstore(add(fmp, 0x06), 0)
            mstore(fmp, 0)
        }
    }

    // -------------------------------------------------------------------------------------------------------------
    // Persistent reads
    // -------------------------------------------------------------------------------------------------------------

    /// @notice `pools[id].slot0`, unpacked. One `extsload`.
    /// @param manager The PoolManager (any `IExtsload`).
    /// @param id The pool id.
    /// @return sqrtPriceX96 The live sqrt price, Q64.96. Zero iff the pool was never initialised.
    /// @return tick The live tick, sign-extended from 24 bits.
    /// @return protocolFee The packed protocol fee.
    /// @return lpFee The live LP fee in pips, including any dynamic override the hook last wrote.
    function slot0(IExtsload manager, PoolId id)
        internal
        view
        returns (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee)
    {
        bytes32 word = manager.extsload(poolStateSlot(id));
        assembly ("memory-safe") {
            sqrtPriceX96 := and(word, MASK_160)
            tick := signextend(2, shr(160, word))
            protocolFee := and(shr(184, word), MASK_24)
            lpFee := and(shr(208, word), MASK_24)
        }
    }

    /// @notice `pools[id].slot0.sqrtPriceX96` and `.tick` only, for callers that do not need the fees.
    /// @param manager The PoolManager.
    /// @param id The pool id.
    /// @return sqrtPriceX96 The live sqrt price.
    /// @return tick The live tick.
    function sqrtPriceAndTick(IExtsload manager, PoolId id) internal view returns (uint160 sqrtPriceX96, int24 tick) {
        (sqrtPriceX96, tick,,) = slot0(manager, id);
    }

    /// @notice `pools[id].liquidity`: the in-range liquidity at the current tick. One `extsload`.
    /// @param manager The PoolManager.
    /// @param id The pool id.
    /// @return liquidity_ The pool's active liquidity.
    function liquidity(IExtsload manager, PoolId id) internal view returns (uint128 liquidity_) {
        bytes32 slot = bytes32(uint256(poolStateSlot(id)) + LIQUIDITY_OFFSET);
        liquidity_ = uint128(uint256(manager.extsload(slot)));
    }

    /// @notice Both global fee-growth accumulators. One batched `extsload` of two consecutive slots.
    /// @dev Global fee growth is trivially inflatable by an LP donating to itself, which is exactly why NAV never
    ///      reads it (§4: uncollected fees are excluded from `A`). It is here for `compound` and the dApp.
    /// @param manager The PoolManager.
    /// @param id The pool id.
    /// @return feeGrowthGlobal0X128 Currency0 fee growth per unit of liquidity, Q128.
    /// @return feeGrowthGlobal1X128 Currency1 fee growth per unit of liquidity, Q128.
    function feeGrowthGlobals(IExtsload manager, PoolId id)
        internal
        view
        returns (uint256 feeGrowthGlobal0X128, uint256 feeGrowthGlobal1X128)
    {
        bytes32 start = bytes32(uint256(poolStateSlot(id)) + FEE_GROWTH_GLOBAL0_OFFSET);
        bytes32[] memory words = manager.extsload(start, 2);
        feeGrowthGlobal0X128 = uint256(words[0]);
        feeGrowthGlobal1X128 = uint256(words[1]);
    }

    /// @notice A tick's whole `TickInfo`. One batched `extsload` of three consecutive slots.
    /// @param manager The PoolManager.
    /// @param id The pool id.
    /// @param tick The tick.
    /// @return liquidityGross Total position liquidity referencing this tick.
    /// @return liquidityNet Liquidity added when the tick is crossed left to right; signed.
    /// @return feeGrowthOutside0X128 Currency0 fee growth on the far side of the tick.
    /// @return feeGrowthOutside1X128 Currency1 fee growth on the far side of the tick.
    function tickInfo(IExtsload manager, PoolId id, int24 tick)
        internal
        view
        returns (
            uint128 liquidityGross,
            int128 liquidityNet,
            uint256 feeGrowthOutside0X128,
            uint256 feeGrowthOutside1X128
        )
    {
        bytes32[] memory words = manager.extsload(tickInfoSlot(id, tick), 3);
        bytes32 packed = words[0];
        assembly ("memory-safe") {
            liquidityGross := and(packed, MASK_128)
            liquidityNet := sar(128, packed)
        }
        feeGrowthOutside0X128 = uint256(words[1]);
        feeGrowthOutside1X128 = uint256(words[2]);
    }

    /// @notice A tick's gross and net liquidity only. One `extsload`.
    /// @param manager The PoolManager.
    /// @param id The pool id.
    /// @param tick The tick.
    /// @return liquidityGross Total position liquidity referencing this tick.
    /// @return liquidityNet Liquidity added when the tick is crossed left to right; signed.
    function tickLiquidity(IExtsload manager, PoolId id, int24 tick)
        internal
        view
        returns (uint128 liquidityGross, int128 liquidityNet)
    {
        bytes32 word = manager.extsload(tickInfoSlot(id, tick));
        assembly ("memory-safe") {
            liquidityGross := and(word, MASK_128)
            liquidityNet := sar(128, word)
        }
    }

    /// @notice A tick's two `feeGrowthOutside` accumulators. One batched `extsload` of two slots, skipping the
    ///         liquidity word.
    /// @param manager The PoolManager.
    /// @param id The pool id.
    /// @param tick The tick.
    /// @return feeGrowthOutside0X128 Currency0 fee growth on the far side of the tick.
    /// @return feeGrowthOutside1X128 Currency1 fee growth on the far side of the tick.
    function tickFeeGrowthOutside(IExtsload manager, PoolId id, int24 tick)
        internal
        view
        returns (uint256 feeGrowthOutside0X128, uint256 feeGrowthOutside1X128)
    {
        bytes32 start = bytes32(uint256(tickInfoSlot(id, tick)) + 1);
        bytes32[] memory words = manager.extsload(start, 2);
        feeGrowthOutside0X128 = uint256(words[0]);
        feeGrowthOutside1X128 = uint256(words[1]);
    }

    /// @notice One word of the pool's tick bitmap. One `extsload`.
    /// @param manager The PoolManager.
    /// @param id The pool id.
    /// @param wordPos The word position.
    /// @return word The 256 initialised-tick flags in that word.
    function tickBitmap(IExtsload manager, PoolId id, int16 wordPos) internal view returns (uint256 word) {
        word = uint256(manager.extsload(tickBitmapSlot(id, wordPos)));
    }

    /// @notice A position's whole `Position.State`. One batched `extsload` of three consecutive slots.
    /// @param manager The PoolManager.
    /// @param id The pool id.
    /// @param owner The position owner.
    /// @param lower The lower tick.
    /// @param upper The upper tick.
    /// @param salt The salt.
    /// @return positionLiquidity_ The position's liquidity.
    /// @return feeGrowthInside0LastX128 Fee growth inside the range at the last update, currency0.
    /// @return feeGrowthInside1LastX128 Fee growth inside the range at the last update, currency1.
    function positionInfo(IExtsload manager, PoolId id, address owner, int24 lower, int24 upper, bytes32 salt)
        internal
        view
        returns (uint128 positionLiquidity_, uint256 feeGrowthInside0LastX128, uint256 feeGrowthInside1LastX128)
    {
        bytes32[] memory words = manager.extsload(positionSlot(id, owner, lower, upper, salt), 3);
        positionLiquidity_ = uint128(uint256(words[0]));
        feeGrowthInside0LastX128 = uint256(words[1]);
        feeGrowthInside1LastX128 = uint256(words[2]);
    }

    /// @notice A position's liquidity only. One `extsload` — the hot path for valuation and redemption sizing.
    /// @param manager The PoolManager.
    /// @param id The pool id.
    /// @param owner The position owner.
    /// @param lower The lower tick.
    /// @param upper The upper tick.
    /// @param salt The salt.
    /// @return positionLiquidity_ The position's liquidity, zero if the position does not exist.
    function positionLiquidity(IExtsload manager, PoolId id, address owner, int24 lower, int24 upper, bytes32 salt)
        internal
        view
        returns (uint128 positionLiquidity_)
    {
        positionLiquidity_ = uint128(uint256(manager.extsload(positionSlot(id, owner, lower, upper, salt))));
    }

    /// @notice The liquidity of many positions in one pool, in one staticcall.
    /// @param manager The PoolManager.
    /// @param id The pool id.
    /// @param keys The position keys, from {positionKey}.
    /// @return liquidities One `uint128` per key, in the same order.
    function positionLiquidityBatch(IExtsload manager, PoolId id, bytes32[] memory keys)
        internal
        view
        returns (uint128[] memory liquidities)
    {
        uint256 length = keys.length;
        bytes32 base = positionsBaseSlot(id);
        bytes32[] memory slots = new bytes32[](length);
        for (uint256 i; i < length; ++i) {
            slots[i] = positionSlotIn(base, keys[i]);
        }
        liquidities = positionLiquidityAtSlots(manager, slots);
    }

    /// @notice The liquidity words at arbitrary pre-derived position slots, in one staticcall.
    /// @dev The grid enumeration in `LadderPositionValuer` derives its 24 slots itself and calls straight into
    ///      this. The returned `bytes32[]` is narrowed **in place**: a `bytes32[] memory` and a `uint128[] memory`
    ///      have identical layout (one 32-byte word per element), so masking each word to its low 128 bits and
    ///      reinterpreting the pointer is exact and allocates nothing.
    /// @param manager The PoolManager.
    /// @param slots The position slots.
    /// @return liquidities One `uint128` per slot, in the same order.
    function positionLiquidityAtSlots(IExtsload manager, bytes32[] memory slots)
        internal
        view
        returns (uint128[] memory liquidities)
    {
        bytes32[] memory words = manager.extsload(slots);
        uint256 length = words.length;
        for (uint256 i; i < length; ++i) {
            bytes32 word = words[i];
            uint128 narrowed = uint128(uint256(word));
            assembly ("memory-safe") {
                mstore(add(add(words, 0x20), shl(5, i)), narrowed)
            }
        }
        assembly ("memory-safe") {
            liquidities := words
        }
    }

    /// @notice Fee growth inside `[lower, upper]` right now, not as of the position's last update.
    /// @dev Branches exactly as v4's accumulator does, in `unchecked` arithmetic: these differences are *meant* to
    ///      wrap, because `feeGrowthOutside` is seeded to the global value at the time a tick is first crossed and
    ///      only the difference is ever meaningful.
    ///      Only the branch that needs the globals reads them, so the "below" and "above" cases cost one fewer
    ///      staticcall than v4's helper; the arithmetic is identical.
    /// @param manager The PoolManager.
    /// @param id The pool id.
    /// @param lower The lower tick.
    /// @param upper The upper tick.
    /// @return feeGrowthInside0X128 Currency0 fee growth inside the range, Q128.
    /// @return feeGrowthInside1X128 Currency1 fee growth inside the range, Q128.
    function feeGrowthInside(IExtsload manager, PoolId id, int24 lower, int24 upper)
        internal
        view
        returns (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128)
    {
        (, int24 tickCurrent,,) = slot0(manager, id);
        (uint256 lower0, uint256 lower1) = tickFeeGrowthOutside(manager, id, lower);
        (uint256 upper0, uint256 upper1) = tickFeeGrowthOutside(manager, id, upper);

        unchecked {
            if (tickCurrent < lower) {
                feeGrowthInside0X128 = lower0 - upper0;
                feeGrowthInside1X128 = lower1 - upper1;
            } else if (tickCurrent >= upper) {
                feeGrowthInside0X128 = upper0 - lower0;
                feeGrowthInside1X128 = upper1 - lower1;
            } else {
                (uint256 global0, uint256 global1) = feeGrowthGlobals(manager, id);
                feeGrowthInside0X128 = global0 - lower0 - upper0;
                feeGrowthInside1X128 = global1 - lower1 - upper1;
            }
        }
    }

    /// @notice Fees a position has accrued but not yet collected.
    /// @dev `owed = mulDiv(feeGrowthInsideNow - feeGrowthInsideLast, L, Q128)`, with the subtraction `unchecked`
    ///      because the accumulators wrap by design.
    /// @dev **Not part of NAV.** `A` excludes uncollected fees (§4, normative): fee growth is the one term a
    ///      wash-trader can inflate cheaply, and including it would make `A` depend on `slot0.tick` through
    ///      {feeGrowthInside}'s branch, which contradicts I7. This exists for `compound`'s own accounting and for
    ///      the dApp.
    /// @param manager The PoolManager.
    /// @param id The pool id.
    /// @param owner The position owner.
    /// @param lower The lower tick.
    /// @param upper The upper tick.
    /// @param salt The salt.
    /// @return owed0 Uncollected currency0 fees, rounded down.
    /// @return owed1 Uncollected currency1 fees, rounded down.
    function feesOwed(IExtsload manager, PoolId id, address owner, int24 lower, int24 upper, bytes32 salt)
        internal
        view
        returns (uint256 owed0, uint256 owed1)
    {
        (uint128 positionLiquidity_, uint256 last0, uint256 last1) =
            positionInfo(manager, id, owner, lower, upper, salt);
        if (positionLiquidity_ == 0) return (0, 0);

        (uint256 now0, uint256 now1) = feeGrowthInside(manager, id, lower, upper);
        unchecked {
            owed0 = FullMath.mulDiv(now0 - last0, positionLiquidity_, FixedPoint128.Q128);
            owed1 = FullMath.mulDiv(now1 - last1, positionLiquidity_, FixedPoint128.Q128);
        }
    }

    // -------------------------------------------------------------------------------------------------------------
    // Transient reads
    // -------------------------------------------------------------------------------------------------------------

    /// @notice Whether the manager is currently unlocked, i.e. inside an `unlock` callback.
    /// @dev Transient storage is cleared at the end of every transaction, so this is only ever non-zero when read
    ///      from inside the same transaction that unlocked the manager.
    /// @param manager The PoolManager (any `IExttload`).
    /// @return unlocked True while a lock is held.
    function isUnlocked(IExttload manager) internal view returns (bool unlocked) {
        unlocked = manager.exttload(IS_UNLOCKED_SLOT) != bytes32(0);
    }

    /// @notice How many currency deltas are still open. Must be zero before the manager will re-lock.
    /// @param manager The PoolManager.
    /// @return count The open-delta count.
    function nonzeroDeltaCount(IExttload manager) internal view returns (uint256 count) {
        count = uint256(manager.exttload(NONZERO_DELTA_COUNT_SLOT));
    }

    /// @notice The transient slot a `(target, currency)` delta lives in.
    /// @dev `keccak256(abi.encode(target, currency))`: 64 bytes, target first, both left-padded to 32.
    /// @param target The credited account.
    /// @param currency The currency.
    /// @return slot The transient slot.
    function currencyDeltaSlot(address target, Currency currency) internal pure returns (bytes32 slot) {
        assembly ("memory-safe") {
            mstore(0x00, and(target, MASK_160))
            mstore(0x20, and(currency, MASK_160))
            slot := keccak256(0x00, 0x40)
        }
    }

    // -------------------------------------------------------------------------------------------------------------
    // Internals
    // -------------------------------------------------------------------------------------------------------------

    /// @dev `keccak256(abi.encodePacked(a, b))` for two 32-byte words — the Solidity mapping-slot rule — written
    ///      through the two scratch words at `[0x00, 0x40)` instead of `abi.encodePacked`, which would allocate
    ///      and copy 96 bytes of memory on every call. The grid enumeration in `LadderPositionValuer` makes 48 of
    ///      these per pool, so the allocation is worth removing; scratch space is explicitly free for this.
    function _hashPair(bytes32 a, bytes32 b) private pure returns (bytes32 hashed) {
        assembly ("memory-safe") {
            mstore(0x00, a)
            mstore(0x20, b)
            hashed := keccak256(0x00, 0x40)
        }
    }

    /// @notice A target's open delta in one currency, signed.
    /// @dev Nothing in the production flow depends on this; the vault reads it only for defensive assertions
    ///      inside its own `unlockCallback` ("every delta I opened, I closed").
    /// @param manager The PoolManager.
    /// @param target The credited account.
    /// @param currency The currency.
    /// @return delta Positive when the manager owes `target`, negative when `target` owes the manager.
    function currencyDelta(IExttload manager, address target, Currency currency) internal view returns (int256 delta) {
        delta = int256(uint256(manager.exttload(currencyDeltaSlot(target, currency))));
    }
}
