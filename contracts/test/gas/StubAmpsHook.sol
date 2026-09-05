// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

/// @title StubAmpsHook
/// @notice Gas-shape stand-in for the production `AmpsHook`. It carries exactly the `0x38C0` permission set
///         (`BEFORE_INITIALIZE | AFTER_INITIALIZE | BEFORE_ADD_LIQUIDITY | BEFORE_SWAP | AFTER_SWAP`), the same
///         storage/transient-storage access pattern and the same return shapes, with none of the business logic:
///         no registry, no oracle gate, no observation ring, no dynamic fee components. It exists solely so that
///         `test/gas/GasBaseline.t.sol` can record the gas floor every later `AmpsHook` revision is measured against.
/// @dev    Invariants mirrored from the design (I13): holds no ERC-20/ERC-6909, never calls
///         `settle`/`take`/`mint`/`burn`/`donate`/`swap`, performs no liquidity operation, `beforeSwap` returns
///         `ZERO_DELTA` and `afterSwap` returns `0`, so neither `*_RETURNS_DELTA` bit is needed.
contract StubAmpsHook is BaseHook {
    using LPFeeLibrary for uint24;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    /// @dev Base buy fee, in pips (hundredths of a bip). 30 bp, the entry-pool bucket.
    uint24 internal constant BUY_FEE_PIPS = 3000;

    /// @dev Base sell fee, in pips. 500 bp, the launch value of `sellFeeBps` inside the hard band [100, 600] bp.
    uint24 internal constant SELL_FEE_PIPS = 50_000;

    /// @dev EIP-1153 slot holding the same-transaction rotation credit, in AMPS wei.
    ///      `keccak256("amplestocks.hook.rotationCredit")`, hard-coded so no hashing happens on the hot path.
    uint256 internal constant ROTATION_CREDIT_SLOT = 0x17028355b3c33ee9845e7567cacb4eaa76fd2e952e37f15609d385e9299f272f;

    /// @notice AMPS. `currency0` of every Amplestocks pool by construction (the token address is CREATE2-mined
    ///         to three leading zero bytes), which fixes `zeroForOne == true` to mean "selling AMPS".
    Currency public immutable amps;

    /// @notice The only address allowed to add liquidity: the protocol vault (POL-only pools).
    address public immutable vault;

    /// @notice One packed word per pool, exactly as the production hook's `HookState` head:
    ///         `[0..23] lastTick (int24) | [24..55] lastUpdate (uint32) | [56..111] tickCumulative (int56) |
    ///          [112..135] highWaterTick (int24)`.
    mapping(PoolId => uint256) internal _packed;

    error Currency0NotAmps();
    error FeeNotDynamic();
    error PoolNotInitialized();
    error SenderNotVault();

    constructor(IPoolManager poolManager_, Currency amps_, address vault_) BaseHook(poolManager_) {
        amps = amps_;
        vault = vault_;
    }

    /// @inheritdoc BaseHook
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: true,
            beforeAddLiquidity: true,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /// @notice Unpacks the per-pool observation word. View-only, never used on the hot path.
    function poolState(PoolId id)
        external
        view
        returns (int24 lastTick, uint32 lastUpdate, int56 tickCumulative, int24 highWaterTick)
    {
        return _unpack(_packed[id]);
    }

    /// @notice The live same-transaction rotation credit, in AMPS wei.
    function rotationCredit() external view returns (uint256 credit) {
        assembly ("memory-safe") {
            credit := tload(ROTATION_CREDIT_SLOT)
        }
    }

    /// @notice TEST ONLY. Lets a single `forge test` transaction measure several independent scenarios: transient
    ///         storage is cleared per transaction on-chain, but a whole test function is one transaction.
    /// @dev    The production `AmpsHook` has no writer for this slot outside `beforeSwap`/`afterSwap`.
    function debugSetRotationCredit(uint256 credit) external {
        assembly ("memory-safe") {
            tstore(ROTATION_CREDIT_SLOT, credit)
        }
    }

    /// @dev `currency0 == AMPS` and a dynamic-fee pool, the two production preconditions that cannot be relaxed.
    function _beforeInitialize(address, PoolKey calldata key, uint160) internal view override returns (bytes4) {
        if (Currency.unwrap(key.currency0) != Currency.unwrap(amps)) revert Currency0NotAmps();
        if (!key.fee.isDynamicFee()) revert FeeNotDynamic();
        return BaseHook.beforeInitialize.selector;
    }

    /// @dev Seeds the pool's packed observation word: one cold `SSTORE` per pool, once.
    function _afterInitialize(address, PoolKey calldata key, uint160, int24 tick) internal override returns (bytes4) {
        _packed[key.toId()] = _pack(tick, uint32(block.timestamp), int56(0), tick);
        return BaseHook.afterInitialize.selector;
    }

    /// @dev POL-only: the vault is the sole liquidity provider in all 32 pools.
    function _beforeAddLiquidity(address sender, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        internal
        view
        override
        returns (bytes4)
    {
        if (sender != vault) revert SenderNotVault();
        return BaseHook.beforeAddLiquidity.selector;
    }

    /// @dev Directional fee with the same-transaction rotation credit. One `SLOAD`, one `TLOAD`, and one `TSTORE`
    ///      when a credit is consumed. `zeroForOne == true` is always "AMPS in", i.e. a sell.
    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        // The production hook reads `lastTick`/`tickCumulative` here for the deviation and volatility terms; the
        // stub reads the same word so the access is priced into the baseline.
        uint256 word = _packed[key.toId()];

        uint256 fee;
        if (params.zeroForOne) {
            fee = SELL_FEE_PIPS;
            if (params.amountSpecified < 0) {
                uint256 amountIn = uint256(-params.amountSpecified);
                uint256 credit;
                assembly ("memory-safe") {
                    credit := tload(ROTATION_CREDIT_SLOT)
                }
                if (credit != 0 && amountIn != 0) {
                    uint256 consumed = credit < amountIn ? credit : amountIn;
                    assembly ("memory-safe") {
                        tstore(ROTATION_CREDIT_SLOT, sub(credit, consumed))
                    }
                    // Blended, rounded up: credited AMPS pays the buy fee, the uncredited excess pays the sell fee.
                    fee = (BUY_FEE_PIPS * consumed + SELL_FEE_PIPS * (amountIn - consumed) + (amountIn - 1)) / amountIn;
                }
            }
        } else {
            fee = BUY_FEE_PIPS;
        }

        // `_afterInitialize` always writes a non-zero timestamp, so this doubles as the "pool is ours" check and
        // keeps the `SLOAD` live for the optimiser.
        if (word == 0) revert PoolNotInitialized();

        return
            (
                BaseHook.beforeSwap.selector,
                BeforeSwapDeltaLibrary.ZERO_DELTA,
                uint24(fee) | LPFeeLibrary.OVERRIDE_FEE_FLAG
            );
    }

    /// @dev Records the observation (one `extsload` + one `SLOAD` + one `SSTORE`) and, on a buy, adds the AMPS the
    ///      swapper actually received to the transient rotation credit. Never reverts a swap.
    function _afterSwap(address, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        PoolId id = key.toId();
        (, int24 tick,,) = poolManager.getSlot0(id);
        (int24 lastTick, uint32 lastUpdate, int56 tickCumulative, int24 highWaterTick) = _unpack(_packed[id]);

        uint32 nowTs = uint32(block.timestamp);
        unchecked {
            tickCumulative += int56(lastTick) * int56(uint56(nowTs - lastUpdate));
        }
        _packed[id] = _pack(tick, nowTs, tickCumulative, tick > highWaterTick ? tick : highWaterTick);

        if (!params.zeroForOne) {
            int128 ampsOut = delta.amount0();
            if (ampsOut > 0) {
                uint256 gained = uint256(uint128(ampsOut));
                assembly ("memory-safe") {
                    tstore(ROTATION_CREDIT_SLOT, add(tload(ROTATION_CREDIT_SLOT), gained))
                }
            }
        }

        return (BaseHook.afterSwap.selector, int128(0));
    }

    function _pack(int24 lastTick, uint32 lastUpdate, int56 tickCumulative, int24 highWaterTick)
        private
        pure
        returns (uint256 word)
    {
        word = uint256(uint24(lastTick)) | (uint256(lastUpdate) << 24) | (uint256(uint56(tickCumulative)) << 56)
            | (uint256(uint24(highWaterTick)) << 112);
    }

    function _unpack(uint256 word)
        private
        pure
        returns (int24 lastTick, uint32 lastUpdate, int56 tickCumulative, int24 highWaterTick)
    {
        lastTick = int24(uint24(word));
        lastUpdate = uint32(word >> 24);
        tickCumulative = int56(uint56(word >> 56));
        highWaterTick = int24(uint24(word >> 112));
    }
}
