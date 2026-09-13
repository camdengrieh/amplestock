// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

import {HookPoolState} from "../types/Types.sol";
import {IMarketReference} from "./IMarketReference.sol";

/// @title IAmpsHook
/// @notice The read surface `AmpsVault`, `AmpsBonds` and `AmpsQuoter` use against the one immutable hook that
///         serves all 32 pools. This is deliberately **not** the `IHooks` callback surface: the PoolManager talks
///         to the hook through `IHooks`, and the protocol talks to it through this.
///
/// @dev **Permissions are `0x38C0`**: `BEFORE_INITIALIZE | AFTER_INITIALIZE | BEFORE_ADD_LIQUIDITY | BEFORE_SWAP |
///      AFTER_SWAP`. No `*_RETURNS_DELTA` bit and no `BEFORE_REMOVE_LIQUIDITY` bit, ever — removals must never be
///      blockable (I18), and a returns-delta bit is what turned every hook-custody incident in the survey into a
///      loss. The hook holds no ERC-20 and no ERC-6909, mirrors no PoolManager balance, and never calls
///      `settle`, `take`, `mint`, `burn`, `donate` or `swap` (I13).
///
/// @dev **What the vault reads here.**
///        - the market reference (inherited from {IMarketReference}): per-pool truncated TWAPs backing `P_mkt`;
///        - the per-pool high-water tick, and the vault-only {resetHighWater} that arms the next buyback-burn
///          window;
///        - the live same-transaction rotation credit, for the quoter;
///        - per-pool configuration, so the quoter can reproduce a fee without simulating a swap.
///
/// @dev **The fee model, revision 6.** {ampsFeeBps} is the base fee on **both** directions of every pool: a buy
///      of AMPS and a sell of AMPS both pay it. {buyFeeBps} is the **pass-through** base — the price of one hop
///      of a rotation — and is charged only on a hop where `sender == router()` and `hookData` is exactly
///      `Constants.ROUTER_ROTATE`. The dynamic components and the rail refusal are unchanged and sit on top.
///
/// @dev **The rotation credit lives in EIP-1153 transient storage**, so it is zero at the start of every
///      transaction and cannot be carried across one (I26). It is credited in `afterSwap` by the AMPS a
///      pass-through buy actually received, and consumed in `beforeSwap` by a pass-through exact-input sell,
///      blended and rounded **up**. Only {router} can earn or spend one: every other hop pays {ampsFeeBps} and
///      leaves the slot alone, so a manufactured credit is not a thing that exists to be gamed.
interface IAmpsHook is IMarketReference {
    /// @notice Emitted by `afterSwap` when a pool's high-water tick advances.
    /// @param poolId The pool.
    /// @param highWaterTick The new mark.
    event HighWaterAdvanced(PoolId indexed poolId, int24 highWaterTick);

    /// @notice Emitted when the vault resets a pool's high-water mark at `compound()`.
    /// @param poolId The pool.
    /// @param previousHighWaterTick The mark that was consumed.
    /// @param newHighWaterTick The mark it was reset to: `min(lastTruncatedTick, lastRawTick)`, so it is never
    ///        left above where the pool actually is. See {resetHighWater}.
    event HighWaterReset(PoolId indexed poolId, int24 previousHighWaterTick, int24 newHighWaterTick);

    /// @notice Emitted when a surge fee is armed.
    /// @param poolId The pool.
    /// @param surgeBps The surge, before decay.
    /// @param reason A short identifier: `bytes32("placement")`, `bytes32("sessionOpen")`,
    ///        `bytes32("multiplierStep")` or `bytes32("refJump")`.
    event SurgeArmed(PoolId indexed poolId, uint16 surgeBps, bytes32 reason);

    /// @notice Emitted when a `uiMultiplier()` step is detected on a constituent.
    /// @dev Both multipliers are reported in the token's own 18-decimal form. The hook caches the previous one as
    ///      X9 (see `HookPoolState.uiMultiplierX9`), so `previousMultiplierX18` is that value scaled back up and
    ///      is therefore a multiple of `1e9`; `newMultiplierX18` is the raw reading, unscaled.
    /// @param poolId The pool.
    /// @param previousMultiplierX18 The cached multiplier.
    /// @param newMultiplierX18 The observed multiplier.
    /// @param captureFeeBps The capture fee armed, or 0 when the step was large enough to freeze instead.
    event MultiplierStepDetected(
        PoolId indexed poolId, uint256 previousMultiplierX18, uint256 newMultiplierX18, uint16 captureFeeBps
    );

    /// @notice Emitted when a same-transaction rotation credit is consumed by a sell.
    /// @param poolId The pool the sell went through.
    /// @param consumed AMPS wei of credit used.
    /// @param blendedFeeBps The blended base fee that resulted.
    event RotationCreditConsumed(PoolId indexed poolId, uint256 consumed, uint16 blendedFeeBps);

    /// @notice Emitted by `afterSwap` when a pool has drifted far enough from fair to be worth a keeper's look.
    /// @dev Advisory only. Nothing on-chain reads it, no path is gated on it, and it is emitted when
    ///      `abs(tick - fairTick) > innerBandTicks / 2`. Ladders are static: the keeper's answer to this event is
    ///      `compound()` or `rollout()`, never a re-centring, which does not exist.
    /// @param poolId The pool.
    /// @param tick The raw post-swap tick.
    /// @param fairTick The fair tick in force.
    event RebalanceNeeded(PoolId indexed poolId, int24 tick, int24 fairTick);

    /// @notice Emitted when `afterSwap` refreshes a pool's cached gate view, at most once per
    ///         `Constants.GATE_CACHE_SECONDS_DEFAULT`.
    /// @dev Emitted on a *failed* refresh as well, with `gateFlags` bit2 (`refreshFailed`) set and the previous
    ///      values repeated: the indexer must be able to tell a stale cache from a fresh one, and no refresh
    ///      failure may ever reach the swapper as a revert.
    /// @param poolId The pool.
    /// @param gateFlags bit0 degraded, bit1 corporateFreeze, bit2 refreshFailed, bit3 caArmed.
    /// @param session The equity session cached.
    /// @param dynCapBps The dynamic-fee cap now in force.
    /// @param innerBandTicks The inner band half-width now in force.
    /// @param outerRailTicks The outer rail half-width now in force.
    /// @param fairTick The fair tick now in force.
    event GateCacheRefreshed(
        PoolId indexed poolId,
        uint8 gateFlags,
        uint8 session,
        uint16 dynCapBps,
        int24 innerBandTicks,
        int24 outerRailTicks,
        int24 fairTick
    );

    /// @notice Emitted by every governed hook setter, so the indexer and the governance drill can follow a
    ///         parameter without decoding calldata. Mirrors `IAmpsVault.VaultParameterChanged`.
    /// @param parameter The parameter name as a short string, e.g. `bytes32("ampsFeeBps")`.
    /// @param poolId The pool the change applies to, or `bytes32(0)` for a protocol-wide parameter.
    /// @param previousValue The value before.
    /// @param newValue The value after.
    event HookParameterChanged(
        bytes32 indexed parameter, PoolId indexed poolId, uint256 previousValue, uint256 newValue
    );

    /// @notice Emitted when the fee policy pointer moves. **7-day timelock.**
    /// @param previousPolicy The policy replaced.
    /// @param newPolicy The policy installed.
    event FeePolicyChanged(address indexed previousPolicy, address indexed newPolicy);

    /// @notice Emitted when the pass-through router pointer moves. **7-day timelock.**
    /// @param previousRouter The router that loses the pass-through exemption.
    /// @param newRouter The router that gains it; `address(0)` turns the exemption off entirely.
    event RouterChanged(address indexed previousRouter, address indexed newRouter);

    /// @notice Emitted when the hook is handed from one vault to another by {setVault}.
    /// @param previousVault The vault that gave the hook up.
    /// @param newVault The vault that now holds every vault-only entry point.
    event VaultChanged(address indexed previousVault, address indexed newVault);

    /// @notice `currency0` of the pool being initialised is not AMPS. Hard requirement: it fixes the sign of every
    ///         fee direction and every one-sided placement in the protocol.
    error Currency0NotAmps();

    /// @notice The pool was not initialised with the dynamic-fee flag.
    error FeeNotDynamic();

    /// @notice The pool is not in `PoolRegistry`.
    /// @param poolId The pool.
    error PoolNotRegistered(PoolId poolId);

    /// @notice The `PoolKey` the PoolManager is initialising disagrees with the registry's record for it.
    /// @dev `beforeInitialize` re-derives `counter` and `tickSpacing` from `PoolRegistry.poolConfig` and compares
    ///      them with `key.currency1` and `key.tickSpacing`. Two contracts hold the pool's shape, so one of them
    ///      has to be the authority and the other has to check; the registry is the authority.
    /// @param field The field that disagreed, as a short string: `bytes32("counter")` or `bytes32("tickSpacing")`.
    error PoolKeyMismatch(bytes32 field);

    /// @notice **Superseded.** The Phase 2 spelling of the rail refusal, retained because a declared error
    ///         selector is ABI and this interface never removes a member.
    /// @dev `docs/phase3-state-model.md` §10 ruling 2 fixes the thrown error as `Errors.BeyondRail(bytes32 poolId,
    ///      int24 devTicks, int24 outerRailTicks)`, shared at file level because the vault-side tests, the quoter
    ///      and the invariant handler all decode it, and checked **twice** — on the start-of-swap tick in
    ///      `beforeSwap` and on the post-swap tick in `afterSwap`. `AmpsHook` throws `Errors.BeyondRail`; nothing
    ///      throws this. Do not add a second thrower.
    /// @param poolId The pool.
    /// @param devTicks The deviation after the swap.
    /// @param outerRailTicks The rail in force.
    error BeyondOuterRail(PoolId poolId, int24 devTicks, int24 outerRailTicks);

    // -------------------------------------------------------------------------------------------------------------
    // Reads (permissionless)
    // -------------------------------------------------------------------------------------------------------------

    /// @notice AMPS. `currency0` of every Amplestocks pool.
    /// @return ampsAddress The token address.
    function amps() external view returns (address ampsAddress);

    /// @notice The vault: the only address allowed to initialise a pool, add liquidity or reset a high-water mark.
    /// @dev Storage rather than an immutable, so `AmpsVault.emergencyMigrate` can hand the hook to the standby
    ///      vault; see {setVault}.
    /// @return vaultAddress The vault address.
    function vault() external view returns (address vaultAddress);

    /// @notice The pool registry.
    /// @return registryAddress The registry address.
    function registry() external view returns (address registryAddress);

    /// @notice The protocol router: the only `sender` whose swaps can ever be pass-through, and then only on a
    ///         hop carrying `Constants.ROUTER_ROTATE` as its `hookData`.
    /// @dev Governed storage, replaceable by the timelock, `address(0)` at deployment and a legal setting
    ///      thereafter (meaning "no router; every hop pays `ampsFeeBps`"). The hook never calls this address —
    ///      it is a permission, not a pointer — so naming a contract here can move no value and block no swap.
    /// @return routerAddress The router address.
    function router() external view returns (address routerAddress);

    /// @notice The oracle gate.
    /// @return gateAddress The gate address.
    function oracleGate() external view returns (address gateAddress);

    /// @notice The fee policy pointer.
    /// @return policyAddress The `IFeePolicy` address.
    function feePolicy() external view returns (address policyAddress);

    /// @notice The governance timelock: the only caller of {setAmpsFeeBps}, {setBuyFeeBps},
    ///         {setMaxTickMovePerBlock} and {setFeePolicy}.
    /// @return timelockAddress The timelock address.
    function timelock() external view returns (address timelockAddress);

    /// @notice How often `afterSwap` may refresh a pool's cached gate view, in seconds.
    /// @dev The whole caching strategy in one number: `beforeSwap` reads three of the hook's own words plus the
    ///      pure fee policy and nothing else, and every external read — gate, registry, feeds, hub TWAP,
    ///      `uiMultiplier()` — happens in `afterSwap` at most this often per pool.
    /// @return seconds_ The interval. `Constants.GATE_CACHE_SECONDS_DEFAULT` (60) at launch.
    function gateCacheSeconds() external view returns (uint32 seconds_);

    /// @notice The origin of a pool's canonical doubling grid, as the hook cached it at `afterInitialize`.
    /// @dev `PriceLib.alignTick(openingTick, tickSpacing, true)`. The same value the registry stores in
    ///      `PoolConfig.gridBaseTick`; the registry's copy is the one `LadderPositionValuer` reads, this one is
    ///      the hook's own so a placement check needs no registry call.
    /// @param poolId The pool.
    /// @return tick The grid origin.
    function gridBaseTick(PoolId poolId) external view returns (int24 tick);

    /// @notice The whole per-pool hook state.
    /// @param poolId The pool.
    /// @return state The state, excluding the observation ring (read that through {IMarketReference}).
    function poolState(PoolId poolId) external view returns (HookPoolState memory state);

    /// @notice The live same-transaction rotation credit one account holds, in AMPS wei.
    /// @dev Reads EIP-1153 transient storage, so it is always zero when read from a fresh transaction — which is
    ///      exactly what makes it useless to an off-chain observer and safe to expose.
    /// @dev **The credit is per `sender`, not per transaction.** It is credited to, and spendable only by, the
    ///      account the PoolManager reports as the swap's `sender` — the router or settlement contract that
    ///      unlocked it. One transaction-global credit would pool the credits of every settlement path in a
    ///      transaction: two independent routers in one multicall, or two bundle-mates sharing a builder's
    ///      transaction, would discount each other's sells, and a credit earned in the deep hub would discount a
    ///      sell into a thin spoke. The `sender` key bounds a credit to the path that earned it.
    ///
    /// @dev **Only {router} can ever hold one.** A buy earns a credit only when it is the protocol router's
    ///      rotation hop — `sender == router()` and `hookData == Constants.ROUTER_ROTATE` — and a sell spends one
    ///      only under the same condition. Every other swap in the system, from any sender and through any
    ///      router, pays `ampsFeeBps` in both directions and neither earns nor spends. This view therefore reads
    ///      zero for every address but the router, and reads zero for the router too outside the one transaction
    ///      in which its `rotate` is running.
    /// @param sender The account whose credit to read; in practice, {router}.
    /// @return credit The credit.
    function rotationCredit(address sender) external view returns (uint256 credit);

    /// @notice The fee the hook would charge for a swap right now, without simulating one.
    /// @dev The quoter's entry point. Never reverts: a swap that would be refused returns `refuse == true`.
    ///
    /// @dev **`passThrough` is the whole fee model in one flag.** `false` prices an ordinary swap by anybody at
    ///      all — base `ampsFeeBps`, in both directions, on every pool. `true` prices the protocol router's
    ///      rotation hop: base `buyFeeBps` on a buy; base `buyFeeBps` on an exact-input sell, because the credit
    ///      a `rotate` carries into hop 2 is by construction exactly the AMPS hop 1 returned; and base
    ///      `ampsFeeBps` on an exact-output sell, which consumes no credit and which the router never builds.
    ///      Nothing else can obtain the `true` pricing: see {router}.
    ///
    /// @dev Reads no transient storage. A credit belongs to the swap's `sender`, which an `eth_call` is not, so
    ///      the pass-through case is *modelled* rather than looked up. A partially covered sell — one larger than
    ///      the rotation that funds it — is priced by `AmpsQuoter.quoteSellWithCredit`.
    ///
    /// @dev **There is exactly one fee entry point, and `passThrough` is not optional.** An earlier revision
    ///      carried a four-argument alias that meant `passThrough == false`; it was removed because an alias for
    ///      the honest case is an invitation to quote the dishonest one by accident, and because an overloaded
    ///      `quoteFee` makes `IAmpsHook.quoteFee.selector` ambiguous, which forced every off-chain and on-chain
    ///      caller to hand-spell the signature. An ordinary swap — which is every swap that is not the protocol
    ///      router's rotation hop — passes `false`.
    /// @param poolId The pool.
    /// @param zeroForOne True for a sell (AMPS in).
    /// @param exactInput True for an exact-input swap.
    /// @param amountIn The input amount, or 0 when unknown.
    /// @param passThrough Whether to price the swap as one leg of a protocol-router rotation.
    /// @return feePips The fee in pips, without the override flag.
    /// @return baseBps The base component: `ampsFeeBps`, `buyFeeBps`, or the blend between them.
    /// @return dynBps The dynamic component after clamping.
    /// @return refuse Whether the swap would be refused for being deviation-increasing beyond the outer rail.
    function quoteFee(PoolId poolId, bool zeroForOne, bool exactInput, uint256 amountIn, bool passThrough)
        external
        view
        returns (uint24 feePips, uint16 baseBps, uint16 dynBps, bool refuse);

    /// @notice The largest total fee, in basis points, the hook is charging in `poolId` right now — the maximum
    ///         of the two directions, base plus the clamped dynamic part, priced as an ordinary (non-pass-through)
    ///         exact-input swap of size zero.
    ///
    /// @dev **Why the maximum, and why it lives here** (audit fix, 2026-09-09). `AmpsVault`'s creator slice
    ///      divides a pool's collected fees back into the volume that produced them, with one divisor for both
    ///      currencies — but the two currencies are earned at two different rates: the AMPS side at the sell rate,
    ///      the counter side at the buy rate, and the dynamic part is asymmetric by construction, because it is
    ///      what makes a deviation-increasing trade expensive. A divisor sampled from one direction and applied to
    ///      the other paid the creator up to 4.33x `CREATOR_FEE_BPS` of that side's volume out of NAV. The larger
    ///      of the two rates bounds both quotients from below, so it is the one number the vault needs — and the
    ///      rate a pool is charging is the hook's own fact, so the hook is where the maximum is taken.
    /// @dev Never reverts. An unknown pool answers zero, which every consumer reads as "no answer".
    /// @param poolId The pool.
    /// @return bps The larger of the two directions' total fee, in bps.
    function chargedFeeBps(PoolId poolId) external view returns (uint16 bps);

    /// @notice The inner band half-width currently in force for a pool.
    /// @param poolId The pool.
    /// @return ticks The half-width.
    function innerBandTicks(PoolId poolId) external view returns (int24 ticks);

    /// @notice The outer rail half-width currently in force for a pool.
    /// @param poolId The pool.
    /// @return ticks The half-width.
    function outerRailTicks(PoolId poolId) external view returns (int24 ticks);

    /// @notice The fair tick a pool's deviation is measured against: `tickOf(P_mkt / P_i)` for a spoke, the pool's
    ///         own truncated TWAP for an entry pool.
    /// @dev Deliberately `P_mkt`, not the rate-limited `P_ref`: a spoke must be able to follow a hub move inside
    ///      one TWAP window, which is the mechanism that turns a hub pump into stock backing across all 30 spokes.
    /// @param poolId The pool.
    /// @return tick The fair tick.
    function fairTick(PoolId poolId) external view returns (int24 tick);

    // -------------------------------------------------------------------------------------------------------------
    // Governed parameters
    // -------------------------------------------------------------------------------------------------------------

    /// @notice The protocol-wide AMPS fee: the base fee on **both** directions of all 32 pools. 500 bp at launch.
    /// @dev Revision 6. It is not a sell fee: a buy of AMPS pays it too, because entering the index and leaving it
    ///      are the same trade seen from two sides, and a fee charged on one side alone is a fee a round trip
    ///      halves. What the base fee is *not* charged on is a rotation — moving between two constituents through
    ///      AMPS — which is the pass-through case {buyFeeBps} prices.
    /// @return value The parameter.
    function ampsFeeBps() external view returns (uint16 value);

    /// @notice A pool's **pass-through** base fee: what one hop of a protocol-router rotation costs.
    /// @dev Revision 6. This is no longer the fee an ordinary buy pays — an ordinary buy pays {ampsFeeBps}, like
    ///      every other hop. It is charged only on a hop where `sender == router()` and the hop carries
    ///      `Constants.ROUTER_ROTATE`, i.e. on the two hops of `AmpsRouter.rotate`, and it is the price of moving
    ///      through the index rather than into or out of it. Bands are unchanged: [5, 100] bp entry, [1, 50] bp
    ///      spoke.
    /// @param poolId The pool.
    /// @return value The parameter. 30 bp entry, 5 or 10 bp spoke.
    function buyFeeBps(PoolId poolId) external view returns (uint16 value);

    // -------------------------------------------------------------------------------------------------------------
    // Hard bands
    // -------------------------------------------------------------------------------------------------------------

    /// @notice Hard floor of `ampsFeeBps`, in bps. 100.
    /// @return value The bound.
    function AMPS_FEE_BPS_MIN() external view returns (uint16 value);

    /// @notice Hard ceiling of `ampsFeeBps`, in bps. 600.
    /// @return value The bound.
    function AMPS_FEE_BPS_MAX() external view returns (uint16 value);

    /// @notice The largest total fee the hook can ever return, in bps. 2,600, far below `MAX_LP_FEE` (I16).
    /// @return value The bound.
    function TOTAL_FEE_BPS_MAX() external view returns (uint16 value);

    /// @notice The hook's permission bits: `0x38C0`. Asserted against the mined address at deployment and
    ///         re-verified in CI after every dependency bump.
    /// @return value The flags.
    function HOOK_FLAGS() external view returns (uint16 value);

    // -------------------------------------------------------------------------------------------------------------
    // Mutative
    // -------------------------------------------------------------------------------------------------------------

    /// @notice Resets a pool's high-water tick to the truncated tick currently in force. **Only vault.**
    /// @dev Called by `compound()` after the buyback burn has consumed the previous window. Vault-only because the
    ///      mark is what decides which AMPS is bought-back inventory: anyone able to reset it could hide a buyback
    ///      from the burn.
    /// @dev The mark is re-armed at `min(lastTruncatedTick, lastRawTick)` and not at the truncated tick alone:
    ///      the truncated tick is rate-limited and can sit thousands of ticks above the pool after a fast fall,
    ///      and a mark left up there would cover the asks the same `compound` re-lays at the fallen price — which
    ///      the next `compound` would then burn as inventory that was never sold. Flooring it can only lower the
    ///      mark, so it never widens what the burn takes.
    /// @param poolId The pool.
    /// @return previousHighWaterTick The mark that was consumed.
    function resetHighWater(PoolId poolId) external returns (int24 previousHighWaterTick);

    /// @notice Arms a surge on a pool. **Only vault.** Called after every placement, so a placement cannot be
    ///         sandwiched at the old fee.
    /// @param poolId The pool.
    /// @param surgeBps The surge to arm, at most `Constants.SURGE_MAX_BPS`.
    /// @param reason A short identifier for the event.
    function armSurge(PoolId poolId, uint16 surgeBps, bytes32 reason) external;

    /// @notice Sets the protocol-wide sell fee. **Only timelock (48 h).**
    /// @param value The new fee, inside `[AMPS_FEE_BPS_MIN, AMPS_FEE_BPS_MAX]`.
    function setAmpsFeeBps(uint16 value) external;

    /// @notice Sets a pool's buy fee. **Only timelock (48 h).**
    /// @param poolId The pool.
    /// @param value The new fee, inside the pool class's band.
    function setBuyFeeBps(PoolId poolId, uint16 value) external;

    /// @notice Sets a pool's per-block oracle truncation cap. **Only timelock (48 h).**
    /// @param poolId The pool.
    /// @param value The new cap, inside
    ///        `[MAX_TICK_MOVE_PER_BLOCK_MIN, MAX_TICK_MOVE_PER_BLOCK_MAX]`.
    function setMaxTickMovePerBlock(PoolId poolId, int24 value) external;

    /// @notice Replaces the fee policy pointer. **Only timelock (7 d).**
    /// @param newPolicy The new `IFeePolicy`.
    function setFeePolicy(address newPolicy) external;

    /// @notice Names the protocol router, the only `sender` that can hold the pass-through exemption. **Only
    ///         timelock (7 d).** Replaceable, and `address(0)` is legal: it withdraws the exemption entirely.
    /// @dev The address is never called by the hook, so there is no code check and no zero check. Emits
    ///      {RouterChanged}.
    /// @param newRouter The new router, or `address(0)` for none.
    function setRouter(address newRouter) external;

    /// @notice Hands the hook to a new vault. **Only the current vault.**
    /// @dev The migration leg of {vault}. `AmpsVault.emergencyMigrate` calls this best-effort while moving the
    ///      protocol to its standby vault; without it the standby could never `initializePool`, add liquidity or
    ///      {armSurge}, because every one of those checks is against {vault}. Reverts on the zero address, and
    ///      emits {VaultChanged}.
    /// @param newVault The vault that takes over every vault-only entry point.
    function setVault(address newVault) external;
}
