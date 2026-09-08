// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

import {PoolClass} from "../types/Types.sol";

/// @title IAmpsQuoter
/// @notice The one read surface an aggregator, a solver, a front end or a monitoring job needs to price an
///         Amplestocks pool without simulating a swap: the reference and market prices, NAV/share and the premium,
///         the band and the rail, both fee directions with the rotation credit applied, the bond terms per market,
///         and the gate state per pool.
///
/// @dev **It never reverts. That is the specification, not an aspiration.** `AmpsQuoter` is immutable and
///      `view`-only, and every external read it makes — into the hook, the gate, the feed registry, the vault's
///      checkpoint, `AmpsBonds` and the observation rings — is a bounded `try`/`staticcall`. A failure leaves that
///      read's fields at zero and raises its bit in {PoolQuote-degraded}; it never propagates. A quoter that can
///      revert is a quoter that takes the whole routing integration down with one stale feed, and the entire point
///      of the contract is to be the thing an external router can call blindly.
///
/// @dev **`degraded != 0` means "do not trade on this field".** The bitfield names *which* sub-read failed, so a
///      consumer can keep using the parts that did not:
///
///      | bit | source                | what is zeroed when it is set                             |
///      |-----|-----------------------|-----------------------------------------------------------|
///      | 0   | `AmpsHook`            | ticks, bands, all fee legs, `refuseBuy`/`refuseSell`               |
///      | 1   | `OracleGate`          | `gateState`, `session`, `feedStale`, `corporateFreeze`     |
///      | 2   | `FeedRegistry`        | the counter-asset price feeding `pMktX18`                  |
///      | 3   | vault checkpoint      | `navPerShareX18`, `pRefX18`, `premiumX18`, `checkpointAge` |
///      | 4   | `AmpsBonds`           | `bondQX18`, `bondDiscountBps`, `bondCapacityLeft`, `bondOpen` |
///      | 5   | TWAP coverage         | `pMktX18` (the ring covers less than `twapWindow`)         |
///
///      Two consequences are load-bearing and are tested as such. `pMktX18 == 0` with bit5 set means "this pool
///      does not have enough observation history to have a market price yet" — a young pool, not a broken one.
///      And `refuseBuy`/`refuseSell` are `false` whenever bit0 is set: the quoter fails **open** for display, and
///      an execution path must never treat a quote with `degraded != 0` as permission to trade.
///
/// @dev **{PoolQuote} is a fee-and-state view, not a curve simulator.** It says what a swap would *cost in
///      fees* and whether it would be refused, not how much comes out. The amount-level answers are separate
///      entry points — {quoteExactIn}, {quoteSellWithCredit} and {quoteRotation} — which walk the PoolManager's
///      own published ticks under the same never-revert rule and report `amountOut == 0` where a curve simulator
///      would throw. `V4Quoter` remains the off-chain cross-check, and the two are reconciled in the dApp.
interface IAmpsQuoter {
    /// @notice Everything the quoter knows about one pool, in one struct.
    ///
    /// @dev Memory-only, returned by value, never stored: no packing discipline, laid out for readability.
    /// @param poolId The pool.
    /// @param poolClass `ENTRY`, `SPOKE` or `SPOKE_HIGH_VOL`; `NONE` for an unregistered pool.
    /// @param counter The pool's `currency1`. AMPS is `currency0` in all 32 pools.
    /// @param pMktX18 The 30-minute truncated TWAP in USD per AMPS. **Zero means bit5 is set**, i.e. the ring does
    ///        not cover `twapWindow` yet — not "the price is zero".
    /// @param pRefX18 The reference price in USD per AMPS, from the vault checkpoint. Never below NAV/share (I24).
    /// @param navPerShareX18 NAV per share in USD, from the vault checkpoint.
    /// @param premiumX18 `pRefX18 / navPerShareX18 - 1`, signed, 18 decimals. Disclosure only: no path issues at
    ///        NAV, so nothing on-chain consumes it.
    /// @param poolTick The pool's live `slot0` tick.
    /// @param fairTick The tick the deviation is measured against.
    /// @param innerBandTicks The inner band half-width in force, by session and class.
    /// @param outerRailTicks The outer rail half-width in force.
    /// @param buyFeeBps The pool's **pass-through** base fee, in bps: what one hop of a protocol-router rotation
    ///        costs. Revision 6 — it is not what an ordinary buy pays.
    /// @param ampsFeeBps The protocol-wide AMPS fee, in bps: the base fee on **both** directions of this pool, and
    ///        what every swap that is not a router rotation hop pays.
    /// @param buyFeePips The **total** fee an ordinary buy would pay right now, in pips: `ampsFeeBps` plus the
    ///        clamped dynamic part. This is the number a front end quotes a user who is buying AMPS.
    /// @param sellFeePips The total fee an ordinary sell would pay right now, in pips. Same base, the sell
    ///        direction's dynamic part.
    /// @param passThroughBuyFeePips The total fee hop 1 of a protocol-router rotation would pay through this pool,
    ///        in pips: `buyFeeBps` plus the buy direction's clamped dynamic part. **Appended field, revision 6.**
    ///        Unreachable except through `AmpsRouter.rotate`; see {quoteRotation}.
    /// @param passThroughSellFeePips The same for hop 2 — an exact-input sell fully covered by the credit hop 1
    ///        created: `buyFeeBps` plus the sell direction's clamped dynamic part. **Appended field, revision 6.**
    /// @param dynBps The dynamic component in force, in bps.
    /// @param dynCapBps The cap on it for the pool's current gate state.
    /// @param refuseSell True when a sell would be refused for beginning beyond the outer rail on the
    ///        deviation-increasing side. False whenever bit0 of `degraded` is set.
    /// @param refuseBuy The same for a buy.
    /// @param bondQX18 The bond price `min(qMarket, qFloor)` for this pool's constituent, AMPS per unit of
    ///        collateral, 18 decimals. Zero for an entry pool with no open market.
    /// @param bondDiscountBps The clamped discount behind `bondQX18`.
    /// @param bondCapacityLeft AMPS wei still issuable by that market in the current epoch, after the global
    ///        daily cap is applied.
    /// @param bondOpen Whether the market accepts new bonds right now.
    /// @param gateState The `GateState` ordinal in force for this pool.
    /// @param session The `Session` ordinal in force.
    /// @param feedStale Whether the constituent's answer is beyond its session-scaled freshness bound.
    /// @param corporateFreeze Whether a corporate-action freeze applies to the constituent.
    /// @param observationCoverage Seconds of history the pool's observation ring covers.
    /// @param checkpointAge Age of the vault checkpoint in seconds.
    /// @param degraded The bitfield above. Zero means every sub-read succeeded.
    /// @param tickSpacing The pool's tick spacing, from the registry, or from the hook's mirror of it when bit1 of
    ///        `degraded`'s registry source is set. **Appended field** (`docs/phase3-state-model.md` §12.4):
    ///        building a Universal Router `PathKey` needs `fee`, `tickSpacing` and `hooks`, and without it a
    ///        router had to issue one `PoolRegistry.poolKey(poolId)` per routed pool on top of `quoteAll()`. `fee`
    ///        is the dynamic-fee sentinel for every Amplestocks pool and `hooks` is the one mined hook address, so
    ///        this is the last piece a caller could not already derive. Zero when neither source could answer.
    struct PoolQuote {
        PoolId poolId;
        PoolClass poolClass;
        address counter;
        uint256 pMktX18;
        uint256 pRefX18;
        uint256 navPerShareX18;
        int256 premiumX18;
        int24 poolTick;
        int24 fairTick;
        int24 innerBandTicks;
        int24 outerRailTicks;
        uint16 buyFeeBps;
        uint16 ampsFeeBps;
        uint24 buyFeePips;
        uint24 sellFeePips;
        uint24 passThroughBuyFeePips;
        uint24 passThroughSellFeePips;
        uint16 dynBps;
        uint16 dynCapBps;
        bool refuseSell;
        bool refuseBuy;
        uint256 bondQX18;
        uint16 bondDiscountBps;
        uint256 bondCapacityLeft;
        bool bondOpen;
        uint8 gateState;
        uint8 session;
        bool feedStale;
        bool corporateFreeze;
        uint32 observationCoverage;
        uint32 checkpointAge;
        uint8 degraded;
        int24 tickSpacing;
    }

    /// @notice The full quote for one pool.
    /// @dev Never reverts, including for an unregistered `poolId`: that returns a zeroed struct with
    ///      `poolClass == NONE`.
    /// @param poolId The pool.
    /// @return quote The quote.
    function quotePool(PoolId poolId) external view returns (PoolQuote memory quote);

    /// @notice {quotePool} for every registered pool, in the registry's own order.
    /// @dev Bounded by `Constants.MAX_CONSTITUENTS + 2`. A `view`, so the cost is the caller's.
    /// @return quotes The quotes.
    function quoteAll() external view returns (PoolQuote[] memory quotes);

    /// @notice Prices one exact-input swap: the fee the hook would charge, whether it would be refused, and the
    ///         output a full tick walk over the PoolManager's published state produces.
    /// @dev Never reverts. `amountOut` is zero whenever the swap would be refused, the pool is not initialised, or
    ///      the walk could not finish — all three of which also raise a bit in `degraded`, except the refusal,
    ///      which is reported through `refuse`.
    /// @dev The fee is the **ordinary** one: base `ampsFeeBps` in both directions, which is what any caller who
    ///      is not `AmpsRouter.rotate` pays. The pass-through price of a hop is {quoteRotation}'s to report.
    /// @param poolId The pool.
    /// @param zeroForOne True for a sell (AMPS in), false for a buy.
    /// @param amountIn The input, in the input currency's raw units.
    /// @return amountOut The output, in the output currency's raw units.
    /// @return feePips The total fee in pips, base plus the clamped dynamic part.
    /// @return refuse Whether the hook would refuse the swap for beginning beyond the outer rail.
    /// @return degraded The bitfield, restricted to the reads this call made.
    function quoteExactIn(PoolId poolId, bool zeroForOne, uint256 amountIn)
        external
        view
        returns (uint256 amountOut, uint24 feePips, bool refuse, uint8 degraded);

    /// @notice Prices a rotation — stock -> AMPS -> stock, or any two-hop path through an Amplestocks pool — with
    ///         the same-transaction rotation credit applied exactly as the hook would apply it.
    ///
    /// @dev **This prices the `AmpsRouter.rotate` path and nothing else.** Both hops are quoted as pass-through —
    ///      base `buyFeeBps[hop1]` and `buyFeeBps[hop2]` — because that is the fee the hook charges when, and only
    ///      when, `sender == IAmpsHook.router()` and both hops carry `Constants.ROUTER_ROTATE`. The same two swaps
    ///      built by hand through any other router each pay `ampsFeeBps`; use {quoteExactIn} twice for that.
    ///
    /// @dev **The credit is simulated, never read.** `IAmpsHook.rotationCredit(sender)` lives in EIP-1153 transient
    ///      storage and is therefore always zero when read from a fresh `eth_call`; consulting it would make every
    ///      quote wrong in exactly the direction that matters. What this function does instead is model the credit
    ///      the router's own hop 1 will create:
    ///
    ///      ```
    ///      hop 1: a pass-through buy in `hop1`, paying buyFeeBps[hop1]; the AMPS it yields is the credit
    ///      hop 2: a pass-through exact-input sell of exactly that AMPS in `hop2`, base fee
    ///             = buyFeeBps[hop2] + ceilDiv((ampsFeeBps - buyFeeBps[hop2]) * (ampsIn - credit), ampsIn)
    ///             = buyFeeBps[hop2], because `rotate` sells precisely what hop 1 bought
    ///      ```
    ///
    ///      That is the hook's own delta form, rounded up the same way, so the quote is exact rather than
    ///      approximate. Exact-**output** sells consume no credit and pay `ampsFeeBps` in full, which is why the
    ///      router only ever builds hop 2 as an exact-input swap.
    /// @param hop1 The pool bought through.
    /// @param hop2 The pool sold through.
    /// @param amountIn The input to hop 1, in `hop1`'s counter-asset raw units.
    /// @return amountOut The output of hop 2, in `hop2`'s counter-asset raw units.
    /// @return hop1FeePips The total fee hop 1 pays, in pips.
    /// @return hop2FeePips The total fee hop 2 pays, in pips, with the credit applied.
    /// @return creditUsed AMPS wei of credit hop 2 consumed.
    function quoteRotation(PoolId hop1, PoolId hop2, uint256 amountIn)
        external
        view
        returns (uint256 amountOut, uint24 hop1FeePips, uint24 hop2FeePips, uint256 creditUsed);

    /// @notice Prices an exact-input **sell** that carries a same-transaction rotation credit: hop 2 of a
    ///         rotation, in the general case where the sell is larger than the buy that funds it.
    ///
    /// @dev **A credit exists only on the protocol router's rotation path.** Since revision 6 the hook credits a
    ///      buy, and lets a sell spend a credit, only when `sender == IAmpsHook.router()` and the hop carries
    ///      `Constants.ROUTER_ROTATE`. So any `credit != 0` passed here describes a hop inside an
    ///      `AmpsRouter.rotate`, and for every other caller in the world the honest argument is `credit == 0` —
    ///      which prices the sell at `ampsFeeBps`, exactly as {quoteExactIn} does.
    /// @dev The general case of hop 2 of {quoteRotation}: `credit >= ampsIn` reproduces a pure rotation and prices
    ///      the whole sell at `buyFeeBps`, `credit == 0` prices it at `ampsFeeBps`, and everything between is the
    ///      hook's `ceilDiv` blend on the uncredited excess. The credit is an argument rather than a read, because
    ///      the hook holds it in transient storage where an `eth_call` always sees zero.
    /// @param poolId The pool sold through.
    /// @param ampsIn AMPS wei sold.
    /// @param credit AMPS wei of same-transaction rotation credit the router will hold when the sell lands; zero
    ///        for every path that is not `AmpsRouter.rotate`.
    /// @return amountOut The counter asset received, in its raw units.
    /// @return feePips The total fee in pips, with the credit applied.
    /// @return refuse Whether the hook would refuse the sell.
    /// @return degraded The bitfield, restricted to the reads this call made.
    function quoteSellWithCredit(PoolId poolId, uint256 ampsIn, uint256 credit)
        external
        view
        returns (uint256 amountOut, uint24 feePips, bool refuse, uint8 degraded);

    /// @notice Whether a swap would revert right now, and why.
    /// @dev The rail is the hook's answer, not this contract's: `IAmpsHook.quoteFee` reports the refusal that
    ///      `beforeSwap` would throw as `Errors.BeyondRail`. The quoter fails **open** — a hook it cannot read
    ///      reports `refuse == false` with bit 0 set — because a display path must not invent a refusal and an
    ///      execution path must never treat `degraded != 0` as permission to trade.
    /// @param poolId The pool.
    /// @param zeroForOne True for a sell (AMPS in).
    /// @param exactInput True for an exact-input swap.
    /// @param amount The input amount, or 0 when unknown.
    /// @return refuse Whether the swap would revert.
    /// @return reason `bytes32(0)`, `bytes32("rail")` or `bytes32("uninitialized")`.
    /// @return degraded The bitfield, restricted to the reads this call made.
    function wouldRevert(PoolId poolId, bool zeroForOne, bool exactInput, uint256 amount)
        external
        view
        returns (bool refuse, bytes32 reason, uint8 degraded);

    /// @notice The redemption floor expressed in the pool's own ticks: the tick at which AMPS trades at NAV/share,
    ///         the rail `NAV_RAIL_TICKS` below it, and whether the pool is currently under that rail.
    /// @dev Disclosure, not enforcement. Nothing on-chain refuses a swap for being below NAV; what the plan says is
    ///      that nobody rational sells below the redemption floor, and this is the number that makes that visible.
    ///      A pool below the rail is a pool where `redeemProRata` is the better exit.
    /// @param poolId The pool.
    /// @return navTick The spacing-aligned tick at which the pool prices AMPS at NAV/share.
    /// @return railTick `navTick - NAV_RAIL_TICKS`, the implementation's `Constants.OUTER_RAIL_MIN_TICKS`.
    /// @return belowRail Whether the live tick is below `railTick`.
    /// @return navPerShareX18 The NAV/share the ticks were derived from.
    /// @return degraded The bitfield, restricted to the reads this call made.
    function navRail(PoolId poolId)
        external
        view
        returns (int24 navTick, int24 railTick, bool belowRail, uint256 navPerShareX18, uint8 degraded);

    /// @notice The bond terms of one market, mirroring `AmpsBonds`' own `min(qMarket, qFloor)` with the same
    ///         rounding directions.
    /// @dev `q <= q_floor` in every state (I27), so a quote that disagrees with the shell is a bug in one of them
    ///      and the reconciliation test says which.
    /// @param marketId The 1-based market id.
    /// @return qX18 AMPS wei issued per unit of collateral, 18 decimals. Zero when the market cannot price.
    /// @return discountBps The clamped discount behind it.
    /// @return capacityLeft AMPS wei still issuable this epoch, after the global daily cap.
    /// @return open Whether the market accepts new bonds right now.
    /// @return degraded The same bitfield as {PoolQuote-degraded}, restricted to the reads this call made.
    function bondQuote(uint16 marketId)
        external
        view
        returns (uint256 qX18, uint16 discountBps, uint256 capacityLeft, bool open, uint8 degraded);

    /// @notice The vault this quoter reads.
    /// @return vaultAddress The vault address.
    function vault() external view returns (address vaultAddress);

    /// @notice The pool registry.
    /// @return registryAddress The registry address.
    function registry() external view returns (address registryAddress);

    /// @notice The hook.
    /// @return hookAddress The hook address.
    function hook() external view returns (address hookAddress);

    /// @notice The bonds shell.
    /// @return bondsAddress The bonds address.
    function bonds() external view returns (address bondsAddress);

    /// @notice Identifier of this quoter, for the dApp and for integration diffs.
    /// @return id A short identifier, e.g. `bytes32("amps-quoter-v1")`.
    function version() external pure returns (bytes32 id);
}
