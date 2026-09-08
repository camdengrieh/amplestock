# amplestocks-quant

Python side of Amplestocks. **Placeholder — populated in Phase 0B.**

Phase 0B is the quantitative gate that has to pass before any production Solidity is written. Nothing
here is imported by the contracts, the dApp or the keeper; it exists to answer parameter questions
with numbers instead of intuition.

Phase 0B use:

- **Ladder shape.** Sweep `ladderTilt` (band `[1.0, 1.5]`, start 1.25) and `ladderDoublings`
  (band `[6, 14]`, start 10) against simulated order flow; confirm the claimed $1 → $1,024 span and
  the capital required to walk each bucket.
- **Rollout.** Sweep `rolloutBpsPerDay` (start 200, cap 1000) and `entryFloorBps` (start 3000) to
  check that entry-pool inventory drains into the 30 spokes without stranding the `AMPS/WETH` and
  `AMPS/USDG` books.
- **Bond pricing.** Backtest `dBase`/`dMin`/`dMax` (12.5/10/15%), `capBpsPerEpoch` (50 bp per 6 h),
  `dailyCapBps` (200 bp) and `minAccretionBps` (50) for NAV accretion under realistic fill rates,
  including the session haircuts `hSession` = 0/50/150/300 bp.
- **Fee split.** Check the sell-fee split (creator → `stakerBps` 3000 → `burnBps` 1000 → re-ladder)
  and the resulting NAV/share path against equity-session volume profiles.
- **Oracle.** Calibrate the truncated geometric-mean TWAP's per-block tick cap against tick series
  from the spoke pools, and size `refUpRateBps` (1000 per hour).

Inputs are the reference data in `packages/config` plus historical equity and feed data pulled in
Phase 0A. Outputs are tables and plots that either confirm the launch parameters or send them back
to the user for a decision.

## Setup

```bash
cd packages/quant
python3 -m venv .venv && . .venv/bin/activate
pip install -e '.[dev]'
```

---

## Launch-constituent selection (`amplestocks_quant.constituents`)

Ranks every Robinhood Stock Token on chain 4663 by the fee revenue Amplestocks' protocol-owned
liquidity would earn per dollar placed, picks the launch set, and writes the report and the deploy
configs. The methodology, the full ranked table and the caveats live in
[`docs/launch-constituents.md`](../../docs/launch-constituents.md), which this command generates.

```
collectors               model                    selection             writers
-----------------------  -----------------------  --------------------  ------------------------------
universe  rhj/assets      V7, V30 (Swap events)    drop dead / no_feed   docs/launch-constituents.md
          docs table      L      (+/-2% depth)     rank by ROI           out/constituents.json
          Blockscout      s = P / (L + P)          >= 10 high-volume     out/launch-set.ts
pools     v4 + v3 logs    R = V30/30 * s * f       weights sqrt(V30*L)   out/constituents.registry.json
market    swaps + state   ROI = R * 365 / P        caps and floors       contracts/script/config/...
feeds     Chainlink RDD   sigma, turnover, flags   tick spacing          (only with an explicit flag)
apis      cross-check
```

### The command

```bash
cd packages/quant
python3 -m venv .venv && . .venv/bin/activate && pip install -e '.[dev]'

# The real run. Nothing else is needed - no API keys, no archive node, no local state.
python -m amplestocks_quant.constituents run \
  --rpc https://rpc.mainnet.chain.robinhood.com \
  --window 30 --placement 300 --out out
```

`--out` is a directory. Useful flags: `--placement` is repeatable and the first one ranks (default
`300 1000 5000`); `--count` / `--min-high-volume` size the set and its rotation-depth floor;
`--fee-basis effective` ranks on the fee the existing pools charge instead of ours;
`--no-cross-check` skips the three aggregators (much faster); `--window 45` is what the registry's
`historyDays >= 30` actually needs. `--help` lists the rest.

The recorded run needs no network at all and produces the same artefacts, labelled
`FIXTURE DATA - not a launch set`:

```bash
python -m amplestocks_quant.constituents run --fixtures --count 12 --api-delay 0 --out out
```

### Hosts it needs

All plain HTTPS, no credentials. A sandbox without egress to these produces a report full of
`NO` rows in §10 rather than wrong numbers.

| Host | Used for | Fatal if blocked? |
|---|---|---|
| `rpc.mainnet.chain.robinhood.com` | `eth_getLogs`, `eth_call`, `eth_getStorageAt` | yes |
| `robinhood-rpc.publicnode.com` | fallback for the above, tried per request | no |
| `api.robinhood.com` | issuer registry (`/rhj/assets`) | no (docs + Blockscout cover it) |
| `docs.robinhood.com` | contracts table | no |
| `robinhoodchain.blockscout.com` | ERC-20 index, filtered by the beacon slot | no |
| `reference-data-directory.vercel.app` | Chainlink feeds | **yes** - no feed, no constituent |
| `api.geckoterminal.com`, `api.dexpaprika.com`, `api.dexscreener.com` | cross-check only | no |

`https://robinhood.hypersync.xyz` is not used: HyperSync's protocol is not JSON-RPC, and the
adaptive chunking below made the plain RPC path fast enough that a second log backend was not worth
the dependency.

### Expected runtime

Dominated by two things: how many `eth_getLogs` calls the window needs, and the aggregator rate
limits.

| Stage | Calls | Notes |
|---|---|---|
| Pool discovery | ~2 x (head / 5,000,000) | genesis-to-head, `--discovery-chunk-blocks` |
| Swap scan | ~(window_blocks / 500,000) x pool groups | 30 days is ~26 M blocks at 100 ms |
| State + metadata | a few batched `eth_call`s per pool and token | |
| Aggregators | 3 per token, `--api-delay` apart | ~9 min for 90 tokens at the 2 s default |

Budget **5-15 minutes** end to end, or **2-5 minutes** with `--no-cross-check`. If the endpoint caps
log ranges hard (some public nodes cap at 10,000 blocks), the swap scan halves its range until the
node accepts it and the run stretches to **30-60 minutes**; `--chunk-blocks 10000` skips the
back-off probing. Nothing is cached between runs.

### What to commit afterwards

`packages/quant/out/` is covered by the repo-wide `out/` ignore, so a run leaves nothing staged by
accident. After a **real** run:

1. **`docs/launch-constituents.md`** - always. It is the record of what was measured and why those
   30 names.
2. **`contracts/script/config/constituents.json`** - only after reading the diff. The run writes its
   candidate to `out/constituents.registry.json`; add `--write-registry-config` to write the
   contracts copy in place. A `--fixtures` run is refused there unless `--force` is also passed,
   because synthetic addresses in a deploy input are a live-fire hazard.
3. **`packages/config/src/index.ts`** - paste `out/launch-set.ts` by hand: replace the
   `launchConstituents` array, set `LAUNCH_CONSTITUENT_COUNT` to match, and keep the file's own
   doc comments. The writer never edits `packages/config` itself. `launchIndexWeightsBps` in that
   file is the vector for the single post-registration `setIndexWeights` call - registration itself
   uses `registrationWeightBps` from the JSON.
4. Re-run `pnpm --filter @amplestocks/config gen:json` and the contracts' config tests before
   pushing; `out/constituents.json` is worth attaching to the launch decision even though it is not
   tracked.

### Tests and fixtures

```bash
python -m pytest              # 114 tests, no network
ruff check src tests tools
python3 tools/generate_fixtures.py   # regenerate the synthetic cassette
```

The cassette (`src/amplestocks_quant/constituents/fixtures/cassette.json`) is **synthetic**: 24
`FX*` tokens with invented addresses, prices and volumes, generated from a fixed seed to put one
name in each corner of the model (deep-and-busy, thin-and-busy, dead, feedless, SVR-only,
corporate-action, WETH-quoted, unreadable multiplier, mid-window listing). It is not market data
and must never be treated as any. Every collector is exercised through it, so a change in decoding
or selection shows up as a test failure rather than in a launch set.

`amplestocks_quant.constituents` imports nothing outside the standard library, including its own
Keccak-256 (`hashlib.sha3_256` is NIST SHA-3, which is a different hash).

MIT licensed — see the repository root `LICENSE`.
