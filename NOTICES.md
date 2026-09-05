# Notices and attribution

Amplestocks is MIT-licensed throughout (see [`LICENSE`](./LICENSE)). This file records where
ideas, mechanisms and third-party artefacts in this repository came from, and what the licence
consequences of each are. It is maintained by hand and enforced mechanically by
[`scripts/licence-gate.py`](./scripts/licence-gate.py), which fails CI if any source file reachable
from `contracts/src/**` carries a BUSL-1.1, AGPL-3.0, GPL-2.0 or GPL-3.0 SPDX header, or no SPDX
header at all.

## Policy

1. Every file we write carries `// SPDX-License-Identifier: MIT`.
2. Nothing under a copyleft or source-available licence (BUSL-1.1, AGPL-3.0, GPL-2.0, GPL-3.0) may
   be reachable from `contracts/src/**` — not by import, not by copy, not by line-by-line port.
3. Where a mechanism is described in a copyleft or source-available project, we take the *idea from
   the description*, reimplement it from first principles in our own code, and record that here.
4. `contracts/test/**` and `contracts/script/**` are exempt from rule 2 (they never ship), but the
   licence gate still reports what they pull in so the exemption stays visible.

## Reimplemented mechanisms (idea taken, code written from scratch)

### Bunni v2 — surge-fee decay shape

The dynamic-fee surge that Amplestocks applies after a large or oracle-divergent swap follows the
*shape* of Bunni v2's surge fee: an instantaneous jump proportional to the disturbance, decaying
back to the base fee over a fixed half-life. Bunni v2 is MIT-licensed, so this would have been
permissible to vendor, but we did not: the decay law here is reimplemented from the published
description of the mechanism, with our own parameterisation, bounds and integer maths. No Bunni
source file is imported, copied or vendored into this repository.

### Truncated geometric-mean oracle

`TruncatedOracleLib` implements a geometric-mean TWAP whose per-block tick movement is clamped to a
maximum, so a single-block price push cannot move the observation series by more than the cap. Two
separate lineages meet in that one file, and they have different licence consequences.

**The truncation itself** follows Uniswap's `TruncGeoOracle` work and OpenZeppelin's
`PanopticOracle` treatment of the same problem. Both were read as prior art and as a specification
of the desired behaviour; the implementation here is written from scratch against our own tick
accounting and observation cardinality, and neither project's source is imported or copied.

**The structure it truncates** — a cumulative-tick accumulator, a fixed-size ring of observations,
and a binary search over that ring to interpolate a reading at an arbitrary past timestamp — is the
shape **Uniswap v3-core's `Oracle.sol`** established, and `consult`'s floor-toward-negative-infinity
rounding matches Uniswap v3-periphery's `OracleLibrary.consult` so that the two cannot disagree
about a mean by one tick.

**Uniswap v3-core is licensed GPL-2.0-or-later**, and v3-periphery GPL-2.0-or-later as well. Neither
is a dependency of this repository: they are not in `lib/`, not in `remappings.txt`, and not
reachable from `contracts/src/**` by any import — which is precisely what
[`scripts/licence-gate.py`](./scripts/licence-gate.py) fails the build over. They were read as a
specification of the accumulator's semantics and then closed. `TruncatedOracleLib` is original MIT
code with its own observation struct, its own per-*block* (not per-*swap*) truncation anchor, its
own exact interpolation — it interpolates with the recorded tick rather than v3's average-slope
formula, which removes a rounding step v3 has — and no `grow()`/cardinality-expansion path at all.
The only thing carried across is the arithmetic contract: `int56` accumulators that wrap by design
and `uint32` timestamps compared on the mod-2³² circle.

### Olympus v2 and Bond Protocol — bond mechanics

`AmpsBonds` and `BondPolicy` implement discounted, vesting issuance against deposited collateral.
The general shape of that market — a base discount that widens when capacity goes unsold and
narrows when it fills, a per-epoch capacity cap, and a linear vest — is the mechanism Olympus v2 and
Bond Protocol popularised.

**Both Olympus v2 and Bond Protocol are licensed AGPL-3.0.** Neither was imported, vendored, copied
or ported line-by-line. They were used as *reference only*: read to understand the mechanism and its
known failure modes, then closed. Every line of `contracts/src/bonds/**` and
`contracts/src/policy/BondPolicy.sol` is original MIT code with our own discount law, capacity
accounting, oracle gating and accretion floor. The licence gate exists in large part to keep this
claim mechanically true.

## Third-party code we do import

| Dependency | Licence | Where it is used |
|---|---|---|
| [`forge-std`](https://github.com/foundry-rs/forge-std) 1.16.2 | MIT | Tests and scripts only. |
| [`OpenZeppelin/uniswap-hooks`](https://github.com/OpenZeppelin/uniswap-hooks) 1.2.2 | MIT | `BaseHook` and hook plumbing, imported by `contracts/src/hook/**`. |
| [`openzeppelin-contracts`](https://github.com/OpenZeppelin/openzeppelin-contracts) 5.7.0 | MIT | ERC-20, ERC-4626, `VestingWallet`, `TimelockController`, `SafeERC20`, access control. |
| [`hookmate`](https://github.com/z0r0z/hookmate) 0.6.0 | MIT | `HookMiner`-adjacent helpers and prebuilt Uniswap v4 artefacts used in tests. |
| Uniswap v4-core 1.0.2 | mixed — see below | Interfaces, libraries and types imported by `contracts/src/**`. |
| Uniswap v4-periphery 1.0.3 | MIT | Periphery libraries and `HookMiner`, used by scripts and tests. |

### Uniswap v4-core is not uniformly MIT

Uniswap v4-core ships a mixture of licences within one repository. The **interfaces, types and
libraries** we import from `contracts/src/**` (`IPoolManager`, `IHooks`, `Currency`, `PoolId`,
`PoolKey`, `BalanceDelta`, `BeforeSwapDelta`, `Hooks`, `TickMath`, `FullMath`, `LPFeeLibrary`,
`IExtsload`, `IExttload`, `SafeCast`, `CustomRevert`, …) are MIT. The **`PoolManager` implementation is
BUSL-1.1** and must never appear in the production import graph. Amplestocks never imports
`v4-core/src/PoolManager.sol`: production code talks to the deployed PoolManager only through the
MIT `IPoolManager` interface, and tests instantiate a PoolManager from hookmate's prebuilt artefact
rather than compiling v4-core's BUSL source. `scripts/licence-gate.py` enforces exactly this
boundary.

Concretely, the BUSL-1.1 files in v4-core are `src/PoolManager.sol`, `src/libraries/Pool.sol`,
`Position.sol`, `Lock.sol`, `CurrencyDelta.sol`, `CurrencyReserves.sol`, `NonzeroDeltaCount.sol` and
`src/test/ProxyPoolManager.sol` (plus one GPL-3.0-or-later file, `src/test/NativeERC20.sol`). Two of
those are reachable through MIT front doors, which is the trap this gate exists to catch:
`StateLibrary.sol` (MIT) imports `Position.sol` (BUSL-1.1), and `TransientStateLibrary.sol` (MIT)
imports `Lock.sol`, `CurrencyReserves.sol` and `NonzeroDeltaCount.sol` (all BUSL-1.1). Production
code therefore reads pool state through `extsload`/`exttload` against the MIT `IExtsload` and
`IExttload` interfaces with slot arithmetic of our own in `PriceLib`; `StateLibrary` is confined to
`test/` and `script/`.

### hookmate artefacts contain compiled Uniswap bytecode

`lib/hookmate` is MIT, but the artefacts it vendors (`hookmate/artifacts/V4PoolManager.sol`,
`V4PositionManager.sol`, `V4Router.sol`, `Permit2.sol`, …) embed **compiled Uniswap v4 bytecode**,
including the BUSL-1.1 `PoolManager`. That bytecode is used **only in tests**, to stand up a
realistic local v4 environment without compiling BUSL source. It is never deployed to a public
network by this repository and is never reachable from `contracts/src/**`. Deployments target the
PoolManager already live on Robinhood Chain
(`0x8366a39cc670b4001a1121b8f6a443a643e40951`), deployed by Uniswap, not by us.

## Reference data

Address books, feed addresses and the launch token list in `packages/config` are public on-chain and
directory data (Uniswap v4 deployments, Robinhood Chain Stock Tokens, the Chainlink Reference Data
Directory). They are facts, not code, and carry no licence obligation; every one of them is marked
for on-chain re-verification before it is hardcoded into a deployment script.

## Reporting

If you believe any file here is derived from code we have not credited, or is under a licence
incompatible with MIT, please open an issue. We will correct or remove it.
