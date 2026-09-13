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

Contracts and their mutability: `Amps`, `AmpsVault`, `AmpsBonds`, `PoolRegistry`, `BountyPot`, `AmpsHook`,
`AmpsQuoter` and `AmpsRouter` are **immutable bytecode**. (`AmpsStaking` was on that list until plan revision 6
removed staking from the protocol; `AmpsRouter` is what revision 6 added in its place, and it holds no funds
between transactions and has no owner.) `OracleGate`, `FeedRegistry`, `BondPolicy`, `LadderPolicy`,
`FeePolicy`, `RolloutPolicy` and the Phase 2 `IPositionValuer` are **pointer-upgradeable** behind the 7-day
timelock and hold no funds.

Deployment order and why the wiring is not all immutable: `Amps`'s constructor takes the vault and the vault's
constructor takes AMPS, so the AMPS address is CREATE2-mined first (`script/01_MineAmps`) and passed to the vault
as an *immutable* before `Amps` itself is deployed at that address. `PoolRegistry`, `AmpsBonds`, `BountyPot` and
`AmpsHook` each take the vault in *their* constructors, so the vault holds them as **set-once** storage pointers,
frozen by the `genesisPlace()` latch. `AmpsRouter` names no vault at all — it reads the registry and the PoolManager
and nothing else — so it is deployed independently and reached only by `AmpsHook.setRouter`.

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
         (reserved)                        [ 16.. 47]   burnBps and stakerBps lived here until revision 6;
                                                        declared rather than implied so the layout is stable
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
         bool    wiringFrozen              [200..207]   set by genesisPlace(); set-once pointers refuse afterwards
         bool    genesisMinted             [208..215]   set by genesisMint; `initialized` stays false until
                                                        genesisPlace, so this is the whole of the window the
                                                        auction runs in
         (free)                            [216..255]
slot 4,5,7 address registry / bonds / bountyPot                  set-once, frozen by genesisPlace()
slot 6     (reserved)                                            the xAMPS staking vault lived here until
                                                                 revision 6; kept as a hole so slots 7+ do not
                                                                 move under a standby vault written against
                                                                 this layout
slot 8     address marketReference                               pointer-upgradeable (7 d) through setPolicyPointer,
                                                                 exactly like slots 9-13: a mock in Phase 2, pointed
                                                                 at AmpsHook in Phase 3, and re-pointable again after
                                                                 that (it is not latched by genesisPlace())
slot 9-13  address oracleGate / feedRegistry / positionValuer /
           ladderPolicy / rolloutPolicy                          pointer-upgradeable (7 d); the last two are
                                                                 Phase 3, positionValuer is the zero-position stub
slot 14  address standbyVault                          14-day timelock
slot 15  uint128 rolloutMoved24h           [  0..127]  Phase 3; decays linearly to zero over ONE_DAY
         uint32  rolloutWindowStart        [128..159]   re-stamped on every charge (rolling, not tumbling)
slot 16  address[] assets                              enumeration for the NAV sum and for redeemProRata
slot 17  mapping(address => uint256) assetIndex        1-based; 0 means "not an asset"
slot 18  mapping(PoolId => PlacementRecord[]) ladder   Phase 3, 2 slots per bucket
slot 19  mapping(PoolId => uint32) lastPlacementAt     Phase 3, 60 s cooldown
slot 20  uint256 deployThresholdUsd18                  the bonded-deployment dust guard (§10 ruling 15)
slot 21  bool    navUnconfirmed            [  0..  7]  §12 ruling AS: any priced asset !fresh || unconfirmed
         uint248 reserved filler           [  8..255]  declared, not implied — see below
slot 22  address genesis                               the AmpsGenesis adapter. Set once through
                                                       setPolicyPointer, before genesisMint, and frozen by
                                                       genesisPlace with the other set-once pointers
```

**Slot 21's filler is declared, not implied.** Solidity packs from the low end, so without it the 20-byte
`genesis` pointer would sit beside `navUnconfirmed` in slot 21 while `VaultNavLib.setPointer` — which writes
pointers *by slot number* — wrote slot 22. The getter would have read `address(0)` for ever, and `genesisMint`
would have refused every proposal for a mismatch it could not explain. `VaultLayout.t.sol` pins slot 21 as the
flag alone, slot 22 as the adapter, and 23 onwards as empty.

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

### 1.3 (removed) `AmpsStaking`

Plan revision 6 removed staking from the protocol. There is no xAMPS share token, no reward stream, no
`stakerBps` and no `notifyReward`, and the vault's slot 6 and the `[16..47]` band of slot 2 are reserved holes
where they used to live. The AMPS side of every fee is **burned** at `compound()` after the creator's slice
(`docs/phase3-state-model.md` §3.6), and the counter-asset side stays as bids in the pool that earned it. Nothing
is distributed to anybody, so there is nothing for a share price to accrue to.

The invariant that used to live here (I36: `totalAssets` never decreasing except by withdrawals, rewards released
never exceeding rewards notified, only the vault notifying, `stakerBps <= 5000`) is **deleted** rather than
restated. What made the compound-sandwich worthless was the stream; what makes it worthless now is that there is
no stream and no claim on one.

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
| `AmpsVault` | `genesisMint` | timelock, once | 48 h |
| `AmpsVault` | `genesisPlace` | the `genesis` adapter **or** timelock, once | 48 h (timelock form) |
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
| `AmpsRouter` | `buy`, `sell`, `rotate` | **P** | — |
| `AmpsRouter` | *(nothing else)* — no owner, no setter, no pause, no fee | — | — |
| `AmpsHook` | `setRouter` | timelock | 7 d |
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
| `AmpsHook` | `setAmpsFeeBps`, `setBuyFeeBps`, `setMaxTickMovePerBlock` / `setFeePolicy` | timelock | 48 h / 7 d |

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
genesisMint (once)                                        -- docs/genesis-cca.md is the whole mechanism
  timelock -> vault.genesisMint(params)
    require(!genesisMinted); require(team + auction + pol == S0 and each == its constant)
    require(genesis pointer set, equals params.genesis, holds code)
    Amps.mint(teamVestingWallet, TEAM_SHARES); Amps.mint(genesis, AUCTION_SHARES); Amps.mint(self, POL_SHARES)
    creator = params.creator; genesisMinted = true          -- A is still 0, initialized still false
    emit GenesisMinted

genesisPlace (once)  -- AmpsGenesis.settle(), or the timelock on the founders'-seed fallback
  require(genesisMinted); require(!initialized); require(p0X18 != 0)
    for each registry asset and each seed token: _registerAsset
    for each token: transferFrom(msg.sender -> poolManager); settle() -> ERC-6909 claim
    if unsoldAmps: AMPS.transferFrom(msg.sender -> self)     -- inventory, never in A
    genesisTimestamp = now; initialized = wiringFrozen = true
    _checkpoint()                                            -> NAV/share == raised / S0 (fully diluted)
    pRef = max(p0X18, NAV)
    emit RefCheckpoint, Genesis, NavCheckpoint

bond
  bonder -> bonds.bond(marketId, amountIn, minAmpsOut, to)
    lock; gate.checkBond(constituentId) -> hSessionBps   (reverts only on CA freeze / guardian / DIVERGED)
    _rollEpoch(marketId); _rollDay()
    vault.depositBonded(marketId, collateral, msg.sender, amountIn)      -- the deposit comes BEFORE the price
        vault: lock; _requireBondsHealthy (7.1); _registerAsset(collateral)
               _checkpoint()                        <- same-block, PRE-deposit NAV, under the bond gate policy
               poolManager.unlock(SETTLE) -> transferFrom(bonder -> poolManager); settle -> ERC-6909 claim
    vault.checkpointData() -> navPerShareX18 (this block's) + staleness check (always 0 here; it guards quote())
    marketReference.twapTick30m(spokePool) -> m
    feedRegistry.latestAnswer(collateral)  -> P_i (stale is allowed; it feeds q_floor with the haircut)
    policy.quote(input) -> q, discount;  require(q <= qFloor recomputed in the shell)
    ampsOut = amountIn18 * q / 1e18   recomputed in the shell; the policy's own ampsOut is never minted (audit fix 15)
    haircut = max(hSessionBps, hSession[CLOSED]) when the collateral answer is not fresh or unconfirmed (audit fix 9)
    clamp ampsOut to per-epoch then global daily capacity   (the AMPS out is clamped; the deposit is not)
    require(ampsOut >= minAmpsOut)
    positions[to].push(VestingPosition{principal: ampsOut, start: now, vestSeconds, marketId})
    vault.mintVesting(address(bonds), ampsOut)         -> Amps.mint; T rises immediately (I30)
    emit Bond; any collateral dust on the shell is forwarded to the vault best-effort (never asserted; audit fix 1)
    -- the deposit is an interaction ahead of the shell's effects; both locks are held across it and any revert
       below it unwinds the settle, so the order buys the fresh NAV without a reentrancy surface

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
      -- redeemFeeBps: 250 bp at launch (revision 6 raised it from 100), governed at 48 h, hard cap 500
    burn the AMPS released from the vault's own inventory   -> T falls by MORE than `shares`
    payout (VaultRedeemLib.payout): try the ERC-20 unlock under gasleft() - REDEEM_PAYOUT_RESERVE_GAS, per asset
      take{gas: 4 x STOCK_TOKEN_PROBE_GAS} -> claim on refusal; on ANY failure (a hostile transfer opening a
      foreign delta included) a second claims-only unlock pays every claim part; idle ERC-20 parts after the
      unlock, best-effort and capped (an unmovable idle wei is not paid)
    emit Redeem, Burn("redeemInventory"); sweepClean (per token: sync + capped transfer outside any unlock, then
                                                          a try-wrapped per-token unlock for settle + mint;
                                                          `SweepResidue` instead of a revert)
    -- no gate read, no oracle, no guardian, no pause; a paused or denylisting constituent is paid
       as an ERC-6909 claim the redeemer takes later, so one issuer can never block the floor (audit fixes 2, 3)

checkpoint  (permissionless, unpaid)
  anyone -> vault.checkpoint()
    gate.poke()                                        stamps layer A
    A = SUM_j P_j * (claim_j + idle_j + valuer.valuePool(pool_j, sqrtP_ref))
    navPerShareX18 = (A + 1) * 1e18 / (T + VIRTUAL_SHARES)
    pMkt = PriceLib(hub TWAP, USDG answer);  pRef = max(nav, rateLimited(pMkt))
    write Checkpoint; emit NavCheckpoint, RefCheckpoint

compound's fee split  (inside compound, Phase 3; `docs/phase3-state-model.md` §3.6)
  anyone -> vault.compound(poolId)
    collect fees in both currencies inside one unlock
    creatorCounter = counterFees * creatorBps(t) / ampsFeeBps   -> paid in kind, best effort, claim fallback
    creatorAmps    = ampsFees   * creatorBps(t) / ampsFeeBps   -> Amps.transfer(creator, ...)
    Amps.burn(self, ampsFees - creatorAmps)                     -> the whole AMPS-side remainder, plus the buyback
    place (counterFees - creatorCounter) as bids in the SAME pool, below the tick
    -- no staking call and no re-ladder: revision 6 removed both. Nothing is distributed to anybody.

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

The coverage branch is **not reachable through `checkpoint()`**: the same missing coverage makes the gate report
`WATCHDOG` for the hub, and `checkpoint()` takes the management policy, so it reverts with `GateNotHealthy` before
`_checkpoint` runs and the previous checkpoint (which already has `P_ref == NAV`) stands. It *is* reached through
the bond path, because `depositBonded` checkpoints under the bond policy, which admits `WATCHDOG`: a bond on an
unobserved hub writes `pMkt = 0`, `P_ref = navPerShareX18` and a fresh timestamp. `Phase2IntegrationTest.
test_a_referenceFallsBackToNavWhenTheHubIsUnobserved` asserts all three halves.

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
hEff      = fresh ? hSessionBps : max(hSessionBps, hSession[CLOSED])   -- `fresh` is false while an answer is
                                                                        -- stale OR held back (unconfirmed)
qFloorNum = collateralPriceUsd18 * (BPS - hEff) / BPS                                      DOWN
qFloorDen = navPerShareX18 * (BPS + minAccretionBps) / BPS                                  UP
qFloor    = qFloorNum * 1e18 / qFloorDen                                                    DOWN
-- precondition: !vault.navUnconfirmed(), else revert UnconfirmedNav (quote: reason "unconfirmedNav")
q         = min(qMarket, qFloor)
ampsOut   = amountIn18 * q / 1e18                                                           DOWN (recomputed by the shell)
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
in Phase 2 cannot dilute anyone. **The registry now answers the realised weight when it can** (second remediation wave): `PoolRegistry.currentWeightBps`
reads `AmpsVault.spokeWeightBps(constituentId)` — the spoke's counter-side position valued at the reference price plus
its idle and claim balances, over the **last checkpointed** `A` (`navPerShareX18 x (T + VIRTUAL_SHARES)`; a live walk
would cost ~150k gas per valued pool and fail every probe budget at 32 pools while passing in a small fixture) —
through a bounded 2M-gas probe and falls back to the target weight on any failure. The read costs one spoke's
valuation plus a feed answer (~200k gas), so the rollout schedule's deficit boost is live (`VaultRolloutLib` reads it
under `COMPOSITE_READ_GAS`, 400k). The bond shell probes the registry under the same `COMPOSITE_READ_GAS` budget
(`AmpsBonds._tryCurrentWeightBps`): under the old 50k token-probe cap the read sat at the budget edge and `quote()`
and `bond()` could see different deficits depending on warm storage, so the budget is the one that makes the read
succeed whenever it is readable at all. **The `k_w` under-weight preference is therefore live**: a name held below its
target weight gets a wider discount, exactly as the formula says, and a registry that cannot answer still prices
`deficit == 0`. **And "the vault cannot price this spoke" is a revert, not a zero** (re-audit finding 11,
2026-09-09): `deficit = (target - current)/target`, so a reported weight of zero is the *largest* deficit the
formula admits, and a dead feed, an absent position valuer or an out-of-range reference answering a clean `0`
walked straight past the target-weight fail-safe and widened the discount to `dMax` for exactly the name nobody
could price. Those three branches now revert `SpokeUnpriceable`, so the probe fails and the fail-safe stands; a
literal `0` is reserved for the one case that means it, which is that the vault holds none of the name. The ABI and the bond bytecode do not change when it lands. A registry
that cannot answer must never be able to close a bond market, which is why the read is a bounded probe and not a
plain call.

`qFloor` is computed from the **last Chainlink answer**, never from the pool: that caps what TWAP manipulation can
buy (the best a spoke-dumper can do is remove their own discount) and bounds weekend-gap exposure to `hSessionBps`
(0 / 50 / 150 / 300 bp) on the bonded amount, which is why markets stay open 24/7 through stale feeds and closed
sessions instead of shutting. Capacity is applied *after* pricing: `ampsOut` is clamped to
`capBpsPerEpoch * T / BPS - issuedThisEpoch`, then to `dailyCapBps * T / BPS - dailyIssued`; a clamp to zero closes
the market until the epoch rolls and does not revert the quote view. **The clamp reduces the AMPS issued, never the
collateral**: the shell settles the whole `amountIn` and issues the capped `ampsOut`, so an over-capacity bond hands
over its entire deposit for the capped issue unless `minAmpsOut` refuses it. `quote()` discloses the clamp and the
dApp must always pass the quoted amount as `minAmpsOut`; the protocol side of an over-capacity bond is a large
accretion, never a loss. The shell recomputes `qFloor` itself, rejects any `q` above it with
`AccretionFloorViolated`, and derives `ampsOut` from `q` itself rather than minting the policy's quantity, so a
hostile or buggy `BondPolicy` pointer can refuse to price but can never issue a dilutive bond (audit fix 15).
**The floor's denominator must itself be confirmed (re-audit finding 7).** The registry reports the *lower* of a
held-back jump's two levels, which is conservative for the collateral numerator but understates `A` — and so
`navPerShareX18`, the denominator of every market's floor — whenever the held-back asset is one the vault holds.
The checkpoint therefore records `navUnconfirmed` (any priced asset `!fresh || unconfirmed`), `_price` reverts
`UnconfirmedNav()` and `quote()` reports `reason == "unconfirmedNav"` while it is set. The shell reads the flag
through a bounded probe that fails open: a vault that cannot answer prices as before, so no single failing read can
halt bonds protocol-wide.

`collateralPriceUsd18` is the registry's answer with its freshness flag consumed: a stale or unconfirmed answer
widens the haircut to the `CLOSED` value in both the shell and the gate (audit fix 9), and the registry itself
reports the *lower* of a held-back jump's two levels (`FeedRegistry` NatSpec, audit fixes 13–14).

**Which NAV the price reads.** `navPerShareX18` comes from `vault.checkpointData()`, and the shell settles the
collateral *before* it prices (§3). `depositBonded` writes a checkpoint under the bond gate policy immediately before
it settles, so the NAV a bond is priced against is always this block's pre-deposit NAV — never a value an earlier
bond, a redemption or a feed move inside `CHECKPOINT_MAX_AGE` (1,800 s) has already left below the live one. This is
what makes I27 exact against the *live* NAV under every gate state bonds are open in, including `DEGRADED` and
`WATCHDOG`, where the management-gated `checkpoint()` refuses and no keeper could have refreshed it. Without it a
second bond inside the window priced off the NAV its predecessor had already raised; with an over-capacity first
bond (whole deposit in, capped AMPS out) the gap was several-fold and the second bond diluted every holder
(`Phase2IntegrationTest.test_b_secondBondInTheSameBlockPricesAgainstTheLiveNav` is the regression). The
`StaleCheckpoint` bound in `_price` is therefore what `quote()` enforces, and what a vault that did *not* refresh
would trip; inside `bond()` the age is zero by construction. A `quote()` and the `bond()` that follows it can differ
by exactly what changed NAV in between, in the protocol's favour. Cost: one checkpoint per bond (the fixture measures
1,165,037 gas for a bond against 707,584 without it, with five constituents and the zero valuer; it scales with the
asset list and, in Phase 3, with the positions the valuer decomposes), independent of placement.

## 7. The structurally ungated surface

Exactly two external state-changing functions are exempt from every gate policy:

| Function | Why |
|---|---|
| `AmpsVault.redeemProRata(shares, to)` | the redemption floor; must survive every feed dead, the watchdog tripped, the guardian frozen and the timelock hostile |
| `AmpsBonds.claim` / `claimAll` | a vest already sold; must complete through collateral removal, market pause, policy swap and guardian freeze (I38) |

"Ungated" is a property of the *code path*, not of a flag. Neither path may contain a reference to `oracleGate`,
`guardian`, `standbyVault`, a freeze timestamp, a pause bool, `feedRegistry`, or any price. Both still take the
transient reentrancy lock — a lock nobody else can hold, released in the same transaction, is not a gate. The
redemption path does call every registered token (balances, the payout, the exit sweep), and each of those calls
is bounded and best-effort: an unreadable balance is skipped, a refused payout becomes an ERC-6909 claim for the
redeemer, a refused absorb is left as `SweepResidue`, and every call carries a gas stipend so a token that burns gas
instead of reverting cannot starve what follows it (measured: one gas-burning constituent plus a 1-wei donation
costs a redemption 732k gas against 351k clean, two stipends' worth). The sweep runs each token's `transfer` outside
any unlock, so a token that re-enters the PoolManager hits `ManagerLocked` instead of opening a foreign delta inside
the vault's own unlock, and the payout falls back to a claims-only unlock if the ERC-20 unlock fails for any reason.
A third party can degrade a redemption; nothing can revert it (audit fixes 2, 3; re-audit findings 1, 3, 5).

### 7.1 The vault has three gate policies, not one

`AmpsVault` reads the gate through one helper with three policies, and the differences are load-bearing:

| Policy | Taken by | Refuses | Passes |
|---|---|---|---|
| `_requirePlaceable` (placement) | `place`, `compound`, `rollout`, `deployBonded`, `withdrawRetiredBids` | `DEGRADED`, `DIVERGED`, `SCHEDULED_FREEZE`, `WATCHDOG` | `GREEN`, `REF_DIVERGED` |
| `_requireManageable` (management) | every governed setter, `checkpoint`, `touch`, `initializePool`, both genesis steps, `setStandbyVault`, `setCreator` | `DIVERGED`, `SCHEDULED_FREEZE`, `WATCHDOG` | `GREEN`, `DEGRADED`, `REF_DIVERGED` |
| `_requireBondsHealthy` (bonds) | `depositBonded`, `mintVesting` | `DIVERGED`, `SCHEDULED_FREEZE` | `GREEN`, `DEGRADED`, `REF_DIVERGED`, `WATCHDOG` |
| any policy, gate pointer **reverts, is codeless or answers malformed** | every gated selector | nothing | everything (fail-open through a bounded hand-decoded read; `setPolicyPointer` refuses a codeless target — audit fix 18) |

The bond policy is the 24/7 bond decision restated inside the vault. A stale feed or a closed session must widen
`h_session`, not close a market, so applying the placement policy to the two bond entry points would be *stricter
than the design* rather than safer: it would shut every bond market every weekend. It mirrors `IOracleGate.checkBond`
exactly, which makes the vault defence in depth behind the shell — a buggy or replaced `AmpsBonds` still cannot
deposit or mint through a market the gate has closed — rather than a second, disagreeing gate.

**Why `DEGRADED` came out of the management set (audit finding 9, 2026-09-08).** `OracleGate.state(0)` reports
`DEGRADED` whenever an equity feed is stale beyond its session-scaled bound *or the session is simply closed* —
which is every weekend, every holiday and every night. Applying the placement policy to management therefore meant
that for roughly 48 hours a week, plus holidays, the timelock could not change a parameter, register a standby,
open a pool, run either genesis step or — the one that matters most — call `setPolicyPointer`, which is the only way
to replace a gate that is wrong but readable; and nobody could `checkpoint()` or `touch()` either, so the calendar
froze governance and NAV upkeep together with no on-chain remedy for the timelock or the guardian. Nothing about
`DEGRADED` argues for refusing governance: it says a price is not currently actionable, which is a reason to stop
committing inventory at that price — the placement policy, unchanged — not a reason to stop the contract's owners
from operating it. The three states that still refuse management are the ones that mean the protocol's own state is
untrustworthy or deliberately halted: layer E's divergence breaker, a corporate-action or guardian freeze, and layer
A's watchdog. A guardian protocol freeze still refuses all three policies, and a `checkpoint()` taken against stale
answers is exactly what slot 21's `navUnconfirmed` flag exists to mark — the bond shell refuses such a NAV itself.

Two further deliberate deviations, both asserted in `GuardSymmetry.t.sol`:

* **`emergencyMigrate` is gated by none of the three.** It is gated by the on-chain denylist predicate, which is
  strictly narrower. The incident it exists for — an issuer denylisting the vault while pausing its oracle — is
  precisely a state in which every one of them refuses, so gating it would brick the evacuation path of an immutable
  contract. `unlockCallback` is the third exemption, guarded by caller identity (`NotPoolManager`). Its 0.5% NAV
  bleed bound measures *both* sides live at the same instant (audit finding 10, 2026-09-08): comparing the stored
  checkpoint — unrefreshable, because `checkpoint()` is gated — against a live valuation made ordinary weekend drift
  of the 24/7 assets roll the whole evacuation back, and an unpriceable side now skips the bound and says so in
  `MigrationBleedUnchecked` rather than vetoing the escape. It measures both sides at the same *basis* too
  (re-audit finding 7, 2026-09-09): `navBefore` is taken **after** the `ACTION_UNWIND` that realises every position
  into claims, so it is balances against balances. Taken before it, positions were valued at
  `sqrtPrice(P_ref / P_counter)` (I7) while the standby's side was realised at whatever the pools cleared at, and a
  pool a fraction of a percent below the reference — one front-running sell into a public, urgent, timelock-free
  call — tripped the 50 bp bound and reverted the guardian's evacuation.
* **A gate pointer that *reverts* is read as absent, not as a refusal.** The gate is the one pointer that can refuse
  every governance call; if a broken one refused, nobody could call `setPolicyPointer` to replace it and a contract
  holding no funds would have bricked the protocol. Failing open grants an attacker nothing they would not already
  have with a `GREEN` gate. **The guardian's protocol freeze is read first, and is exempt from that rule**
  (re-audit finding 6, 2026-09-09): `protocolFreezeUntil()` is one `SLOAD` behind a getter (~2.6k) while `state(0)`
  walks the calendar, the feeds, the market reference and the registry (330-390k against real aggregators), so
  reading the expensive one first put the fail-open `return` between the caller and the freeze — and a gated
  selector sent with a gas limit that starves the composite and nothing else proceeded while the freeze was live.
  The refusal that cannot be starved therefore runs before the read that can; neither read's own semantics change,
  and a gate that answers neither is still absent.

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
   site reachable from a selector other than **`genesisMint`** — `mintVesting` (I10).

## 8. Migration surface

* **Standby vault.** `setStandbyVault(address)` — timelock, 14 days. Registering it moves nothing; a codeless
  address is refused (re-audit lead).
* **Predicate.** `emergencyMigrate(standby)` is guardian-callable with no delay, and reverts with
  `MigrationPredicateNotMet` unless, checked on-chain at call time: `IStockToken(token).isBlocked(vault) == true`
  for at least one registered constituent, **or** a bounded 1-wei self-transfer probe reverts for at least two
  constituents. Every probe is a `staticcall`/`call` capped at `Constants.STOCK_TOKEN_PROBE_GAS`.
* **What moves.** Per pool, inside one `unlock`: remove liquidity -> `take` as ERC-6909 claims -> transfer the
  claims PoolManager-internally to the standby vault -> the standby re-adds at the same ticks. The R1 bleed cap is
  relaxed from 2 bp to `MIGRATION_BLEED_BPS_MAX` (50 bp) only inside this call. The idle ERC-20 leg of `evacuate`
  is a gas-capped best-effort transfer (re-audit finding 5), so a gas-burning constituent cannot starve the roles
  handed over after it.
* **What follows in the same transaction.** `VaultNavLib.handover` moves **five** roles: `Amps.setVault`,
  `AmpsBonds.setVault`, `BountyPot.setVault`, `PoolRegistry.setVault` and a best-effort, gas-bounded
  `AmpsHook.setVault` (the hook's `vault` is storage since audit fix 12). All five are `onlyVault`, which is why
  they can be handed on atomically and why nobody else can hand them on at all; the hook leg is best-effort so a
  hook without the setter can never veto an evacuation. A sixth leg handed `AmpsStaking` on until plan revision 6
  removed staking; the registry and the hook are the other two contracts that name a vault, and leaving either
  behind would let a standby fail to open a pool while the old hook still trusted the evacuated shell.
* **What the migration does not have to move.** `AmpsRouter` names no vault: it reads the PoolManager and the
  registry, both of which survive a migration unchanged, so an evacuation does not touch it. What *would* need
  attention is `AmpsHook.setRouter` if a migration ever replaced the hook, which it does not — the hook is
  immutable and is handed on, not redeployed.
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
* Every external function sweeps at exit: any ERC-20 balance of a registered asset on the vault is absorbed into
  ERC-6909 claims best-effort and residue is emitted as `SweepResidue`, never asserted; `AmpsBonds` forwards
  collateral dust to the vault. I12 is therefore "no *movable* asset rests as ERC-20", which a donation of a
  paused token cannot break (audit fixes 1, 3).

## 9.1 Bootstrap ordering: the gate and the first pool are circular

`AmpsVault.initializePool`, `genesisMint` and `genesisPlace` all take `_requireManageable`, and
`OracleGate._referenceIntegrity` reports `WATCHDOG` whenever the hub pool is unregistered *or* its observation ring
covers less than `twapWindow`. A freshly initialised hook pool has no observations at all, so with the gate already
wired **no pool can be registered and neither genesis step can run**: all three revert with
`GateNotHealthy(WATCHDOG)` until the hub has thirty minutes of history it cannot acquire without existing.

Revision 7 adds a second circularity on top of it. `PoolRegistry._openPool` anchors every pool at
`AmpsVault.pRefX18()` and registration opens the pool in the same call, so if the 32 pools are to open at the
auction's clearing price the whole of `05_Registry` has to run **after** `genesisPlace` — while `genesisPlace`
itself ends in a checkpoint, and a checkpoint prices every asset the vault holds. The Phase 2 integration fixture
resolves both the only way the contracts allow, and the deploy runbook (`script/05_Registry`,
`script/06a_GenesisAuction`, `script/06b_GenesisSettle`, `script/09_Phase3Wire`) must use the same order:

1. deploy everything and wire the vault's set-once pointers (`registry`, `bonds`, `bountyPot`, and the new
   `genesis`) and the pointer-upgradeable `feedRegistry`, `positionValuer`, `marketReference` — but **leave
   `oracleGate` unset** (`_requireGate` returns when the pointer is zero). `09_Phase3Wire` with
   `WIRE_DEFER_GATE=true` is that pass;
2. **install every feed and register nothing** (`05_Registry` with `REGISTRY_FEEDS_ONLY=true`). A checkpoint prices
   every asset the vault holds, so WETH9's and USDG's feeds must exist before `genesisPlace` — which is why feed
   installation is now its own step rather than a side effect of registration;
3. `genesisMint`, then `AmpsGenesis.createAuctions` (`06a_GenesisAuction`): `S0` is minted, the auction tranche is
   inside the two auctions, `initialized` is still false;
4. bidding, about 72 hours;
5. `AmpsGenesis.settle()` → `genesisPlace` (`06b_GenesisSettle`), which writes `P_ref = max(P0, NAV/share)`;
6. register the 32 pools through `PoolRegistry` (each `vault.initializePool` passes with no gate, and each pool
   opens at `P0` because `pRefX18()` is no longer zero);
7. wait until the hook's hub ring covers `twapWindow` — on Robinhood Chain that is thirty minutes of blocks after
   the hub's first observation; on a test chain, seed the ring;
8. point the vault at `OracleGate` through `setPolicyPointer`, confirm `gate.state(0) == GREEN` (`09_Phase3Wire`
   pass 2);
9. lay the §3.3 ladders (`11_GenesisPlacement`, two phases 60 s apart).

Nothing is lost by the order: a gate that is absent is exactly as permissive as a gate that is `GREEN` (§7.1), the
vault holds no assets before `genesisPlace`, and the `wiringFrozen` latch that `genesisPlace` sets does not cover
the gate pointer, which stays governable for the life of the vault. One consequence is load-bearing rather than
incidental: because `settle()` is permissionless *and* gated, **the gate pointer must not be set between steps 3
and 5** — a third party's `settle()` would revert `GateNotHealthy` and the launch would stall. See
`docs/genesis-cca.md` §5 for the whole table, including which script each step is.

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
