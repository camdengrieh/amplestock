# Entry Point Map

> Amplestocks ($AMPS) | 110 entry points | 21 permissionless | 29 role-gated | 60 admin-only

Scope: every `external`/`public` non-view, non-pure function in `contracts/src/**` excluding interfaces and mocks, plus the five Uniswap v4 callbacks `AmpsHook` inherits from OZ `BaseHook` and the four ERC-4626 entry points `AmpsStaking` inherits from OZ `ERC4626`. The 14 `public` functions of the four linked vault libraries (`VaultNavLib`, `VaultPlacementLib`, `VaultRedeemLib`, `VaultRolloutLib`) are downstream `DELEGATECALL` targets of the vault, not entry points: Solidity refuses a direct `CALL` into a state-changing library function, and every one of them takes the vault's storage by reference.

---

## Protocol Flow Paths

### Deployment & wiring (Timelock)

`Amps(vault)` → `AmpsVault(amps, poolManager, timelock, guardian)` → `AmpsVault.setPolicyPointer("registry" | "bonds" | "staking" | "bountyPot" | "oracleGate" | "feedRegistry" | "marketReference" | "positionValuer" | "ladderPolicy" | "rolloutPolicy")`
→ `FeedRegistry.setStandardProxy()` → `FeedRegistry.setFeed()` → `OracleGate.setFeedRegistry()` / `setRegistry()` / `setMarketReference()`
→ `PoolRegistry.registerEntryPool()` ×2 → `PoolRegistry.addConstituent()` ×30  ◄── each opens the pool through `AmpsVault.initializePool()` and its bond market through `AmpsBonds.addCollateral()`
→ `AmpsVault.genesis()`  ◄── mints S0, seeds ETH/USDG, freezes the four custody pointers
→ `AmpsVault.place()` per pool  ◄── genesis ask ladders and seed bids; gate must be GREEN, which needs 30 min of hub TWAP history

### Trader flow

`[wiring above]` → `PoolManager.swap()` → `AmpsHook.beforeSwap()` → `AmpsHook.afterSwap()`  ◄── fee = base + dyn; only a deviation-increasing swap beyond the outer rail reverts
                                                └─→ same tx, second pool: rotation credit blends the sell fee

### Bonder flow

`[wiring above]` → `[market open]` → `AmpsBonds.bond()`  ◄── gate not DIVERGED/SCHEDULED_FREEZE for the constituent; epoch and daily capacity left
                                        └─→ [vestSeconds elapse, linearly] → `AmpsBonds.claim()` / `claimAll()`

### Holder flow

`[genesis above]` → `AmpsVault.redeemProRata()`  ◄── no gate, no oracle, no guardian; only the transient lock
`[genesis above]` → `AmpsStaking.deposit()` / `mint()` → [rewards stream from compounds] → `AmpsStaking.withdraw()` / `redeem()`

### Keeper flow

`[place above]` → [swaps accrue fees] → `AmpsVault.compound(poolId)`  ◄── gate GREEN/REF_DIVERGED, 60 s cooldown, tick within 800 of fair
`[place above]` → [24 h rollout budget left] → `AmpsVault.rollout(constituentId)`
`[bond above]` → [idle collateral ≥ deployThresholdUsd18] → `AmpsVault.deployBonded(constituentId)`
`AmpsVault.checkpoint()` / `touch()` / `OracleGate.poke*()` / `FeedRegistry.refresh()` / `AmpsStaking.accrue()` / `BountyPot.fund()`  ◄── unpaid upkeep, any time

### Lifecycle (Timelock)

`PoolRegistry.retireConstituent()` → `PoolRegistry.withdrawRetiredBids()` → `AmpsVault.withdrawRetiredBids()`
                                  └─→ `PoolRegistry.reinstateConstituent()`

### Emergency (Guardian)

`OracleGate.freezeConstituent()` / `freezeProtocol()`  ◄── ≤ 7 days, disable-only, never touches redemption or claims
`AmpsVault.setStandbyVault()` [Timelock, 14 d] → [issuer denylists the vault] → `AmpsVault.emergencyMigrate(standby)`  ◄── predicate: `isBlocked(vault)` or two failed 1-wei probes

---

## Permissionless

Entry points callable by any address with no effective access restriction. Sorted by value flow: tokens-in first, tokens-out second, no-token-movement last.

### `AmpsBonds.bond()`

| Aspect | Detail |
|--------|--------|
| Visibility | external, `lock` (transient reentrancy guard) |
| Caller | Any holder of a registered collateral |
| Parameters | marketId (user-controlled), amountIn (user-controlled), minAmpsOut (user-controlled), to (user-controlled) |
| Call chain | `→ OracleGate.checkBond() → AmpsBonds._rollEpoch/_rollDay → AmpsVault.depositBonded() → AmpsVault._checkpoint() → PoolManager.unlock(ACTION_SETTLE) → VaultRedeemLib.settleFrom() → IERC20.transferFrom(bonder → PoolManager) → AmpsBonds._price() → AmpsVault.checkpointData() → FeedRegistry.latestAnswer() → AmpsHook.twapTick30m() → BondPolicy.quote() → AmpsBonds._issue() → AmpsVault.mintVesting() → Amps.mint(AmpsBonds)` |
| State modified | `_markets[id].issuedThisEpoch/totalIssued/lastBondAt/epochStart`, `_dailyIssued`, `_dailyWindowStart`, `_positions[to]` (push); vault `_assets`/`_assetIndex`, checkpoint words; `Amps.totalSupply` |
| Value flow | Collateral: bonder → PoolManager (vault claim); AMPS: minted to `AmpsBonds` (vesting) |
| Reentrancy guard | yes (bonds `lock` + vault `locked`) |

### `AmpsStaking.deposit()` / `AmpsStaking.mint()`

| Aspect | Detail |
|--------|--------|
| Visibility | public (inherited from OZ `ERC4626`) |
| Caller | Any AMPS holder |
| Parameters | assets / shares (user-controlled), receiver (user-controlled) |
| Call chain | `→ AmpsStaking._deposit() → AmpsStaking._accrue() → ERC4626._deposit() → IERC20.safeTransferFrom(staker → AmpsStaking) → ERC20._mint(xAMPS)` |
| State modified | `_pendingRewards`, `lastAccrualAt`, xAMPS `totalSupply`/`balanceOf` |
| Value flow | AMPS: staker → AmpsStaking |
| Reentrancy guard | no (AMPS is a plain OZ ERC-20 with no hooks) |

### `BountyPot.fund()`

| Aspect | Detail |
|--------|--------|
| Visibility | external |
| Caller | Anyone (governance, sponsors) |
| Parameters | amountRaw (user-controlled) |
| Call chain | `→ IERC20.safeTransferFrom(funder → BountyPot)` |
| State modified | none (balance only) |
| Value flow | USDG: funder → BountyPot |
| Reentrancy guard | no |

### `AmpsVault.redeemProRata()`

| Aspect | Detail |
|--------|--------|
| Visibility | external, `locked` |
| Caller | Any AMPS holder |
| Parameters | shares (user-controlled), to (user-controlled) |
| Call chain | `→ Amps.totalSupply() → Amps.burn(msg.sender) → PoolManager.unlock(ACTION_UNWIND) → VaultRedeemLib.unwind() → PoolManager.modifyLiquidity() per record → PoolManager.mint(claims) → VaultRedeemLib.redemption() → PoolManager.unlock(ACTION_PAYOUT) → VaultRedeemLib._payOut() → PoolManager.burn(claim) + PoolManager.take(to) / IERC20.safeTransfer(to) → Amps.burn(vault, inventoryBurned)` |
| State modified | `ladderAt[*][*].liquidity` (−), `LIVE_CELLS_SLOT`; `Amps.totalSupply` (−shares −inventory) |
| Value flow | AMPS: redeemer → burned; every non-AMPS asset: PoolManager/vault → `to`, net of `redeemFeeBps` |
| Reentrancy guard | yes (transient lock; no gate, oracle, registry or guardian read on the path) |

### `AmpsBonds.claim()` / `AmpsBonds.claimAll()`

| Aspect | Detail |
|--------|--------|
| Visibility | external, `lock` |
| Caller | A bonder with a vesting position |
| Parameters | positionId (user-controlled, `claim` only), to (user-controlled) |
| Call chain | `→ AmpsBonds._vested() → IERC20(amps).transfer(to)` |
| State modified | `_positions[msg.sender][i].claimed` |
| Value flow | AMPS: AmpsBonds → `to` |
| Reentrancy guard | yes (`lock`); structurally ungated: no pointer, gate or governance read |

### `AmpsStaking.withdraw()` / `AmpsStaking.redeem()`

| Aspect | Detail |
|--------|--------|
| Visibility | public (inherited from OZ `ERC4626`) |
| Caller | xAMPS holder or an approved spender |
| Parameters | assets / shares (user-controlled), receiver (user-controlled), owner (user-controlled, allowance-checked) |
| Call chain | `→ AmpsStaking._withdraw() → AmpsStaking._accrue() → ERC4626._withdraw() → ERC20._burn(xAMPS) → IERC20.safeTransfer(receiver)` |
| State modified | `_pendingRewards`, `lastAccrualAt`, xAMPS `totalSupply`/`balanceOf` |
| Value flow | AMPS: AmpsStaking → receiver |
| Reentrancy guard | no |

### `AmpsVault.compound()`

| Aspect | Detail |
|--------|--------|
| Visibility | external, `locked` |
| Caller | Keeper (bountied) |
| Parameters | poolId (user-controlled) |
| Call chain | `→ AmpsVault._requireHealthy() → OracleGate.state() → VaultPlacementLib.compound() → OracleGate.checkPlacement() → PoolStateLib.sqrtPriceAndTick() → PoolManager.unlock(ACTION_COMPOUND/BURNBACK) → PoolManager.modifyLiquidity(0) [collect] → Amps.burn(boughtBack) → VaultPlacementLib._split() → IERC20.safeTransfer(creator) → IERC20.safeTransfer(staking) + AmpsStaking.notifyReward() → Amps.burn(burnCut) → VaultPlacementLib._placeLadder() → PoolManager.unlock(ACTION_PLACE) → PoolManager.modifyLiquidity() → AmpsHook.resetHighWater() / armSurge() → VaultPlacementLib.payBounty() → BountyPot.pay(msg.sender) → AmpsVault._afterPlacement() → AmpsVault._checkpoint()` |
| State modified | `ladderAt[poolId]`, `_lastPlacementAt[poolId]`, `LIVE_CELLS_SLOT`, checkpoint words; hook `_obs/_arm/_dyn`; staking stream; pot window; `Amps.totalSupply` (−) |
| Value flow | Fees: PoolManager → vault claims; AMPS: vault → creator, → AmpsStaking, → burned; USDG bounty: BountyPot → keeper |
| Reentrancy guard | yes |

### `AmpsVault.rollout()`

| Aspect | Detail |
|--------|--------|
| Visibility | external, `locked` |
| Caller | Keeper (bountied) |
| Parameters | constituentId (user-controlled) |
| Call chain | `→ AmpsVault._requireHealthy() → VaultRolloutLib.rollout() → PoolRegistry.constituent()/poolIdOf()/currentWeightBps() → RolloutPolicy.propose() → VaultRolloutLib._harvestAsks() → PoolManager.unlock(ACTION_HARVEST) → PoolManager.modifyLiquidity() [entry pools] → VaultPlacementLib.place() [spoke asks] → VaultPlacementLib.payBounty() → BountyPot.pay() → AmpsVault._afterPlacement()` |
| State modified | `ladderAt[entry]` (−), `ladderAt[spoke]` (+), `_lastPlacementAt`, `SLOT_ROLLOUT_WINDOW`, `LIVE_CELLS_SLOT`, checkpoint words |
| Value flow | AMPS inventory: entry-pool positions → spoke positions (PoolManager-internal); USDG bounty: BountyPot → keeper |
| Reentrancy guard | yes |

### `AmpsVault.deployBonded()`

| Aspect | Detail |
|--------|--------|
| Visibility | external, `locked` |
| Caller | Keeper (bountied) |
| Parameters | constituentId (user-controlled) |
| Call chain | `→ AmpsVault._requireHealthy() → VaultRolloutLib.deployBonded() → PoolRegistry.constituent()/poolConfig() → FeedRegistry.latestAnswer() → [idle ≥ deployThresholdUsd18] → VaultPlacementLib.place() [spoke bids] → PoolManager.unlock(ACTION_PLACE) → PoolManager.modifyLiquidity() → BountyPot.pay() → AmpsVault._afterPlacement()` |
| State modified | `ladderAt[spoke]` (+ bids), `_lastPlacementAt`, `LIVE_CELLS_SLOT`, checkpoint words |
| Value flow | Bonded collateral: vault claims → spoke bid positions; USDG bounty: BountyPot → keeper |
| Reentrancy guard | yes |

### `AmpsVault.checkpoint()` / `AmpsVault.touch()`

| Aspect | Detail |
|--------|--------|
| Visibility | external, `locked` |
| Caller | Anyone (unpaid upkeep) |
| Parameters | none |
| Call chain | `→ OracleGate.poke() → AmpsVault._requireHealthy() → [checkpoint only] AmpsVault._checkpoint() → VaultNavLib.totalAssetsUsd18() → LadderPositionValuer.valuePool() → PoolManager.extsload() → FeedRegistry.latestAnswer() → VaultNavLib.marketPrice() → AmpsHook.twapTick() → VaultNavLib.referencePrice()` |
| State modified | `_navPerShareX18`, `_pRefX18`, `_pMktX18`, `_checkpointTimestamp`, `_checkpointBlock` (`checkpoint` only); gate `_lastBlock/_lastTimestamp` |
| Value flow | none |
| Reentrancy guard | yes |

### `OracleGate.poke()` / `pokePool()` / `pokePools()` / `pokeConstituent()`

| Aspect | Detail |
|--------|--------|
| Visibility | external / public |
| Caller | Anyone (keeper, indexer) |
| Parameters | poolId / poolIds / constituentId (user-controlled) |
| Call chain | `→ OracleGate._stamp() → [pool variants] OracleGate._updateDivergence() → PoolRegistry.poolConfig() → AmpsHook.lastTruncatedTick() → GatePriceMath.fairTick() → [constituent] IStockToken.oraclePaused()/effectiveAt()/uiMultiplier() (bounded staticcalls)` |
| State modified | `_lastBlock`, `_lastTimestamp`, `_divergedSince[poolId]` |
| Value flow | none |
| Reentrancy guard | no (no external state-changing calls) |

### `FeedRegistry.refresh()` / `FeedRegistry.refreshMany()`

| Aspect | Detail |
|--------|--------|
| Visibility | public / external |
| Caller | Anyone |
| Parameters | token / tokens (user-controlled; must be configured) |
| Call chain | `→ FeedRegistry._probe() → IAggregatorV3.latestRoundData() (try, gas-capped) → OracleGate.sessionNow() (try) → FeedRegistry._latch()` |
| State modified | `_accepted[token]`, `_pending[token]` |
| Value flow | none |
| Reentrancy guard | no |

### `AmpsStaking.accrue()`

| Aspect | Detail |
|--------|--------|
| Visibility | external |
| Caller | Anyone |
| Parameters | none |
| Call chain | `→ AmpsStaking._accrue()` |
| State modified | `_pendingRewards`, `lastAccrualAt` |
| Value flow | none |
| Reentrancy guard | no |

---

## Role-Gated

Entry points restricted by a role modifier or an in-body `msg.sender` check. Grouped by role.

### `AmpsBonds` (bonds shell → vault)

#### `AmpsVault.depositBonded()`

| Aspect | Detail |
|--------|--------|
| Visibility | external, `locked`, `msg.sender == _bonds` |
| Caller | `AmpsBonds.bond()` |
| Parameters | marketId (protocol-derived), collateral (protocol-derived), from (user-controlled via bond), amount (user-controlled via bond) |
| Call chain | `→ AmpsVault._requireBondsHealthy() → AmpsVault._registerAsset() → AmpsVault._checkpoint() → PoolManager.unlock(ACTION_SETTLE) → VaultRedeemLib.settleFrom() → IERC20.safeTransferFrom(from → PoolManager) → PoolManager.settle() → PoolManager.mint(vault claim)` |
| State modified | `_assets`, `_assetIndex`, checkpoint words |
| Value flow | Collateral: bonder → PoolManager (vault claim) |
| Reentrancy guard | yes |

#### `AmpsVault.mintVesting()`

| Aspect | Detail |
|--------|--------|
| Visibility | external, `locked`, `msg.sender == _bonds`, `to == _bonds` |
| Caller | `AmpsBonds._issue()` |
| Parameters | to (protocol-derived), amount (protocol-derived) |
| Call chain | `→ AmpsVault._requireBondsHealthy() → Amps.mint(AmpsBonds)` |
| State modified | `Amps.totalSupply`, `Amps.balanceOf[AmpsBonds]` |
| Value flow | AMPS: minted to AmpsBonds |
| Reentrancy guard | yes |

### `PoolRegistry` (registry → vault)

#### `AmpsVault.initializePool()`

| Aspect | Detail |
|--------|--------|
| Visibility | external, `locked`, `msg.sender == _registry` |
| Caller | `PoolRegistry._openPool()` |
| Parameters | key (protocol-derived, validated by registry), sqrtPriceX96 (timelock-provided) |
| Call chain | `→ AmpsVault._requireHealthy() → VaultPlacementLib.alignedOpeningPrice() → PoolManager.initialize() → AmpsHook.beforeInitialize()/afterInitialize() → AmpsVault._registerAsset() ×2` |
| State modified | `POOL_KEYS_SLOT` (push), `_assets`, `_assetIndex`; hook `_cfg/_obs/_dyn/_arm` |
| Value flow | none |
| Reentrancy guard | yes |

#### `AmpsVault.withdrawRetiredBids()`

| Aspect | Detail |
|--------|--------|
| Visibility | external, `locked`, `msg.sender == _registry` |
| Caller | `PoolRegistry.withdrawRetiredBids()` |
| Parameters | constituentId (timelock-provided) |
| Call chain | `→ AmpsVault._requireHealthy() → VaultRolloutLib.withdrawRetiredBids() → PoolManager.unlock(ACTION_HARVEST) → PoolManager.modifyLiquidity() → PoolManager.mint(claims) → AmpsVault._afterPlacement()` |
| State modified | `ladderAt[spoke]` bids zeroed, `_lastPlacementAt`, `LIVE_CELLS_SLOT`, checkpoint words |
| Value flow | Counter asset: spoke bid positions → vault claims |
| Reentrancy guard | yes |

#### `AmpsBonds.addCollateral()` / `AmpsBonds.setMarketOpen()`

| Aspect | Detail |
|--------|--------|
| Visibility | external, `lock`, `_requireGovernance` (registry **or** timelock) |
| Caller | `PoolRegistry.addConstituent()` / `retireConstituent()` / `reinstateConstituent()`, or the timelock directly |
| Parameters | collateral, class, dBase/dMin/dMax, capBpsPerEpoch, open (protocol-derived from the proposal) |
| Call chain | `→ IERC20Metadata.decimals() → PoolRegistry.constituentIdOf()/constituent()` |
| State modified | `marketCount`, `marketIdOf`, `_markets[id]` |
| Value flow | none |
| Reentrancy guard | yes |

### Timelock **or** registry

#### `AmpsVault.place()`

| Aspect | Detail |
|--------|--------|
| Visibility | external, `locked`, `msg.sender == _TIMELOCK || msg.sender == _registry` (in body) |
| Caller | Genesis proposal / registry seeding |
| Parameters | poolId, above, amount (timelock-provided) |
| Call chain | `→ AmpsVault._requireHealthy() → VaultPlacementLib.place(strictBudget = true) → OracleGate.checkPlacement() → LadderPolicy.weights() → PoolManager.unlock(ACTION_PLACE) → PoolManager.modifyLiquidity() → AmpsHook.armSurge() → AmpsVault._afterPlacement()` |
| State modified | `ladderAt[poolId]`, `_lastPlacementAt`, `LIVE_CELLS_SLOT`, checkpoint words |
| Value flow | Inventory: vault claims/idle → positions |
| Reentrancy guard | yes |

### Vault (`onlyVault`)

#### `Amps.mint()` / `Amps.burn()` / `Amps.setVault()`

| Aspect | Detail |
|--------|--------|
| Visibility | external, `onlyVault` |
| Caller | `AmpsVault` (genesis, mintVesting, redemption, compound, migration) |
| Parameters | to/from, amount, newVault (protocol-derived) |
| Call chain | `→ ERC20._mint() / _burn()` |
| State modified | `totalSupply`, `balanceOf`, `vault` |
| Value flow | AMPS minted to / burned from the given account (no allowance) |
| Reentrancy guard | no |

#### `AmpsStaking.notifyReward()` / `AmpsStaking.setVault()`

| Aspect | Detail |
|--------|--------|
| Visibility | external, `onlyVault` |
| Caller | `VaultPlacementLib._split()` / `AmpsVault.emergencyMigrate()` |
| Parameters | amount / newVault (protocol-derived) |
| Call chain | `→ AmpsStaking._accrue() → IERC20.balanceOf(this)` |
| State modified | `_pendingRewards`, `_rewardRatePerSecond`, `streamEnd`, `totalNotified`, `lastAccrualAt` / `vault` |
| Value flow | none (AMPS already delivered) |
| Reentrancy guard | no |

#### `BountyPot.pay()` / `BountyPot.setVault()`

| Aspect | Detail |
|--------|--------|
| Visibility | external, `onlyVault` |
| Caller | `VaultPlacementLib.payBounty()` / `AmpsVault.emergencyMigrate()` |
| Parameters | to (keeper, protocol-relayed), workValueUsd18, gasCostUsd18 (protocol-derived) / newVault |
| Call chain | `→ BountyPot._quote() → IERC20.balanceOf(this) → BountyPot._chargeWindow() → IERC20.safeTransfer(to)` |
| State modified | `_spentWindowUsd18`, `_windowStart` / `vault` |
| Value flow | USDG: BountyPot → keeper |
| Reentrancy guard | no |

#### `AmpsBonds.setVault()`

| Aspect | Detail |
|--------|--------|
| Visibility | external, `lock`, `msg.sender == vault` |
| Caller | `AmpsVault.emergencyMigrate()` |
| Parameters | newVault (protocol-derived, the registered standby) |
| Call chain | none |
| State modified | `vault` |
| Value flow | none |
| Reentrancy guard | yes |

#### `AmpsHook.resetHighWater()` / `AmpsHook.armSurge()`

| Aspect | Detail |
|--------|--------|
| Visibility | external, `msg.sender == vault` |
| Caller | `VaultPlacementLib._resetHighWater()` / `_armSurge()` (try-wrapped) |
| Parameters | poolId, surgeBps, reason (protocol-derived) |
| Call chain | `→ TruncatedOracleLib.resetHighWater()` / `HookStateLib.pack*()` |
| State modified | `_obs[poolId].highWaterTick` / `_arm[poolId]`, `_dyn[poolId].gateAttemptedAt` |
| Value flow | none |
| Reentrancy guard | no |

### PoolManager (`onlyPoolManager`)

#### `AmpsHook.beforeInitialize()` / `afterInitialize()` / `beforeAddLiquidity()` / `beforeSwap()` / `afterSwap()`

| Aspect | Detail |
|--------|--------|
| Visibility | external, `onlyPoolManager` (OZ `BaseHook`) |
| Caller | Uniswap v4 `PoolManager` during `initialize` / `modifyLiquidity` / `swap` |
| Parameters | sender (protocol-derived: the vault or router), key, params, hookData (user-controlled through the router), delta (protocol-derived) |
| Call chain | `→ PoolRegistry.poolConfig() [init] · FeePolicy.quoteFee() (bounded staticcall) [beforeSwap] · PoolStateLib.slot0() → TruncatedOracleLib.write() → OracleGate.snapshotByPool()/closedHours() · FeePolicy.innerBandTicks()/outerRailTicks() · IStockToken.uiMultiplier() (all bounded staticcalls) [afterSwap]` |
| State modified | `_cfg`, `_obs`, `_dyn`, `_arm` per pool; transient `ROTATION_CREDIT_SLOT` |
| Value flow | none (fee returned via `OVERRIDE_FEE_FLAG`, charged by the PoolManager on the input currency into the vault's positions) |
| Reentrancy guard | no (PoolManager's own lock) |

#### `AmpsVault.unlockCallback()`

| Aspect | Detail |
|--------|--------|
| Visibility | external, `msg.sender == _POOL_MANAGER` |
| Caller | `PoolManager.unlock()` re-entering the vault |
| Parameters | data (protocol-derived: encoded by the vault itself); action read from transient `UNLOCK_ACTION` |
| Call chain | `→ VaultPlacementLib.unlockAction() [PLACE/COMPOUND/BURNBACK/HARVEST] or VaultRedeemLib.unlockAction() [SETTLE/PAYOUT/ABSORB/UNWIND] → PoolManager.modifyLiquidity()/sync()/settle()/mint()/burn()/take()` |
| State modified | `ladderAt`, `LIVE_CELLS_SLOT` (per action) |
| Value flow | Per action: settle in, pay out, absorb idle, add/remove liquidity |
| Reentrancy guard | inherits the outer `locked` frame; a callback with `UNLOCK_ACTION == 0` reverts `UnknownUnlockAction` |

### Creator

#### `AmpsVault.setCreator()`

| Aspect | Detail |
|--------|--------|
| Visibility | external, `locked`, `msg.sender == _creator` |
| Caller | The current creator |
| Parameters | newCreator (user-controlled) |
| Call chain | `→ AmpsVault._requireHealthy()` |
| State modified | `_creator` |
| Value flow | none |
| Reentrancy guard | yes |

### Guardian

#### `AmpsVault.emergencyMigrate()`

| Aspect | Detail |
|--------|--------|
| Visibility | external, `locked`, `msg.sender == _GUARDIAN` |
| Caller | Guardian Safe |
| Parameters | standby (must equal `_standbyVault`) |
| Call chain | `→ VaultNavLib.migrationPredicate() → IStockToken.isBlocked() / IERC20.transfer(self, 1) probes → PoolManager.unlock(ACTION_UNWIND) → VaultRedeemLib.unwind() → VaultNavLib.evacuate() → PoolManager.transfer(standby, claims) + IERC20.safeTransfer(standby) → Amps.setVault(standby) → AmpsBonds.setVault() → AmpsStaking.setVault() → BountyPot.setVault() → this.assetsUsd18Of() (try)` |
| State modified | `ladderAt` (all liquidity removed), `LIVE_CELLS_SLOT`; `vault` pointer in Amps/Bonds/Staking/Pot |
| Value flow | Every claim and idle balance incl. AMPS: vault → standby |
| Reentrancy guard | yes; not gate-gated by design |

#### `OracleGate.freezeConstituent()` / `OracleGate.freezeProtocol()`

| Aspect | Detail |
|--------|--------|
| Visibility | external, `onlyGuardian` |
| Caller | Guardian Safe |
| Parameters | constituentId, until (guardian-provided, ≤ 7 days ahead) |
| Call chain | none |
| State modified | `_constituentFreezeUntil[id]` / `_protocolFreezeUntil` |
| Value flow | none |
| Reentrancy guard | no |

### Guardian **or** Timelock

#### `OracleGate.unfreezeConstituent()` / `OracleGate.unfreezeProtocol()`

| Aspect | Detail |
|--------|--------|
| Visibility | external, `onlyGuardianOrTimelock` |
| Caller | Guardian Safe or timelock |
| Parameters | constituentId |
| Call chain | none |
| State modified | `_constituentFreezeUntil[id]` (delete) / `_protocolFreezeUntil = 0` |
| Value flow | none |
| Reentrancy guard | no |

---

## Admin-Only

Entry points restricted to the governance timelock (`onlyTimelock` / `_requireTimelock`). Every numeric setter is band-checked against `Constants` (`OutOfBand`), and every vault setter also passes `_requireHealthy()`.

| Contract | Function | Parameters | State Modified |
|----------|----------|------------|----------------|
| AmpsVault | `genesis()` | teamShares, polShares, teamVestingWallet, creator, seedTokens[], seedAmounts[] | mints S0; `_assets`; `_creator`; `_genesisTimestamp`; `_initialized`; `_wiringFrozen`; checkpoint words |
| AmpsVault | `setRedeemFeeBps()` | value ≤ 500 | `_redeemFeeBps` |
| AmpsVault | `setBurnBps()` | value ≤ 2500 | `_burnBps` |
| AmpsVault | `setStakerBps()` | value ≤ 5000 | `_stakerBps` |
| AmpsVault | `setRefUpRateBps()` | value ∈ [100, 5000] | `_refUpRateBps` |
| AmpsVault | `setRefDivergenceBps()` | value ∈ [100, 2000] | `_refDivergenceBps` |
| AmpsVault | `setTwapWindow()` | value ∈ [300, 7200] | `_twapWindow` |
| AmpsVault | `setLadderShape()` | tiltX18 ∈ [1.0, 1.5]e18, doublings ∈ [6, 14], seedHalvings, bondBidHalvings ∈ [2, 8] | `_ladderTiltX18`, `_ladderDoublings`, `_seedHalvings`, `_bondBidHalvings` |
| AmpsVault | `setRolloutParams()` | bpsPerDay ≤ 1000, floorBps ≤ 8000 | `_rolloutBpsPerDay`, `_entryFloorBps` |
| AmpsVault | `setSpokeSeedBps()` | value ∈ [10, 1000] | `_spokeSeedBps` |
| AmpsVault | `setDeployThresholdUsd18()` | value ∈ [10, 10000]e18 | `_deployThresholdUsd18` |
| AmpsVault | `setPolicyPointer()` | slot name, newPointer | one of slots 4-13 (`registry`/`bonds`/`staking`/`bountyPot` frozen after genesis; `marketReference`/`oracleGate`/`feedRegistry`/`positionValuer`/`ladderPolicy`/`rolloutPolicy` free) |
| AmpsVault | `setStandbyVault()` | standby | `_standbyVault` |
| AmpsBonds | `removeCollateral()` | collateral | `marketIdOf` (delete), `_markets[id].open = false` |
| AmpsBonds | `setDiscountParams()` | marketId, dBase/dMin/dMax ∈ [500, 2500] | `_markets[id].dBaseBps/dMinBps/dMaxBps` |
| AmpsBonds | `setCoefficients()` | marketId (0 = default), kWeight/kFill ≤ 2e18 | `defaultKWeightX18/defaultKFillX18` or `_markets[id].kWeightX18/kFillX18` |
| AmpsBonds | `setCapBpsPerEpoch()` | marketId, cap ≤ 200 | `_markets[id].capBpsPerEpoch` |
| AmpsBonds | `setEpochSeconds()` | value ∈ [1 h, 7 d] | `epochSeconds` |
| AmpsBonds | `setDailyCapBps()` | value ≤ 500 | `dailyCapBps` |
| AmpsBonds | `setVestSeconds()` | value ∈ [1 h, 7 d] | `vestSeconds` (future positions only) |
| AmpsBonds | `setMinAccretionBps()` | value ≤ 500 | `minAccretionBps` |
| AmpsBonds | `setPolicy()` | newPolicy | `policy` |
| AmpsStaking | `setRewardStreamSeconds()` | value ∈ [1 h, 7 d] | `rewardStreamSeconds` |
| BountyPot | `sweep()` | to, amountRaw | none (USDG: pot → to) |
| BountyPot | `setTipUsd18()` | value ≤ 5e18 | `tipUsd18` |
| BountyPot | `setChipBps()` | value ≤ 1000 | `chipBps` |
| BountyPot | `setChostUsd18()` | value ≤ 1000e18 | `chostUsd18` |
| BountyPot | `setGasCapMultiple()` | value ∈ [1, 10] | `gasCapMultiple` |
| BountyPot | `setDailyCeilingUsd18()` | value ≤ 100000e18 | `dailyCeilingUsd18` |
| AmpsHook | `setSellFeeBps()` | value ∈ [100, 600] | `_sellFee` |
| AmpsHook | `setBuyFeeBps()` | poolId, value ∈ [5, 100] entry / [1, 50] spoke | `_cfg[poolId].buyFeeBps` |
| AmpsHook | `setMaxTickMovePerBlock()` | poolId, value ∈ [10, 2000] | `_cfg[poolId].maxTickMovePerBlock` |
| AmpsHook | `setFeePolicy()` | newPolicy (must have code) | `_policy` |
| AmpsHook | `setGateCacheSeconds()` | value ∈ [1, 900] | `_gateCache` |
| FeedRegistry | `setStandardProxy()` / `setStandardProxies()` | aggregator(s), standard flag(s) | `isStandardProxy` |
| FeedRegistry | `setFeed()` | token, aggregator (Standard proxy), config | `_feeds[token]`, clears `_accepted`/`_pending`, probes and latches |
| FeedRegistry | `configureFeed()` | token, heartbeat ∈ [60, 86400], thresholdBps, min/max answer | `_feeds[token]` bounds |
| FeedRegistry | `setFreshnessMultiplier()` | session, multiplier ∈ [100, 2400] | `_freshness*` |
| FeedRegistry | `setConfirmSeconds()` | value ∈ [300, 86400] | `_confirmSeconds` |
| FeedRegistry | `setOracleGate()` | gate | `_oracleGate` |
| OracleGate | `setGraceSeconds()` / `setGapSeconds()` | value (ordered: gap < grace) | `_graceSeconds` / `_gapSeconds` |
| OracleGate | `setDivergenceBps()` / `setDivergenceSustainSeconds()` | value ≤ 2000 / ≤ 3600 | `_divergenceBps` / `_divergenceSustainSeconds` |
| OracleGate | `setCorporateActionWindow()` | value ≤ 86400 | `_corporateActionWindow` |
| OracleGate | `setRefDivergenceBps()` | value ∈ [100, 2000] | `_refDivergenceBps` |
| OracleGate | `setHSessionBps()` | session, bps ≤ 1000 | `_hSession*` |
| OracleGate | `setHolidayBitmap()` | year, bitmap[2] | `_holidayBitmap[year]` |
| OracleGate | `setDstTable()` | starts[], ends[] | `_dstStarts`, `_dstEnds` |
| OracleGate | `setFeedRegistry()` / `setRegistry()` / `setMarketReference()` | address | `_feedRegistry` / `_registry` / `_marketReference` |
| PoolRegistry | `registerEntryPool()` | key, counterDecimals, buyFeeBps, feed | `_hubPoolId`/`_wethPoolId`, `_pools`, `_keys`, `_poolCount`; opens the pool via the vault |
| PoolRegistry | `addConstituent()` | params (token, feed, weights, inclusion record, bond params) | `_constituents`, `_inclusion`, `_constituentIdOf`, `_poolIdOf`, `_pools`, `_keys`, counters; opens pool and bond market |
| PoolRegistry | `retireConstituent()` | constituentId | `status = RETIRED`, `rolloutWeightBps = 0`, `retiredAt`, `_activeCount`; closes the market |
| PoolRegistry | `reinstateConstituent()` | constituentId, rolloutWeightBps | `status = ACTIVE`, `rolloutWeightBps`, `_activeCount`; reopens the market |
| PoolRegistry | `reconfigureConstituent()` | constituentId, params (fee class, buy fee, target/rollout weight, feed, h_session override, CA freeze override) | the named fields of `_constituents[id]` / `_pools[poolId]` |
| PoolRegistry | `setIndexWeights()` | ids[], weightsBps[] (sum = 10,000, each within [floor_n, cap_n]) | `_constituents[id].targetWeightBps` |
| PoolRegistry | `withdrawRetiredBids()` | constituentId (must be RETIRED) | none locally; `AmpsVault.withdrawRetiredBids()` |

### Initialization

No proxies and no `initialize()` functions exist: every contract is deployed with immutables. The one-time setup entry points are `AmpsVault.genesis()` (admin-only, latched by `_initialized`) and the set-once pointer slots of `setPolicyPointer()` (frozen by `genesis`). Deployment order matters: the oracle-gate pointer must stay unset until the hub pool has 30 minutes of TWAP history, or `genesis()`/`initializePool()` refuse on their own `WATCHDOG` verdict (`docs/phase2-state-model.md` §9.1).
