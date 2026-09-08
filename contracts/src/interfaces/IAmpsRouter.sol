// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @title IAmpsRouter
/// @notice The protocol's own swap router: the three shapes an Amplestocks user actually trades — buy AMPS, sell
///         AMPS, and rotate between two constituents through AMPS — and the only contract in the world whose
///         rotation hops the hook prices at the pass-through fee.
///
/// @dev **Why a first-party router exists at all, when Uniswap's own works fine.** Revision 6 of the fee model
///      charges `AmpsHook.ampsFeeBps()` (500 bp at launch) on *both* directions of every pool: entering the index
///      and leaving it are the same trade seen from two sides, and a fee charged on one side alone is a fee a
///      round trip halves. But a **rotation** — selling one constituent to buy another, which passes through AMPS
///      and leaves the index's AMPS float exactly where it found it — is not an entry or an exit, and taxing it
///      twice at 500 bp would make the index unusable as an index. The pass-through fee (`AmpsHook.buyFeeBps`,
///      5-30 bp) is the price of that move, and this contract is how it is claimed.
///
/// @dev **Why the exemption is bound to one contract instead of being a property of the swap.** A hop's fee is
///      fixed in `beforeSwap`, before the swap runs. Hop 1 of a route cannot know that a hop 2 follows: it is one
///      `IPoolManager.swap` call, and whether another comes after it is a fact about the caller's intentions, not
///      about the pool. Three alternatives were considered and rejected:
///
///      1. *Charge the pass-through fee on every hop and reconcile at the end.* The reconciliation is a refund,
///         and a refund needs the hook to hold value. The hook holds no ERC-20 and no ERC-6909 and never calls
///         `settle`, `take`, `mint` or `burn` (I13); that property is worth more than the flexibility.
///      2. *Let any caller flag any hop as pass-through.* Then every exit flags itself and the AMPS fee is
///         voluntary.
///      3. *Infer a rotation from the transient credit alone.* That is what revision 5 did, and it made the
///         credit a thing to manufacture: any buy, from anyone, minted a discount that any sell in the same
///         transaction could spend, so a batching settlement contract could pair an unrelated party's entry with
///         its own exit and pay the pass-through fee on a genuine exit.
///
///      What is left is a declaration the hook can check: `sender == AmpsHook.router()` **and** the hop carries
///      `Constants.ROUTER_ROTATE` in its `hookData`. This contract sets that flag on the two hops of {rotate} and
///      nowhere else — its own {buy} and {sell} pass empty `hookData` and pay the AMPS fee like everybody else,
///      because routing an exit through the protocol's front end must not make the exit cheaper.
///
/// @dev **What this contract is not.** It has no owner, no upgrade path, no fee of its own and no privileged
///      relationship with the vault, the registry or the bonds shell. Every address it holds is immutable, every
///      entry point takes a deadline and a minimum output, and it never holds an ERC-20 or native balance between
///      transactions: whatever is left at the end of a call is swept to the caller. Governance's only lever over
///      it is `AmpsHook.setRouter`, which can withdraw the pass-through exemption from it — or hand it to a
///      successor — without redeploying anything else.
interface IAmpsRouter {
    /// @notice Emitted by {buy}.
    /// @param poolId The pool bought through.
    /// @param payer The account whose counter asset was spent.
    /// @param to The account that received the AMPS.
    /// @param amountIn Counter asset spent, in its raw units.
    /// @param ampsOut AMPS received, in wei.
    event Bought(PoolId indexed poolId, address indexed payer, address indexed to, uint256 amountIn, uint256 ampsOut);

    /// @notice Emitted by {sell}.
    /// @param poolId The pool sold through.
    /// @param payer The account whose AMPS was spent.
    /// @param to The account that received the counter asset (or the ether, when unwrapped).
    /// @param ampsIn AMPS spent, in wei.
    /// @param amountOut Counter asset received, in its raw units.
    event Sold(PoolId indexed poolId, address indexed payer, address indexed to, uint256 ampsIn, uint256 amountOut);

    /// @notice Emitted by {rotate}, the one shape that pays the pass-through fee.
    /// @param hop1 The pool bought through.
    /// @param hop2 The pool sold through.
    /// @param to The account that received the output.
    /// @param amountIn Hop 1's input, in its raw units.
    /// @param ampsThrough The AMPS hop 1 realised, and therefore exactly what hop 2 sold.
    /// @param amountOut Hop 2's output, in its raw units.
    event Rotated(
        PoolId indexed hop1,
        PoolId indexed hop2,
        address indexed to,
        uint256 amountIn,
        uint256 ampsThrough,
        uint256 amountOut
    );

    // -------------------------------------------------------------------------------------------------------------
    // Reads
    // -------------------------------------------------------------------------------------------------------------

    /// @notice The Uniswap v4 PoolManager every swap goes through.
    /// @return poolManagerAddress The PoolManager.
    function poolManager() external view returns (address poolManagerAddress);

    /// @notice AMPS: `currency0` of all 32 pools, and the asset a rotation passes through.
    /// @return ampsAddress The token.
    function amps() external view returns (address ampsAddress);

    /// @notice The pool registry, which is where every `PoolKey` this contract uses comes from. A pool the
    ///         registry does not know cannot be traded here at all.
    /// @return registryAddress The registry.
    function registry() external view returns (address registryAddress);

    /// @notice The wrapped native token of the deployment chain, i.e. the counter asset of the `AMPS/WETH` entry
    ///         pool. The only asset {buy} will wrap `msg.value` into and the only one {sell} and {rotate} will
    ///         unwrap on the way out.
    /// @return wethAddress The wrapped native token.
    function weth() external view returns (address wethAddress);

    /// @notice The `hookData` this contract puts on both hops of a {rotate}, and on nothing else:
    ///         `Constants.ROUTER_ROTATE`.
    /// @dev Exposed so an integrator can verify against `AmpsHook` what the exemption actually keys on, rather
    ///      than taking a comment's word for it.
    /// @return flag The flag.
    function ROTATE_FLAG() external view returns (bytes32 flag);

    // -------------------------------------------------------------------------------------------------------------
    // Trades
    // -------------------------------------------------------------------------------------------------------------

    /// @notice Buys AMPS with a pool's counter asset: one exact-input swap, empty `hookData`.
    /// @dev **This is not pass-through.** It pays `AmpsHook.ampsFeeBps()` plus the pool's dynamic components, the
    ///      same as the identical swap through any other router, and it earns no rotation credit. Buying AMPS is
    ///      entering the index; only {rotate} moves through it.
    /// @dev Pass `msg.value == amountIn` to have native ether wrapped for you, which is legal only when the pool's
    ///      counter asset is {weth}. Otherwise `amountIn` is pulled from `msg.sender`, who must have approved this
    ///      contract.
    /// @param poolId The pool, which must be registered.
    /// @param amountIn Counter asset in, in its raw units.
    /// @param minAmpsOut The least AMPS the caller will accept; the call reverts `SlippageExceeded` below it.
    /// @param to The recipient of the AMPS.
    /// @param deadline The last block timestamp at which this call may execute.
    /// @return ampsOut AMPS received, in wei.
    function buy(PoolId poolId, uint256 amountIn, uint256 minAmpsOut, address to, uint256 deadline)
        external
        payable
        returns (uint256 ampsOut);

    /// @notice Sells AMPS for a pool's counter asset: one exact-input swap, empty `hookData`.
    /// @dev **This is not pass-through either**, and it spends no rotation credit even when called in the same
    ///      transaction as a {buy}: the two together are a round trip, not a rotation, and they pay
    ///      `AmpsHook.ampsFeeBps()` twice.
    /// @param poolId The pool, which must be registered.
    /// @param ampsIn AMPS in, in wei, pulled from `msg.sender`.
    /// @param minOut The least counter asset the caller will accept.
    /// @param to The recipient.
    /// @param unwrap Whether to unwrap the output to native ether, legal only on the {weth} pool.
    /// @param deadline The last block timestamp at which this call may execute.
    /// @return amountOut Counter asset received, in its raw units.
    function sell(PoolId poolId, uint256 ampsIn, uint256 minOut, address to, bool unwrap, uint256 deadline)
        external
        returns (uint256 amountOut);

    /// @notice Rotates between two pools through AMPS — the one shape that pays the pass-through fee on both hops.
    ///
    /// @dev Both hops run inside a single `IPoolManager.unlock`, both carry {ROTATE_FLAG} as `hookData`, and hop 2
    ///      sells **exactly** the AMPS hop 1 realised, read from the swap's own `BalanceDelta` rather than from
    ///      anything quoted beforehand. The router's AMPS delta on the PoolManager is asserted to be zero before
    ///      anything is settled, so a rotation that somehow failed to consume its own intermediate reverts rather
    ///      than banking the difference: no caller can end a `rotate` holding AMPS.
    ///
    /// @dev The two hops must be different pools. Buying AMPS in a pool and selling it straight back into the same
    ///      pool is a round trip that moves the tick out and back, not a rotation, and pricing it at two
    ///      pass-through fees would make the pool's liquidity pay for the caller's own noise.
    /// @param hop1 The pool bought through; its counter asset is the input.
    /// @param hop2 The pool sold through; its counter asset is the output.
    /// @param amountIn Hop 1's input, in its raw units. Pass `msg.value == amountIn` to wrap ether, legal only
    ///        when hop 1's counter asset is {weth}.
    /// @param minOut The least output the caller will accept.
    /// @param to The recipient of the output.
    /// @param unwrap Whether to unwrap the output to native ether, legal only when hop 2's counter is {weth}.
    /// @param deadline The last block timestamp at which this call may execute.
    /// @return amountOut Hop 2's output, in its raw units.
    /// @return ampsThrough The AMPS that passed through, in wei: hop 1's realised output and hop 2's whole input.
    function rotate(
        PoolId hop1,
        PoolId hop2,
        uint256 amountIn,
        uint256 minOut,
        address to,
        bool unwrap,
        uint256 deadline
    ) external payable returns (uint256 amountOut, uint256 ampsThrough);
}
