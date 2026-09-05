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

MIT licensed — see the repository root `LICENSE`.
