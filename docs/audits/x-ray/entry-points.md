# Entry Point Map

> Amplestocks ($AMPS) | 110 entry points | 20 permissionless | 31 role-gated | 59 admin-only

Scope: `contracts/src/**` at `ccffe6c`. View/pure functions, interface declarations, mocks and the four linked
vault libraries' `public` functions are excluded. `AmpsQuoter`, `AmpsBondsLens`, `PoolRegistryLens`,
`GatePriceMath` and all four policy contracts expose no state-changing external function at all.

---

## Protocol Flow Paths

### Deployment (Deployer → Timelock)

`03_Core: deploy Amps, AmpsVault, AmpsHook, PoolRegistry` → `AmpsVault.setPolicyPointer("registry"/"bonds"/"bountyPot"/"genesis")` → `FeedRegistry.setStandardProxy()` → `FeedRegistry.setFeed()` → `PoolRegistry.registerEntryPool()` ×2  ◄── vault `pRefX18() == 0`, so pools anchor at $1.00

### Launch (Timelock → Genesis adapter → Anyone)

`[deploy above]` → `AmpsVault.genesisMint()` → `AmpsGenesis.createAuctions()` → [bidding window] → `AmpsGenesis.settle()`
                                                                                          ├─→ `AmpsVault.genesisPlace()`  ◄── at least one leg graduated
                                                                                          └─→ [aborted: proceeds forwarded, timelock runs `genesisPlace` with the founders' seed]

`[genesisPlace above]` → `PoolRegistry.addConstituent()` ×30 → `AmpsVault.initializePool()` → `AmpsVault.place()` (seed ask) → `AmpsBonds.addCollateral()`

### Wiring the gate (Timelock, after the first pools exist)

`[registerEntryPool above]` → `AmpsVault.setPolicyPointer("oracleGate")`  ◄── §9.1: the gate reports `WATCHDOG` on an unobserved hub, so it is pointed last

### User — trade

`AmpsRouter.buy()`  ◄── pool registered and initialised
`AmpsRouter.sell()`
`AmpsRouter.rotate()`  ◄── at least one leg is a spoke; `hop1 != hop2`
        └─→ `PoolManager.swap()` ×2 → `AmpsHook.beforeSwap()` / `afterSwap()`  ◄── refused only beyond the outer rail

### User — redeem

`[genesisPlace above]` → `AmpsVault.redeemProRata()`  ◄── `_initialized`; no gate, no price, no registry on the path
        ├─→ ERC-20 payout per asset
        └─→ ERC-6909 claim per asset  ◄── the ERC-20 leg failed for any reason

### User — bond and claim

`[addCollateral above]` → `AmpsBonds.bond()`  ◄── market open; gate not frozen/diverged; checkpoint < 30 min; NAV confirmed
        └─→ [vestSeconds elapse] → `AmpsBonds.claim()` / `claimAll()`  ◄── structurally ungated

### Keeper — upkeep (bountied)

`[genesisPlace above]` → `AmpsVault.checkpoint()`  ◄── gate not DIVERGED/frozen/WATCHDOG
`[place above]` → [60 s cooldown] → [pool within 800 ticks of fair] → `AmpsVault.compound()`
                                                                     ├─→ `AmpsVault.rollout()`  ◄── rollout policy wired; daily budget and entry floor have room
                                                                     └─→ `AmpsVault.deployBonded()`  ◄── constituent ACTIVE; idle collateral ≥ `deployThresholdUsd18`

### Keeper — oracle upkeep (unpaid)

`OracleGate.poke()` / `pokePool()` / `pokePools()` / `pokeConstituent()`
`FeedRegistry.refresh()` / `refreshMany()`  ◄── feed configured

### Guardian — incident

`OracleGate.freezeProtocol()` / `freezeConstituent()`  ◄── expiry ≤ 7 days ahead
`[setStandbyVault above]` → `AmpsVault.emergencyMigrate()`  ◄── denylist predicate holds on-chain
        └─→ `Amps.setVault()` + `AmpsBonds.setVault()` + `BountyPot.setVault()` + `PoolRegistry.setVault()` + `AmpsHook.setVault()`

### Retirement (Timelock)

`PoolRegistry.retireConstituent()` → `AmpsBonds.setMarketOpen(false)` → `PoolRegistry.withdrawRetiredBids()` → `AmpsVault.withdrawRetiredBids()`

---

## Permissionless

### `AmpsVault.redeemProRata()`

| Aspect | Detail |
|--------|--------|
| Visibility | external, `locked` (EIP-1153 transient lock) |
| Caller | Any AMPS holder |
| Parameters | `shares` (user-controlled), `to` (user-controlled) |
| Call chain | `→ Amps.burn() → PoolManager.unlock() → VaultRedeemLib.unwind() → PoolManager.modifyLiquidity() → VaultRedeemLib.redemption() → VaultRedeemLib.payout() → PoolManager.take()` |
| State modified | `Amps.totalSupply`, `ladderAt[poolId][].liquidity`, `VaultRedeemLib` live-cell counter |
| Value flow | Vault → recipient (ERC-20 per asset, or ERC-6909 claims on fallback); AMPS burned |
| Reentrancy guard | yes |

### `AmpsBonds.bond()`

| Aspect | Detail |
|--------|--------|
| Visibility | external, `lock` (transient bool) |
| Caller | Any address holding a registered collateral |
| Parameters | `marketId` (user-controlled), `amountIn` (user-controlled), `minAmpsOut` (user-controlled), `to` (user-controlled) |
| Call chain | `→ OracleGate.checkBond() → AmpsVault.depositBonded() → AmpsVault._checkpoint() → PoolManager.unlock() → VaultRedeemLib.settleFrom() → BondPolicy.quote() → AmpsVault.mintVesting() → Amps.mint()` |
| State modified | `_markets[id].issuedThisEpoch/.totalIssued/.lastBondAt/.epochStart`, `_dailyIssued`, `_positions[to]`, vault checkpoint words, `Amps.totalSupply` |
| Value flow | Bonder → PoolManager (collateral); AMPS minted to `AmpsBonds` for vesting |
| Reentrancy guard | yes (both contracts hold their own locks across the call) |

### `AmpsBonds.claim()` / `AmpsBonds.claimAll()`

| Aspect | Detail |
|--------|--------|
| Visibility | external, `lock` |
| Caller | Position owner (`_positions[msg.sender]` only) |
| Parameters | `positionId` (user-controlled), `to` (user-controlled) |
| Call chain | `→ Amps.transfer()` |
| State modified | `_positions[msg.sender][id].claimed` |
| Value flow | `AmpsBonds` → recipient (AMPS) |
| Reentrancy guard | yes |

### `AmpsRouter.buy()`

| Aspect | Detail |
|--------|--------|
| Visibility | external payable, `nonReentrant`, `before(deadline)` |
| Caller | Any |
| Parameters | `poolId` (user-controlled), `amountIn` (user-controlled), `minAmpsOut` (user-controlled), `to` (user-controlled), `deadline` (user-controlled) |
| Call chain | `→ PoolRegistry.poolKey() → PoolManager.unlock() → PoolManager.swap() → AmpsHook.beforeSwap()/afterSwap() → PoolManager.take()` |
| State modified | Pool state in the PoolManager; hook DYNAMIC/ARMED words and observation ring |
| Value flow | Caller → PoolManager (counter asset, or wrapped `msg.value`); AMPS → `to` |
| Reentrancy guard | yes |

### `AmpsRouter.sell()`

| Aspect | Detail |
|--------|--------|
| Visibility | external, `nonReentrant`, `before(deadline)` |
| Caller | Any |
| Parameters | `poolId`, `ampsIn`, `minOut`, `to`, `unwrap` (all user-controlled), `deadline` (user-controlled) |
| Call chain | `→ PoolRegistry.poolKey() → PoolManager.unlock() → PoolManager.swap() → AmpsHook.beforeSwap()/afterSwap() → PoolManager.take() → WETH9.withdraw()` (unwrap only) |
| State modified | Pool state; hook DYNAMIC/ARMED words and observation ring |
| Value flow | Caller → router → PoolManager (AMPS); counter asset or native ETH → `to` |
| Reentrancy guard | yes |

### `AmpsRouter.rotate()`

| Aspect | Detail |
|--------|--------|
| Visibility | external payable, `nonReentrant`, `before(deadline)` |
| Caller | Any |
| Parameters | `hop1`, `hop2`, `amountIn`, `minOut`, `to`, `unwrap`, `deadline` (all user-controlled) |
| Call chain | `→ PoolRegistry.poolKey() ×2 → PoolManager.unlock() → PoolManager.swap() ×2 with hookData = ROUTER_ROTATE → AmpsHook.beforeSwap()/afterSwap() ×2 → PoolManager.take()` |
| State modified | Pool state in two pools; hook transient rotation credit and pass-through counter; hook DYNAMIC/ARMED words |
| Value flow | Caller → PoolManager (hop-1 counter); hop-2 counter → `to`; AMPS delta asserted zero |
| Reentrancy guard | yes |

### `AmpsVault.compound()`

| Aspect | Detail |
|--------|--------|
| Visibility | external, `locked` |
| Caller | Keeper (anyone; paid from `BountyPot`) |
| Parameters | `poolId` (user-controlled) |
| Call chain | `→ OracleGate.checkPlacement() → VaultPlacementLib.compound() → PoolManager.unlock() → PoolManager.modifyLiquidity() → Amps.burn() → AmpsHook.resetHighWater() → AmpsHook.armSurge() → BountyPot.pay()` |
| State modified | `ladderAt[poolId]`, `_lastPlacementAt[poolId]`, live-cell counter, checkpoint words, `Amps.totalSupply`, hook ARMED/DYNAMIC words, `BountyPot` window |
| Value flow | Fees realised into claims; creator slice out; AMPS remainder burned; USDG bounty → caller |
| Reentrancy guard | yes |

### `AmpsVault.rollout()`

| Aspect | Detail |
|--------|--------|
| Visibility | external, `locked` |
| Caller | Keeper (anyone; paid) |
| Parameters | `constituentId` (user-controlled) |
| Call chain | `→ OracleGate.checkPlacement() → VaultRolloutLib.rollout() → RolloutPolicy.propose() → PoolManager.unlock() → PoolManager.modifyLiquidity() → VaultPlacementLib.place() → BountyPot.pay()` |
| State modified | `ladderAt` in up to three pools, `_lastPlacementAt`, rollout window (slot 15), live-cell counter, checkpoint words |
| Value flow | AMPS moved between entry pools and one spoke; USDG bounty → caller |
| Reentrancy guard | yes |

### `AmpsVault.deployBonded()`

| Aspect | Detail |
|--------|--------|
| Visibility | external, `locked` |
| Caller | Keeper (anyone; paid) |
| Parameters | `constituentId` (user-controlled) |
| Call chain | `→ OracleGate.checkPlacement() → VaultRolloutLib.deployBonded() → FeedRegistry.latestAnswer() → VaultPlacementLib.place() → PoolManager.modifyLiquidity() → BountyPot.pay()` |
| State modified | `ladderAt[poolId]`, `_lastPlacementAt`, live-cell counter, checkpoint words |
| Value flow | Idle bonded collateral → v4 bid positions; USDG bounty → caller |
| Reentrancy guard | yes |

### `AmpsVault.checkpoint()` / `AmpsVault.touch()`

| Aspect | Detail |
|--------|--------|
| Visibility | external, `locked` |
| Caller | Anyone (unpaid) |
| Parameters | none |
| Call chain | `→ OracleGate.poke() → OracleGate.state() → VaultNavLib.totalAssetsUsd18() → VaultNavLib.marketPrice() → VaultNavLib.referencePrice() → VaultRedeemLib.sweepClean()` |
| State modified | `_navPerShareX18`, `_pRefX18`, `_pMktX18`, `_checkpointTimestamp`, `_checkpointBlock`, `_navUnconfirmed`; `touch` stamps the gate only |
| Value flow | none (the exit sweep may absorb idle dust into claims) |
| Reentrancy guard | yes |

### `AmpsGenesis.settle()`

| Aspect | Detail |
|--------|--------|
| Visibility | external |
| Caller | Anyone, once, after both legs' `claimBlock` |
| Parameters | none |
| Call chain | `→ IContinuousClearingAuction.checkpoint()/isGraduated()/sweepCurrency()/sweepUnsoldTokens() → WETH9.deposit() → FeedRegistry.latestAnswerUsd18() → AmpsVault.genesisPlace()` |
| State modified | `_settledLatch`, `_abortedLatch`, `_p0X18`, `_raisedUsdg`, `_raisedWeth`, `_unsoldAmps`, `_ethUsdX18`; vault genesis latches |
| Value flow | Auctions → adapter → vault (USDG, WETH, unsold AMPS) |
| Reentrancy guard | the one-shot latch, set before every interaction |

### `FeedRegistry.refresh()` / `refreshMany()`

| Aspect | Detail |
|--------|--------|
| Visibility | public / external |
| Caller | Anyone (unpaid) |
| Parameters | `token` / `tokens[]` (user-controlled) |
| Call chain | `→ IAggregatorV3.latestRoundData() → IAggregatorV3.getRoundData() → OracleGate.sessionNow()` |
| State modified | `_accepted[token]`, `_pending[token]` |
| Value flow | none |
| Reentrancy guard | no (no external value movement) |

### `OracleGate.poke()` / `pokePool()` / `pokePools()` / `pokeConstituent()`

| Aspect | Detail |
|--------|--------|
| Visibility | external / public |
| Caller | Anyone (unpaid) |
| Parameters | `poolId` / `poolIds[]` / `constituentId` (user-controlled) |
| Call chain | `→ IMarketReference.lastTruncatedTick()/twapTick() → FeedRegistry.feedStatusIn() → GatePriceMath.fairTick() → IStockToken.oraclePaused()/effectiveAt()` |
| State modified | `_lastBlock`, `_lastTimestamp`, `_divergedSince[poolId]` |
| Value flow | none |
| Reentrancy guard | no |

### `BountyPot.fund()`

| Aspect | Detail |
|--------|--------|
| Visibility | external |
| Caller | Anyone |
| Parameters | `amountRaw` (user-controlled) |
| Call chain | `→ IERC20.safeTransferFrom()` |
| State modified | none (balance only) |
| Value flow | Funder → pot (USDG) |
| Reentrancy guard | no |

---

## Role-Gated

### `vault` (the `AmpsVault` address, movable only by `emergencyMigrate`)

| Contract | Function | Parameters | State Modified |
|----------|----------|------------|----------------|
| `Amps` | `mint()` | `to`, `amount` (protocol-derived) | `totalSupply`, `balanceOf` |
| `Amps` | `burn()` | `from`, `amount` (protocol-derived) | `totalSupply`, `balanceOf` |
| `Amps` | `setVault()` | `newVault` (protocol-derived) | `vault` |
| `AmpsBonds` | `setVault()` | `newVault` (protocol-derived) | `vault` |
| `BountyPot` | `pay()` | `to` (keeper-provided), `workValueUsd18`, `gasCostUsd18` (protocol-derived) | `_spentWindowUsd18`, `_windowStart`; USDG out |
| `BountyPot` | `setVault()` | `newVault` (protocol-derived) | `vault` |
| `PoolRegistry` | `setVault()` | `newVault` (protocol-derived) | `_vault` |
| `AmpsHook` | `resetHighWater()` | `poolId` (protocol-derived) | `_obs[poolId].highWaterTick` |
| `AmpsHook` | `armSurge()` | `poolId`, `surgeBps_`, `reason` (protocol-derived) | `_arm[poolId]`, `_dyn[poolId].gateAttemptedAt` |
| `AmpsHook` | `setVault()` | `newVault` (protocol-derived) | `vault` |

### `AmpsBonds` (the vault's set-once `bonds` pointer)

#### `AmpsVault.depositBonded()`

| Aspect | Detail |
|--------|--------|
| Visibility | external, `locked` |
| Caller | `AmpsBonds`, from inside `bond()` |
| Parameters | `marketId`, `collateral`, `from`, `amount` (all keeper-/user-provided, relayed by the shell) |
| Call chain | `→ VaultRedeemLib.sweepClean() → _checkpoint() → PoolManager.unlock() → VaultRedeemLib.settleFrom() → PoolManager.settle()/mint()` |
| State modified | `_assets`, `_assetIndex`, all five checkpoint fields, `_navUnconfirmed` |
| Value flow | Bonder → PoolManager (ERC-6909 claim to the vault) |
| Reentrancy guard | yes |

#### `AmpsVault.mintVesting()`

| Aspect | Detail |
|--------|--------|
| Visibility | external, `locked` |
| Caller | `AmpsBonds` |
| Parameters | `to` (must equal `bonds`), `amount` (protocol-derived) |
| Call chain | `→ Amps.mint()` |
| State modified | `Amps.totalSupply`, `Amps.balanceOf[bonds]` |
| Value flow | AMPS minted into `AmpsBonds` custody |
| Reentrancy guard | yes |

### `PoolRegistry`

| Contract | Function | Parameters | State Modified |
|----------|----------|------------|----------------|
| `AmpsVault` | `initializePool()` | `key`, `sqrtPriceX96` (protocol-derived) | `_poolKeys`, `_assets`, `_assetIndex`; opens the v4 pool |
| `AmpsVault` | `place()` | `poolId`, `above`, `amount` (protocol-derived) — also callable by the timelock | `ladderAt`, `_lastPlacementAt`, live cells, checkpoint |
| `AmpsVault` | `withdrawRetiredBids()` | `constituentId` (protocol-derived) | `ladderAt[poolId]`, `_lastPlacementAt`, live cells |
| `AmpsBonds` | `addCollateral()` | 7 params (protocol-derived) — also callable by the timelock | `_markets`, `marketIdOf`, `marketCount` |
| `AmpsBonds` | `setMarketOpen()` | `marketId`, `open` — also callable by the timelock | `_markets[id].open` |

### `guardian` (immutable Safe)

| Contract | Function | Parameters | State Modified |
|----------|----------|------------|----------------|
| `AmpsVault` | `emergencyMigrate()` | `standby` (must equal the registered address) | Every claim balance, five `onlyVault` role pointers, `ladderAt` (fully unwound) |
| `OracleGate` | `freezeProtocol()` | `until` (guardian-provided, ≤ 7 d) | `_protocolFreezeUntil` |
| `OracleGate` | `freezeConstituent()` | `constituentId`, `until` (guardian-provided, ≤ 7 d) | `_constituentFreezeUntil[id]` |
| `OracleGate` | `unfreezeProtocol()` | none — also callable by the timelock | `_protocolFreezeUntil` |
| `OracleGate` | `unfreezeConstituent()` | `constituentId` — also callable by the timelock | `_constituentFreezeUntil[id]` |

### `creator`

| Contract | Function | Parameters | State Modified |
|----------|----------|------------|----------------|
| `AmpsVault` | `setCreator()` | `newCreator` (user-controlled by the current creator) | `_creator` |

### `genesis` adapter (set-once, latched at `genesisMint`)

| Contract | Function | Parameters | State Modified |
|----------|----------|------------|----------------|
| `AmpsVault` | `genesisPlace()` | `params` (adapter-derived) — also callable by the timelock | `_assets`, `_assetIndex`, `_genesisTimestamp`, `_initialized`, `_wiringFrozen`, `_pRefX18`, checkpoint |

### `PoolManager` (Uniswap v4, immutable)

| Contract | Function | Parameters | State Modified |
|----------|----------|------------|----------------|
| `AmpsVault` | `unlockCallback()` | `data` (protocol-derived; dispatched on a transient discriminator the vault set) | Depends on the action: claims, ladder records, live cells |
| `AmpsRouter` | `unlockCallback()` | `data` (protocol-derived; also requires the router's own transient lock held) | Pool state only |
| `AmpsHook` | `beforeInitialize()` / `afterInitialize()` | `sender`, `key`, `sqrtPriceX96`, `tick` | `_cfg[id]`, `_dyn[id]`, `_arm[id]`, `_obs[id]` |
| `AmpsHook` | `beforeAddLiquidity()` | `sender`, `key`, `params` | none (refuses any non-vault sender) |
| `AmpsHook` | `beforeSwap()` | `sender`, `key`, `params`, `hookData` (user-controlled) | Transient rotation credit and pass-through counter |
| `AmpsHook` | `afterSwap()` | `sender`, `key`, `params`, `delta`, `hookData` (user-controlled) | `_dyn[id]`, `_arm[id]`, `_obs[id]`, transient credit |

---

## Admin-Only

All 59 rows below are gated on `msg.sender == timelock` — one `TimelockController` address per contract, fixed at
construction. The 48-hour / 7-day / 14-day tiers the documentation assigns to these functions are a governance
convention, not an on-chain distinction.

| Contract | Function | Parameters | State Modified |
|----------|----------|------------|----------------|
| `AmpsVault` | `genesisMint()` | `params` (tranche split, team wallet, creator, adapter) | `_genesisMinted`, `_creator`; mints all of `S0` |
| `AmpsVault` | `setRedeemFeeBps()` | `value` ∈ [0, 500] | `_redeemFeeBps` |
| `AmpsVault` | `setRefUpRateBps()` | `value` ∈ [100, 5000] | `_refUpRateBps` |
| `AmpsVault` | `setRefDivergenceBps()` | `value` ∈ [100, 2000] | `_refDivergenceBps` |
| `AmpsVault` | `setTwapWindow()` | `value` ∈ [300, 7200] | `_twapWindow` |
| `AmpsVault` | `setLadderShape()` | `tiltX18`, `doublings`, `seedHalvings_`, `bondBidHalvings_` | `_ladderTiltX18`, `_ladderDoublings`, `_seedHalvings`, `_bondBidHalvings` |
| `AmpsVault` | `setRolloutParams()` | `bpsPerDay` ∈ [0, 1000], `floorBps` ∈ [0, 8000] | `_rolloutBpsPerDay`, `_entryFloorBps` |
| `AmpsVault` | `setSpokeSeedBps()` | `value` ∈ [10, 1000] | `_spokeSeedBps` |
| `AmpsVault` | `setDeployThresholdUsd18()` | `value` ∈ [10e18, 10_000e18] | `_deployThresholdUsd18` |
| `AmpsVault` | `setPolicyPointer()` | `slot` (short string), `newPointer` (must hold code) | One of slots 4, 5, 7, 8, 9, 10, 11, 12, 13, 22 |
| `AmpsVault` | `setStandbyVault()` | `standby` (must hold code) | `_standbyVault` |
| `AmpsBonds` | `removeCollateral()` | `collateral` | `marketIdOf[collateral]`, `_markets[id].open` |
| `AmpsBonds` | `setDiscountParams()` | `marketId`, `dBaseBps`, `dMinBps`, `dMaxBps` ∈ [500, 2500] | `_markets[id]` discount triple |
| `AmpsBonds` | `setCoefficients()` | `marketId` (0 = global), `kWeightX18`, `kFillX18` ≤ 2e18 | `_markets[id]` or `defaultKWeightX18`/`defaultKFillX18` |
| `AmpsBonds` | `setCapBpsPerEpoch()` | `marketId`, `capBpsPerEpoch` ≤ 200 | `_markets[id].capBpsPerEpoch` |
| `AmpsBonds` | `setEpochSeconds()` | `value` ∈ [1 h, 7 d] | `epochSeconds` |
| `AmpsBonds` | `setDailyCapBps()` | `value` ≤ 500 | `dailyCapBps` |
| `AmpsBonds` | `setVestSeconds()` | `value` ∈ [1 h, 7 d] | `vestSeconds` |
| `AmpsBonds` | `setMinAccretionBps()` | `value` ≤ 500 | `minAccretionBps` |
| `AmpsBonds` | `setPolicy()` | `newPolicy` | `policy` |
| `AmpsHook` | `setAmpsFeeBps()` | `value` ∈ [100, 600] | `_ampsFee` |
| `AmpsHook` | `setBuyFeeBps()` | `poolId`, `value` (class band) | `_cfg[poolId].buyFeeBps` |
| `AmpsHook` | `setMaxTickMovePerBlock()` | `poolId`, `value` ∈ [10, 2000] | `_cfg[poolId].maxTickMovePerBlock` |
| `AmpsHook` | `setFeePolicy()` | `newPolicy` (must hold code) | `_policy` |
| `AmpsHook` | `setRouter()` | `newRouter` (zero permitted) | `router` |
| `AmpsHook` | `setGateCacheSeconds()` | `value` ∈ [1, 900] | `_gateCache` |
| `OracleGate` | `setGraceSeconds()` | `value` ∈ [300, 86400], `> gapSeconds` | `_graceSeconds` |
| `OracleGate` | `setGapSeconds()` | `value` ∈ [1, 1800], `< graceSeconds` | `_gapSeconds` |
| `OracleGate` | `setDivergenceBps()` | `value` ∈ [1, 2000] | `_divergenceBps` |
| `OracleGate` | `setDivergenceSustainSeconds()` | `value` ≤ 3600 | `_divergenceSustainSeconds` |
| `OracleGate` | `setCorporateActionWindow()` | `value` ≤ 86400 | `_corporateActionWindow` |
| `OracleGate` | `setRefDivergenceBps()` | `value` ∈ [100, 2000] | `_refDivergenceBps` |
| `OracleGate` | `setHSessionBps()` | `session`, `bps` ≤ 1000 | One of the four `_hSession*` fields |
| `OracleGate` | `setHolidayBitmap()` | `year`, `bitmap[2]` (unvalidated content) | `_holidayBitmap[year]` |
| `OracleGate` | `setDstTable()` | `starts[]`, `ends[]` (≤ 64, ascending, non-overlapping) | `_dstStarts`, `_dstEnds` |
| `OracleGate` | `setFeedRegistry()` | `value` | `_feedRegistry` |
| `OracleGate` | `setRegistry()` | `value` | `_registry` |
| `OracleGate` | `setMarketReference()` | `value` | `_marketReference` |
| `FeedRegistry` | `setStandardProxy()` | `aggregator`, `standard` | `isStandardProxy[aggregator]` |
| `FeedRegistry` | `setStandardProxies()` | `aggregators[]`, `standard[]` | `isStandardProxy[]` |
| `FeedRegistry` | `setFeed()` | `token`, `aggregator`, `config` | `_feeds[token]`, clears `_accepted`/`_pending`, re-latches |
| `FeedRegistry` | `configureFeed()` | `token`, `heartbeat`, `thresholdBps`, `minAnswerUsd8`, `maxAnswerUsd8` | `_feeds[token]` bands |
| `FeedRegistry` | `setFreshnessMultiplier()` | `session`, `multiplier` ∈ [100, 2400] | One of the four `_freshness*` fields |
| `FeedRegistry` | `setConfirmSeconds()` | `value` ∈ [300, 86400] | `_confirmSeconds` |
| `FeedRegistry` | `setOracleGate()` | `gate` | `_oracleGate` |
| `PoolRegistry` | `registerEntryPool()` | `key`, `counterDecimals`, `buyFeeBps`, `feed` | `_pools`, `_keys`, `_poolCount`, `_hubPoolId` or `_wethPoolId`; opens the pool |
| `PoolRegistry` | `addConstituent()` | `params` (token, class, weights, inclusion record, feed, tick spacing) | `_constituents`, `_inclusion`, `_constituentIdOf`, `_poolIdOf`, `_pools`, `_keys`, counters; opens the pool and the bond market |
| `PoolRegistry` | `retireConstituent()` | `constituentId` | `status`, `rolloutWeightBps`, `retiredAt`, `_activeCount`; closes the bond market |
| `PoolRegistry` | `reinstateConstituent()` | `constituentId`, `rolloutWeightBps` | `status`, `rolloutWeightBps`, `retiredAt`, `_activeCount`; re-opens the market |
| `PoolRegistry` | `reconfigureConstituent()` | `constituentId`, `params` (8 optional fields) | `poolClass`, `buyFeeBps`, `targetWeightBps`, `rolloutWeightBps`, `feed`, `hSessionOverride*`, `caFreezeOverride` |
| `PoolRegistry` | `setIndexWeights()` | `ids[]`, `weightsBps[]` (must sum to `BPS`) | `targetWeightBps` per named constituent |
| `PoolRegistry` | `withdrawRetiredBids()` | `constituentId` | Calls `AmpsVault.withdrawRetiredBids` |
| `BountyPot` | `sweep()` | `to`, `amountRaw` | USDG out of the pot |
| `BountyPot` | `setTipUsd18()` | `value` ≤ 5e18 | `tipUsd18` |
| `BountyPot` | `setChipBps()` | `value` ≤ 1000 | `chipBps` |
| `BountyPot` | `setChostUsd18()` | `value` ≤ 1000e18 | `chostUsd18` |
| `BountyPot` | `setGasCapMultiple()` | `value` ∈ [1, 10] | `gasCapMultiple` |
| `BountyPot` | `setDailyCeilingUsd18()` | `value` ≤ 100_000e18 | `dailyCeilingUsd18` |
| `AmpsGenesis` | `createAuctions()` | `usdgSpec`, `ethSpec`, `ethUsdX18_` | `_usdgAuction`, `_ethAuction`, `_startBlock`, `_endBlock`, `_ethUsdX18`, both floors; deploys and funds both auctions |

---

## Initialization

No proxies and no `initialize()` functions: every contract is immutable bytecode with a constructor. The
equivalent one-time surface is:

| Function | Caller | Latch |
|----------|--------|-------|
| `AmpsVault.setPolicyPointer()` for `registry`, `bonds`, `bountyPot` | timelock | `_wiringFrozen`, closed by `genesisPlace` |
| `AmpsVault.setPolicyPointer("genesis")` | timelock | `_genesisMinted`, closed by `genesisMint` |
| `AmpsVault.genesisMint()` | timelock | `_genesisMinted` |
| `AmpsVault.genesisPlace()` | genesis adapter or timelock | `_initialized` |
| `AmpsGenesis.createAuctions()` | timelock | both auction addresses non-zero |
| `AmpsGenesis.settle()` | anyone | `_settledLatch` |
| `PoolRegistry.registerEntryPool()` | timelock | `_hubPoolId` / `_wethPoolId` per leg |
| `AmpsVault.initializePool()` | registry | v4's own already-initialised check |
