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
immutable  amps (Currency)   vault   registry   timelock        poolManager (from BaseHook)
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

**Transient (EIP-1153).** One slot, `ROTATION_CREDIT = keccak256("amplestocks.hook.ROTATION_CREDIT")`. Zero at
the start of every transaction by EVM rule, which is what makes I26 structural rather than enforced.

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
       credit = tload(ROTATION_CREDIT);  c = credit < amountIn ? credit : amountIn
       if (c != 0) {
           tstore(ROTATION_CREDIT, credit - c)
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
   tstore(ROTATION_CREDIT, tload(ROTATION_CREDIT) + uint256(uint128(out))); }` — credited from the **realised**
   delta, never the requested amount, so I26 holds by construction.
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

* **asks** 1,662.5 AMPS each, `ladderDoublings = 10`, `ladderTilt = 1.25`, `above = true`, cells `m = 0..9`.
  `sum 1.25^k (k=0..9) = 33.2529`, so `w_0 = 3.007%` (50.0 AMPS over $1-$2) up to `w_9 = 28.008%` (465.7 AMPS
  over $512-$1,024). A one-sided range order raises `sqrt(P_lo * P_hi)` per AMPS, so bucket 0 raises ~$70.7 per
  pool, ~$141 across both — the plan's "about $140 of buying doubles the price from $1", which confirms the shape.
  Bucket 9 raises ~$337k per pool, ~$674k across both (decision 9).
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
`upperTick` the mark has crossed was fully sold as an ask, so AMPS in it now is inventory the vault **bought
back** and must burn (I33). The current tick decides how much:

```
tick >= upper          : pure counter    -> nothing bought back, nothing to do
lower < tick < upper   : mixed           -> remove all L; burn amount0; re-place amount1 as a bid over
                                            [lower, alignDown(tick)]; set above = false
tick <= lower          : pure AMPS       -> remove all L; burn all of it; liquidity = 0
```

"Keep the counter side in place" is not literally possible in the mixed case — a single-sided `amount1` position
must lie entirely below the tick — so the counter side is re-placed at `[lower, alignDown(tick)]`, still inside
the cell and still on the grid (decision 8). A degenerate range leaves the counter as an ERC-6909 claim for the
next `compound`/`deployBonded`.

**Ordering rule (normative).** Every ask placement into a pool is preceded by that pool's burn step and followed
by `resetHighWater`, so freshly re-laddered AMPS can never be mistaken for bought-back inventory:
`collect -> burn crossed cells -> split fees -> re-ladder -> resetHighWater -> armSurge`.

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
   creatorCut    = ampsFees * min(creatorBps(t), sellFeeBps) / sellFeeBps                -> transfer to `creator`
   stakerCut     = (ampsFees - creatorCut) * stakerBps / BPS                             -> AmpsStaking.notifyReward
   burnCut       = (ampsFees - creatorCut - stakerCut) * burnBps / BPS                   -> Amps.burn
   relaid        = ampsFees - creatorCut - stakerCut - burnCut                           -> new asks
   ```
   Creator payouts are the only transfer of protocol-held AMPS to a non-pool address (I31).
6. **Re-ladder** `relaid` across grid cells strictly above `alignUp(slot0.tick)` via `ILadderPolicy.propose` with
   the anchor snapped to the grid; merge into existing records by `m`.
7. **Re-add counter-side fees** as bids across cells strictly below `alignDown(slot0.tick)`, same shape.
8. `resetHighWater(poolId)`; `armSurge(poolId, SURGE_MAX_BPS, "compound")`.
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
the hook, so the quote is exact rather than approximate. `IAmpsHook.rotationCredit()` is deliberately **not**
consulted: it is transient and always zero when read from a fresh transaction, so the quoter simulates the credit
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
* **I26** `rotationCredit <= sum(AMPS received by swappers this tx)`, zero at every transaction boundary.
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
9. **The plan's "top bucket raises about $540k" does not reconcile.** Bucket 9 holds 465.7 AMPS over $512-$1,024
   and raises `465.7 * sqrt(512*1024)` = ~$337k per entry pool, ~$674k across both; bucket 0 raises ~$141 across
   both, which *does* match "$140 doubles the price". *Proposal:* publish the derived table in the dApp and
   correct the plan's figure. No code depends on it.
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
| 9 | **Plan corrected.** The plan's "$540k" is the top bucket of the whole 3,325-AMPS entry tranche; per pool it is roughly half. The per-bucket derivation in §3.3 is normative. |
| 10 | **Accepted.** `OracleGate` is redeployed in Phase 3 (pointer-upgradeable, nothing deployed yet) to read `IAmpsHook.poolState` for the corporate-action flag, keeping its own token probes as the fallback. |
| 11 | **Accepted.** `place` is timelock-or-registry; `compound`, `rollout`, `deployBonded` are the permissionless bountied paths. |
| 12 | **Accepted.** `salt = bytes32(0)` everywhere, asserted as an invariant. |
| 13 | **Accepted.** Stranded out-of-range fees are measured and disclosed, not engineered around. |
| 14 | **Accepted.** `gridBase` in the hook CONFIG word, mirrored in `PoolConfig.gridBaseTick`. |
| 15 | **Accepted.** `DEPLOY_THRESHOLD_USD18 = 100e18`, 48-hour governed. |
