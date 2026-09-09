// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IAmpsRouter} from "../interfaces/IAmpsRouter.sol";
import {IPoolRegistry} from "../interfaces/IPoolRegistry.sol";
import {PoolStateLib} from "../lib/PoolStateLib.sol";
import {Constants} from "../types/Constants.sol";
import {
    AmpsResidual,
    DeadlineExpired,
    NativeTransferFailed,
    NotARotation,
    NotPoolManager,
    NotWrappedNative,
    Reentrancy,
    SameHop,
    SlippageExceeded,
    UnexpectedValue,
    UnknownPool,
    ZeroAddress,
    ZeroAmount
} from "../types/Errors.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IExttload} from "@uniswap/v4-core/src/interfaces/IExttload.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

/// @title AmpsRouter
/// @notice The protocol's own swap router: buy AMPS, sell AMPS, rotate between two constituents through AMPS.
///         Immutable, ownerless, feeless, and the only contract whose rotation hops `AmpsHook` prices at the
///         pass-through fee.
///
/// @dev **The one thing this contract has that others do not.** `AmpsHook` charges `ampsFeeBps` (500 bp at
///      launch) as the base fee on *both* directions of every pool. The single exception is a hop where the
///      PoolManager reports `sender == AmpsHook.router()` **and** the hop's `hookData` is exactly
///      `Constants.ROUTER_ROTATE`; such a hop pays the pool's `buyFeeBps` (5-30 bp) instead, and it may earn or
///      spend the same-transaction rotation credit. {rotate} sets that flag on its two hops. {buy} and {sell} do
///      not, and pay the AMPS fee like any other swap through any other router.
///
/// @dev **Why the hook cannot work this out for itself, and why the exemption is therefore a contract address.**
///      The fee for a hop is fixed in `beforeSwap`, *before* the swap executes. Hop 1 of a route is one
///      `IPoolManager.swap` call and cannot know whether a hop 2 follows — that is a fact about the caller's
///      intention, not about the pool. Charging the pass-through fee optimistically and refunding the difference
///      would need the hook to hold and return value, and the hook holds no ERC-20 and no ERC-6909 and never
///      calls `settle`, `take`, `mint` or `burn` (I13). Letting any caller flag any hop as pass-through would make
///      the AMPS fee voluntary. Inferring a rotation from the transient credit alone — the previous revision —
///      turned the credit into something to manufacture, because *any* buy minted a discount that *any* sell in
///      the same transaction could spend, so a batching settlement contract could pair a stranger's entry with its
///      own exit and pay 30 bp on a genuine exit. What remains is a declaration the hook can check against an
///      address only the 48-hour timelock can move: this one.
///
/// @dev **Custody.** The router never holds an ERC-20 or a native balance between transactions. Inside a call it
///      holds only what it is about to pay in or has just been paid out, and at the end of every entry point the
///      assets it touched are swept to `msg.sender` on a best-effort basis. The sweep is a *transfer*, not an
///      assertion that the balance is zero, on purpose: an assertion would let anyone brick a pool's whole route
///      by sending one wei of its counter asset to this address. Sweeping instead makes a donation a tip to the
///      next caller, which is the standard, ungriefable answer.
///
/// @dev **Trust.** No owner, no upgrade, no pause, no fee, no allowance held on anyone's behalf beyond the one
///      being spent in the current call. Every address is immutable and every pool is resolved through
///      `IPoolRegistry.poolKey`, which reverts for a pool the registry does not know, so this contract cannot be
///      pointed at a pool the protocol has not registered. Governance's only lever is `AmpsHook.setRouter`, which
///      withdraws or reassigns the pass-through exemption without redeploying anything.
contract AmpsRouter is IAmpsRouter, IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using SafeERC20 for IERC20;

    // -------------------------------------------------------------------------------------------------------------
    // Transient slots (EIP-1153)
    // -------------------------------------------------------------------------------------------------------------

    /// @dev `keccak256("amplestocks.router.REENTRANCY_LOCK")`, spelled as a literal because inline assembly takes
    ///      only direct number constants. Pinned against the string it is derived from in
    ///      `test/unit/AmpsRouter.t.sol`, which is what keeps the two from drifting.
    ///
    /// @dev The lock does double duty: it is the reentrancy guard on the three entry points, and it is what
    ///      {unlockCallback} checks to know the unlock it is being called inside is one *this* contract opened.
    uint256 private constant REENTRANCY_LOCK = 0x8d4554710d68d2fa17f9017173db9ef290e4bf31a3eb1b9b04bd1274abd91940;

    // -------------------------------------------------------------------------------------------------------------
    // Working types
    // -------------------------------------------------------------------------------------------------------------

    /// @dev What {unlockCallback} is being asked to do. Encoded as the first word of the unlock payload.
    enum Action {
        BUY,
        SELL,
        ROTATE
    }

    // -------------------------------------------------------------------------------------------------------------
    // Immutables
    // -------------------------------------------------------------------------------------------------------------

    /// @inheritdoc IAmpsRouter
    address public immutable poolManager;

    /// @inheritdoc IAmpsRouter
    address public immutable amps;

    /// @inheritdoc IAmpsRouter
    address public immutable registry;

    /// @inheritdoc IAmpsRouter
    address public immutable weth;

    /// @param poolManager_ The Uniswap v4 PoolManager.
    /// @param amps_ AMPS, `currency0` of every Amplestocks pool.
    /// @param registry_ The pool registry; every `PoolKey` this contract uses is read from it.
    /// @param weth_ The wrapped native token, i.e. the `AMPS/WETH` entry pool's counter asset.
    constructor(IPoolManager poolManager_, address amps_, address registry_, address weth_) {
        if (
            address(poolManager_) == address(0) || amps_ == address(0) || registry_ == address(0) || weth_ == address(0)
        ) {
            revert ZeroAddress();
        }
        poolManager = address(poolManager_);
        amps = amps_;
        registry = registry_;
        weth = weth_;
    }

    /// @inheritdoc IAmpsRouter
    function ROTATE_FLAG() external pure returns (bytes32 flag) {
        flag = Constants.ROUTER_ROTATE;
    }

    // -------------------------------------------------------------------------------------------------------------
    // Guards
    // -------------------------------------------------------------------------------------------------------------

    /// @dev The EIP-1153 reentrancy lock, held for the whole of one entry point — the `unlock` included, so that
    ///      a hostile token reached during `settle` cannot re-enter and open a second unlock inside the first.
    modifier nonReentrant() {
        uint256 lockSlot = REENTRANCY_LOCK;
        assembly ("memory-safe") {
            if tload(lockSlot) {
                mstore(0x00, 0xab143c06) // Reentrancy()
                revert(0x1c, 0x04)
            }
            tstore(lockSlot, 1)
        }
        _;
        assembly ("memory-safe") {
            tstore(lockSlot, 0)
        }
    }

    /// @dev A trade quoted for one block is not the trade that lands three blocks later: the session may have
    ///      changed, the gate may have degraded and the dynamic fee moves with both.
    modifier before(uint256 deadline) {
        if (block.timestamp > deadline) revert DeadlineExpired(deadline, block.timestamp);
        _;
    }

    // -------------------------------------------------------------------------------------------------------------
    // Trades
    // -------------------------------------------------------------------------------------------------------------

    /// @inheritdoc IAmpsRouter
    function buy(PoolId poolId, uint256 amountIn, uint256 minAmpsOut, address to, uint256 deadline)
        external
        payable
        nonReentrant
        before(deadline)
        returns (uint256 ampsOut)
    {
        if (to == address(0)) revert ZeroAddress();
        if (amountIn == 0) revert ZeroAmount();

        PoolKey memory key = _poolKey(poolId);
        address counter = Currency.unwrap(key.currency1);
        _takeInput(counter, amountIn);

        // Empty `hookData`: a buy is an entry, not a rotation, so it pays `ampsFeeBps` like any other swap.
        ampsOut = abi.decode(
            IPoolManager(poolManager).unlock(abi.encode(Action.BUY, abi.encode(key, amountIn, to))), (uint256)
        );
        if (ampsOut < minAmpsOut) revert SlippageExceeded(ampsOut, minAmpsOut);

        _sweep(counter);
        _sweep(amps);
        _sweepNative();
        emit Bought(poolId, msg.sender, to, amountIn, ampsOut);
    }

    /// @inheritdoc IAmpsRouter
    function sell(PoolId poolId, uint256 ampsIn, uint256 minOut, address to, bool unwrap, uint256 deadline)
        external
        nonReentrant
        before(deadline)
        returns (uint256 amountOut)
    {
        if (to == address(0)) revert ZeroAddress();
        if (ampsIn == 0) revert ZeroAmount();

        PoolKey memory key = _poolKey(poolId);
        address counter = Currency.unwrap(key.currency1);
        if (unwrap && counter != weth) revert NotWrappedNative(counter);

        IERC20(amps).safeTransferFrom(msg.sender, address(this), ampsIn);

        // The output goes straight to `to` unless it has to be unwrapped first, in which case it lands here.
        address recipient = unwrap ? address(this) : to;
        amountOut = abi.decode(
            IPoolManager(poolManager).unlock(abi.encode(Action.SELL, abi.encode(key, ampsIn, recipient))), (uint256)
        );
        if (amountOut < minOut) revert SlippageExceeded(amountOut, minOut);
        if (unwrap) _unwrapTo(to, amountOut);

        _sweep(amps);
        _sweep(counter);
        _sweepNative();
        emit Sold(poolId, msg.sender, to, ampsIn, amountOut);
    }

    /// @inheritdoc IAmpsRouter
    function rotate(
        PoolId hop1,
        PoolId hop2,
        uint256 amountIn,
        uint256 minOut,
        address to,
        bool unwrap,
        uint256 deadline
    ) external payable nonReentrant before(deadline) returns (uint256 amountOut, uint256 ampsThrough) {
        if (to == address(0)) revert ZeroAddress();
        if (amountIn == 0) revert ZeroAmount();
        if (PoolId.unwrap(hop1) == PoolId.unwrap(hop2)) revert SameHop(PoolId.unwrap(hop1));

        PoolKey memory key1 = _poolKey(hop1);
        PoolKey memory key2 = _poolKey(hop2);
        // **At least one leg must be a constituent's spoke** (audit fix, 2026-09-08). See {NotARotation}: the two
        // entry pools are the way in and the way out of the index, so a hop between them is not a rotation at any
        // price, and pricing it pass-through sold a 60 bp USDG/WETH swap against protocol-owned liquidity.
        if (!_isSpoke(hop1) && !_isSpoke(hop2)) revert NotARotation(PoolId.unwrap(hop1), PoolId.unwrap(hop2));
        if (unwrap && Currency.unwrap(key2.currency1) != weth) {
            revert NotWrappedNative(Currency.unwrap(key2.currency1));
        }

        _takeInput(Currency.unwrap(key1.currency1), amountIn);
        (amountOut, ampsThrough) = _rotateUnlock(key1, key2, amountIn, unwrap ? address(this) : to);
        if (amountOut < minOut) revert SlippageExceeded(amountOut, minOut);
        if (unwrap) _unwrapTo(to, amountOut);

        _sweep(Currency.unwrap(key1.currency1));
        _sweep(Currency.unwrap(key2.currency1));
        _sweep(amps);
        _sweepNative();
        emit Rotated(hop1, hop2, to, amountIn, ampsThrough, amountOut);
    }

    /// @dev The `unlock` half of {rotate}, split out because the legacy pipeline runs the seven-argument entry
    ///      point out of stack slots otherwise.
    function _rotateUnlock(PoolKey memory key1, PoolKey memory key2, uint256 amountIn, address recipient)
        private
        returns (uint256 amountOut, uint256 ampsThrough)
    {
        (amountOut, ampsThrough) = abi.decode(
            IPoolManager(poolManager).unlock(abi.encode(Action.ROTATE, abi.encode(key1, key2, amountIn, recipient))),
            (uint256, uint256)
        );
    }

    // -------------------------------------------------------------------------------------------------------------
    // The sole unlock callback
    // -------------------------------------------------------------------------------------------------------------

    /// @inheritdoc IUnlockCallback
    /// @dev Two guards, and both are needed. `msg.sender == poolManager` is the usual one. The transient lock is
    ///      the second: it is set only by one of the three entry points above, so an `unlock` opened by anyone
    ///      else — who could pass this contract as the callback target — finds it clear and is refused. Without
    ///      it, a third party could open an unlock and have this contract execute a swap and a settle inside a
    ///      frame it did not start.
    function unlockCallback(bytes calldata data) external returns (bytes memory result) {
        if (msg.sender != poolManager) revert NotPoolManager(msg.sender);
        uint256 lockSlot = REENTRANCY_LOCK;
        uint256 held;
        assembly ("memory-safe") {
            held := tload(lockSlot)
        }
        if (held == 0) revert Reentrancy();

        (Action action, bytes memory payload) = abi.decode(data, (Action, bytes));
        if (action == Action.BUY) return _buyAction(payload);
        if (action == Action.SELL) return _sellAction(payload);
        return _rotateAction(payload);
    }

    /// @dev One exact-input buy: the counter asset in, AMPS out to `to`. Empty `hookData`, so `ampsFeeBps`.
    function _buyAction(bytes memory payload) private returns (bytes memory result) {
        (PoolKey memory key, uint256 amountIn, address to) = abi.decode(payload, (PoolKey, uint256, address));

        BalanceDelta delta = _swap(key, false, amountIn, "");
        uint256 ampsOut = _positive(delta.amount0());

        // **The realised input, not the requested one** (audit fix, 2026-09-08). An exact-input swap runs with the
        // price limit open, so the pool can still fill less than the whole amount — it runs out of liquidity, or
        // the hook's rail stops the tick — and settling the *requested* amount then over-pays the PoolManager,
        // which reverts the whole call with v4's `CurrencyNotSettled` instead of the `SlippageExceeded` the caller
        // can read. The unspent remainder stays here and is swept back to the caller by the entry point.
        _settle(key.currency1, _owed(delta.amount1()));
        IPoolManager(poolManager).take(key.currency0, to, ampsOut);
        result = abi.encode(ampsOut);
    }

    /// @dev One exact-input sell: AMPS in, the counter asset out. Empty `hookData`, so `ampsFeeBps`, and no
    ///      rotation credit is earned or spent whatever else this transaction has done.
    function _sellAction(bytes memory payload) private returns (bytes memory result) {
        (PoolKey memory key, uint256 ampsIn, address to) = abi.decode(payload, (PoolKey, uint256, address));

        BalanceDelta delta = _swap(key, true, ampsIn, "");
        uint256 amountOut = _positive(delta.amount1());

        // The realised AMPS in, for the reason {_buyAction} gives.
        _settle(key.currency0, _owed(delta.amount0()));
        IPoolManager(poolManager).take(key.currency1, to, amountOut);
        result = abi.encode(amountOut);
    }

    /// @dev The rotation: two exact-input hops inside one unlock, both flagged `Constants.ROUTER_ROTATE`.
    ///
    /// @dev **Hop 2 sells the realised delta of hop 1, never a quoted number.** `ampsThrough` is read off hop 1's
    ///      own `BalanceDelta`, which is what the hook credited in `afterSwap`, so hop 2's credit covers hop 2's
    ///      input exactly and the blend resolves to `buyFeeBps` rather than to something a basis point off it.
    ///
    /// @dev **The zero-AMPS assertion.** Before anything is settled, the router's AMPS delta on the PoolManager
    ///      must be exactly zero: hop 1 bought `ampsThrough` and hop 2 sold `ampsThrough`, so they net out and no
    ///      AMPS is left for the caller to take. It is asserted rather than assumed because it is the property
    ///      that makes a rotation a rotation — if a `rotate` could end with AMPS in hand, it would be an entry
    ///      wearing a rotation's fee — and because the two swaps are separated by a hook callback that a future
    ///      revision could give a delta.
    function _rotateAction(bytes memory payload) private returns (bytes memory result) {
        (PoolKey memory key1, PoolKey memory key2, uint256 amountIn, address to) =
            abi.decode(payload, (PoolKey, PoolKey, uint256, address));

        bytes memory rotateFlag = abi.encode(Constants.ROUTER_ROTATE);

        BalanceDelta hop1 = _swap(key1, false, amountIn, rotateFlag);
        uint256 ampsThrough = _positive(hop1.amount0());
        if (ampsThrough == 0) revert ZeroAmount();

        BalanceDelta hop2 = _swap(key2, true, ampsThrough, rotateFlag);
        uint256 amountOut = _positive(hop2.amount1());

        int256 residual = PoolStateLib.currencyDelta(IExttload(poolManager), address(this), key1.currency0);
        if (residual != 0) revert AmpsResidual(residual);

        // The realised input of hop 1, for the reason {_buyAction} gives; hop 2's input is `ampsThrough`, which is
        // already hop 1's realised output, and the AMPS legs are asserted to net to zero above.
        _settle(key1.currency1, _owed(hop1.amount1()));
        IPoolManager(poolManager).take(key2.currency1, to, amountOut);
        result = abi.encode(amountOut, ampsThrough);
    }

    // -------------------------------------------------------------------------------------------------------------
    // PoolManager plumbing
    // -------------------------------------------------------------------------------------------------------------

    /// @dev One exact-input swap with the price limit opened all the way: the hook's rail, the caller's `minOut`
    ///      and the pool's own liquidity are the bounds that matter, and a tighter `sqrtPriceLimitX96` would only
    ///      turn a slippage revert into a silent partial fill.
    function _swap(PoolKey memory key, bool zeroForOne, uint256 amountIn, bytes memory hookData)
        private
        returns (BalanceDelta delta)
    {
        delta = IPoolManager(poolManager)
            .swap(
                key,
                SwapParams({
                    zeroForOne: zeroForOne,
                    // Checked, not cast: `-int256(amountIn)` for an `amountIn` at or above `2**255` is *positive*,
                    // which would silently turn this exact-input swap into an exact-output one — a shape the router
                    // must never build, because an exact-output hop consumes no rotation credit.
                    amountSpecified: -SafeCast.toInt256(amountIn),
                    sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
                }),
                hookData
            );
    }

    /// @dev `sync -> transfer -> settle`. Every Amplestocks currency is an ERC-20 — AMPS is `currency0` in all 32
    ///      pools and the counters are USDG, WETH and the stock tokens — so there is no native-currency branch to
    ///      write, and `settle` is called with no value.
    function _settle(Currency currency, uint256 amount) private {
        IPoolManager(poolManager).sync(currency);
        IERC20(Currency.unwrap(currency)).safeTransfer(poolManager, amount);
        IPoolManager(poolManager).settle();
    }

    // -------------------------------------------------------------------------------------------------------------
    // Custody: in, out, and nothing left behind
    // -------------------------------------------------------------------------------------------------------------

    /// @dev Brings the input asset under this contract's control: wrapped from `msg.value` when the caller sent
    ///      ether and the pool's counter really is {weth}, pulled from `msg.sender` otherwise.
    /// @dev `msg.value` must equal `amountIn` exactly rather than merely cover it. A router that accepted more and
    ///      refunded the difference would be a router that can be made to send ether to an arbitrary address in
    ///      the middle of a swap; requiring the exact amount removes the refund and the question with it.
    function _takeInput(address counter, uint256 amountIn) private {
        if (msg.value == 0) {
            IERC20(counter).safeTransferFrom(msg.sender, address(this), amountIn);
            return;
        }
        if (counter != weth) revert NotWrappedNative(counter);
        if (msg.value != amountIn) revert UnexpectedValue(msg.value);
        IWrappedNative(weth).deposit{value: amountIn}();
    }

    /// @dev Unwraps `amount` of {weth} and forwards it as ether. The only path on which this contract ever sends
    ///      native value, and it sends it to the recipient the caller named.
    function _unwrapTo(address to, uint256 amount) private {
        IWrappedNative(weth).withdraw(amount);
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert NativeTransferFailed(to, amount);
    }

    /// @dev Best-effort return of any residual balance of one asset to the caller.
    ///
    /// @dev **Why a sweep and not `require(balanceOf(this) == 0)`.** The invariant that matters is that this
    ///      contract holds nothing *between* transactions, and both forms achieve it — but an assertion also
    ///      makes anyone able to disable a route for one wei: send dust of a pool's counter asset here and every
    ///      subsequent trade through that pool reverts, permanently, because nothing can clear it. Sweeping
    ///      instead turns a donation into a tip for the next caller. The transfer is a bounded low-level call
    ///      whose failure is ignored, so a token that reverts on a zero-value or blocked transfer cannot take a
    ///      completed trade down after the fact.
    function _sweep(address token) private {
        (bool got, uint256 held) = _balanceOf(token);
        if (!got || held == 0) return;
        // solhint-disable-next-line avoid-low-level-calls
        (bool moved,) =
            token.call{gas: Constants.STOCK_TOKEN_PROBE_GAS * 4}(abi.encodeCall(IERC20.transfer, (msg.sender, held)));
        // Deliberately not asserted: the caller's trade has already executed and settled, and a token that
        // refuses to move its own dust is the token's problem, not a reason to unwind a completed swap.
        if (!moved) return;
    }

    /// @dev The native counterpart of {_sweep}: any ether left over — an over-generous unwrap, a forced transfer —
    ///      goes back to the caller, and a caller that refuses it leaves it for the next one rather than reverting
    ///      a trade that has already happened.
    function _sweepNative() private {
        uint256 held = address(this).balance;
        if (held == 0) return;
        // Bounded, so a caller with an expensive `receive` cannot make the sweep the dominant cost of a trade,
        // and ignored, for the same reason {_sweep} ignores its own result.
        // solhint-disable-next-line avoid-low-level-calls
        (bool sent,) = msg.sender.call{value: held, gas: Constants.STOCK_TOKEN_PROBE_GAS}("");
        if (!sent) return;
    }

    /// @dev One bounded `balanceOf`, hand-decoded, so a token that answers with garbage degrades the sweep into a
    ///      no-op instead of reverting a settled trade.
    function _balanceOf(address token) private view returns (bool ok, uint256 held) {
        bytes memory returndata;
        (ok, returndata) =
            token.staticcall{gas: Constants.STOCK_TOKEN_PROBE_GAS}(abi.encodeCall(IERC20.balanceOf, (address(this))));
        if (!ok || returndata.length < 32) return (false, 0);
        assembly ("memory-safe") {
            held := mload(add(returndata, 0x20))
        }
    }

    /// @notice Accepts ether from {weth} alone, which is the unwrap path returning what this contract just asked
    ///         for. Nothing else may send ether here: there is no shape of this contract in which an unsolicited
    ///         balance is useful, and accepting one silently would make {_sweepNative} a way to hand a stranger's
    ///         ether to whoever trades next.
    receive() external payable {
        if (msg.sender != weth) revert UnexpectedValue(msg.value);
    }

    // -------------------------------------------------------------------------------------------------------------
    // Pure helpers
    // -------------------------------------------------------------------------------------------------------------

    /// @dev The pool's key, from the registry, which reverts `UnknownPool` for anything it has not registered.
    ///      This is the only place a `PoolKey` enters the contract, so an unregistered pool cannot be traded here
    ///      even by a caller who knows its exact shape.
    ///
    /// @dev **The key is then checked against the id that asked for it.** `PoolId` *is* `keccak256(abi.encode(
    ///      key))`, so re-deriving it costs one hash and turns the registry from an oracle this contract trusts
    ///      into one it verifies: a registry that answered with some other pool's key — by bug, by misconfigured
    ///      write, or by compromise — would route the caller's funds through a pool they did not name, and this
    ///      is what makes that impossible rather than merely unlikely. The `currency0 == amps` check beside it is
    ///      the second half: every Amplestocks pool has AMPS as `currency0`, and every fee direction, every
    ///      credit and every delta sign in this contract is written against that fact.
    function _poolKey(PoolId poolId) private view returns (PoolKey memory key) {
        key = IPoolRegistry(registry).poolKey(poolId);
        if (PoolId.unwrap(key.toId()) != PoolId.unwrap(poolId)) revert UnknownPool(PoolId.unwrap(poolId));
        if (Currency.unwrap(key.currency0) != amps) revert UnknownPool(PoolId.unwrap(poolId));
    }

    /// @dev The positive half of a realised delta, as an unsigned amount. A swap's output side is credited to the
    ///      unlocker, so this is what there is to `take`; a non-positive value means the swap produced nothing and
    ///      there is nothing to take.
    function _positive(int128 amount) private pure returns (uint256 value) {
        value = amount > 0 ? uint256(uint128(amount)) : 0;
    }

    /// @dev The negative half of a realised delta, as an unsigned amount: what the swap actually consumed and
    ///      therefore what has to be settled. Zero when the pool took nothing.
    function _owed(int128 amount) private pure returns (uint256 value) {
        value = amount < 0 ? uint256(uint128(-amount)) : 0;
    }

    /// @dev Whether a pool is a constituent's spoke rather than one of the two entry pools. Read from the registry,
    ///      which is the one authority on the index's membership; an entry pool's `constituentId` is zero.
    function _isSpoke(PoolId poolId) private view returns (bool spoke) {
        spoke = IPoolRegistry(registry).poolConfig(poolId).constituentId != 0;
    }
}

/// @title IWrappedNative
/// @notice The two WETH9 entry points this router uses. Declared here rather than in `src/interfaces/` because
///         nothing else in the protocol wraps or unwraps: the vault, the bonds shell and the hook all treat WETH
///         as an ordinary ERC-20.
interface IWrappedNative {
    /// @notice Wraps the ether sent with the call.
    function deposit() external payable;

    /// @notice Unwraps `amount` back to ether, sent to the caller.
    /// @param amount The amount to unwrap.
    function withdraw(uint256 amount) external;
}
