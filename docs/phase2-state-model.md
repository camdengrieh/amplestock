# Phase 2 state model

The written half of task #8. The Solidity half is `contracts/src/types/{Types,Constants,Errors}.sol` and
`contracts/src/interfaces/*.sol`; this file says how the five Phase 2 contracts use them — storage layout, access
control, call graphs, and the exact arithmetic of NAV, the reference price and bond pricing.

Everything marked **Phase 3** is declared in the interfaces so that the immutable contracts are final in Phase 2,
but is not implemented until the hook exists.

## 0. Conventions

`A` is the NAV numerator in 18-decimal USD; `T` is `Amps.totalSupply()` in AMPS wei; `P_j` is asset `j`'s Chainlink
answer converted through `PriceLib`; `X18` is 1e18 fixed point; `usd8`/`usd18` are 8- and 18-decimal USD; bps are
basis points of `Constants.BPS` = 10,000.

Contracts and their mutability: `Amps`, `AmpsVault`, `AmpsBonds`, `AmpsStaking`, `PoolRegistry`, `BountyPot`,
`AmpsHook`, `AmpsQuoter` are **immutable bytecode**. `OracleGate`, `FeedRegistry`, `BondPolicy`, `LadderPolicy`,
`FeePolicy`, `RolloutPolicy` and the Phase 2 `IPositionValuer` are **pointer-upgradeable** behind the 7-day
timelock and hold no funds.

Deployment order and why the wiring is not all immutable: `Amps`'s constructor takes the vault and the vault's
constructor takes AMPS, so the AMPS address is CREATE2-mined first (`script/01_MineAmps`) and passed to the vault
as an *immutable* before `Amps` itself is deployed at that address. `PoolRegistry`, `AmpsBonds`, `AmpsStaking`,
`BountyPot` and `AmpsHook` each take the vault in *their* constructors, so the vault holds them as **set-once**
storage pointers, frozen by the `genesis()` latch.

## 1. Storage layouts

Packed words are given bit by bit; unannotated lines are one plain slot each. A mapping occupies one slot for its
base and is listed with the size of each value.

### 1.1 `AmpsVault`

Immutables (bytecode, no slot): `amps`, `poolManager`, `timelock`, `guardian`.

```
slot 0   uint128 navPerShareX18            [  0..127]   Checkpoint word 0
         uint128 pRefX18                   [128..255]
slot 1   uint128 pMktX18                   [  0..127]   Checkpoint word 1
         uint32  checkpointTimestamp       [128..159]
         uint32  checkpointBlock           [160..191]
         (free)                            [192..255]
slot 2   uint16  redeemFeeBps              [  0.. 15]   the whole governed numeric set, one SLOAD
         uint16  burnBps                   [ 16.. 31]
         uint16  stakerBps                 [ 32.. 47]
         uint16  refUpRateBps              [ 48.. 63]
         uint16  refDivergenceBps          [ 64.. 79]
         uint32  twapWindow                [ 80..111]
         uint64  ladderTiltX18             [112..175]   Phase 3
         uint8   ladderDoublings           [176..183]   Phase 3
         uint8   seedHalvings              [184..191]   Phase 3
         uint8   bondBidHalvings           [192..199]   Phase 3
         uint16  spokeSeedBps              [200..215]   Phase 3
         uint16  rolloutBpsPerDay          [216..231]   Phase 3
         uint16  entryFloorBps             [232..247]   Phase 3
slot 3   address creator                   [  0..159]
         uint32  genesisTimestamp          [160..191]
         bool    initialized               [192..199]   the genesis latch, one-way
         bool    wiringFrozen              [200..207]   set by genesis(); set-once pointers refuse afterwards
         (free)                            [208..255]
slot 4-7   address registry / bonds / staking / bountyPot        set-once, frozen by genesis()
slot 8     address marketReference                               set-once (mock in Phase 2), re-pointed once to
                                                                 AmpsHook under the 7-day timelock
slot 9-13  address oracleGate / feedRegistry / positionValuer /
           ladderPolicy / rolloutPolicy                          pointer-upgradeable (7 d); the last two are
                                                                 Phase 3, positionValuer is the zero-position stub
slot 14  address standbyVault                          14-day timelock
slot 15  uint128 rolloutMoved24h           [  0..127]  Phase 3
         uint32  rolloutWindowStart        [128..159]
slot 16  address[] assets                              enumeration for the NAV sum and for redeemProRata
slot 17  mapping(address => uint256) assetIndex        1-based; 0 means "not an asset"
slot 18  mapping(PoolId => PlacementRecord[]) ladder   Phase 3, 2 slots per bucket
slot 19  mapping(PoolId => uint32) lastPlacementAt     Phase 3, 60 s cooldown
```

Transient (EIP-1153), derived as `keccak256("amplestocks.vault.<name>")` and hard-coded:

```
REENTRANCY_LOCK   taken by every external function including redeemProRata (a lock is not a gate: nobody else
                  can hold it, and it is released in the same transaction)
UNLOCK_ACTION     the action discriminator the sole IUnlockCallback dispatches on
NAV_BEFORE        navPerShareX18 captured at entry, for the R1 post-condition (Phase 3)
```

### 1.2 `AmpsBonds`

Immutable: `amps`.

```
slot 0   address vault                     [  0..159]   set-once, then only reassigned by setVault (migration)
         uint32  epochSeconds              [160..191]
         uint16  dailyCapBps               [192..207]
         uint32  vestSeconds               [208..239]
         uint16  minAccretionBps           [240..255]
slot 1   address policy                    [  0..159]   IBondPolicy pointer (7 d)
         uint16  marketCount               [160..175]
         uint64  defaultKWeightX18         [176..239]
slot 2   address registry                  [  0..159]   set-once
         uint64  defaultKFillX18           [160..223]
slot 3   uint128 dailyIssued               [  0..127]   AMPS wei issued in the current rolling day
         uint32  dailyWindowStart          [128..159]
slot 4   mapping(uint16 => BondMarket) markets              3 slots each
slot 5   mapping(address => uint16) marketIdOf              1-based
slot 6   mapping(address => VestingPosition[]) positions    2 slots each

`oracleGate()` and `hSessionBps(session)` are pass-throughs (`vault.oracleGate()`, `gate.hSessionBps(...)`), not
cached copies: the gate pointer is 7-day upgradeable and the haircut table belongs to whoever owns the session
calendar, so each has exactly one home.
```

### 1.3 `AmpsStaking`

OZ `ERC20` + `ERC4626` occupy slots 0-4 (`_balances`, `_allowances`, `_totalSupply`, `_name`, `_symbol`); `asset`
and the decimals offset are immutable.

```
slot 5   address vault                     [  0..159]   reassigned only by setVault (migration)
         uint32  rewardStreamSeconds       [160..191]
         uint32  streamEnd                 [192..223]
         uint32  lastAccrualAt             [224..255]
slot 6   uint128 pendingRewards            [  0..127]   notified but not yet released
         uint128 rewardRatePerSecond       [128..255]
slot 7   uint256 totalNotified                          cumulative, for the realised-APR view
```

`totalAssets() = amps.balanceOf(address(this)) - pendingRewards`. That single line is what makes the
compound-sandwich worthless and I36 true: a notified tranche is invisible to the share price until the stream has
released it, and a donation to the contract raises `totalAssets` for everyone rather than for the donor.

### 1.4 `PoolRegistry`

```
slot 0   address vault                     [  0..159]   set-once
         uint16  constituentCount          [160..175]   ids ever issued; ids are never reused
         uint16  activeCount               [176..191]   the `n` the index cap and floor use
         uint16  poolCount                 [192..207]
slot 1   address hook                      [  0..159]   set-once
slot 2   PoolId  hubPoolId                               AMPS/USDG
slot 3   PoolId  wethPoolId                              AMPS/WETH
slot 4   mapping(PoolId => PoolConfig) pools             1 slot each
slot 5   mapping(PoolId => PoolKey) keys                 3 slots each
slot 6   mapping(uint16 => ConstituentConfig) consts     2 slots each
slot 7   mapping(uint16 => InclusionRecord) inclusion    1 slot each
slot 8   mapping(address => uint16) constituentIdOf
slot 9   mapping(uint16 => PoolId) poolIdOf
```

### 1.5 `OracleGate` and 1.6 `FeedRegistry` (both pointer-upgradeable)

```
slot 0   uint32  lastBlock                 [  0.. 31]   layer A
         uint32  lastTimestamp             [ 32.. 63]
         uint32  graceSeconds              [ 64.. 95]
         uint32  gapSeconds                [ 96..127]
         uint32  divergenceSustainSeconds  [128..159]   layer E
         uint32  corporateActionWindow     [160..191]   layer D
         uint16  divergenceBps             [192..207]
         uint32  protocolFreezeUntil       [208..239]   guardian, auto-expiring
slot 1   address feedRegistry              [  0..159]
         uint16  hSessionBps[4]            [160..223]
slot 2   address registry                                for constituent -> token/feed/pool lookups
slot 3   address marketReference                         for fairTick and observation coverage
slot 4   mapping(uint16 => uint32) constituentFreezeUntil
slot 5   mapping(PoolId => uint32) divergedSince         0 when inside the band
slot 6   mapping(uint16 => uint256[2]) holidayBitmap     one bitmap per calendar year
slot 7   uint32[] dstStarts
slot 8   uint32[] dstEnds

--- FeedRegistry ---
slot 0   address oracleGate                [  0..159]   for the current Session
         uint16  freshnessMultiplier[4]    [160..223]   hundredths; the CLOSED entry is unused
slot 1   mapping(address => FeedConfig) feeds           2 slots each
slot 2   mapping(address => Accepted) accepted          uint128 answerUsd8 | uint32 updatedAt | uint80 roundId
slot 3   mapping(address => Pending) pending            uint128 answerUsd8 | uint32 seenAt   | uint80 roundId

--- BountyPot (immutable: `token`, USDG) ---
slot 0   uint256 tipUsd18
slot 1   uint256 chostUsd18
slot 2   uint256 dailyCeilingUsd18
slot 3   uint128 spentWindowUsd18          [  0..127]
         uint32  windowStart               [128..159]
         uint16  chipBps                   [160..175]
         uint16  gasCapMultiple            [176..191]
slot 4   address vault                                   reassigned only by migration
```

## 2. Who may call what

`P` = permissionless, `U` = structurally ungated (no gate reference exists in the code path).

| Contract | Function | Caller | Delay |
|---|---|---|---|
| `Amps` | `mint`, `burn`, `setVault` | vault | — |
| `AmpsVault` | `redeemProRata` | **P, U** | — |
| `AmpsVault` | `checkpoint`, `touch` | **P** (unpaid) | — |
| `AmpsVault` | `depositBonded`, `mintVesting` | `AmpsBonds` | — |
| `AmpsVault` | `genesis` | timelock, once | 48 h |
| `AmpsVault` | `compound`, `rollout`, `deployBonded` (Phase 3) | **P**, paid from `BountyPot` | — |
| `AmpsVault` | `place` (Phase 3) | timelock, or registry during `addConstituent` | 7 d |
| `AmpsVault` | `initializePool` | registry | 7 d (via `addConstituent`) |
| `AmpsVault` | `setRedeemFeeBps` … `setSpokeSeedBps` | timelock | 48 h |
| `AmpsVault` | `setPolicyPointer` / `setStandbyVault` | timelock | 7 d / 14 d |
| `AmpsVault` | `setCreator` | current `creator` only | — |
| `AmpsVault` | `emergencyMigrate` | guardian, predicate-gated | none |
| `AmpsBonds` | `bond` | **P** | — |
| `AmpsBonds` | `claim`, `claimAll` | **P, U** (position owner) | — |
| `AmpsBonds` | `removeCollateral`, `setPolicy` | timelock | 7 d |
| `AmpsBonds` | `addCollateral` | timelock, **or `PoolRegistry`** | 7 d |
| `AmpsBonds` | `setMarketOpen` | timelock, **or `PoolRegistry`** | 48 h |
| `AmpsBonds` | every other `set*` (the `h_session` table lives in `OracleGate`) | timelock | 48 h |
| `AmpsBonds` | `setVault` | vault | — |
| `AmpsStaking` | `deposit`/`mint`/`withdraw`/`redeem`, `accrue` | **P** | — |
| `AmpsStaking` | `notifyReward`, `setVault` | vault | — |
| `AmpsStaking` | `setRewardStreamSeconds` | timelock | 48 h |
| `PoolRegistry` | every read | **P** | — |
| `PoolRegistry` | `addConstituent`, `retire`, `reinstate`, `reconfigure`, `setIndexWeights`, `registerEntryPool`, `withdrawRetiredBids` | timelock | 7 d |
| `OracleGate` | `poke`, `pokePool`, `pokePools`, `pokeConstituent` | **P** (unpaid) | — |
| `OracleGate` | `freeze*` (disable-only, auto-expiring) / `unfreeze*` | guardian | none |
| `OracleGate` | every `set*`, `unfreeze*` | timelock | 48 h |
| `FeedRegistry` | `setFeed` / `configureFeed`, `setFreshnessMultiplier` | timelock | 7 d / 48 h |
| `BountyPot` | `fund` | **P** | — |
| `BountyPot` | `pay` | vault | — |
| `BountyPot` | `sweep`, every `set*` | timelock | 48 h |
| `AmpsHook` | `resetHighWater`, `armSurge` | vault | — |
| `AmpsHook` | `setSellFeeBps`, `setBuyFeeBps`, `setMaxTickMovePerBlock` / `setFeePolicy` | timelock | 48 h / 7 d |

The guardian's entire power is: cancel a timelock operation, freeze one constituent or the protocol (disable-only,
expiring within 7 days), and trigger `emergencyMigrate` when the on-chain denylist predicate holds. It can move no
funds and can block neither `redeemProRata` nor `claim`.

### 2.1 Why `PoolRegistry` is an accepted caller on `AmpsBonds`

`AmpsBonds.addCollateral` and `setMarketOpen` accept two callers: the timelock, and the registry. The registry is not
a second governance root — every one of its own mutators is timelock-only behind the 7-day delay — so the delay and
the proposal review are identical either way. What the second caller buys is **atomicity**: `addConstituent` opens the
new name's bond market inside its own operation, and `retireConstituent` closes it inside its own, so "a new
constituent has a bond market" and "a retired constituent has no open bond market" (I37) hold at every block rather
than only after a second proposal lands. The alternative leaves a window in which the index and the bond board
disagree, and a window is exactly what an issuer halt exploits.

The shell reaches the registry through its own set-once `registry` pointer, and the registry reaches the shell through
`IAmpsVault.bonds()` — the vault is the single system of record for every protocol pointer, and §1.4 gives the
registry no slot for a second one. `test/unit/RegistryBondsWiring.t.sol` is the one place both real contracts are
deployed together, because every other suite mocks one side of that boundary and therefore answers the access-control
question for itself.

### 2.2 `checkBond(0)` and `isBondAllowed(0)`

`constituentId == 0` is a **valid, protocol-wide bond check**, not an unknown constituent. WETH and USDG are bond
collateral without being index constituents, so `AmpsBonds` hands the gate id 0 for every `ENTRY`-class market. On
that path the gate resolves no pool (`poolIdOf(0)` is `bytes32(0)`), reads no feed, runs no corporate-action probe
and measures no divergence: layers C, D and E have nothing to say about an id that names no token. What is left is
the guardian's protocol-wide freeze and the session haircut table, which is exactly what an entry market should
price. It must never revert with `UnknownConstituent` — the gate never looks id 0 up in the registry at all, so a
hostile, mis-pointed or absent registry cannot close an entry market either.

## 3. Call graphs

```
genesis (once)
  timelock -> vault.genesis(params)
    require(!initialized); require(teamShares + polShares == S0)
    Amps.mint(teamVestingWallet, TEAM_SHARES); Amps.mint(self, POL_SHARES)
    for each seed asset: transferFrom(msg.sender -> poolManager); poolManager.settle() -> ERC-6909 claim
    creator = params.creator; genesisTimestamp = now; initialized = wiringFrozen = true
    _checkpoint()                                     -> NAV/share == $1.00 by construction
    emit Genesis, NavCheckpoint, RefCheckpoint

bond
  bonder -> bonds.bond(marketId, amountIn, minAmpsOut, to)
    lock; gate.checkBond(constituentId) -> hSessionBps   (reverts only on CA freeze / guardian / DIVERGED)
    _rollEpoch(marketId); vault.checkpointData() -> navPerShareX18 + staleness check
    marketReference.twapTick30m(spokePool) -> m
    feedRegistry.latestAnswer(collateral)  -> P_i (stale is allowed; it feeds q_floor with the haircut)
    policy.quote(input) -> ampsOut, q, discount;  require(q <= qFloor recomputed in the shell)
    clamp ampsOut to per-epoch then global daily capacity
    require(ampsOut >= minAmpsOut)
    vault.depositBonded(marketId, collateral, msg.sender, amountIn)
        vault: lock; poolManager.unlock(SETTLE) -> transferFrom(bonder -> poolManager); settle -> ERC-6909 claim
    vault.mintVesting(address(bonds), ampsOut)         -> Amps.mint; T rises immediately (I30)
    positions[to].push(VestingPosition{principal: ampsOut, start: now, vestSeconds, marketId})
    emit Bond; sweepClean assert

claim  (structurally ungated)
  owner -> bonds.claim(positionId, to)
    lock; p = positions[owner][positionId]
    vested   = p.principal * min(now - p.start, p.vestSeconds) / p.vestSeconds     (floor)
    amount   = vested - p.claimed;  p.claimed += amount
    Amps.transfer(to, amount); emit Claim
    -- no gate read, no guardian read, no market lookup, no policy call

redeem  (structurally ungated)
  holder -> vault.redeemProRata(shares, to)
    lock; T = Amps.totalSupply()                       read once, before the burn
    Amps.burn(msg.sender, shares)                      effects before interactions
    for each pool (Phase 3): remove floor(L_p * shares / T) from every PlacementRecord
    for each asset j != AMPS: pay floor(b_j * shares / T) * (BPS - redeemFeeBps) / BPS
    burn the AMPS released from the vault's own inventory   -> T falls by MORE than `shares`
    emit Redeem, Burn("redeemInventory"); sweepClean assert
    -- no _requireHealthy, no gate, no oracle, no guardian, no pause

checkpoint  (permissionless, unpaid)
  anyone -> vault.checkpoint()
    gate.poke()                                        stamps layer A
    A = SUM_j P_j * (claim_j + idle_j + valuer.valuePool(pool_j, sqrtP_ref))
    navPerShareX18 = (A + 1) * 1e18 / (T + VIRTUAL_SHARES)
    pMkt = PriceLib(hub TWAP, USDG answer);  pRef = max(nav, rateLimited(pMkt))
    write Checkpoint; emit NavCheckpoint, RefCheckpoint

notifyReward  (inside compound, Phase 3)
  vault.compound(poolId)
    -> Amps.transfer(staking, stakerCut); staking.notifyReward(stakerCut)
         accrue(); pending += amount; streamEnd = now + rewardStreamSeconds
         rewardRatePerSecond = pending / rewardStreamSeconds

lifecycle  (every action leaves NAV/share unchanged: I37)
  timelock -> registry.addConstituent(params)
    checks inclusion inputs, MAX_CONSTITUENTS, weight in [floor_n, cap_n], feed is a Standard proxy
    -> vault.initializePool(key, sqrtPriceX96)   (AmpsHook.beforeInitialize requires sender == vault)
    records ConstituentConfig + InclusionRecord; optionally bonds.addCollateral(...)
    the seed ask arrives with the next rollout (Phase 3), not inside this call
  timelock -> registry.retireConstituent(id)
    bonds.setMarketOpen(marketId, false); rolloutWeightBps = 0; status = RETIRED
    -> vault returns unfilled ask buckets to the entry pools (Phase 3); bids stay as an exit market
  timelock -> registry.reinstateConstituent(id, weight) | reconfigureConstituent(id, params)

guardian freeze
  guardian -> gate.freezeConstituent(id, until <= now + 7 d)   (or freezeProtocol)
    placements, compound and bonds refuse; swaps are only re-priced; redemption and claim untouched
    expires with no further action; guardian or timelock may clear it early
```

## 4. NAV, exactly as implemented

```
A   = SUM_j P_j * ( erc6909Claim_j + idleErc20_j + valuer.valuePool(pool_j, sqrtPriceRef_j) )   - liabilities
      j ranges over the registered constituents, WETH and USDG.
      Every AMPS leg is valued at ZERO (I5). The BountyPot balance is excluded (I21).
T   = Amps.totalSupply()                       fully diluted; protocol inventory counts like any share (I6)
navPerShareX18 = FullMath.mulDiv(A + 1, 1e18, T + VIRTUAL_SHARES)      VIRTUAL_SHARES = 1e3 wei, rounds DOWN
```

`A` is 18-decimal USD and `T` is AMPS wei, so the `1e18` is the unit conversion. Each `P_j * amount_j` term goes
through `PriceLib.counterValueUsd18`, which rounds **down**, so `A` is never overstated. Positions are decomposed
at the **reference-implied** sqrt price `sqrtPrice(P_ref / P_j)` from the *previous* checkpoint, never at `slot0` —
which is what I7 tests by forcing `slot0` +/-50% and asserting `A` moves by at most dust. Phase 2 ships
`ZeroPositionValuer`, which returns `(0, 0)` for every pool, so `A` is exactly the idle ERC-20 balances plus the
ERC-6909 claims; Phase 3 re-points `positionValuer` under the 7-day timelock with no storage or formula change.

## 5. `P_mkt` and `P_ref`

```
pMktX18 = PriceLib.sqrtPriceX96ToAmpsPriceUsd18(
              PriceLib.tickToSqrtPriceX96( marketReference.twapTick(hubPoolId, twapWindow) ),
              feedRegistry.priceUsd8(USDG), 6 )                                     rounds DOWN

elapsed = now - checkpointTimestamp
cap     = pRefPrev + FullMath.mulDiv(pRefPrev, refUpRateBps * elapsed, ONE_HOUR * BPS)   rounds DOWN
cand    = pMkt <= pRefPrev ? pMkt                       // down: immediate, no limit
                           : min(pMkt, cap)             // up:   at most refUpRateBps per hour
pRefX18 = max(navPerShareX18, cand)                     // NAV floor, always (I24)
```

Three overrides are checked before `cand` is used at all, and each sets `pRef = navPerShareX18`:
`GateState.REF_DIVERGED` (the hub TWAP and `AMPS/WETH x ETH/USD` disagree by more than `refDivergenceBps`, 500 bp);
`GateState.WATCHDOG` (no observation or block for longer than `graceSeconds`); and observation coverage below
`twapWindow` on a young pool, which additionally records `pMkt` as 0.

`premium = pRef / navPerShare - 1` is disclosure only. `P_mkt` is what the hook's fee wall, the bond `m` and the
quoter read; `P_ref` is what NAV valuation and (Phase 3) placement anchors read. An attacker who moves one spoke
moves neither: `P_mkt` comes from the hub, and both are truncated TWAPs.

## 6. Bond pricing, with rounding directions

```
m         = AMPS wei per 1e18 of collateral, from the spoke's 30-minute truncated TWAP      DOWN
deficit   = clamp( (w_target - w_current) * 1e18 / w_target, 0, 1e18 )                      DOWN
fill      = clamp( issuedThisEpoch * 1e18 / capacity, 0, 1e18 )                             UP
d         = clamp( dBase + kWeight*deficit/1e18 - kFill*fill/1e18, dMin, dMax )              DOWN
qMarket   = m * BPS / (BPS - d)                                                             DOWN
qFloorNum = collateralPriceUsd18 * (BPS - hSessionBps) / BPS                                DOWN
qFloorDen = navPerShareX18 * (BPS + minAccretionBps) / BPS                                  UP
qFloor    = qFloorNum * 1e18 / qFloorDen                                                    DOWN
q         = min(qMarket, qFloor)
ampsOut   = amountIn18 * q / 1e18                                                           DOWN
```

Every direction favours the protocol, which is what makes I27 (`NAV/share after a bond >= NAV/share before`) exact
rather than up-to-dust. `amountIn18` is the raw deposit normalised to 18 decimals, so USDG's 6 decimals are scaled
up once, in the shell, before the policy sees anything.

`w_current` is `IPoolRegistry.currentWeightBps(constituentId)`, read through a bounded `try` whose every failure —
a revert, an out-of-range answer, a registry deployed before the view existed — prices `deficit == 0`. **Phase 2's
registry answers the target weight**, so the deficit is exactly zero on every market: the realised weight is the
vault's valuation of that spoke's position divided by the whole index, and Phase 2 ships `ZeroPositionValuer`, so
there is no position to value and any other answer would be invented. Zero is also the protocol-favourable reading —
a smaller deficit is a smaller discount and less AMPS issued for the same collateral — so an input that is unknowable
in Phase 2 cannot dilute anyone. Phase 3 sources the numerator from the vault's valuation with no ABI change and no
new bond bytecode. A registry that cannot answer must never be able to close a bond market, which is why the read is
a bounded probe and not a plain call.

`qFloor` is computed from the **last Chainlink answer**, never from the pool: that caps what TWAP manipulation can
buy (the best a spoke-dumper can do is remove their own discount) and bounds weekend-gap exposure to `hSessionBps`
(0 / 50 / 150 / 300 bp) on the bonded amount, which is why markets stay open 24/7 through stale feeds and closed
sessions instead of shutting. Capacity is applied *after* pricing: `ampsOut` is clamped to
`capBpsPerEpoch * T / BPS - issuedThisEpoch`, then to `dailyCapBps * T / BPS - dailyIssued`; a clamp to zero closes
the market until the epoch rolls and does not revert the quote view. The shell recomputes `qFloor` itself and
rejects any `q` above it with `AccretionFloorViolated`, so a hostile or buggy `BondPolicy` pointer can refuse to
price but can never issue a dilutive bond.

## 7. The structurally ungated surface

Exactly two external state-changing functions are exempt from `_requireHealthy`:

| Function | Why |
|---|---|
| `AmpsVault.redeemProRata(shares, to)` | the redemption floor; must survive every feed dead, the watchdog tripped, the guardian frozen and the timelock hostile |
| `AmpsBonds.claim` / `claimAll` | a vest already sold; must complete through collateral removal, market pause, policy swap and guardian freeze (I38) |

"Ungated" is a property of the *code path*, not of a flag. Neither path may contain a reference to `oracleGate`,
`guardian`, `standbyVault`, a freeze timestamp, a pause bool, `feedRegistry`, or any price. Both still take the
transient reentrancy lock — a lock nobody else can hold, released in the same transaction, is not a gate.

### 7.1 The vault has two gate policies, not one

`AmpsVault` reads the gate through one helper with two policies, and the difference is load-bearing:

| Policy | Taken by | Refuses | Passes |
|---|---|---|---|
| `_requireHealthy` (management) | every mutating selector except the three classified exemptions and the two below | `DEGRADED`, `DIVERGED`, `SCHEDULED_FREEZE`, `WATCHDOG` | `GREEN`, `REF_DIVERGED` |
| `_requireBondsHealthy` (bonds) | `depositBonded`, `mintVesting` | `DIVERGED`, `SCHEDULED_FREEZE` | `GREEN`, `DEGRADED`, `REF_DIVERGED`, `WATCHDOG` |

The bond policy is the 24/7 bond decision restated inside the vault. A stale feed or a closed session must widen
`h_session`, not close a market, so applying the management policy to the two bond entry points would be *stricter
than the design* rather than safer: it would shut every bond market every weekend. It mirrors `IOracleGate.checkBond`
exactly, which makes the vault defence in depth behind the shell — a buggy or replaced `AmpsBonds` still cannot
deposit or mint through a market the gate has closed — rather than a second, disagreeing gate.

Two further deliberate deviations, both asserted in `GuardSymmetry.t.sol`:

* **`emergencyMigrate` is not `_requireHealthy`-gated.** It is gated by the on-chain denylist predicate, which is
  strictly narrower. The incident it exists for — an issuer denylisting the vault while pausing its oracle — is
  precisely a state in which `_requireHealthy` refuses, so gating it would brick the evacuation path of an immutable
  contract. `unlockCallback` is the third exemption, guarded by caller identity (`NotPoolManager`).
* **A gate pointer that *reverts* is read as absent, not as a refusal.** The gate is the one pointer that can refuse
  every governance call; if a broken one refused, nobody could call `setPolicyPointer` to replace it and a contract
  holding no funds would have bricked the protocol. Failing open grants an attacker nothing they would not already
  have with a `GREEN` gate.

**How the I14 enumeration test verifies it** (`test/unit/GuardSymmetry.t.sol`):

1. *Enumerate.* The test holds one classification entry per external mutating selector of `AmpsVault` (the
   `_buildSelectorTable` list, three buckets: `MANAGEMENT`, `BONDS`, `EXEMPT`) and of `AmpsBonds` (the
   `selector-gate:AmpsBonds` block, three buckets: gated, exempt, governed), plus an expected count for each. The CI
   step `scripts/selector-gate.py` reads `out/<Contract>.sol/<Contract>.json`, lists the ABI's non-`view`/non-`pure`
   selectors and fails on any name missing from those tables, so adding a function without deciding how it is
   guarded cannot merge. (`ffi` is off and `fs_permissions` does not cover `out*`, so this comparison lives in the
   CI script, not in Solidity.)
2. *Assert refusal.* With the gate forced to each of `DEGRADED`, `DIVERGED`, `SCHEDULED_FREEZE` and `WATCHDOG`,
   every management-gated selector must revert with `GateNotHealthy` or `ConstituentFrozen`, and the two
   bond-gated ones must refuse under `DIVERGED` and `SCHEDULED_FREEZE` and succeed under the other two.
3. *Assert the exemptions succeed.* With every feed reverting, the watchdog tripped, the guardian freeze active and
   the timelock replaced by a contract that reverts on any call, `redeemProRata` and `claim` must succeed, and the
   redemption must pay exactly `(1 - redeemFeeBps/BPS) * shares / T` of every non-AMPS balance (I23).
4. *Assert no read happened.* `vm.record()` around each exempt call, then `vm.accesses()` on `oracleGate`,
   `feedRegistry` and `registry` must all be empty — the storage-level proof that the path *cannot* be gated, not
   merely that it is not gated today.
5. *Assert at the bytecode level.* `AmpsVault`'s deployed code must contain no `PUSH` of the gate, feed-registry or
   guardian slot in any basic block reachable from the `redeemProRata` selector, and exactly one `Amps.mint` call
   site reachable from a selector other than `genesis` — `mintVesting` (I10).

## 8. Migration surface

* **Standby vault.** `setStandbyVault(address)` — timelock, 14 days. Registering it moves nothing.
* **Predicate.** `emergencyMigrate(standby)` is guardian-callable with no delay, and reverts with
  `MigrationPredicateNotMet` unless, checked on-chain at call time: `IStockToken(token).isBlocked(vault) == true`
  for at least one registered constituent, **or** a bounded 1-wei self-transfer probe reverts for at least two
  constituents. Every probe is a `staticcall`/`call` capped at `Constants.STOCK_TOKEN_PROBE_GAS`.
* **What moves.** Per pool, inside one `unlock`: remove liquidity -> `take` as ERC-6909 claims -> transfer the
  claims PoolManager-internally to the standby vault -> the standby re-adds at the same ticks. The R1 bleed cap is
  relaxed from 2 bp to `MIGRATION_BLEED_BPS_MAX` (50 bp) only inside this call.
* **What follows in the same transaction.** `Amps.setVault`, `AmpsBonds.setVault`, `AmpsStaking.setVault` and
  `BountyPot`'s vault pointer. All four are `onlyVault`, which is why they can be handed on atomically and why
  nobody else can hand them on at all.
* **What does not move.** Vesting positions stay in `AmpsBonds`, whose bytecode is immutable and whose `claim`
  never reads the vault, so a migration cannot strand a vest.

## 9. What Phase 2 stubs, and what the implementation agents must not do

* `IPositionValuer` is stubbed by a zero-position valuer. Do not add a position term to `A` by any other route.
* `IMarketReference` is stubbed by a mock in `test/mocks/`. Do not import `AmpsHook`; it does not exist yet.
* No `poolManager.swap()` and no `donate()` anywhere in `src/`, in any phase.
* Production code must not import `StateLibrary` or `TransientStateLibrary`: both are MIT front doors onto
  BUSL-1.1 files and the licence gate fails the build. Read pool state through `IExtsload`/`IExttload` with our own
  slot arithmetic.
* Every governed setter throws `OutOfBand(bytes32 parameter, value, min, max)` with the parameter's name as a
  short string, and reads its bound from `Constants`. Do not restate a bound as a literal.
* Every external function asserts `sweepClean` at exit: the ERC-20 balance of every registered asset on the vault,
  the hook and `AmpsBonds` must be zero.

## 10. How Phase 2 actually builds: libraries, lenses and per-path compilation

Three facts about the build are not visible from the source alone and every deployment script depends on all three.

### 10.1 `VaultNavLib` is a **linked** library, not an inlined one

`AmpsVault` implements the whole of `IAmpsVault` and does not fit EIP-170 with the read side inlined: 45,818 B as
one contract under the project-wide `optimizer_runs = 1_000_000`, and still 26,509 B at `runs = 1`. The read side —
`A`, `P_mkt`, the reference overrides, the inventory disclosure and the migration predicate — therefore lives in
`src/vault/VaultNavLib.sol`, which has `public`/`external` functions and is consequently a **deployed** library
reached by `DELEGATECALL`, not an internal one folded into the caller.

What that means in practice:

* **Deploy scripts must deploy `VaultNavLib` first and link `AmpsVault` against it.** An unlinked `AmpsVault`
  artefact carries `__$...$__` placeholders in its bytecode and cannot be deployed. `forge script` links
  automatically from the artefact's link references; a raw `create` from bytecode does not, and will deploy a
  contract whose every NAV read reverts.
* **The library address is fixed at link time and is not governable.** There is no pointer to re-point and no
  storage in the library, so it is part of `AmpsVault` for every governance and audit purpose: a change to
  `VaultNavLib` is a change to the vault, and a vault migration.
* **Splitting the reads out, not the writes, is deliberate.** `redeemProRata` stays entirely inside `AmpsVault` and
  makes no `DELEGATECALL` at all, which is what keeps §7's structural argument true: the ungated path cannot reach
  a gate, a feed or a price even through a library.

### 10.2 Two contracts are compiled under per-path restrictions

`foundry.toml` carries `[[profile.default.compilation_restrictions]]` entries for `src/vault/*` and `src/bonds/*`,
both at `optimizer_runs = 200` with `via_ir = true`, while everything else stays on the project-wide legacy
pipeline at `optimizer_runs = 1_000_000`.

| Path | Why |
|---|---|
| `src/vault/*` | Even with the read side in `VaultNavLib`, the vault is 26,509 B at `runs = 1` on the legacy pipeline. The IR pipeline at 200 runs brings it to ~23.8 kB, inside EIP-170 with margin. |
| `src/bonds/*` | `AmpsBonds` carries the whole bond call graph plus the collateral registry and twelve governed setters; at 1,000,000 runs solc inlines it past EIP-170. At 200 runs through IR it fits with room to spare. |

The restriction is **per path, not per profile**, precisely so that nothing else moves: every other contract's
codegen — and therefore every gas baseline in `test/gas/` — is byte-identical to what it was before either
restriction was added. Widening the compiler profile globally instead would silently re-price every measurement in
the gas suite, which is why an addition that pushes `AmpsVault` over the limit must move logic into `VaultNavLib`
rather than relax the profile. The vault's remaining margin is small (roughly 0.8 kB) and should be treated as a
budget.

### 10.3 The read-only lens contracts

Two contracts exist only to hold reads that would otherwise not fit inside EIP-170:

* **`PoolRegistryLens`** — the active-constituent list, the index weight vector, and the cap/floor rule evaluated at
  an arbitrary `n`. All of it is derived from `IPoolRegistry`'s getters.
* **`AmpsBondsLens`** — position enumeration and the whole-board quote, both pure aggregations of `IAmpsBonds`'s
  views.

Neither holds storage, neither is referenced by any other contract, and neither is governed or upgradeable: they are
stateless views over the contract they name, redeployable at will, and nothing on any protocol path reads them.
`PoolRegistry.wiring()` returns its four immutables as one tuple for the same reason — four separate getters cost
bytecode the registry does not have.
