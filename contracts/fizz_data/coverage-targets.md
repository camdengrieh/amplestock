# Coverage targets (fizz Step 8)

Fuzz profile: **default profile, via-IR only on `src/vault/*`, `src/bonds/*`, `src/hook/*`** (per-path
`compilation_restrictions` in `foundry.toml`). `setup_fuzz_profile.sh` was not run: a `[profile.fuzz]` would drop
those per-path restrictions and push `AmpsVault` past EIP-170. Coverage for the vault, bonds and hook is therefore
deflated ("ir fallback" column, ~15–20%); every other contract compiles without IR and is accurate.

## How coverage is measured here

Medusa 1.5.1 attributes **nothing** to a deployed contract whose runtime code carries immutables (the deployed
code differs from the artifact at the immutable slots, so the source map never matches): `AmpsVault`, `AmpsHook`,
`AmpsBonds`, `PoolRegistry`, `OracleGate`, `AmpsRouter`, `Amps`, `BountyPot`, `LadderPositionValuer` and
`FeePolicy` all read 0% in the lcov/HTML report however much they run. Per-file percentages are only meaningful
for the immutable-free contracts (`BondPolicy`, `RolloutPolicy`, `LadderPolicy`, `PriceLib`, `LadderLib`, the
mocks) and for the harness itself (`test/fizz/**`, whose per-handler line coverage proves which handlers land).

The cycles below are therefore driven by (1) the **aggregate `branches` counter** Medusa prints, (2) the harness's
own per-handler line coverage from the lcov, and (3) targeted `FoundryTester` probes for paths the counter cannot
attribute. Per-contract targets are kept as the skill asks, with "n/a (immutables)" where Medusa cannot report.

## Per-contract targets

| Contract | Role | Target (ir fallback / no-ir) | Measurable by Medusa? |
|---|---|---|---|
| AmpsVault (+ VaultNavLib, VaultPlacementLib, VaultRedeemLib, VaultRolloutLib) | core | 65% | no (immutables); proxied by handler coverage + `branches` |
| AmpsHook | core | 65% | no (immutables) |
| AmpsBonds | core | 65% | no (immutables) |
| AmpsRouter | periphery | 35% | no (immutables) |
| PoolRegistry | access / lifecycle | 45% | no (immutables) |
| OracleGate, FeedRegistry | access / gate | 45% | no (immutables) |
| BondPolicy, RolloutPolicy, LadderPolicy | libraries via callers | inherited | yes |
| PriceLib, LadderLib, TruncatedOracleLib | libraries | inherited | yes (inlined into callers where internal) |
| test/fizz handlers | harness | every clamped handler ≥ 1 successful landing | yes |

## Acceptable skips (with reasons)

- The ordinary v4 `swapRouter` path (`Phase3Fixture.buyAmps/sellAmps/rotate`): pulls through Permit2, which is a
  `STOP` stub in this harness because Medusa 1.5.1 cannot reliably call `vm.etch`-installed code (68-byte and
  132-byte calls fail with a stack underflow). Every trade goes through `AmpsRouter` instead, which is the
  protocol's own path and exercises both fee directions and the pass-through.
- `emergencyMigrate`, `genesisMint`/`genesisPlace`, `Amps.mint`/`burn`, `AmpsBonds.addCollateral`, the hook's
  PoolManager-only callbacks: excluded by the entry-point selection (one-shot bootstrap, vault-only plumbing,
  callbacks driven by every swap).
- Gate states that need a real feed failure (WATCHDOG after `GRACE`, sustained DIVERGED): reachable only through
  the `env_secondary` dispatcher's warp/moveFeed actions in the right order; counted as reached when the
  `branches` counter moves on those sequences, not by per-file lines.

## Cycle history

## Cycle 1 (2026-09-10 07:07 UTC, Medusa 1.5.1, 20,000 calls / 489 sequences, 1m47s of fuzzing after a 31-minute compile)

Aggregate `branches` counter: 9,687 at the constructor, 17,025 at the end (the smoke run reached 17,044). Stopped by the smoke-run `testLimit` of 20,000, not by the plateau detector: the wrapper looks for `branches hit:` while Medusa 1.5.1 prints `branches:`, so plateau mode never engages (recorded; `testLimit` is now 0 so the campaign's `--timeout` governs). 57 handlers, 0 failures.

### Harness line coverage (proves which handlers land)

| File | Lines hit | Lines | % |
|---|---|---|---|
| `test/fizz/Actor.sol` | 2 | 9 | 22% |
| `test/fizz/Base.sol` | 130 | 138 | 94% |
| `test/fizz/FoundryTester.sol` | 0 | 78 | 0% |
| `test/fizz/FuzzTester.sol` | 1 | 1 | 100% |
| `test/fizz/handlers/AmpsBondsHandler.sol` | 45 | 46 | 97% |
| `test/fizz/handlers/AmpsHandler.sol` | 15 | 16 | 93% |
| `test/fizz/handlers/AmpsHookHandler.sol` | 10 | 10 | 100% |
| `test/fizz/handlers/AmpsRouterHandler.sol` | 29 | 29 | 100% |
| `test/fizz/handlers/AmpsVaultHandler.sol` | 51 | 51 | 100% |
| `test/fizz/handlers/BountyPotHandler.sol` | 9 | 9 | 100% |
| `test/fizz/handlers/FeedRegistryHandler.sol` | 7 | 7 | 100% |
| `test/fizz/handlers/Handlers.sol` | 1 | 1 | 100% |
| `test/fizz/handlers/OracleGateHandler.sol` | 36 | 36 | 100% |
| `test/fizz/handlers/PoolRegistryHandler.sol` | 22 | 22 | 100% |
| `test/fizz/utils/Clamp.sol` | 9 | 9 | 100% |
| `test/fizz/utils/DecimalPrinter.sol` | 3 | 32 | 9% |
| `test/fizz/utils/Deployer.sol` | 1 | 1 | 100% |
| `test/fizz/utils/EnumerableSet.sol` | 1 | 1 | 100% |
| `test/fizz/utils/Logger.sol` | 2 | 2 | 100% |
| `test/fizz/utils/Math.sol` | 1 | 1 | 100% |
| `test/fizz/utils/MockERC20.sol` | 0 | 67 | 0% |
| `test/fizz/utils/PropertiesAsserts.sol` | 1 | 1 | 100% |
| `test/fizz/utils/StringUtils.sol` | 2 | 2 | 100% |

### Immutable-free protocol files (the only `src/` files Medusa can attribute)

| File | Lines hit | Lines | % |
|---|---|---|---|
| `lib/forge-std/src/StdChains.sol` | 1 | 1 | 100% |
| `lib/forge-std/src/StdConstants.sol` | 1 | 1 | 100% |
| `lib/forge-std/src/StdMath.sol` | 1 | 1 | 100% |
| `lib/forge-std/src/StdStorage.sol` | 2 | 2 | 100% |
| `lib/forge-std/src/StdStyle.sol` | 1 | 1 | 100% |
| `lib/forge-std/src/StdToml.sol` | 1 | 1 | 100% |
| `lib/forge-std/src/Test.sol` | 1 | 1 | 100% |
| `lib/forge-std/src/safeconsole.sol` | 1 | 1 | 100% |
| `lib/hookmate/src/interfaces/router/PathKey.sol` | 1 | 1 | 100% |
| `lib/uniswap-hooks/lib/v4-core/src/libraries/CurrencyDelta.sol` | 1 | 1 | 100% |
| `lib/uniswap-hooks/lib/v4-core/src/libraries/CurrencyReserves.sol` | 1 | 1 | 100% |
| `lib/uniswap-hooks/lib/v4-core/src/libraries/NonzeroDeltaCount.sol` | 1 | 1 | 100% |
| `lib/uniswap-hooks/lib/v4-core/src/libraries/ParseBytes.sol` | 1 | 1 | 100% |
| `lib/uniswap-hooks/lib/v4-periphery/src/libraries/PositionInfoLibrary.sol` | 1 | 1 | 100% |
| `lib/uniswap-hooks/lib/v4-core/src/libraries/LPFeeLibrary.sol` | 5 | 6 | 83% |
| `src/policy/BondPolicy.sol` | 30 | 42 | 71% |
| `lib/uniswap-hooks/lib/v4-core/src/types/PoolId.sol` | 2 | 3 | 66% |
| `src/policy/RolloutPolicy.sol` | 18 | 33 | 54% |
| `lib/uniswap-hooks/lib/v4-periphery/src/utils/HookMiner.sol` | 7 | 13 | 53% |
| `lib/forge-std/src/Base.sol` | 1 | 2 | 50% |
| `lib/hookmate/src/artifacts/V4PositionManager.sol` | 3 | 6 | 50% |
| `lib/uniswap-hooks/lib/v4-core/src/libraries/FixedPoint128.sol` | 1 | 2 | 50% |
| `lib/uniswap-hooks/lib/v4-core/src/libraries/Lock.sol` | 1 | 2 | 50% |
| `lib/uniswap-hooks/lib/v4-core/src/types/BeforeSwapDelta.sol` | 1 | 2 | 50% |
| `lib/uniswap-hooks/lib/v4-core/src/libraries/FullMath.sol` | 17 | 37 | 45% |
| `lib/uniswap-hooks/lib/v4-core/src/libraries/TickMath.sol` | 53 | 123 | 43% |
| `lib/hookmate/src/artifacts/V4PoolManager.sol` | 3 | 7 | 42% |
| `lib/hookmate/src/artifacts/V4Router.sol` | 3 | 7 | 42% |
| `src/lib/PriceLib.sol` | 29 | 76 | 38% |
| `lib/uniswap-hooks/lib/v4-core/src/libraries/FixedPoint96.sol` | 1 | 3 | 33% |
| `lib/uniswap-hooks/lib/v4-core/src/libraries/UnsafeMath.sol` | 1 | 3 | 33% |
| `lib/uniswap-hooks/lib/v4-core/src/types/Currency.sol` | 1 | 3 | 33% |
| `lib/forge-std/src/StdError.sol` | 3 | 10 | 30% |
| `lib/hookmate/src/artifacts/DeployHelper.sol` | 3 | 11 | 27% |
| `src/lib/LadderLib.sol` | 23 | 89 | 25% |
| `lib/uniswap-hooks/lib/v4-core/src/libraries/SafeCast.sol` | 1 | 5 | 20% |
| `lib/hookmate/src/artifacts/Permit2.sol` | 1 | 6 | 16% |
| `lib/uniswap-hooks/lib/v4-core/src/libraries/LiquidityMath.sol` | 1 | 6 | 16% |
| `src/oracle/GatePriceMath.sol` | 1 | 6 | 16% |
| `lib/uniswap-hooks/lib/v4-core/src/libraries/BitMath.sol` | 3 | 19 | 15% |
| `lib/uniswap-hooks/lib/v4-core/src/types/BalanceDelta.sol` | 1 | 7 | 14% |
| `src/types/Constants.sol` | 25 | 191 | 13% |
| `lib/uniswap-hooks/lib/v4-core/src/libraries/ProtocolFeeLibrary.sol` | 1 | 9 | 11% |
| `lib/uniswap-hooks/lib/v4-core/src/libraries/TickBitmap.sol` | 1 | 9 | 11% |
| `lib/uniswap-hooks/lib/v4-core/src/libraries/TransientStateLibrary.sol` | 1 | 9 | 11% |
| `lib/uniswap-hooks/lib/v4-core/src/libraries/Position.sol` | 1 | 11 | 9% |
| `lib/forge-std/src/StdJson.sol` | 1 | 14 | 7% |
| `lib/uniswap-hooks/lib/v4-core/src/libraries/CustomRevert.sol` | 1 | 16 | 6% |
| `lib/uniswap-hooks/lib/v4-core/src/libraries/Hooks.sol` | 2 | 33 | 6% |
| `lib/uniswap-hooks/lib/v4-periphery/src/libraries/LiquidityAmounts.sol` | 1 | 17 | 5% |
| `lib/forge-std/src/StdInvariant.sol` | 1 | 22 | 4% |
| `lib/forge-std/src/console.sol` | 1 | 24 | 4% |
| `lib/uniswap-hooks/lib/v4-core/lib/solmate/src/utils/FixedPointMathLib.sol` | 1 | 25 | 4% |
| `src/oracle/StreamsSchemaLib.sol` | 1 | 27 | 3% |
| `src/policy/LadderPolicy.sol` | 2 | 66 | 3% |
| `lib/uniswap-hooks/lib/v4-core/src/libraries/SwapMath.sol` | 1 | 40 | 2% |
| `src/hook/HookStateLib.sol` | 1 | 51 | 1% |
| `lib/hookmate/src/constants/AddressConstants.sol` | 2 | 122 | 1% |
| `src/periphery/QuoterSwapLib.sol` | 1 | 61 | 1% |
| `lib/uniswap-hooks/lib/v4-core/src/libraries/SqrtPriceMath.sol` | 1 | 72 | 1% |
| `lib/uniswap-hooks/lib/v4-core/src/libraries/StateLibrary.sol` | 1 | 84 | 1% |
| `src/lib/PoolStateLib.sol` | 1 | 134 | 0% |
| `src/lib/TruncatedOracleLib.sol` | 1 | 137 | 0% |
| `src/vault/VaultRolloutLib.sol` | 1 | 172 | 0% |
| `src/vault/VaultRedeemLib.sol` | 1 | 180 | 0% |
| `src/vault/VaultNavLib.sol` | 1 | 218 | 0% |
| `src/vault/VaultPlacementLib.sol` | 1 | 375 | 0% |

Every other `src/` file reports 0% for the immutables reason above; the aggregate counter and the harness lines are the signal. Decision: one coverage cycle. The handlers all land (`test_sequence` executes every primary handler with zero refusals; every harness file above has non-zero coverage), the aggregate counter plateaus at the smoke run's level within 20k calls, and each further cycle costs a 31-minute compile that buys no attributable number. The remaining reachability gaps are handler *shapes* (the discovery agents listed the missing ones: privilege probe, refresh-then-bond, two rotations in one transaction, bond-to-victim, whole-inventory place, whole-capacity bond, cross-user redeem, feed walk), which the property implementers add in Step 9d; the campaign in Step 10 runs with those in place.

## Campaigns (Step 10)

| Run | Calls | Sequences | Branches | Result | Disposition |
|---|---|---|---|---|---|
| Campaign 1 (2026-09-10 10:34 UTC, 600 s) | 1,721 | 601 | 28,290 | 153 passed, 2 failed (SP-18, SP-35) | both harness over-statements against documented behaviour (`amountPlaced` reports the split; a donation handler targets the hook); corrected |
| Campaign 2 (16:02 UTC, 600 s) | 1,268 | 1,350 | 28,014 | 152 passed, 3 failed (SP-05, SP-20, SP-14) | SP-05: the bond's own checkpoint latched a walked feed (bond handlers now checkpoint first); SP-20: compared against the hook's cached fair tick, not the vault guard's measure (corrected); SP-14: the accepted reference-vs-pool valuation gap, ~2 bp of the payout, EXPLORATORY lead (slack widened to 25 bp) |
| Campaign 3 (2026-09-11 12:22 UTC, 600 s; wall 18,415 s of which ~5 h shrinking) | 16,850 | 1,705 | 29,722 | 152 passed, 3 failed (GL-47, SP-43, SP-07) | GL-47: the "never above `lastTruncatedTick`" clause misread a running maximum (removed); SP-43: a refused buy-back left a bare sell under the comparison (the handler now skips a refused second leg); SP-07: the bond's own checkpoint moved the NAV basis between the quote and the pricing by the reference's self-referential convergence step (lead L-1; the property rescales by the observed basis ratio, SP-05 restated as I27's identity on the bond's basis, the preview NAV leg dropped from SP-05/SP-08). The SP-20 replay of campaign 2 was re-diagnosed on the way: `deployBonded` had placed nothing, so the property now applies only to calls that did work |
| Campaign 4 (2026-09-12 03:15 UTC, 600 s; wall 11,495 s) | 20,979 | 2,173 | 29,347 | 153 passed, 2 failed (SP-04, SP-46) | SP-04: a donation resting on the bond shell is forwarded to the vault with the next bond (`CollateralForwarded`), so the vault's holding rises by `amountIn` plus that dust (the property now adds the forwarded term); SP-46: the counter-only measure read the redemption-floor arbitrage as extraction (SP-45/SP-46 now arm only when `previewRedeem`'s counter amount does not exceed the payment). The three campaign-3 corrections held |
| Campaign 5 (2026-09-12 10:20 UTC, 600 s; wall 13,401 s of which ~3 h was Medusa's silent post-run phase) | 29,221 (last tick) | 2,717 | 29,588 | 154 passed, 1 failed (SP-33) | SP-33: the router sweeps its residual balance of every asset it touched to its caller (`_sweep`, GL-39), so a recipient who is also the caller receives the reported output plus any dust an earlier call left on the router (22,947,131 wei of AMPS here); the property now counts the swept balance separately. The campaign-3 and campaign-4 corrections held |

Call counts are low because every early violation parks its worker in shrinking, and each shrink replay redeploys the
617M-gas world; `shrinkLimit` was lowered from 1,000 to 200 after campaign 1 to 50 after campaign 3 (whose three violations cost four workers about five hours of shrinking) and to 20 after campaign 4 (two violations, three hours). The branch counter is the coverage
signal (see above); it rose from the 17k of the handler-only cycle to 28k once the properties and the sixteen
adversarial handlers were in place.
