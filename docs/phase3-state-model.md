# Phase 3 state model

The specification the five Phase 3 agents code against: `AmpsHook` + `PoolStateLib`, the three policies, the vault
placement path, `LadderPositionValuer`, and `AmpsQuoter` + scripts. It continues
[`phase2-state-model.md`](./phase2-state-model.md) and reuses its conventions (`A`, `T`, `X18`, bps of
`Constants.BPS`). The Phase 2 interfaces — `IAmpsHook`, `IMarketReference`, `IPositionValuer`, `ILadderPolicy`,
`IFeePolicy`, `IRolloutPolicy` — and `types/{Types,Constants,Errors}.sol` are **normative**; where this document
adds a field, a constant or a getter, section 9 says so and why.

**What Phase 3 may not change.** `IAmpsVault`'s 91 declared functions; the vault's storage layout (slots 0-19);
the NAV formula; `redeemProRata`'s structural ungatedness; the hard bands in `Constants`. `HookPoolState`,
`PlacementRecord` and `Constants` may gain fields and values — they are types, not deployed state — but no
existing field may move.

**Licence rule, restated because it bites here.** Production code must not import `StateLibrary` (MIT, imports
BUSL `Position.sol`) or `TransientStateLibrary` (MIT, imports BUSL `Lock`/`CurrencyReserves`/`NonzeroDeltaCount`).
Section 2 derives every slot we need, so `PoolStateLib` is written from scratch under MIT.

---

## 1. `AmpsHook` (`src/hook/AmpsHook.sol`)

One immutable contract for all 32 pools, mined so `address & 0x3FFF == 0x38C0` (`BEFORE_INITIALIZE |
AFTER_INITIALIZE | BEFORE_ADD_LIQUIDITY | BEFORE_SWAP | AFTER_SWAP`). Holds no ERC-20 and no ERC-6909, never calls
`settle/take/mint/burn/donate/swap`, performs no liquidity op in any callback (I13).

### 1.1 Imports — MIT only

Permitted: `@openzeppelin/uniswap-hooks/src/base/BaseHook.sol` (MIT, pulls nothing BUSL); v4-core
`interfaces/{IPoolManager,IHooks,IExtsload}`, `types/{Currency,PoolId,PoolKey,BalanceDelta,BeforeSwapDelta,PoolOperation}`,
`libraries/{Hooks,LPFeeLibrary,TickMath,FullMath,SafeCast,FixedPoint96,FixedPoint128}`; ours: `PriceLib`, `TruncatedOracleLib`,
`PoolStateLib`, `Constants`, `Types`, `Errors`, `IFeePolicy`, `IPoolRegistry`, `IOracleGate`, `IStockToken`.
Forbidden and CI-gated: `StateLibrary`, `TransientStateLibrary`, `Position.sol`, `Pool.sol`, `PoolManager.sol`.

### 1.2 Storage

```
immutable  amps (Currency)   registry   timelock        poolManager (from BaseHook)
storage    address vault    — set in the constructor; reassigned only by setVault (msg.sender == vault), the
                             migration handover (audit fix 12)
slot 0     uint16 _sellFeeBps | address _feePolicy | uint16 _gateCacheSeconds
mapping(PoolId => uint256) _cfg    CONFIG word   — written at afterInitialize, then only by governance
mapping(PoolId => uint256) _dyn    DYNAMIC word  — written by afterSwap
mapping(PoolId => uint256) _arm    ARMED word    — written by afterSwap and by armSurge
mapping(PoolId => TruncatedOracleLib.State) _obs   64 ring slots + 1 head slot per pool
```

```
CONFIG _cfg                                DYNAMIC _dyn                        ARMED _arm
[  0.. 15] uint16 buyFeeBps                [  0.. 23] int24  lastTick          [  0.. 15] uint16 surgeBps
[ 16.. 31] uint16 constituentId            [ 24.. 55] uint32 lastUpdate        [ 16.. 47] uint32 surgeArmedAt
[ 32.. 39] uint8  poolClass                [ 56.. 79] int24  fairTick          [ 48.. 63] uint16 captureFeeBps
[ 40.. 63] int24  tickSpacing              [ 80..103] int24  innerBandTicks    [ 64.. 95] uint32 captureArmedAt
[ 64.. 87] int24  maxTickMovePerBlock      [104..127] int24  outerRailTicks    [ 96..159] uint64 uiMultiplierX18
[ 88.. 95] uint8  counterDecimals          [128..143] uint16 dynCapBps         [160..223] uint64 varianceX18
[ 96..119] int24  gridBaseTick             [144..151] uint8  session           [224..255] uint32 lastCorporateCheck
[120..127] bool   initialized              [152..159] uint8  gateFlags
[128..255] (free)                          [160..167] uint8  fVolBps      pre-computed, 0..100 bp
                                           [168..199] uint32 gateRefreshedAt
                                           [200..255] (free)
```

`gateFlags`: bit0 degraded, bit1 corporateFreeze, bit2 refreshFailed, bit3 caArmed.

`beforeSwap` reads exactly these three words plus the pure fee policy, and nothing else. `f_vol` is pre-computed
into `fVolBps` by `afterSwap` from the full-precision `varianceX18`, so `beforeSwap` needs no `k_vol` multiply.
`TruncatedOracleLib.State` already carries `highWaterTick`, `lastTruncatedTick`, `blockAnchorTick` and
`lastBlockNumber` in its head slot; the hook must **not** duplicate them. `lastTick` in `_dyn` is the *raw*
post-swap tick (deviation and EWMA input); the truncated tick is `_obs[id].lastTruncatedTick`. `HookPoolState` is
the memory view assembled by `poolState()`, not the storage layout (decision 4).

**Transient (EIP-1153).** One slot per swap `sender`: `slot(sender) = keccak256(abi.encode(ROTATION_CREDIT_SLOT, sender))`
with `ROTATION_CREDIT_SLOT = keccak256("amplestocks.hook.ROTATION_CREDIT")` as the domain separator. Zero at the
start of every transaction by EVM rule, which is what makes I26 structural rather than enforced; keying by `sender`
(the router the PoolManager reports for both hops of a rotation) is what stops one party's buy from discounting
another party's sell inside a batched transaction (audit fix 17).

### 1.3 `beforeInitialize` / `afterInitialize` / `beforeAddLiquidity`

```
_beforeInitialize(sender, key, sqrtPriceX96)
  require(sender == vault)                                        NotVault
  require(Currency.unwrap(key.currency0) == amps)                 Currency0NotAmps   (catches native ETH == 0)
  require(key.fee.isDynamicFee())                                 FeeNotDynamic
  cfg = registry.poolConfig(key.toId()); require(cfg.registered)  UnknownPool
  require(cfg.counter == Currency.unwrap(key.currency1) && cfg.tickSpacing == key.tickSpacing)

_afterInitialize(sender, key, sqrtPriceX96, tick)
  write CONFIG from cfg; gridBaseTick = PriceLib.alignTick(tick, tickSpacing, true)
  _obs[id].initialize(uint32(block.timestamp), tick)
  _dyn: lastTick = fairTick = tick; full gate refresh (band, rail, dynCap, session)
  _arm: uiMultiplierX18 = bounded staticcall uiMultiplier() (1e18 for WETH/USDG)

_beforeAddLiquidity(sender, ...)   require(sender == vault)       NotVault
```

There is no `beforeRemoveLiquidity` bit, so removals can never be blocked (I18).

### 1.4 `beforeSwap` — the exact algorithm

1. `id = key.toId(); cfg = _cfg[id]; dyn = _dyn[id]; arm = _arm[id];` (three cold SLOADs).
   `require(cfg.initialized)`.
2. `sell = p.zeroForOne` — AMPS is currency0 in all 32 pools, so `zeroForOne == true` is unconditionally "AMPS
   in". `exactInput = p.amountSpecified < 0`; `amountIn = exactInput ? uint256(-p.amountSpecified) : 0`.
3. **Base fee and rotation credit.**
   ```
   base = sell ? sellFeeBps : cfg.buyFeeBps
   if (sell && exactInput && amountIn != 0) {
       slot = keccak256(abi.encode(ROTATION_CREDIT_SLOT, sender))
       credit = tload(slot);  c = credit < amountIn ? credit : amountIn
       if (c != 0) {
           tstore(slot, credit - c)
           // sellFeeBps >= buyFeeBps always (bands [100,600] vs [1,100]), so the delta form cannot underflow
           base = cfg.buyFeeBps
                + FullMath.mulDivRoundingUp(sellFeeBps - cfg.buyFeeBps, amountIn - c, amountIn)
       }
   }
   ```
   Rounded **up**, so a credit never rounds a fee down in the swapper's favour. Exact-output sells consume no
   credit and pay `sellFeeBps` in full; the dApp always builds hop 2 as `SWAP_EXACT_IN`. Note that the naive
   `(buy*c + sell*(in-c) + in-1)/in` used by `StubAmpsHook` overflows for `amountIn > 2^256/600`; `mulDivRoundingUp`
   carries the 512-bit intermediate and does not.
4. **Deviation, measured pre-swap.** `dev = abs(dyn.lastTick - dyn.fairTick)`;
   `deviationIncreasing = sell ? (dyn.lastTick <= dyn.fairTick) : (dyn.lastTick >= dyn.fairTick)` — a sell pushes
   the tick down, a buy up. The rail is a **start-of-swap** condition (decision 2): a deviation-increasing swap
   with `dev > outerRailTicks` reverts `RailBreached(dev, rail)`. A price-improving swap is never refused and
   never pays `f_dev`.
5. **`IFeePolicy.quoteFee`** on the pointer, with `FeeInput` assembled from `cfg`, `dyn`, `arm` and the credit.
   The law: `f_dev = K_DEV_BPS * dev^2 / 1e4` inside the band; between band and rail a quadratic ramp
   `f_inner + (F_WALL_BPS - f_inner) * (dev - band)^2 / (rail - band)^2` with `F_WALL_BPS = 1500`; beyond the
   rail, `refuse = true` (returned, never thrown, so the quoter can report it).
   `dyn_total = f_vol + f_dev + f_div + f_session + surge`.
6. `fee = clamp(base + dyn_total, F_MIN_BPS = 3, base + dyn.dynCapBps)`, with the dynamic part floored at
   `FROZEN_FEE_FLOOR_BPS = 100` when `gateFlags.degraded`. **A swap is never reverted for a gate reason** (I15).
   `f_session` = 0/5/10/25 bp for Regular/Pre-Post/Overnight/Closed and is **stock legs only**: entry pools pass
   `Session.REGULAR` unconditionally.
7. `require(fee <= TOTAL_FEE_BPS_MAX)` (2,600) and return `(selector, BeforeSwapDeltaLibrary.ZERO_DELTA,
   uint24(fee * PIPS_PER_BPS) | LPFeeLibrary.OVERRIDE_FEE_FLAG)`.

### 1.5 `afterSwap` — the exact algorithm, and it may never revert

Every step that touches an external contract is a bounded `staticcall` whose failure sets `gateFlags.refreshFailed`
and leaves the cached value in place. No path reverts, under any fuzzed downstream failure.

1. `(, int24 tick,,) = PoolStateLib.slot0(poolManager, id)` — one `extsload`, not `getSlot0`.
2. `truncated = _obs[id].write(uint32(block.timestamp), uint32(block.number), tick, cfg.maxTickMovePerBlock)`,
   which also advances `highWaterTick` (the I33 mark) and the 30-minute TWAP (I25).
3. **EWMA variance**, `lambda = 0.98`, on the raw tick delta `d = tick - dyn.lastTick`:
   `varianceX18 = (LAMBDA_X18 * varianceX18 + (1e18 - LAMBDA_X18) * uint256(int256(d) * int256(d)) * 1e18) / 1e18`,
   saturating at `type(uint64).max`; then `fVolBps = min(K_VOL_X18 * varianceX18 / 1e36, F_VOL_CAP_BPS)`.
4. **Rotation credit** (buys only): `if (!p.zeroForOne) { int128 out = delta.amount0(); if (out > 0)
   tstore(slot(sender), tload(slot(sender)) + uint256(uint128(out))); }` — credited from the **realised**
   delta, never the requested amount, and to the `sender` the PoolManager reports, so I26 holds by construction.
5. **Surge and capture** are not recomputed here; both are pure functions of `(armedBps, elapsed)` evaluated at
   quote time. `afterSwap` only zeroes them once fully decayed, to keep `_arm` clean.
6. **Gate cache refresh**, at most once per `_gateCacheSeconds` (60 s) per pool: `session`/`closedHours` from
   `OracleGate`; `dynCapBps` from `OracleGate.dynCapBps(id)`; `innerBand`/`outerRail` from the fee policy;
   `fairTick` = for a spoke `PriceLib.fairTick(pMkt, stockAnswerUsd8, decimals, tickSpacing)` with `pMkt` from
   `_obs[hubPoolId].twap30m()`, for an entry pool its own `_obs[id].twap30m()`. When the cache is older than
   `GATE_CACHE_MAX_AGE` (900 s), `beforeSwap` substitutes the **most conservative** values: widest band for the
   class, `DYN_CAP_DEGRADED_BPS`, `FROZEN_FEE_FLOOR_BPS` on the dynamic part.
7. **Dividend-step detector** (spokes only, same interval): bounded `staticcall uiMultiplier()` capped at
   `Constants.STOCK_TOKEN_PROBE_GAS`, with `prev = arm.uiMultiplierX18`:
   ```
   deltaBps = m > prev ? (m - prev) * BPS / prev : 0
   0 < deltaBps <= DIVIDEND_STEP_BPS_MAX (200)  -> captureFeeBps = deltaBps * DIVIDEND_CAPTURE_NUMERATOR_BPS / BPS
                                                   captureArmedAt = now;  half-life 300 s
   deltaBps > 200                               -> gateFlags.caArmed = 1;  dynCapBps = DYN_CAP_ESCALATION_BPS
   always                                       -> arm.uiMultiplierX18 = m
   ```
   A `+Delta` step makes each raw stock token worth more, so the arbitrage is to take stock **out** of the pool —
   which, AMPS being currency0, is `zeroForOne == true` (a sell). The capture fee applies to that direction only
   and leaves the arbitrageur 20% of the step.
8. `dyn.lastTick = tick; dyn.lastUpdate = now;` (one dirty SSTORE). Emit `RebalanceNeeded(id, tick, fairTick)`
   when `abs(tick - fairTick) > innerBand / 2`.
9. Return `(selector, int128(0))` — never a delta; no returns-delta bit exists.

### 1.6 `IMarketReference` and the vault-only mutators

```
twapTick(poolId, window)     -> _obs[poolId].consult(now, window)        reverts WindowNotCovered; callers read
twapTick30m(poolId)          -> _obs[poolId].twap30m(now)                observationCoverage first
observationCoverage(poolId)  -> _obs[poolId].observationCoverage(now)
lastTruncatedTick(poolId)    -> _obs[poolId].lastTruncatedTick
highWaterTick(poolId)        -> _obs[poolId].highWaterTick
twapWindow()                 -> TruncatedOracleLib.TWAP_WINDOW (1800), protocol-wide
maxTickMovePerBlock(poolId)  -> _cfg[poolId].maxTickMovePerBlock

resetHighWater(poolId)             onlyVault  returns the consumed mark, then _obs[poolId].resetHighWater()
armSurge(poolId, bps, reason)      onlyVault  require(bps <= SURGE_MAX_BPS); writes _arm; forces a gate refresh
setSellFeeBps / setBuyFeeBps / setMaxTickMovePerBlock  onlyTimelock 48 h, `_band`-checked against Constants
setFeePolicy                                          onlyTimelock 7 d
```

The vault arms a surge after every placement; the hook arms one itself on a session open, a multiplier step and a
reference jump above `SURGE_REF_JUMP_BPS` (25 bp). Decay is `IFeePolicy.surgeDecay`: 60 s half-life, zero at 8
half-lives.

### 1.7 What is read from where, and the caching strategy

| Read | Source | Cold cost | When |
|---|---|---|---|
| `PoolConfig` | `IPoolRegistry` | ~2.7k call + 2.1k SLOAD | `afterInitialize` **only**, then CONFIG |
| `dynCapBps`, session | `IOracleGate` | 15-40k (feed + TWAP + registry inside) | gate refresh, <= 1/60 s |
| Chainlink answer | `IFeedRegistry` | ~10k | inside the gate refresh only |
| Hub TWAP | own `_obs[hub]` | ~12k (binary search) | inside the gate refresh only |
| `uiMultiplier()` | `IStockToken` | <= 50k, capped | inside the gate refresh only |
| CONFIG + DYNAMIC + ARMED | own storage | 3 x 2.1k | every `beforeSwap` |
| `IFeePolicy.quoteFee` | policy pointer | ~2.6k account + ~1.5k | every `beforeSwap` |

**`beforeSwap` reads nothing outside the hook except the pure fee policy.** That is the whole strategy: the gate,
the registry, the feeds and the hub TWAP are pulled in `afterSwap` at most once per pool per `_gateCacheSeconds`,
and a refresh failure is a flag, never a revert.

**Gas.** Baseline (`gas/baseline.json`, `StubAmpsHook`, cold): `beforeSwap` 12,735, `afterSwap` 33,776,
`swapOneHopBuy` 132,058, `swapOneHopSell` 132,055, `swapTwoHopRotation` 175,208, `swapBuyThenSell` 164,908.
Production adds two cold SLOADs (+4.2k) and the policy staticcall (+~4k) to `beforeSwap` => ~21k, which exceeds
`12,735 x 1.2 = 15,282`; and the oracle head SSTORE plus the `_arm` word (+~10k) to `afterSwap` => ~44k, which
exceeds `33,776 x 1.2 = 40,531`. End to end those deltas are +~8k and +~10k against a 132k swap => ~150k, inside
`132,055 x 1.2 = 158,466`, and ~197k on the two-hop, inside `175,208 x 1.2 = 210,250`. **Normative gate
(decision 3): the four end-to-end numbers stay at baseline + 20%; `beforeSwap` and `afterSwap` are re-baselined
against the real hook with explicit ceilings `beforeSwap <= 22,000`, `afterSwap <= 55,000`**, recorded in
`gas/baseline.json` beside the Phase 1 stub numbers.

---

## 2. `PoolStateLib` (`src/lib/PoolStateLib.sol`, MIT, ours)

Reads PoolManager state through the MIT `IExtsload`/`IExttload` with our own slot arithmetic. Every derivation
below is a fact about the deployed contract, established by reading the BUSL source; no BUSL code is imported,
copied or ported.

**Deriving the pools-mapping slot.** `PoolManager is IPoolManager, ProtocolFees, NoDelegateCall, ERC6909Claims,
Extsload, Exttload`. Solidity allocates slots in C3-linearised order, most-base first: `Owned.owner` = 0;
`ProtocolFees.protocolFeesAccrued` = 1, `.protocolFeeController` = 2; `NoDelegateCall` has only immutables;
`ERC6909.isOperator` = 3, `.balanceOf` = 4, `.allowance` = 5; `Extsload`/`Exttload` have no storage; therefore
`PoolManager._pools` = **6**, matching `StateLibrary.POOLS_SLOT`.

```
POOLS_SLOT        = bytes32(uint256(6))
poolStateSlot(id) = keccak256(abi.encodePacked(PoolId.unwrap(id), POOLS_SLOT))
```

**`Pool.State`** is seven consecutive slots from `poolStateSlot`:

```
+0 slot0   sqrtPriceX96 [0..159] | tick [160..183] (signextend 2) | protocolFee [184..207] | lpFee [208..231]
+1 feeGrowthGlobal0X128 uint256
+2 feeGrowthGlobal1X128 uint256
+3 liquidity            uint128 in the low 128 bits
+4 ticks       base  ->  keccak256(abi.encodePacked(int256(tick),          bytes32(poolStateSlot + 4)))
+5 tickBitmap  base  ->  keccak256(abi.encodePacked(int256(int16(wordPos)),bytes32(poolStateSlot + 5)))
+6 positions   base  ->  keccak256(abi.encodePacked(positionKey,           bytes32(poolStateSlot + 6)))
```

`TickInfo` is three words at the tick slot: `+0` = `liquidityGross [0..127] | liquidityNet [128..255]` (recover
`liquidityNet` with `sar(128, word)`), `+1` = `feeGrowthOutside0X128`, `+2` = `feeGrowthOutside1X128`.
`Position.State` is three words at the position slot: `+0` = `liquidity` (uint128, low bits),
`+1` = `feeGrowthInside0LastX128`, `+2` = `feeGrowthInside1LastX128`.

**Position key** — 58 packed bytes, `keccak256(abi.encodePacked(owner /*20*/, tickLower /*3*/, tickUpper /*3*/,
salt /*32*/))`. Ours, because `Position.calculatePositionKey` is BUSL:

```solidity
function positionKey(address owner, int24 lower, int24 upper, bytes32 salt) internal pure returns (bytes32 k) {
    assembly ("memory-safe") {
        let fmp := mload(0x40)
        mstore(add(fmp, 0x26), salt)   // [0x26, 0x46)
        mstore(add(fmp, 0x06), upper)  // [0x23, 0x26)
        mstore(add(fmp, 0x03), lower)  // [0x20, 0x23)
        mstore(fmp, owner)             // [0x0c, 0x20)
        k := keccak256(add(fmp, 0x0c), 0x3a)
        mstore(add(fmp, 0x26), 0) mstore(add(fmp, 0x06), 0) mstore(fmp, 0)
    }
}
```

**Surface.**

```
slot0(pm, id)                    -> (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee)  1 extsload
liquidity(pm, id)                -> uint128                                                               1 extsload
feeGrowthGlobals(pm, id)         -> (uint256, uint256)                                        extsload(slot, 2)
positionInfo(pm, id, owner, lo, hi, salt) -> (uint128 L, uint256 fgi0Last, uint256 fgi1Last)  extsload(slot, 3)
positionLiquidity(...)           -> uint128                                                   1 extsload (hot path)
tickFeeGrowthOutside(pm, id, t)  -> (uint256, uint256)                                        extsload(slot+1, 2)
feeGrowthInside(pm, id, lo, hi)  -> (uint256, uint256)                                        5 extsloads
feesOwed(pm, id, owner, lo, hi, salt) -> (uint256 owed0, uint256 owed1)
        = FullMath.mulDiv(fgiNow - fgiLast, L, FixedPoint128.Q128), with the subtraction unchecked
positionLiquidityBatch(pm, id, keys[]) -> uint128[]     IExtsload.extsload(bytes32[]), one staticcall for a grid
currencyDelta(pm, target, currency)    -> int256        exttload(keccak256(abi.encode(target, currency)))
```

`feeGrowthInside` branches exactly as v4 does, in `unchecked` arithmetic (these differences are meant to wrap):
`tickCurrent < lower` => `lowerOutside - upperOutside`; `tickCurrent >= upper` => `upperOutside - lowerOutside`;
otherwise `global - lowerOutside - upperOutside`, per currency. `currencyDelta` uses the transient slot
`keccak256(abi.encode(target, currency))` — 64 bytes, target then currency, both left-padded — read with
`exttload`. Nothing in the production flow depends on it; the vault uses it only for defensive assertions inside
`unlockCallback`.

---

## 3. The placement path

### 3.1 Where the code lives: `VaultPlacementLib`

`AmpsVault` is 23,765 bytes under `via_ir` at 200 runs — **811 bytes of EIP-170 margin**. The placement path is
several kilobytes. Two options:

| | Linked public library (`DELEGATECALL`) | Separate immutable `Placer` (`CALL`) |
|---|---|---|
| Position owner at the PoolManager | the vault: `beforeAddLiquidity(sender == vault)` holds | the `Placer` — **breaks** POL-only, I9, I35, custody |
| Vault storage (`_ladder`, `_lastPlacementAt`) | typed `storage` pointers, compiler-checked | unreachable; needs a mirrored book |
| Trust boundary | none: the address is fixed in the vault's bytecode at link time | a new one |
| Cost | one `DELEGATECALL` (~1.1k) per entry point | a `CALL` plus re-entering the vault for every custody op |
| Precedent | `VaultNavLib`, already linked | none |

**Recommendation: `VaultPlacementLib`**, a `public` linked library mirroring `VaultNavLib`. Public library
functions may take `storage` pointers (ABI-encoded as slot numbers), so signatures read
`placeLadder(mapping(PoolId => PlacementRecordStorage[]) storage ladder, mapping(PoolId => uint32) storage
cooldown, PlaceParams memory p) public returns (Placed memory)`. The vault's five externals become 6-10-line
forwarders: lock, `_requireHealthy`, capture `NAV_BEFORE`, call the library, re-check R1, `_sweepClean`. Budget:
forwarders ~150 B each plus ~400 B of new `unlockCallback` branches exceeds 811 B, so **`redeemProRata`'s position
removal moves out too, into a second minimal library `VaultRedeemLib`** (decision 6). `forge build --sizes` is a
hard CI gate at 24,576 B. The I14 bytecode proof must follow the link: CI analyses the vault **and every linked
library's deployed code** and asserts no `PUSH` of the gate, feed-registry or guardian slot is reachable from
`redeemProRata` in the union.

### 3.2 The canonical bucket grid — why it is mandatory

A v4 position is keyed by `(owner, tickLower, tickUpper, salt)`. With `salt == 0` (our choice: `PlacementRecord`
has no salt field), **two placements over the same range are one position at the PoolManager**, so appending a
second record for that range would double-count. Two further pressures point the same way: `redeemProRata` must
remove `floor(L * shares / T)` from *every* record and so needs a bounded record count; and
`LadderPositionValuer` is a separate contract that **cannot read the vault's private `_ladder` mapping** —
`IAmpsVault` has no ladder getter and the ABI is final.

**Normative: every vault position in a pool lies on that pool's canonical doubling grid.**

```
D          = LadderLib.doublingTicks(tickSpacing)              one doubling, rounded up to a whole spacing
gridBase   = _cfg[poolId].gridBaseTick                         set at afterInitialize, mirrored in PoolConfig
cell m     = [gridBase + m*D, gridBase + (m+1)*D)              m in [GRID_MIN_M, GRID_MAX_M)
GRID_MIN_M = -8    GRID_MAX_M = 16    GRID_CELLS = 24
```

Genesis asks occupy `m = 0..9`, seed bids `m = -4..-1`; re-laddered fee asks, rolled-out asks and bonded bids all
snap to the same lattice, so records **merge by `m`** rather than accumulate. Consequences: at most 24 records per
pool; `redeemProRata`'s work is bounded and measurable; the valuer can enumerate without a getter. New invariant
**I39**: every record in pool `p` has `lowerTick == gridBase_p + m*D_p` for some `m` in `[GRID_MIN_M, GRID_MAX_M)`
and no two records share an `m`.

### 3.3 Genesis placement

**Entry pools** (`AMPS/WETH`, `AMPS/USDG`), anchor $1.00 via
`PriceLib.ampsPerCounterToSqrtPriceX96(1e18, counterPriceUsd8, counterDecimals)` then `sqrtPriceX96ToTick`:

* **asks** 1,662.5 AMPS each, `ladderDoublings = 10`, `ladderTilt = 1.25`, `above = true`, cells `m = 0..9`
  (or `m = 1..10` for a pool whose fair tick has crossed its origin by the time it is placed: §12.2 ruling L).
  `sum 1.25^k (k=0..9) = 33.2529`, so `w_0 = 3.007%` (50.0 AMPS over $1-$2) up to `w_9 = 1.25^9 / 33.2529 =
  22.406%` (372.5 AMPS over $512-$1,024; an earlier draft wrote 28.008% / 465.7 AMPS, which is `1.25^10 / 33.2529`,
  one power too many — `LadderLib` and `unit/LadderLib.t.sol` pin the correct vector). A one-sided range order
  raises `sqrt(P_lo * P_hi)` per AMPS, so bucket 0 raises ~$70.7 per pool, ~$141 across both — the plan's "about
  $140 of buying doubles the price from $1", which confirms the shape. Bucket 9 raises ~$270k per pool, ~$539k
  across both, which is the plan's "$540k" (decision 9).
* **seed bids** $2,500 of counter each, `seedHalvings = 4`, `above = false`, cells `m = -4..-1`. `LadderLib`
  applies the weight vector reversed for bids, so the cell adjacent to $1 is largest: 33.87% / 27.10% / 21.68% /
  17.34% => $846.72 / $677.38 / $541.90 / $433.60.

**Spokes** (30): 47.5 AMPS each (1% of the 4,750 POL tranche), 10 doublings, tilt 1.25, anchored at
`PriceLib.fairTick(pRef, stockPriceUsd8, 18, tickSpacing)` = `tickOf(P_ref / P_stock)`. No bids until buys or
bonds bring stock in. Totals: 1,425 + 3,325 = 4,750 POL, 250 team, `S0` = 5,000.

### 3.4 `PlacementRecord` bookkeeping, and symmetric proceeds

`PlacementRecordStorage` (vault slot 18, two slots per record) is written once per grid cell and updated in place.
`lowerTick`/`upperTick` are the cell bounds and `lowerTick` is the merge key; `liquidity` is the live position
liquidity and must equal `PoolStateLib.positionLiquidity`; `bucketIndex = uint8(m - GRID_MIN_M)` (0..23); `buckets`
is the ladder length at first placement; `above` is true while the cell is an ask, false once converted to a bid;
`placedAt` is the last add; `amount` is cumulative token added (disclosure only); `tiltX18` and `anchorTick` record
the shape for the dApp's ladder chart.

**Symmetric proceeds: nothing to do.** A v4 position converts in place as the price crosses it, so a filled ask
becomes the bid at exactly the prices that raised it. No code, no record change, no keeper.

### 3.5 The buyback burn

The hook's `highWaterTick` is the maximum truncated tick since the vault's last `resetHighWater`. A cell whose
`upperTick` the mark has crossed was fully sold as an ask; once the price has come all the way back down through
it, the AMPS in it is inventory the vault **bought back** and must burn (I33). Two conditions select a cell, and
both must hold (audit fix 4, 2026-09-07):

```
record.upperTick <= highWater   : the mark crossed the whole cell (it was fully sold)
pool.tick        <= record.lowerTick : the price is back at or below its floor (it is pure AMPS again)
                                  -> remove all L; burn all of it; liquidity = 0; the counter fees it
                                     accrued land in claims
anything else                   : leave the cell alone
```

A straddled cell (`lower < tick < upper`) is **never** touched: removing it whole and re-laying its counter half a
cell lower is what let every bid cell — which satisfies `upperTick <= highWater` from the moment it is placed,
because bids sit below the tick and the mark is at the tick — be liquidated by the next `compound` after a one-tick
move, ratcheting the bid ladder a doubling lower each time (audit finding 4). Partially bought-back inventory stays
in place and re-sells on the way up, which is the symmetric-proceeds design of decision 16; only a full round trip
retires supply. The `tick == lower` case is pure `amount0` in v4 terms and burns.

**Ordering rule (normative).** Every ask placement — `place`, `rollout`, `deployBonded` and `compound` alike — is
followed by `resetHighWater`, and `compound`'s burn step precedes its re-ladder, so freshly placed AMPS can never
satisfy `upperTick <= highWater` off a stale excursion: `collect -> burn crossed cells -> split fees -> re-ladder
-> resetHighWater -> armSurge`. A `compound` that collected nothing, burned nothing and placed nothing resets no
mark, arms no surge and takes no cooldown (audit fix 5).

### 3.6 `compound(poolId)`, step by step

Permissionless, paid from `BountyPot`.

1. `locked`; `_requireHealthy()`; `gate.checkPlacement(poolId)`; 60 s cooldown on `_lastPlacementAt[poolId]`;
   `NAV_BEFORE = previewNavPerShareX18()`.
2. Divergence at entry: `abs(slot0.tick - tickOf(P_mkt / P_i)) <= PLACEMENT_DIVERGENCE_TICKS` (800).
3. One `unlock`, `ACTION_COMPOUND`: `modifyLiquidity(lower, upper, 0, salt 0)` per record realises `feesAccrued`;
   positive deltas are `mint`ed as ERC-6909 claims. Fees earned while no position was in range are never credited
   by v4 and are not ours to claim (decision 13).
4. **Buyback burn** per section 3.5, in the same unlock.
5. **AMPS-side split**, in order, on `ampsFees`:
   ```
   creatorBps(t) = CREATOR_FEE_BPS * max(0, 1 - (t - genesis)/CREATOR_DECAY_SECONDS)     100 bp -> 0 over 30 d
   divisor       = max(sellFeeBps, SELL_FEE_BPS_DEFAULT)                                  -- a fee cut never enlarges the slice
   creatorCut    = ampsFees * min(creatorBps(t), divisor) / divisor                      -> transfer to `creator`
   stakerCut     = (ampsFees - creatorCut) * stakerBps / BPS                             -> AmpsStaking.notifyReward
   burnCut       = (ampsFees - creatorCut - stakerCut) * burnBps / BPS                   -> Amps.burn
   relaid        = ampsFees - creatorCut - stakerCut - burnCut                           -> new asks
   ```
   Creator payouts are the only transfer of protocol-held AMPS to a non-pool address (I31). `ampsFees` was
   collected at `base + dyn`, so the slice over-states the 100 bp schedule by at most `(base + dynCap) / base`
   under `GREEN` (1.6x) and can never exceed one fifth of the AMPS-side fees (audit fix 6).
6. **Re-ladder** `relaid` across grid cells strictly above both `alignUp(slot0.tick)` and the reference anchor
   `tickOf(P_ref / P_i)` — the same anchor `place`, `rollout` and `deployBonded` use, so no ask is ever offered
   below `P_ref` (I32; audit fix 16) — via `ILadderPolicy.propose` with the anchor snapped to the grid; merge into
   existing records by `m`.
7. **Re-add counter-side fees** as bids across cells strictly below `alignDown(slot0.tick)`, same shape.
8. Only if the call did work (`burned != 0 || relaid != 0 || counterFees != 0`): `resetHighWater(poolId)` (also
   performed inside every ask placement), `armSurge(poolId, SURGE_MAX_BPS, "compound")` and the cooldown write; a
   zero-work compound leaves all three untouched (audit fix 5).
9. Divergence at exit; `_checkpoint()`; **R1**: `navAfter >= NAV_BEFORE * (BPS - 2) / BPS` else revert
   `NavBleedExceeded` (I11); `_lastPlacementAt[poolId] = now`; `BountyPot.pay(...)`; `_sweepClean()`; emit
   `Compound(poolId, ampsFees, creatorPaid, stakerPaid, burned, relaid)`.

### 3.7 `rollout`, `deployBonded`, `withdrawRetiredBids`, `place`

* **`rollout(constituentId)`** — permissionless, bountied. Rolls the 24 h window (`_rolloutMoved24h`,
  `_rolloutWindowStart`), builds `IRolloutPolicy.RolloutRequest`, calls `propose`, then **re-checks all three
  limits itself** (I32): `moved24h + amount <= rolloutBpsPerDay * polTranche / BPS`; entry-pool ask inventory
  after the move `>= entryFloorBps * polTranche / BPS`; every destination cell's `lowerTick >= tickOf(P_ref /
  P_stock)`, so a rolled-out ask is never placed below `P_ref`. Only **unfilled** ask cells move (`above == true`
  and `lowerTick > slot0.tick` in the source), so no counter-asset is touched. Both pools pay the full gauntlet.
* **`deployBonded(constituentId)`** — permissionless, bountied. Places the idle ERC-6909 claim of that
  constituent's stock as `bondBidHalvings = 4` cells strictly below `alignDown(slot0.tick)`, weights running with
  price (largest nearest the tick). No-op below `DEPLOY_THRESHOLD_USD18` (decision 15).
* **`withdrawRetiredBids(constituentId)`** — registry-only, 7 d. Removes every bid record in a `RETIRED` spoke and
  `take`s the counter into ERC-6909 claims, where `A` still values it and `redeemProRata` still pays it. Ask cells
  were already returned to the entry pools by `retireConstituent`.
* **`place(poolId, above, amount)`** — timelock, or the registry inside `addConstituent` for the `spokeSeedBps`
  seed ask (decision 11). Genesis placement runs through it.

### 3.8 The gauntlet — every guard on every placement

1. `locked` (transient reentrancy) and `_requireHealthy()`.
2. `IOracleGate.checkPlacement(poolId)` — refuses on `SCHEDULED_FREEZE`, `DIVERGED`, `WATCHDOG`, guardian freeze.
   `REF_DIVERGED` is permitted but forces the NAV anchor (`P_ref == navPerShare`).
3. Divergence at **entry and exit**: `abs(slot0.tick - tickOf(P_mkt / P_i)) <= PLACEMENT_DIVERGENCE_TICKS` (800).
4. Sidedness (I9, unconditional): asks strictly above `alignUp(slot0.tick)`, bids strictly below
   `alignDown(slot0.tick)`. Every proposed bucket is re-checked by the vault, never trusted from the policy.
5. Grid membership (I39) and `sum(amounts) <= inventory`.
6. 60 s per-pool cooldown.
7. **R1** as a revert: `navAfter >= navBefore * (1 - PLACEMENT_BLEED_BPS_MAX/BPS)` (2 bp; 50 bp only inside
   `emergencyMigrate`).
8. `armSurge` after, so a placement cannot be sandwiched at the pre-placement fee.
9. `_sweepClean()` at exit (I12).

### 3.9 `unlockCallback`: the Phase 3 action set

Existing: `ACTION_SETTLE = 1`, `ACTION_PAYOUT = 2`, `ACTION_ABSORB = 3`. Added:

```
ACTION_PLACE    = 4  (PoolKey key, Bucket[] buckets, bool above)
    per bucket: modifyLiquidity(key, {lower, upper, +int256(L), salt: 0}, "")
    delta.amount0 < 0 (AMPS owed)     -> burn(vault, AMPS id, -amount0)   settle by claim
    delta.amount1 < 0 (counter owed)  -> burn(vault, id1, -amount1)
    positive residue                  -> mint(vault, id, +amount) back into claims
    invariant: an ask ladder has delta.amount1 == 0; a bid ladder has delta.amount0 == 0

ACTION_COMPOUND = 5  (PoolKey key, Record[] records)
    modifyLiquidity(..., 0, "") per record -> feesAccrued; positive deltas -> mint claims

ACTION_BURNBACK = 6  (PoolKey key, Cell[] crossed, int24 tickNow)
    modifyLiquidity(-L) per crossed cell; take amount0 as an AMPS claim and burn it;
    re-add amount1 over [lower, alignDown(tickNow)] when non-degenerate, else hold it as a claim

ACTION_UNWIND   = 7  (PoolKey key, Record[] records, uint256 shares, uint256 supply)
    per record: dL = uint128(FullMath.mulDiv(L, shares, supply)); modifyLiquidity(-dL)
    released counter -> claims (paid by ACTION_PAYOUT); released AMPS -> burned
```

AMPS is currency0 and is never `take`n to an EOA: it is settled by claim inside the unlock, and any AMPS the vault
ends up holding is burned or re-placed. The vault never calls `poolManager.swap()` and never `donate()`s.

### 3.10 How redemption removes liquidity

`redeemProRata` reads `T = Amps.totalSupply()` **before** the burn, burns the redeemer's shares, then removes
exactly `floor(L_p * shares / T)` from every `PlacementRecord` in every registered pool inside one `ACTION_UNWIND`
unlock (I23). Released counter assets join the pro-rata payout net of `redeemFeeBps`; released inventory AMPS is
burned, so `T` falls by more than `shares`. Bounded work: 32 pools x 24 cells = 768 `modifyLiquidity` calls worst
case. A Phase 3 gas test must measure the worst reachable redemption and assert it fits one block (decision 7);
the mitigation is never a gate, a rate limit or an instalment on the floor.

---

## 4. `LadderPositionValuer` (`src/valuer/LadderPositionValuer.sol`)

Implements `IPositionValuer`; replaces `ZeroPositionValuer` under the 7-day pointer swap. Immutables
`poolManager`, `vault`, `registry`. `view`, holds nothing, never calls back into the vault.

```
valuePool(poolId, sqrtPriceRefX96) -> (amount0, amount1)
  1. cfg = registry.poolConfig(poolId); D = LadderLib.doublingTicks(cfg.tickSpacing); base = cfg.gridBaseTick
  2. build 24 position slots: for m in [GRID_MIN_M, GRID_MAX_M):
       lower = base + m*D; upper = lower + D
       slot  = PoolStateLib.positionSlot(poolId, vault, lower, upper, bytes32(0))
  3. one IExtsload.extsload(bytes32[]) staticcall -> 24 liquidity words
  4. per non-zero L, decompose at sqrtPriceRefX96 with LiquidityAmounts (v4-periphery, MIT):
       sqrtRef <= sqrtLower : amount0 += getAmount0ForLiquidity(sqrtLower, sqrtUpper, L)
       sqrtRef >= sqrtUpper : amount1 += getAmount1ForLiquidity(sqrtLower, sqrtUpper, L)
       otherwise            : amount0 += getAmount0ForLiquidity(sqrtRef,  sqrtUpper, L)
                              amount1 += getAmount1ForLiquidity(sqrtLower, sqrtRef,  L)
     All four round **down** (`SqrtPriceMath.getAmount*Delta(..., false)`), so `A` is never overstated.

totalLiquidity(poolId) -> sum of the 24 words (uint128, saturating)
version()              -> bytes32("ladder-grid-valuer-v1")
```

**Enumerating the grid rather than the vault's records** is deliberate: `IAmpsVault` exposes no ladder getter and
the ABI is final; the PoolManager is the authority on what the vault actually owns; and a bookkeeping bug in the
vault cannot inflate NAV. `amount0` (AMPS) is returned for disclosure and valued at zero by the caller (I5).

**Uncollected fees are excluded** (normative). `A` must never be overstated, and fee growth is the one term an
attacker can inflate cheaply by wash-trading; including it would make `A` depend on `slot0.tick` through
`feeGrowthInside`'s branch, contradicting I7 (positions valued at the reference price only); and the next
`compound` collects them into claims, so the omission is a lag, never a loss. `PoolStateLib.feesOwed` still exists
for the dApp and for `compound`'s own accounting.

**Gas.** One registry call (~3k) + one batched `extsload` of 24 cold slots (~2.6k + 24 x 2.1k = 53k) + 24
decompositions (~600 each) ~= **70k per pool**, ~2.2M for a 32-pool `checkpoint()`. `checkpoint()` is
permissionless and unpaid, so that is acceptable; `previewNavPerShareX18` carries the same cost as a `view`. Every
bond carries one checkpoint too (`depositBonded` checkpoints before it settles so the price is read from this
block's pre-deposit NAV, Phase 2 §6), so a Phase 3 bond costs roughly `checkpoint()` plus ~700k; that is the
price of I27 holding against the live NAV and is independent of placement, as the plan requires.

---

## 5. Policies (`src/policy/`)

All three are pure, stateless, pointer-upgradeable (7 d), propose-only, and hold no funds. Each exposes
`version()` and its hard bands as `external view` constants read from `Constants`, never restated as literals.

**`LadderPolicy` (`geometric-doubling-v1`)** — a governable wrapper over `LadderLib`. `propose(LadderRequest) ->
LadderBucket[]`: `bucketBounds(anchorTick, tickSpacing, k, above)` for `k < buckets`; `weights(tiltX18, buckets)`
= `tilt^k / sum tilt^j` (floored, residue to the last element so the sum is exactly 1e18); `split(inventory, w)`
exact; `liquidityForAmount0Above` / `liquidityForAmount1Below` rounded down. Reverts
`LadderNotPlaceable("degenerateBucket")` rather than truncating. Bands: tilt `[1e18, 1.5e18]`, doublings
`[6, 14]`, halvings `[2, 8]`.

**`FeePolicy` (`directional-wall-v1`)** — `quoteFee(FeeInput) -> FeeQuote` implements section 1.4 steps 3-7 in
pure form: the rotation blend (rounded up, `creditConsumed` returned so the hook decrements by exactly that);
`f_vol` capped at 100 bp; `f_dev` quadratic inside the band and a quadratic ramp to `F_WALL_BPS = 1500` between
band and rail, `refuse = true` beyond the rail **and only when `deviationIncreasing`**; `f_div =
surgeDecay(captureFeeBps, captureElapsed)` on `captureDirectionTakesStock` only; `f_session` 0/5/10/25 bp with
entry pools always 0; `surge = surgeDecay(surgeBps, surgeElapsed)`; then `clamp(base + dyn, F_MIN_BPS, base +
dynCapBps)` and a hard `<= TOTAL_FEE_BPS_MAX`.
`innerBandTicks(class, session, closedHours)`: entry pools a flat 200 (no session widening); spokes
`200 / 300 / 500 / (770 + 25 * closedHours)` capped at 1,500 and monotone non-decreasing in closedness (I19).
`outerRailTicks(class, innerBand)`: `max(3 * innerBand, 800)` for spokes, a flat 2,000 for entry pools.
`surgeDecay(armedBps, elapsed)`: 60 s half-life, `armedBps >> (elapsed / 60)` with linear interpolation across the
remainder, zero at 8 half-lives. It may never throw and never refuses for a gate reason.

**`RolloutPolicy` (`weighted-deficit-v1`)** — `propose(RolloutRequest) -> RolloutDecision`:

```
budget    = rolloutBpsPerDay * polTrancheAmps / BPS - movedLast24hAmps            (0 when negative)
floorRoom = entryInventoryAmps - entryFloorBps * polTrancheAmps / BPS             (0 when negative)
deficit   = max(0, targetWeightBps - currentWeightBps) * 1e18 / max(1, targetWeightBps)
share     = rolloutWeightBps * (spokeHasDepth ? 1e18 : DEPTHLESS_DISCOUNT_X18 /*0.5e18*/) / BPS
amount    = min(budget, floorRoom, budget * share/1e18 * (1e18 + deficit)/1e18)
floorBinding = (amount == floorRoom) && floorRoom < budget
```

`amountAmps == 0` is a valid answer and a no-op for the vault, never a revert. Bands: `rolloutBpsPerDay <= 1000`,
`entryFloorBps <= 8000`.

---

## 6. `AmpsQuoter` (`src/periphery/AmpsQuoter.sol`)

Immutable, `view`-only, and **it never reverts**: every external read is a bounded `try`/`staticcall` whose
failure degrades a field and raises a flag.

```solidity
struct PoolQuote {
    PoolId  poolId;    PoolClass poolClass;   address counter;
    uint256 pMktX18;   uint256 pRefX18;       uint256 navPerShareX18;  int256 premiumX18;
    int24   poolTick;  int24 fairTick;        int24 innerBandTicks;    int24 outerRailTicks;
    uint16  buyFeeBps; uint16 sellFeeBps;     uint24 buyFeePips;       uint24 sellFeePips;
    uint16  dynBps;    uint16 dynCapBps;      bool   refuseSell;       bool refuseBuy;
    uint256 bondQX18;  uint16 bondDiscountBps;uint256 bondCapacityLeft;bool bondOpen;
    uint8   gateState; uint8 session;         bool   feedStale;        bool corporateFreeze;
    uint32  observationCoverage;              uint32 checkpointAge;    uint8 degraded;
}
```

`quotePool(poolId)` and `quoteAll()` fill it. `degraded` is a bitfield naming which sub-read failed: bit0 hook,
bit1 gate, bit2 feeds, bit3 vault checkpoint, bit4 bonds, bit5 TWAP coverage.

**Degraded semantics, documented and tested.** A failed read leaves its fields zero and sets its bit; a consumer
must treat `degraded != 0` as "do not trade on this field". `pMktX18 == 0` specifically means the pool has less
than `twapWindow` of observation coverage. `refuseSell`/`refuseBuy` come from `IAmpsHook.quoteFee(..., refuse)`
and are `false` when bit0 is set — fail open for display, never for execution.

**Rotation-credit-aware two-hop quote.** `quoteRotation(PoolId hop1, PoolId hop2, uint256 amountIn) -> (uint256
amountOut, uint24 hop1FeePips, uint24 hop2FeePips, uint256 creditUsed)`: hop 1 is a buy in `hop1` paying
`buyFeeBps[hop1]`; the AMPS it yields is the credit; hop 2 is an exact-input sell in `hop2` whose base is
`buyFeeBps[hop2] + ceilDiv((sellFeeBps - buyFeeBps[hop2]) * (ampsIn - credit), ampsIn)` — the same delta form as
the hook, so the quote is exact rather than approximate. `IAmpsHook.rotationCredit(sender)` is deliberately **not**
consulted: it is transient, keyed by the swap `sender`, and always zero when read from a fresh transaction, so the quoter simulates the credit
the caller's own hop 1 will create. `bondQ(marketId)` mirrors `AmpsBonds`' `min(qMarket, qFloor)` with the same
rounding. Amount-level pricing stays in `V4Quoter` off-chain; this struct is a fee-and-state view, not a curve
simulator.

---

## 7. Scripts (`contracts/script/`)

* **`04_MineHook.s.sol`** — `HookMiner.find(CREATE2_FACTORY = 0x4e59b44847b379578588920cA78FbF26c0B4956C, 0x38C0,
  type(AmpsHook).creationCode, abi.encode(poolManager, amps, vault, registry, timelock))`; deploy through the
  factory; assert `uint160(hook) & uint160(Hooks.ALL_HOOK_MASK) == 0x38C0`, that neither returns-delta bit nor the
  remove-liquidity bit is set, and `hook.code.length != 0`; write address and salt to `script/config/hook.json`.
  Re-run in CI after every dependency bump — the creation code moves with solc and with library addresses.
* **`05_Registry.s.sol`** (extended) — batch-register 32 pools: `registerEntryPool` for `AMPS/WETH` and
  `AMPS/USDG`, `addConstituent` x30. Each `PoolKey` is `{currency0: AMPS, currency1: counter, fee:
  LPFeeLibrary.DYNAMIC_FEE_FLAG, tickSpacing, hooks: AmpsHook}`.
* **`09_Phase3Wire.s.sol`** — the pointer moves, as timelock proposals: `marketReference -> AmpsHook` (set-once,
  7 d), `positionValuer -> LadderPositionValuer`, `ladderPolicy`, `rolloutPolicy` (7 d each), and
  `AmpsHook.setFeePolicy` (7 d). `OracleGate` is redeployed and re-pointed in the same batch so it reads the
  hook's `poolState` for the corporate-action flag (decision 10).
* **`10_TestnetPools.s.sol`** (46630) — deploy 30 `MockStockToken` (settable `uiMultiplier`, `oraclePaused`,
  `effectiveAt`, denylist) and 30 `MockAggregator` at realistic prices, plus `MockUsdg` and a WETH9 stand-in;
  register and initialise all 32 pools at `PriceLib.ampsPerCounterToSqrtPriceX96($1.00, price, decimals)`.
  Idempotent and resumable off `script/config/testnet.json`.
* **`11_GenesisPlacement.s.sol`** — the section 3.3 ladders, one `place` per pool, respecting the 60 s cooldown.
* **Library linking.** `VaultNavLib`, `VaultPlacementLib` and `VaultRedeemLib` deploy first (deterministic CREATE2
  from the same factory) and are linked by address: `--libraries src/vault/VaultNavLib.sol:VaultNavLib:0x...`
  and the same for the other two, with the triple pinned in `foundry.toml`'s `libraries` key so `forge build
  --sizes` and CI measure the linked artefact. `script/config/libraries.json` records them.

---

## 8. Tests and invariants

### 8.1 File map

| File | Covers |
|---|---|
| `unit/AmpsHook.t.sol` | permission bits; `beforeInitialize` rejections (non-AMPS currency0 incl. `address(0)`, static fee, unregistered pool, non-vault sender); `beforeAddLiquidity`; CONFIG/DYNAMIC/ARMED packing round trips |
| `unit/AmpsHookFee.t.sol` | fee table by direction and class; blend arithmetic; `f_min`; `dynCap` per gate state; `frozenFeeFloor`; `OVERRIDE_FEE_FLAG`; I16 |
| `unit/RotationCredit.t.sol` | one-tx stock->AMPS->stock pays buy+buy; buy-then-larger-sell pays sell on the excess; exact-output sells pay full; a 1-wei buy unlocks 1 wei; **no cross-transaction credit**; credit decremented by exactly `creditConsumed` (I26) |
| `fuzz/FeePolicy.fuzz.t.sol` | monotone in `dev`; continuous at band and rail; `refuse` only when deviation-increasing (I15); total `<= base + dynCap` and `<= TOTAL_FEE_BPS_MAX`; band monotone in closedness (I19) |
| `unit/PoolStateLib.t.sol` | every read differentially tested against `StateLibrary` (test-only import allowed) on a live local pool, incl. non-zero salts and negative ticks |
| `unit/LadderPositionValuer.t.sol` | decomposition below/inside/above the range; rounding always down; empty pool returns zeros; `totalLiquidity`; I7 (`slot0` +/-50% moves `A` by <= dust) |
| `unit/VaultPlacement.t.sol` | genesis ladders to the wei (3.3); sidedness (I9); grid membership (I39); merge-by-cell; cooldown; divergence at entry and exit; R1 revert on a manipulated tick |
| `unit/VaultCompound.t.sol` | creator/staker/burn/re-ladder split to the wei; `creatorBps(t) == 0` after day 30 (I31); buyback burn in all three tick positions (I33); high-water reset ordering |
| `unit/VaultRollout.t.sol` | `rolloutBpsPerDay` and `entryFloorBps` never breached; no ask below `P_ref` (I32); retirement returns unfilled asks; `withdrawRetiredBids` |
| `unit/AmpsQuoter.t.sol` | never reverts with every dependency reverting, singly and together; degraded bitfield; rotation quote matches a real two-hop swap to the wei |
| `integration/Phase3Flywheel.t.sol` | ladder consumed bottom-up with per-bucket proceeds matching `LadderLib`; pump-then-dump round trip ends with `totalSupply` lower and `A == seed + fees` |
| `integration/HubPump.t.sol` | hub +30% in 10 min; every spoke follows within one TWAP window via arbitrage against its ladder while `P_ref` lags at `<= refUpRateBps` |
| `integration/CorporateAction.t.sol` | a 0.5% dividend step captured `>= 60%`; a 10:1 split with `oraclePaused()` gives zero position movement, zero NAV change, a closed bond market |
| `attack/*.t.sol` | spoke-TWAP dump then bond; hub pump then dump into spoke bids; JIT at an empty tick; VTSwapHook double-positive-delta; Bunni rounding grind-down; rotation-credit gaming; creator-fee wash trading |
| `invariant/Phase3.invariant.t.sol` | I9, I11, I13, I15, I16, I18, I19, I26, I29, I31-I35, I39 |
| `gas/GasBaseline.t.sol` (extended) | real-hook `beforeSwap`/`afterSwap` ceilings; the four end-to-end numbers at baseline+20%; `redeemProRata` at the worst reachable state |

### 8.2 Invariant handler design

`Phase3Handler` drives a bounded action space against a fully wired local stack. Thirty-two pools is too slow, so
use **four**: `AMPS/USDG` as the hub, `AMPS/WETH`, one `SPOKE`, one `SPOKE_HIGH_VOL`. Actions: `swapBuy`,
`swapSell`, `swapRotate` (two-hop in one tx), `bond`, `claim`, `redeem`, `compound`, `rollout`, `deployBonded`,
`checkpoint`, `warp`, `moveFeed`, `stepMultiplier`, `armGate`. Ghosts: `mintedVesting`, `burnedTotal`,
`creatorPaid`, `rolloutMoved`, `maxRecordsSeen`, `navEverFell`, `swapEverReverted`, `quoterEverReverted`,
`actionCount`. Assertions:

* **I9** each record satisfies `above ? lowerTick >= alignUp(tick) : upperTick <= alignDown(tick)` at placement,
  and an ask position's `amount1 == 0` at the reference price. **I34** bucket `k` holds `tilt^k / sum tilt^j`
  within rounding; cells are contiguous doublings. **I39** grid membership and cell uniqueness.
* **I11** `navEverFell == false` at 2 bp across every placement and compound.
* **I13** hook ERC-20 and ERC-6909 balances zero; `beforeSwap` returned `ZERO_DELTA`; `afterSwap` returned 0.
  **I18** no `BEFORE_REMOVE_LIQUIDITY` bit; a removal succeeds in every gate state.
* **I15** `swapEverReverted` is set only by `RailBreached` on a deviation-increasing swap — never for a gate
  reason, never inside the rail. **I16** every fee decomposes as `base + dyn`, `base in {buyFee, blended,
  sellFee}`, `sellFeeBps in [100, 600]`, `dyn <= dynCap_state`, total `<= MAX_LP_FEE`. **I19** band monotone in
  closedness and untouched by the breaker.
* **I26** `rotationCredit(sender) <= sum(AMPS received by that sender this tx)`, zero at every transaction boundary;
  one sender's buy never discounts another sender's sell (audit fix 17).
* **I29** every bid traces to the seed, a filled ask cell at its own prices, or a bonded ladder; none placed above
  the tick or moved up. **I35** positions shrink only through redemption, rollout, the buyback burn, migration.
* **I31** `creatorPaid <= ampsFees * creatorBps(t) / sellFeeBps` per compound, `creatorBps` monotone
  non-increasing and 0 after 30 days, and no other transfer of protocol AMPS to a non-pool address.
  **I32** `rolloutMoved` per rolling 24 h within budget, entry inventory never below `entryFloorBps`, no
  rolled-out ask below `P_ref`. **I33** AMPS in a high-water-crossed cell is burned at the next compound and never
  re-placed; `totalSupply` never rises outside `AmpsBonds`.
* `afterSwap` never reverts and `AmpsQuoter` never reverts under a fault-injecting wrapper that makes the gate,
  feed registry, registry and stock token revert, run out of gas, or return garbage, in every combination.

### 8.3 Medusa readiness

`medusa.json` targets `Phase3Handler` with the same assertions as `medusa_`-prefixed properties, `testLimit` 1e7,
`workers` 8, reusing the Foundry fixture through `setUp()`. Two conditions make it useful: the handler must never
revert on a *valid* action (reverts poison coverage), and every ghost must be readable through a `view` so
property functions need no storage access. Run it over `src/hook/**`, `src/policy/**`, `src/vault/**` and
`src/valuer/**` as part of the Phase 6 `fizz` campaign.

---

## 9. Open decisions for the orchestrator

1. **The valuer cannot read the vault's ladder** — no getter on `IAmpsVault`, ABI final, and no cross-contract
   storage reads. *Proposal:* adopt the **canonical doubling grid** (3.2) so the valuer enumerates 24
   deterministic ranges by `extsload`; additionally add `view` getters `ladderAt(PoolId, uint256)` and
   `ladderLength(PoolId)` for the dApp, permitted because the I14 CI check enumerates only non-`view` selectors.
   *Cost:* anchors confined to a lattice; a pool past +16 doublings (65,536x) needs a migration to place more asks.
2. **"`dev` post-swap" is unimplementable in `beforeSwap`** — v4 needs the fee first and `afterSwap` may never
   revert. *Proposal:* the rail is a **start-of-swap** condition; `f_dev` and the refusal both use the pre-swap
   tick, so one swap may cross the rail but the next deviation-increasing one is refused. Restate I15 as "only a
   deviation-increasing swap that *begins* beyond the outer rail reverts". *Cost:* one swap can overshoot, bounded
   by I25 and by the wall's quadratic ramp.
3. **The isolated-callback gas gate cannot hold at stub + 20%** (deltas +~8k, +~10k; 1.7). *Proposal:* gate the
   four **end-to-end** numbers at baseline + 20%, which pass, and re-baseline the two isolated numbers with
   ceilings `beforeSwap <= 22,000` and `afterSwap <= 55,000` as new keys beside the Phase 1 stub values. *Cost:*
   the Phase 3 exit criterion needs this footnote.
4. **`Types.HookPoolState` does not describe the hook's storage** — it lacks `lastTick`, `fairTick`, `gateFlags`,
   `fVolBps` and duplicates the oracle head slot. *Proposal:* treat it as the **memory view** returned by
   `poolState()` and extend it with `int24 lastTick; int24 fairTick; uint8 gateFlags; uint8 fVolBps; uint32
   gateRefreshedAt` — a type change, not a storage change. Do not add `highWaterTick`; it stays on
   `IMarketReference`.
5. **`k_vol` and `k_dev` are absent from `Constants`.** *Proposal:* add `K_VOL_X18 = 5e15` (f_vol saturates at
   100 bp near a 45-tick per-swap sigma), `K_DEV_BPS = 25` (f_dev = 100 bp at the 200-tick Regular band),
   `F_WALL_BPS = 1500`, `LAMBDA_X18 = 0.98e18`, `GATE_CACHE_SECONDS_DEFAULT = 60`, `GATE_CACHE_MAX_AGE = 900`,
   `GRID_MIN_M = -8`, `GRID_MAX_M = 16`, `DEPTHLESS_DISCOUNT_X18 = 0.5e18`. Placeholders to be calibrated against
   Phase 0's cadence and volatility sample; they live in the pointer-upgradeable policies, not the immutable hook.
6. **A library-hosted removal weakens the I14 bytecode proof.** *Proposal:* put pro-rata position removal in its
   own minimal `VaultRedeemLib` with no gate, feed, guardian or price import, and extend the CI proof to the
   **union** of the vault and every linked library's deployed code. *Cost:* one more library and link argument.
7. **`redeemProRata` gas is unbounded in the plan** (worst case 32 x 24 = 768 `modifyLiquidity` calls).
   *Proposal:* the grid bounds it; add a gas test asserting the worst reachable redemption fits one block, and if
   it does not, reduce `GRID_CELLS` and cap records at placement time. The floor is never gated, rate-limited or
   split into instalments to make it fit.
8. **"Keep the counter side in place" is impossible for a partially re-crossed cell** — a single-sided `amount1`
   position must lie entirely below the tick. *Proposal:* re-place it at `[lower, alignDown(currentTick)]`, still
   inside the cell and still on the grid (3.5).
9. **The plan's "top bucket raises about $540k" reconciles once the weight is computed correctly.** Bucket 9
   holds 372.5 AMPS over $512-$1,024 (`1.25^9 / 33.2529 = 22.406%`; the first draft of this section used one
   power too many and wrote 465.7 AMPS) and raises `372.5 * sqrt(512*1024)` = ~$270k per entry pool, ~$539k
   across both; bucket 0 raises ~$141 across both, which matches "$140 doubles the price". *Proposal:* publish
   the derived table in the dApp. No code depends on it.
10. **The corporate-action flag has no path from hook to gate** — the Phase 2 `OracleGate` reads the token
    directly and holds a mock market reference. *Proposal:* redeploy `OracleGate` in Phase 3 (a swap already
    required for the market-reference move) so `_corporateAction` also consults
    `IAmpsHook.poolState(poolId).uiMultiplierX18` against the token's live `uiMultiplier()`.
11. **`place`'s caller set is ambiguous**, and `addConstituent` must seed a new spoke. *Proposal:* `place` is
    **timelock-or-registry**; `compound`, `rollout` and `deployBonded` are the permissionless bountied paths;
    genesis placement runs through `place`.
12. **Position `salt` is unspecified** — `PlacementRecord` has no salt field. *Proposal:* `salt == bytes32(0)`
    everywhere, which is what makes merge-by-range correct and grid enumeration complete; record it as an
    invariant so no future placement kind opens a second salt namespace.
13. **Fees accrued while no position is in range are stranded** — v4 credits `feeGrowthGlobal` only when
    `liquidity > 0`, so a spoke with no bids earns nothing on the sell side. *Proposal:* accept and document it,
    measure the leak in `Phase3Flywheel.t.sol`, surface it in the dApp as "unbacked range". A floor position
    spanning the whole range would break I9.
14. **`gridBase` has no home.** *Proposal:* store it in `_cfg[poolId].gridBaseTick` in the hook and mirror it into
    `PoolRegistry`'s `PoolConfig` as a new `int24 gridBaseTick` written by `initializePool`, since the registry is
    already the valuer's source of truth for decimals and tick spacing.
15. **`deployThreshold` is named in the plan but absent from `Constants`.** *Proposal:* add
    `DEPLOY_THRESHOLD_USD18 = 100e18`, governed at 48 h inside `[10e18, 10_000e18]`, so `deployBonded` is a no-op
    below $100 of idle collateral and cannot be used to drain the bounty pot.

## 10. Orchestrator rulings on §9 (2026-09-05)

| # | Ruling |
|---|---|
| 1 | **Accepted.** The canonical doubling grid is normative: every ladder bucket is one cell of the grid, positions use `salt = bytes32(0)`, and `LadderPositionValuer` enumerates the grid by `extsload`. The vault gains `view`-only ladder getters for the dApp. |
| 2 | **Accepted with an addition.** The outer rail is checked twice: in `beforeSwap` on the start-of-swap tick and direction (revert `BeyondRail` when the swap starts beyond the rail on the deviation-increasing side), and in `afterSwap` on the post-swap tick (revert `BeyondRail` when the swap ends beyond the rail and increased the deviation). The "afterSwap never reverts" rule means no *failure* path may revert (oracle, registry, gate, arithmetic); the rail revert is the one deliberate, deterministic exception and I15 is restated accordingly. |
| 3 | **Accepted.** Gate the four end-to-end numbers at the existing baseline + 20%; re-baseline `beforeSwap`/`afterSwap` against the real hook with the stated ceilings (22,000 / 55,000) and record why in `gas/baseline.json`. |
| 4 | **Accepted.** `HookPoolState` is a memory view with the extended fields. |
| 5 | **Accepted.** Add the proposed constants; `k_vol`, `k_dev`, `F_WALL_BPS`, `LAMBDA_X18` live in the pointer-upgradeable `FeePolicy` with bands in `Constants`. |
| 6 | **Accepted.** Redemption's position removal lives in a minimal linked `VaultRedeemLib`; the I14 proof (`vm.accesses` + selector enumeration) covers the vault and every linked library. |
| 7 | **Accepted.** Grid-bounded loop, worst-case single-block gas test, never gated. |
| 8 | **Accepted.** Re-place the counter side at `[lower, alignDown(tick)]`. |
| 9 | **Reconciled.** The plan's "$540k" is the top bucket across both entry pools (~$270k each) once `w_9 = 1.25^9 / Σ` is used; §3.3's first draft had one power too many. The per-bucket derivation in §3.3 (as corrected) is normative and `LadderLib` pins it. |
| 10 | **Accepted.** `OracleGate` is redeployed in Phase 3 (pointer-upgradeable, nothing deployed yet) to read `IAmpsHook.poolState` for the corporate-action flag, keeping its own token probes as the fallback. |
| 11 | **Accepted.** `place` is timelock-or-registry; `compound`, `rollout`, `deployBonded` are the permissionless bountied paths. |
| 12 | **Accepted.** `salt = bytes32(0)` everywhere, asserted as an invariant. |
| 13 | **Accepted.** Stranded out-of-range fees are measured and disclosed, not engineered around. |
| 14 | **Accepted.** `gridBase` in the hook CONFIG word, mirrored in `PoolConfig.gridBaseTick`. |
| 15 | **Accepted.** `DEPLOY_THRESHOLD_USD18 = 100e18`, 48-hour governed. |

---

## 11. Declarations as landed

Everything §10's rulings require now exists in `contracts/src/types/{Types,Constants,Errors}.sol` and
`contracts/src/interfaces/*.sol`, so the hook, policy, placement, valuer and quoter agents build against final
declarations without touching a shared file. This section is the inventory: what was added, who consumes it, and
every place a name or a shape was chosen rather than quoted.

### 11.1 `types/Types.sol`

| Declaration | Shape | Consumed by |
|---|---|---|
| `PoolConfig.gridBaseTick` | `int24`, **appended** — it starts slot +1 of the struct; every existing field keeps its slot and bit range | `PoolRegistry` (writes it), `LadderPositionValuer` (§4), `VaultPlacementLib` (§3.2), `AmpsQuoter` |
| `HookPoolState` + `counterDecimals`, `gridBaseTick`, `lastTick`, `fairTick`, `session`, `gateFlags`, `fVolBps`, `gateRefreshedAt` | eight appended fields; the struct is now documented as the **memory view** `poolState()` assembles, not a storage layout | `AmpsHook.poolState`, `OracleGate` (ruling 10), `AmpsQuoter` |
| `GridCell` | `{uint8 index; int24 lowerTick; int24 upperTick; uint128 liquidity; bool above;}` | `VaultPlacementLib` — it is the `Cell[]` of §3.9's `ACTION_BURNBACK`; also the grid arithmetic's shared vocabulary |
| `PlaceParams` | `{PoolKey key; PoolClass poolClass; bool above; uint256 amount; int24 anchorTick; int24 currentTick; int24 gridBaseTick; uint8 buckets; uint64 tiltX18; bytes32 reason;}` | `AmpsVault` → `VaultPlacementLib` (§3.1's signature) |
| `Placed` | `{uint256 amountPlaced; uint128 liquidityAdded; uint8 cells; int24 lowestTick; int24 highestTick;}` | `VaultPlacementLib` → `AmpsVault` |

`Types.sol` gains one import, MIT v4-core `PoolKey`, for `PlaceParams.key`.

**Already present, not duplicated.** `ILadderPolicy.LadderRequest` / `LadderBucket`, `IFeePolicy.FeeInput` /
`FeeQuote`, `IRolloutPolicy.RolloutRequest` / `RolloutDecision` and `Types.PlacementRecord` were declared in
Phase 2 and are unchanged. There is no `FeeOutput` and no `RolloutMove`: the doc's names are `FeeQuote` and
`RolloutDecision`, and both already exist.

### 11.2 `types/Constants.sol`

| Constant | Value | Consumed by |
|---|---|---|
| `HOOK_ADDRESS_MASK` | `0x3FFF` | `04_MineHook.s.sol`, the deployment assertion, `unit/AmpsHook.t.sol` |
| `K_VOL_X18`, `K_VOL_X18_MIN`, `K_VOL_X18_MAX` | `5e15`, `1e14`, `1e17` | `FeePolicy` |
| `K_DEV_BPS`, `K_DEV_BPS_MIN`, `K_DEV_BPS_MAX` | `25`, `1`, `100` | `FeePolicy` |
| `F_WALL_BPS`, `F_WALL_BPS_MIN`, `F_WALL_BPS_MAX` | `1500`, `100`, `DYN_CAP_ESCALATION_BPS` | `FeePolicy` |
| `LAMBDA_X18`, `LAMBDA_X18_MIN`, `LAMBDA_X18_MAX` | `0.98e18`, `0.5e18`, `0.999e18` | `AmpsHook.afterSwap` (the EWMA), `FeePolicy` |
| `GATE_CACHE_SECONDS_DEFAULT`, `GATE_CACHE_MAX_AGE` | `60`, `900` | `AmpsHook` (§1.5 step 6, §1.4 step 6) |
| `ROTATION_CREDIT_SLOT` | `keccak256("amplestocks.hook.ROTATION_CREDIT")`, the domain separator of the per-sender slot `keccak256(abi.encode(ROTATION_CREDIT_SLOT, sender))` | `AmpsHook`, `unit/RotationCredit.t.sol` |
| `PLACEMENT_STAGE_SLOT` | `keccak256("amplestocks.vault.PLACEMENT_STAGE")` (the transient staging buffer base; pinned by `unit/VaultPlacement.t.sol`) | `VaultPlacementLib` |
| `GRID_MIN_M`, `GRID_MAX_M`, `GRID_CELLS` | `-8`, `16`, `24` | `VaultPlacementLib`, `LadderPositionValuer`, `AmpsVault`, `Phase3.invariant` (I39) |
| `POSITION_SALT` | `bytes32(0)` | every placement and every enumeration (ruling 12) |
| `DEPTHLESS_DISCOUNT_X18` | `0.5e18` | `RolloutPolicy` |
| `DEPLOY_THRESHOLD_USD18_DEFAULT`, `_MIN`, `_MAX` | `100e18`, `10e18`, `10_000e18` | `AmpsVault.deployBonded` and its 48-hour setter (ruling 15) |

Ruling 5 places `k_vol`, `k_dev`, `f_wall` and `lambda` in the pointer-upgradeable `FeePolicy` "with bands in
`Constants`". Both the launch value and the band live here, because §5 also requires each policy to read its
numbers from `Constants` rather than restate them as literals — a policy needs somewhere to read the value *from*,
not only somewhere to be checked against.

Two things deliberately **not** added, to avoid a second home for one number:

* **the observation ring size.** It already exists as `TruncatedOracleLib.MAX_CARDINALITY = 64`, beside the ring it
  describes and beside `TWAP_WINDOW = 1800`. Restating it in `Constants` would create two values that can drift.
* **the `beforeSwap <= 22,000` / `afterSwap <= 55,000` gas ceilings of ruling 3.** §1.7 homes them in
  `gas/baseline.json` "beside the Phase 1 stub numbers", which is where the gas suite reads its ceilings from.

### 11.3 `types/Errors.sol`

| Error | Thrown by |
|---|---|
| `BeyondRail(bytes32 poolId, int24 devTicks, int24 outerRailTicks)` | `AmpsHook.beforeSwap` (start-of-swap tick) and `AmpsHook.afterSwap` (post-swap tick), per ruling 2 |
| `PlacementCooldown(bytes32 poolId, uint32 readyAt)` | `AmpsVault` / `VaultPlacementLib`, gauntlet step 6 |
| `PlacementDiverged(bytes32 poolId, int24 poolTick, int24 fairTick, int24 maxTicks)` | gauntlet step 3, at entry and at exit |
| `WrongSide(bytes32 poolId, bool above, int24 bucketTick, int24 boundTick)` | gauntlet step 4 (I9) |
| `OffGrid(bytes32 poolId, int24 lowerTick, int24 gridBaseTick, int24 cellWidth)` | gauntlet step 5 (I39) |
| `InsufficientInventory(uint256 requested, uint256 available)` | gauntlet step 5 |
| `RolloutLimitExceeded(bytes32 limit, uint256 requested, uint256 available)` | `rollout`'s own re-check of all three limits (I32) |

Only `BeyondRail` is named by §10; the other six are the gauntlet's revert sites, named here rather than left to
the placement agent so that the invariant handler and the attack tests can decode them.

**`IAmpsHook.BeyondOuterRail` is superseded, not removed.** A declared error selector is ABI and this interface
never removes a member, so it stays with a NatSpec note saying that `Errors.BeyondRail` is what the hook throws.
Nothing throws `BeyondOuterRail`. This is the one place where the Phase 2 declaration and ruling 2 disagree, and
the ruling wins.

### 11.4 Interfaces

| Interface | Added |
|---|---|
| `IAmpsHook` | events `RebalanceNeeded`, `GateCacheRefreshed`, `HookParameterChanged`, `FeePolicyChanged`; error `PoolKeyMismatch(bytes32 field)`; views `timelock()`, `gateCacheSeconds()`, `gridBaseTick(PoolId)` |
| `IFeePolicy` | `captureDecay(uint16,uint32)`; bound getters `FROZEN_FEE_FLOOR_BPS()`, `K_VOL_X18()`, `K_DEV_BPS()`, `F_WALL_BPS()`, `LAMBDA_X18()` |
| `ILadderPolicy` | `bucketBounds(int24,int24,uint8,bool)`, `split(uint256,uint256[])` — both named in §5 |
| `IRolloutPolicy` | `DEPTHLESS_DISCOUNT_X18()` |
| `IPositionValuer` | no members; the §4 normative rules (grid enumeration, uncollected fees excluded) are now in its NatSpec |
| `IMarketReference` | nothing — it was already complete against §1.6 |
| `IAmpsQuoter` (**new file**) | `PoolQuote` exactly as §6 gives it, plus `quotePool`, `quoteAll`, `quoteRotation`, `bondQuote`, `vault()`, `registry()`, `hook()`, `bonds()`, `version()` |
| `IAmpsVault` | `ladderLength(PoolId)`, `ladderAt(PoolId,uint256)`, `deployThresholdUsd18()`, `setDeployThresholdUsd18(uint256)`, `DEPLOY_THRESHOLD_USD18_MIN()`, `DEPLOY_THRESHOLD_USD18_MAX()` |

`IAmpsVault` grows from 91 to 97 declared functions. The header of this document froze it at 91; rulings 1 and 15
override that, and the growth is five `view`/`pure` getters plus one governed setter. Only the setter is a
mutating selector, so it is the only one the I14 enumeration and `scripts/selector-gate.py` see.

**`captureDecay` resolves a contradiction rather than adding a feature.** §5 writes
`f_div = surgeDecay(captureFeeBps, captureElapsed)`, but §1.5 and `Constants.DIVIDEND_CAPTURE_HALF_LIFE` both put
the capture fee's half-life at 300 s while the surge's is 60 s. Reusing `surgeDecay` would decay the capture fee
five times too fast and would leave `DIVIDEND_CAPTURE_HALF_LIFE` with no consumer at all. `captureDecay` is the
same shape on the other half-life.

### 11.5 Implementations, kept minimal

* **`AmpsVault`** — slot **20**, `uint256 _deployThresholdUsd18`, initialised to
  `DEPLOY_THRESHOLD_USD18_DEFAULT`; `setDeployThresholdUsd18` through the existing `_band` helper (same
  `OutOfBand`, same `VaultParameterChanged`, same `locked` + `onlyTimelock` + management gate as every other
  setter); the two band getters; `ladderLength`. Slot 18's value type changes from the vault-local
  `PlacementRecordStorage` to `Types.PlacementRecord` — the same ten fields in the same order, so the layout is
  bit-identical — and the mapping is declared `public` under the name `ladderAt`, which *is* the implementation of
  `IAmpsVault.ladderAt`. `place`, `compound`, `rollout`, `deployBonded` and `withdrawRetiredBids` remain
  `Phase3NotImplemented`.
* **`PoolRegistry`** — `_openPool` mirrors `gridBaseTick` from the hook after the vault has opened the pool,
  guarded by `extcodesize` and `try`/`catch`.
* **`VaultNavLib`** — unchanged in substance.

**Where the vault's headroom went.** `AmpsVault` is **24,505 B**, 71 B under EIP-170, against 23,774 B before this
slice. Three decisions fell out of that 802-byte budget and are worth recording because they are visible in the
ABI:

1. `ladderAt` returns the record's fields **flattened** rather than a `Types.PlacementRecord` struct. Solidity's
   generated getter for the `public` mapping is 234 B smaller than the hand-written struct-returning form, which
   is a fifth of the whole budget. It also reverts with **empty return data** on an out-of-range index rather than
   `Panic(0x32)`, so a consumer reads `ladderLength` first.
2. There is **no by-cell getter and no `lastPlacementAt` getter**. Ruling 1 names exactly `ladderAt` and
   `ladderLength`; a cell lookup is `ladderLength` plus at most `GRID_CELLS` reads of `bucketIndex`, which is the
   same work the vault would have done. Both were written, measured (184 B and 130 B) and removed.
3. Moving these getters into `VaultNavLib` was tried and is **worse**: the `DELEGATECALL` plus the ABI round trip
   for a ten-field struct costs 168 B *more* than the inline form. Recorded so nobody tries it twice.

`VaultRedeemLib` (ruling 6) is what reopens this headroom, and it belongs to the placement slice. Until it lands,
anything added to `AmpsVault` has 71 bytes to fit in.

**Why the registry mirrors the grid origin instead of deriving it.** §9.14 says `gridBaseTick` is "written by
`initializePool`", and the tick that `initializePool` hands the hook is the PoolManager's own. Re-deriving it in
`PoolRegistry` from `sqrtPriceX96` means a second call site for `TickMath.getTickAtSqrtPrice`, which costs
**2,822 B** at the registry's 1,000,000-run optimizer settings — it does not fit — and, much worse, gives the
system two derivations of one number that can disagree. A disagreement would point `LadderPositionValuer` at
ranges the vault never placed on. So the hook owns the value and the registry reads it back through the
`gridBaseTick(PoolId)` getter added to `IAmpsHook`. Consequences the hook agent must honour:

* `AmpsHook.afterInitialize` must have written its CONFIG word, `gridBaseTick` included, before it returns. It
  does — §1.3 already specifies exactly that — and `_openPool` reads it on the next line.
* `AmpsHook.gridBaseTick(poolId)` must not revert for a pool it has just initialised. If it does, registration
  still succeeds and the origin stays 0; `unit/PoolRegistry.t.sol` pins that.
* Before the hook exists, `gridBaseTick` is 0 for every pool, which is correct: without a hook there is no grid.
  The `extcodesize` guard is load-bearing, because a `staticcall` to an address with no code *succeeds* with empty
  return data and a decode failure after a successful call is not catchable by `catch`.

### 11.6 Names chosen, not quoted

The document fixes most of these; where it does not, this is what was chosen and why.

| Name | Status |
|---|---|
| `PlaceParams`, `Placed` | names from the task and §3.1's signature; **fields chosen** — exactly what §3.3 and §3.8 need, so the library never calls back out mid-placement |
| `GridCell` | chosen. §3.9 calls the payload `Cell[]`; `Cell` is too generic for a file-level type |
| `PlacementCooldown`, `PlacementDiverged`, `WrongSide`, `OffGrid`, `InsufficientInventory`, `RolloutLimitExceeded` | chosen. §3.8 names the checks, not the reverts |
| `BeyondRail`'s parameters | chosen as `(bytes32 poolId, int24 devTicks, int24 outerRailTicks)`, following §1.4's `RailBreached(dev, rail)` and adding the pool. `bytes32` rather than `PoolId` so contracts that do not import v4-core's types can still decode it |
| `captureDecay` | chosen; see §11.4 |
| `GateCacheRefreshed`, `HookParameterChanged`, `FeePolicyChanged`, `PoolKeyMismatch`, `gateCacheSeconds`, `gridBaseTick` | chosen. `RebalanceNeeded` is the plan's own name |
| `K_VOL_X18`, `K_DEV_BPS`, `F_WALL_BPS`, `LAMBDA_X18` | §9.5's names, kept bare so the formulas in §1.4 and §1.5 read literally; the `_MIN`/`_MAX` bands beside them are chosen |
| `bondQuote` | chosen. §6 calls it `bondQ(marketId)`; `bondQuote` matches `quotePool`/`quoteAll`/`quoteRotation` and returns the discount, the capacity and the `degraded` bitfield alongside `q` |
| `HookPoolState`'s three extra fields beyond ruling 4 | chosen. Ruling 4 names `lastTick`, `fairTick`, `gateFlags`, `fVolBps`, `gateRefreshedAt`; `counterDecimals`, `gridBaseTick` and `session` are in §1.2's CONFIG and DYNAMIC words and a memory *view* of those words that omitted them would be an incomplete view |

**One field §1.2 asks for that `FeeInput` cannot carry.** §1.2 says `beforeSwap` needs no `k_vol` multiply because
`afterSwap` pre-computes `fVolBps`. `IFeePolicy.FeeInput` is a Phase 2 declaration and carries `varianceX18`, not
`fVolBps`, and §9 does not propose changing it — so `FeePolicy` computes `f_vol = min(K_VOL_X18 * varianceX18 /
1e36, F_VOL_CAP_BPS)` from the full-precision variance. The hook still does no multiply; the pure policy does.
`HookPoolState.fVolBps` remains the cached value `beforeSwap` falls back to when the gate cache is older than
`GATE_CACHE_MAX_AGE`, and what `AmpsQuoter` reads.

## 12. Placement path as landed (orchestrator rulings, 2026-09-06)

The placement slice landed with five deliberate deviations from §3 and §10; each is accepted or amended here, and
this section wins over the earlier text where they differ.

| # | Ruling |
|---|---|
| A | **Four linked libraries, not three.** `VaultPlacementLib` with `rollout`/`deployBonded`/`withdrawRetiredBids` inlined is 30,237 B, so those three live in `src/vault/VaultRolloutLib.sol` and route every placement back through `VaultPlacementLib.place`. Deploy scripts link `VaultNavLib`, `VaultPlacementLib`, `VaultRedeemLib`, `VaultRolloutLib`; `script/config/libraries.json` records four addresses. The libraries read the vault's parameter word and pointer set by slot (a `DELEGATECALL` shares storage); §1.1's layout is pinned by `VaultLayout.t.sol`, and `_poolKeys` lives at `keccak256("amplestocks.vault.poolKeys")` so the numbered layout still ends at slot 20. |
| B | **Ruling 8 superseded.** The counter side of a burnt-back cell is *not* re-placed at `[lower, alignDown(tick)]` (a fraction of a cell is invisible to the valuer, so R1 would revert the `compound` that created it). It is held as an ERC-6909 claim and re-enters the ladder in step 7 of the same `compound` as a proper grid bid below the tick. |
| C | **Genesis price is grid-aligned.** §3.3's seed bids at cells `-4..-1` require the opening price to sit exactly on the grid origin: `initializePool` uses `TickMath.getSqrtPriceAtTick(gridBaseTick)` with `gridBaseTick` the spacing-aligned tick nearest the intended price (the launch price is therefore the aligned price nearest $1.00, within one tick spacing). Sidedness is checked in exact v4 terms — an ask needs `sqrtPriceX96 <= getSqrtPriceAtTick(lowerTick)`, a bid needs `sqrtPriceX96 >= getSqrtPriceAtTick(upperTick)` — so at the aligned opening price cell 0 holds pure AMPS and cell -1 pure counter, and the seed bids land at `-1..-4` as specified. |
| D | **The vault consumes `ILadderPolicy.weights`, not `propose`**, because the grid already fixes every bucket bound; a policy that reverts or answers badly falls back to `LadderLib`. The ladder is clipped to the grid rather than reverting `OffGrid` when a pool has run most of the way up. |
| E | **A vault-wide live-cell budget bounds redemption gas.** `redeemProRata` costs ~46k gas per live cell (measured: 2.20M for 48 cells over four pools). At the launch shape (14 cells per pool) 32 pools are ~20.5M and every grid cell occupied (24 x 32) is ~35M, which does not fit a 32M transaction. `Constants.MAX_LIVE_CELLS = 512` (~23.5M) is enforced at every new-cell opening: `place` reverts `CellBudgetExceeded`; `compound`/`rollout`/`deployBonded` merge into existing cells and leave the remainder idle. `IAmpsVault.liveCells()` exposes the count. Consequence for Decision 19: at 14 cells per pool the budget admits ~36 pools, so growing toward `MAX_CONSTITUENTS = 64` needs coarser ladders or a migration with a larger budget, and Phase 0 must read the chain's `MaxTxGasLimit`. **This narrows a user decision and is raised to the user.** |
| F | **Redemption burns the AMPS claim slice too.** `inventoryBurned` covers the vault's AMPS ERC-20 balance and its AMPS ERC-6909 claim (a merge-add can leave a small claim); the claim is taken inside the redemption `unlock` and burned with the rest. |

Gas of the placement paths at the worst reachable state in the fixture: `place` 2.2–3.0M, `compound` 1.0–3.3M, `rollout` 1.1–2.9M, `deployBonded` 1.5–2.4M, `emergencyMigrate` with a full ladder unwind ~2.1M for four pools (~16M for 32). The bounty for v1 reports a flat `$1` gas allowance (`BountyPot._quote` caps at `gasCostUsd18 x gasCapMultiple`, so `0` would pay nothing); the Phase 4 keeper reports measured gas.

### 12.1 Hook, fee calibration and gas as landed (orchestrator rulings, 2026-09-06)

| # | Ruling |
|---|---|
| G | **Gas re-baselined against the real hook; ruling 3's 22,000 `beforeSwap` ceiling is superseded.** Measured cold, each in its own frame: `beforeSwap` buy 25,116 / credited sell 28,863, `afterSwap` 39,744 (59,308 with a gate refresh), one-hop buy 153,260, one-hop sell 145,325, two-hop rotation 244,359, buy-then-sell 224,037. The decomposition (three cold hook words + slot 0, a cold `IFeePolicy` account and its ~2.3k of maths, ~9k of hook execution dominated by encoding the 20-field `FeeInput`) is recorded in `gas/baseline.json`; §1.7 had assumed two extra SLOADs and a 4k policy call. The stub numbers were placeholders with no policy call, so the multi-swap budgets derived from them (stub + 20%) are replaced by the hook's own recordings + 20%; `afterSwap <= 55,000` stands. Shrinking `FeeInput` is a Phase 4/6 tuning item, not a gate. |
| H | **`f_vol` recalibrated.** `AmpsHook` writes `FeeInput.varianceX18 = EWMA(d^2) x 1e18`, `d` the raw tick change of one swap, lambda 0.98 per swap. The field is now `uint128` (a `uint64` saturated at 18.45 ticks^2, which made the term structurally zero at `K_VOL_X18 = 5e15`); the hook keeps its packed 64-bit store but must scale it so the X18 value it hands the policy reaches the cap. With `K_VOL_X18 = 5e15`, `f_vol_bps = k x varianceX18 / 1e36` is 1 bp at a per-swap sigma of ~14 ticks and the 100 bp cap at ~141 ticks. Phase 0 recalibrates from the cadence sample. |
| I | **Hook deviations accepted:** `gateAttemptedAt` in DYNAMIC's free bits [200..231] (rate-limits refresh attempts; `gateRefreshedAt` is the last *successful* refresh); `beforeSwap` reads four cold words (the three packed words plus slot 0 for `sellFeeBps` and the policy pointer); the corporate-action detector runs before the gate refresh and `caArmed` is cleared when the multiplier is stable, the oracle un-paused and no `effectiveAt` is inside the window (unreadable probes leave it up); `IAmpsHook.quoteFee`'s second argument is `zeroForOne` (true = sell); price-improving swaps skip `f_dev` only (the dividend-capture direction is deviation-decreasing by construction); `TOTAL_FEE_BPS_MAX` is a clamp, not a revert (I15 outranks an unreachable revert); `PoolNotRegistered(PoolId)` replaces §1.3's `UnknownPool`; `setGateCacheSeconds` is on the hook but not on `IAmpsHook`; every hot-path external read is a hand-decoded `staticcall` with clamped enums and ticks, because `try`/`catch` cannot survive a decode failure after a successful call. `src/hook/*` compiles under the same per-path IR/200-runs restriction as the vault and bonds (20,757 B; 28,014 B on the legacy pipeline). |
| J | **`PoolRegistry.PoolOpened` emits the price the pool actually opened at**, read back from the PoolManager through `PoolStateLib` after `initializePool`, because the vault snaps the requested price down to the grid origin (ruling C) and an event that disagreed with `slot0` by up to one spacing would mislead the indexer. |
| K | **Cached-versus-effective hook words.** `poolState()` words 13/14/15 are the cached band, rail and cap; when the cache is older than `GATE_CACHE_MAX_AGE` the effective values are the conservative substitutes (band 1,500, the class rail, the DEGRADED cap) that `innerBandTicks()`, `outerRailTicks()` and `quoteFee()` use. Readers wanting the charged fee use `quoteFee`. |

### 12.2 Genesis placement order (orchestrator ruling, 2026-09-06)

| # | Ruling |
|---|---|
| L | **A genesis ask ladder may start one cell above the origin, and that is I32 working.** Every ask placement is valued at the reference price by `LadderPositionValuer`, so NAV/share and `P_ref` tick up by a few bp as the 32 ladders are placed in sequence (measured: $0.999999… → $1.000204 after all 32). `VaultPlacementLib._cells` anchors a ladder at `ceilDiv(fairTick(P_ref) − gridBase, D)`, which is 1 for any pool whose exact fair tick sits within ~2 ticks below a spacing boundary (~3% of pools at the launch vector). The ladder is still ten contiguous one-cell asks and the bids still sit at `m = -1..-4`; `11_GenesisPlacement.assertLayout` asserts exactly that shape ("anchored at the origin or one cell above it"), and no contract changes. Placing the entry pools first and the spokes in one batch keeps the drift to two basis points. |

### 12.3 Measured against the wired system (orchestrator notes, 2026-09-06)

The full Phase 3 fixture (real hook, real policies, real valuer, four linked libraries, live v4 pools) corrects
several numbers and wordings above; where they differ, this section wins.

| # | Note |
|---|---|
| M | **Redemption gas per live cell is ~43k at the launch shape**, not ~46k: 14,156,742 gas for 328 live cells over 32 pools (43,160/cell), so `MAX_LIVE_CELLS = 512` projects to 22.1M, inside the 24M budget. The four-pool average (47.5k) is dominated by the fixed part and must not be extrapolated. |
| N | **Two-hop rotation through real ladders costs ~977k gas**, about 4x ruling G's 244k, because each hop crosses several initialised ticks; `gas/baseline.json`'s end-to-end numbers are flat-liquidity figures and are gated as such. |
| O | **The quadratic wall to `F_WALL_BPS = 1500` is unreachable while the gate is `NORMAL`**: `beforeSwap`'s clamp to `base + dynCapBps` caps the dynamic part at 300 bp, which the ramp reaches at ~346 ticks of deviation, well inside the rail. The wall shows only once the cap is escalated (`DEGRADED` 1,000, `BAND_ESCALATION` 2,000). This is the intended precedence (the cap is the gate's lever), recorded so nobody expects 1,500 bp under a green gate. |
| P | **A "+30% in ten minutes" hub pump is a sequence, not an event**: it is achievable (+2,662 ticks in 555 s) only as ~185 small buys riding the rail, because `fairTick` is the pool's own truncated TWAP and lags; any single swap or a schedule coarser than ~3 s is refused `BeyondRail`. |
| Q | **`AmpsBonds.bond` keeps the whole deposit when it clamps to capacity** (Phase 2 §6): with `minAmpsOut == 0` a bonder hands over the full collateral for the capped issue. The dApp must always pass the quoted amount as `minAmpsOut`, and every fixture that bonds must size the deposit to capacity. |
| R | **`PoolRegistry.setIndexWeights` requires the vector to sum to exactly `BPS`**; an even 30-name split cannot, so the launch scripts register every name at 500 bp and assign the residue explicitly when the real vector is set. |
| S | **Test hazard.** solc hoists `TIMESTAMP`/`NUMBER` as loop-invariant, so `vm.roll(block.number + 1)` inside a warping loop rolls once and silently freezes `TruncatedOracleLib`'s per-block truncation anchor. Fixtures advance the clock through `vm.getBlockTimestamp()`/`vm.getBlockNumber()` (`Phase3Fixture.advance()`). |
| T | **I11's ghost is checked ex market moves**: `A` decomposes positions at the previous checkpoint's reference (I7) and every placement checkpoints on exit, so previews before and after a placement are computed at different references; the handler compares them only when `P_ref` came out where it went in, and `checkpoint()` is classified as a market move. |
| U | **Open finding, raised to the user (economic, no stated invariant broken):** because `redeemProRata` burns the released ladder inventory as well as the redeemer's shares (I23), every redemption lifts NAV/share for whoever redeems next, including the same redeemer's next slice: 300 AMPS redeemed in one shot returns 148.50 USDG, in 60 slices 152.76 (+2.9%), monotone in the split count. The effect scales with inventory's share of supply (95% at genesis) and shrinks as inventory sells. Candidate fixes: return released inventory AMPS to idle inventory instead of burning it (redemption becomes split-neutral apart from the 1% fee, at the cost of Decision 14's accretion-on-exit), or defer the burn to a rate-limited stream. Decision pending; the current behaviour stands until the user rules. |
| V | **Fixed.** `TruncatedOracleLib.MAX_CARDINALITY = 64` with one observation per distinct second lost TWAP coverage on any pool trading in more than 63 distinct seconds inside the window (70 writes 3 s apart left 189 s of coverage), which turned the hub into `WATCHDOG` under ordinary trading. The library now advances an exact head accumulator on every write and commits a ring slot only every `MIN_INSERT_INTERVAL = ceil(7200 / 63) = 115 s`, so a full ring spans 7,245 s (the widest governable window) and coverage is bounded below for every governed `twapWindow`; consults interpolate between exact endpoints with an error at most ~0.4% of the I25 budget; zero new storage (the three head fields fill the existing scalar slot); `afterSwap` fell from 39,815 to 31,755 gas, and the hook was re-mined (`script/config/hook.json`). |


### 12.4 Pre-audit polish: measured bounty economics, app-facing views and events, gate hardening (2026-09-06)

Three findings from the Phase 4 and Phase 5 reports, and one from the quoter slice, closed in `contracts/src/**`.
Nothing about the launch parameters, the gauntlet, the invariants or ruling U's open split-redemption question
changes; the vault's storage layout is untouched and every ABI change is an **append**.

| # | Ruling |
|---|---|
| W | **The keeper bounty is measured, not flat, and `chost` can now fire.** `VaultPlacementLib` and `VaultRolloutLib` passed `WORK_VALUE_USD18 = GAS_ALLOWANCE_USD18 = 1e18` to `BountyPot.pay`, which made two of the pot's four guards dead letters (`docs/keeper-runbook.md` §3.1, §3.2): the dust guard refuses on `workValueUsd18 < chostUsd18` and `1e18 < 1e18` is false at the launch `chost` of $1, so an *empty* `compound()` was paid the full tip; and `3 × $1 = $3` sits far above the `$0.05 + 2% × $1 = $0.07` a job could earn, so the gas cap never bound. Both inputs are now derived inside the call. **Work value:** `compound` — `(ampsFees + boughtBack) × P_ref` plus the counter-side *fees* at their feed price (freed burn-back inventory is excluded: it is value the vault already owned); `rollout` — `moved × P_ref`; `deployBonded` — the collateral placed, at the same feed price the deploy threshold was tested against. **Gas allowance:** `gasleft()` is captured as the first statement of the vault forwarder and the delta is taken in `VaultPlacementLib.payBounty`, plus `Constants.KEEPER_GAS_OVERHEAD` (80,000) for the intrinsic cost, the calldata and the payment itself, **minus `gasleft() / 63`** and clamped to `Constants.KEEPER_GAS_MAX` (8M). The correction is EIP-150 and it is not cosmetic: every message call forwards at most 63/64 of the caller's remaining gas, so the naive delta across the vault's delegatecall into the library charges the job for 1/64 of the *transaction's gas limit* as well as for the gas it spent — 16.8M under Foundry's 2^30 default, eight times a real `compound`, and on chain a lever a keeper could pull to inflate the pot's own 3x ceiling simply by sending the job with a large gas limit. `available = gasleft() * 64 / 63`, so adding `gasleft() / 63` back recovers the true consumption exactly for `compound` and to within one further 64th for the two-hop `rollout`/`deployBonded` paths; `KEEPER_GAS_MAX` is the belt that bounds every shape of it. `test_theGasAllowanceMeasuresTheJobNotTheCallersGasLimit` reconstructs the figure the pot was handed out of the payment the cap produced and holds it against what the call really burned. It is priced at `block.basefee` clamped into `[KEEPER_BASEFEE_FLOOR_WEI, KEEPER_BASEFEE_CAP_WEI]` = [0.01 gwei, 1 gwei] and at the ETH/USD answer the feed registry already holds for the `AMPS/WETH` entry pool's counter. **No new governance parameter, no new pointer and no new oracle**: it is the same feed `A` values the vault's WETH bids with, which is why the alternative (a governed `gasPriceUsd18`) was not taken — it would have added a vault storage slot, a setter, a band and a selector-gate entry to reach a number the protocol already reads. `IBountyPot` and `BountyPot` are unchanged; the pot's own note already said "the basefee cap lives in the caller". An ETH price the registry cannot answer leaves the allowance at zero, so the cap binds at zero and the job is unpaid but still done — I21's degradation, not a stop. At the launch shape this makes the **gas cap the binding constraint on an ordinary job**. Measured in `VaultCompoundTest` at the floor basefee and $2,500 ETH: an empty `compound` reports `workValueUsd18 == 0` and is paid `0` with `reason == "chost"`; a `compound` after one buy and one sell reports $18.51 of work (1.59 AMPS of fees plus 16.67 AMPS bought back, at `P_ref`, plus the USDG-side fees) and 2,682,720 gas, so the allowance is $0.0671 and the 3x ceiling $0.2012 — which is what it pays, because tip + chip is $0.4201 at the launch 2% chip and $1.9007 at the 10% band ceiling. With `dailyCeilingUsd18` governed to $0.02 the same job pays exactly $0.02 and the window is then exhausted (`reason == "dailyCeiling"` on the next quote). All four guards therefore bind on the same fixture, and none of them could before. |
| X | **`VaultPlacementLib.payBounty` and `ampsValueUsd18` are `public` library functions**, called by `VaultRolloutLib` the way `place` already is. `DELEGATECALL` preserves both the vault's storage and `msg.sender`, so the keeper is still the payee; nothing new is linked and `script/config/libraries.json` is unchanged. `AmpsVault.compound`, `rollout` and `deployBonded` each gained one `gasleft()` and one argument — no second call site, which is what keeps the change inside the vault's EIP-170 margin. |
| Y | **Views and events the apps had to work around.** All additions, all append-only, none of them a new mutating selector, so the I14 tables and `scripts/selector-gate.py` are untouched: `AmpsVault.lastPlacementAt(PoolId)` (the keeper's screening step 5, previously approximated from the newest `placedAt` in `ladderAt`); `Placement` gains `reason`, `lowerTick` and `upperTick` (the indexer classified placements from the transaction's four-byte selector and rebuilt ranges from `ModifyLiquidity`); a new `Rollout(constituentId, poolId, movedAmps, placedAmps)`; `PoolRegistry.PoolRegistered` gains `tickSpacing`, `counterDecimals` and `buyFeeBps`, and a new `PoolGridSet(poolId, gridBaseTick)` is emitted beside `PoolOpened` — the grid origin does not exist when `PoolRegistered` fires (the record must be written before the vault opens the pool), and it is a separate event rather than a field on `PoolOpened` because `script/05_Registry.s.sol` filters that event by a hardcoded topic, so the three together are what is log-complete; `AmpsBonds.Bond` gains `vestSeconds`; `AmpsVault.VestingMinted` gains `reason` (`bytes32("bond")`), which is what tells a bond's mint from the team's vest without cross-referencing `Bond` — the team's 5% is minted in `genesis` and reported by `Genesis`; `redeemProRata` now emits `Burn(shares, "redeem")` for the redeemer's own burn alongside `Burn(inventoryBurned, "redeemInventory")`, so "sum the `Burn` events" is the supply reduction (the emit reads no gate, price or pointer, so the I14 exemption and its storage-access proof stand); `IAmpsQuoter.PoolQuote` gains a trailing `int24 tickSpacing`, which is the last field a router needed beyond `quoteAll()` to build a `PathKey`; `LadderPositionValuer.amountsOf(poolId)` and `referenceSqrtPriceX96(poolId)` publish per-pool POL depth in tokens at the same reference, decomposition and rounding `A` uses. **Every appended event field changes that event's `topic0`**, so `packages/abis` must be regenerated and the indexer's handlers re-pointed; nothing was reordered or removed. |
| Z | **`AmpsBonds.unvestedOf(address)` is per owner, and there is deliberately no nullary `unvested()`.** Vesting is linear from each position's own `start` over its own frozen `vestSeconds` (I38), positions live in per-owner arrays with no global enumeration, and an aggregate maintained on the way in would have to be corrected again at each position's vest end — a scheduled write an immutable contract has nowhere to put and nobody to pay for. `AmpsBondsLens.unvested(bonds, owners)` and `unvestedOf(bonds, marketId, owners)` are the exact totals over an owner set the indexer and the dApp both already hold; `Amps.balanceOf(bonds)` stays the honest upper bound for a caller with no list. |
| AA | **`OracleGate` no longer decodes any external answer with a typed `try`.** `_feedAnswer`, `_constituent`, `_poolConfig`, `_poolOf`, `_constituentOfPool`, `_hubPoolId`, `_wethPoolId`, `_twapTick`, `_lastTruncatedTick` and both `GatePriceMath` calls are bounded `staticcall`s unpacked by hand, exactly as ruling 10's hook read already was. Solidity decodes a *successful* call's returndata in the caller's frame, so five bytes, no bytes or `0xff…ff` for a `uint32` raised a `Panic` that `try`/`catch` cannot catch, and `snapshot`, `state`, `isBondAllowed`, `checkBond`, `isPlacementAllowed` and `dynCapBps` reverted instead of degrading. Two consequences worth stating: `_constituent` and `_poolConfig` now return only the four fields the gate consumes (rebuilding the thirteen- and eight-field structs would spend EIP-170 headroom on fields nobody here reads), and `_twapTick` **bounds the window the market reference declares** to `[Constants.TWAP_WINDOW_MIN, TWAP_WINDOW_MAX]` — a reference claiming a zero or absurd window is "no reference", not a window to obey, which is what stops a garbage answer becoming a garbage price. `test_wholeReferenceMisbehaving_isBoundedToRevertsOnly` is now the positive assertion over all seven fault modes, and every read the gate offers is exercised in each of them. |
| AB | **Two reported gaps needed no code.** `IAmpsHook` already declares `highWaterTick` and `observationCoverage`: it is `IAmpsHook is IMarketReference`, and both are `IMarketReference`'s, so they are in the compiled `IAmpsHook` ABI and in `packages/abis`' `AmpsHook` export already — `docs/keeper-runbook.md`'s note is a false positive and nothing was re-declared. And `Placement` carrying no *per-cell* data (`docs/indexer.md` §8 gap 3) stays as it is: the cell range is now in the event, but liquidity per cell is exactly what the vault's own `ModifyLiquidity` logs already carry, exactly, and duplicating 24 cells into an event field would cost gas on every placement to publish what is already published. |

### 12.5 Audit remediation as landed (orchestrator rulings, 2026-09-07)

The twelve-agent `solidity-auditor` review of `89e451d` (`docs/audits/amplestock-pashov-ai-audit-report-20260907-045500.md`) produced 20 findings and 34 leads; `docs/audits/fix-log.md` carries the disposition of each. The rulings that change stated behaviour:

| # | Ruling |
|---|---|
| AC | **I12 is best-effort, not asserted.** The exit sweep probes balances through bounded staticcalls, absorbs per token, and emits `SweepResidue` instead of reverting; `AmpsVault._assertSweepZero` is gone and `AmpsBonds._issue` forwards collateral dust to the vault. A one-wei donation of a paused or denylisting Stock Token can no longer brick a redemption, a bond market, or any entry point (findings 1, 3). |
| AD | **Redemption pays a refusing token as a claim.** `_payOut` tries `take`; a token that refuses the transfer leaves the redeemer an ERC-6909 claim (`pm.transfer`) they take once the issuer relents, and an unmovable idle wei is simply not paid. The floor is therefore unblockable by any single issuer (finding 2); §7's "no reference to a gate or a price" still holds — the calls are into the tokens themselves, bounded and best-effort. |
| AE | **The buyback burn selects only fully round-tripped cells** (`upperTick <= highWater && tick <= lowerTick`), straddled cells are left alone, and every ask placement resets the mark (§3.5; findings 4 and the stale-mark lead). Decision 16's "AMPS bought back is burned" now means "burned once the cell is pure AMPS again"; partially bought-back inventory re-sells on the way up. |
| AF | **A zero-work `compound` is inert**: no surge, no mark reset, no cooldown (§3.6 step 8; finding 5). |
| AG | **The creator divisor is floored at `SELL_FEE_BPS_DEFAULT`** so the slice is at most one fifth of AMPS-side fees whatever `sellFeeBps` is set to; the dynamic-fee over-statement (≤ 1.6x under GREEN) is accepted and documented rather than tracked per swap, which would cost an SSTORE on every sell (finding 6). |
| AH | **`checkpoint()`/`touch()` refuse before genesis** and `navPerShare` is 0 at zero supply, so the reference can never be written as `1e15` before the first pool opens (finding 7). |
| AI | **`compound` re-ladders at the reference anchor** like every other ask placement (I32; finding 16). |
| AJ | **`deployBonded` refuses a constituent that is not `ACTIVE`** (finding 10); `rollout` charges the window and pays the bounty on what was placed, leaving an unplaced remainder idle and reported by the `Rollout` event; `spokeHasDepth` is derived from the spoke's own bid records. |
| AK | **The rotation credit is keyed by the swap `sender`** (§1.2, §1.4, §1.5; I26; finding 17). Both hops of a router rotation share the router's slot; a batched transaction cannot spend another party's credit. |
| AL | **The hook's `vault` is storage with `setVault`, `PoolRegistry` has `setVault`, and `emergencyMigrate` hands over six roles through `VaultNavLib.handover`** (finding 12); the migration predicate and the self-transfer probe hand-decode returndata (finding 11); `evacuate`'s idle leg is best-effort and the migration asserts no sweep (finding 8). |
| AM | **Every gate read from the vault is a bounded hand-decoded staticcall** and `setPolicyPointer` refuses a codeless target (finding 18). |
| AN | **The feed registry's jump rule is stateless when the latch is stale**: it measures a candidate against the aggregator's previous round, confirms by `confirmSeconds` since the candidate or by agreement with the round before, and while held reports `min(held, candidate)` with `unconfirmed = true`; the aged-pending escape requires agreement with the pending level; the gate treats `unconfirmed` as stale and floors the bond haircut at the `CLOSED` value; the bonds shell recomputes `ampsOut` from `q` and consumes the freshness flag (findings 9, 13, 14, 15). |
| AO | **The hook's multiplier-step detector compares the saturated cache with a saturated reading** (finding 19); `Placed.highestTick` is seeded (finding 20); `STAGE_SLOT` is the hash its comment claims (`Constants.PLACEMENT_STAGE_SLOT`). |
| AP | **Accepted, not changed** (leads): weekend `CLOSED ⇒ DEGRADED` suspends upkeep and vault governance setters (design: placements pause when equities are closed; the timelock keeps `OracleGate`'s own setters and can batch `unfreezeProtocol`); the layer-A restamp inside `checkpoint()` (design: a checkpoint is what clears a passed outage); `pokePool`/`refresh` liveness rests on the keeper (§3.5 of the keeper runbook); third-party growth of a bonder's position array (griefing of `claimAll` only, per-id `claim` unaffected); the reference-basis valuation of straddled cells (bounded by one cell, disclosed as `premium`). |
