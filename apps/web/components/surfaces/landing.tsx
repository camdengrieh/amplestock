// SPDX-License-Identifier: MIT
'use client'

import Link from 'next/link'
import * as React from 'react'
import {useReadContract} from 'wagmi'
import type {Address} from 'viem'

import {AssetMark, Inverted, Kicker, RowGroup, SectionHead, StatBand, StatCell, Step} from '@/components/ledger/primitives'
import {Value} from '@/components/common/value'
import {Table, TableBody, TableCell, TableHead, TableHeader, TableRow} from '@/components/ui/table'
import {useIndexerQuery} from '@/hooks/use-indexer'
import {symbolForCounter, usePoolDirectory} from '@/hooks/use-pools'
import {usePolAmounts} from '@/hooks/use-pol'
import {useActiveConstituents, useConstituentRecords, useRegistrySummary} from '@/hooks/use-registry'
import {useCreatorBps, useLadderLengths, useVaultSnapshot} from '@/hooks/use-vault'
import {contract} from '@/lib/contracts'
import {LANDING_COPY} from '@/lib/copy'
import {formatAmount, formatBps, formatPremiumX18, formatUsd18} from '@/lib/format'

/**
 * The landing page, built to the design's `Landing` screen.
 *
 * Structure, in the design's order: a sticky header (in `layout/shell.tsx`), a four-column ticker
 * strip, a two-column hero with the NAV panel beside the headline, three pillars, the holdings grid,
 * an **inverted** section for the floor, "how NAV grows" with its numbered loop and the ladder
 * table, "by the numbers", and the footer.
 *
 * The design's own figures are illustrative. Every one of them here is a live read or an explicit
 * dash — including the constituent grid, whose value line is the realised index weight rather than a
 * USD amount, because the vault publishes weights and this app has no per-constituent USD read that
 * is not a multiplication of two other numbers. `design/ledger/ledger.md` §4 records that.
 */
export function LandingSurface() {
  const now = Math.floor(Date.now() / 1000)
  const vault = useVaultSnapshot()
  const creator = useCreatorBps(now)
  const registry = useRegistrySummary()
  const active = useActiveConstituents()
  const ids = React.useMemo(() => (active.ids ?? []).map(Number), [active.ids])
  const constituents = useConstituentRecords(ids)
  const {pools} = usePoolDirectory()
  const poolIds = React.useMemo(() => pools.map((p) => p.poolId), [pools])
  const pol = usePolAmounts(poolIds)
  const ladderLengths = useLadderLengths(poolIds)
  const navHistory = useIndexerQuery(['nav-history'], (client) => client.navHistory({limit: 200}))

  const ampsToken = contract('amps')
  const supply = useReadContract({
    ...(ampsToken ?? {address: undefined as unknown as Address, abi: [] as never}),
    functionName: 'totalSupply',
    query: {enabled: ampsToken !== undefined},
  })

  const checkpoint = vault.checkpoint
  const premiumX18 =
    checkpoint && checkpoint.navPerShareX18 > 0n
      ? (checkpoint.pRefX18 * 10n ** 18n) / checkpoint.navPerShareX18 - 10n ** 18n
      : undefined

  const nav = checkpoint ? formatUsd18(checkpoint.navPerShareX18, 4) : undefined
  const market = checkpoint && checkpoint.pMktX18 > 0n ? formatUsd18(checkpoint.pMktX18, 4) : undefined
  const premium = premiumX18 !== undefined ? formatPremiumX18(premiumX18) : undefined
  const assets = vault.totalAssetsUsd18 !== undefined ? formatUsd18(vault.totalAssetsUsd18) : undefined

  // The bar is the target weight against the largest target weight, so the widest bar is the
  // heaviest name rather than an arbitrary hundred per cent.
  const maxTarget = constituents.records.reduce((max, r) => Math.max(max, r.targetWeightBps), 0)

  return (
    <div data-testid="landing-surface">
      {/* --- The ticker strip ------------------------------------------------------------- */}
      <div className="overflow-hidden border-b border-rule">
        <div className="mx-auto grid w-full max-w-[1200px] grid-cols-2 px-5 sm:px-7 lg:grid-cols-4">
          {[
            {k: 'NAV / share', v: nav, reason: 'The vault checkpoint could not be read'},
            {k: 'Market', v: market, reason: 'Not enough observation history yet'},
            {k: 'Premium', v: premium, reason: 'The vault checkpoint could not be read'},
            {k: 'Vault assets', v: assets, reason: 'The vault could not be read'},
          ].map((t) => (
            <div key={t.k} className="flex items-baseline gap-2.5 border-r border-hair py-3 pr-[18px] last:border-r-0">
              <span className="ledger-micro whitespace-nowrap">{t.k}</span>
              <span className="ml-auto text-[19px] tabular-nums">
                <Value unavailable={t.v === undefined} reason={t.reason}>
                  {t.v}
                </Value>
              </span>
            </div>
          ))}
        </div>
      </div>

      {/* --- Hero -------------------------------------------------------------------------- */}
      <section className="mx-auto grid w-full max-w-[1200px] items-end gap-x-16 gap-y-12 px-5 pb-16 pt-[76px] sm:px-7 lg:grid-cols-[minmax(0,1.35fr)_minmax(0,1fr)]">
        <div>
          <Kicker className="mb-6">A NAV-floored index share</Kicker>
          <h1 className="ledger-hero">
            One share.
            <br />
            Thirty companies.
            <br />
            <em className="font-light italic">A floor you can always take.</em>
          </h1>
          <p className="mt-8 max-w-[54ch] text-[20px] leading-[1.5]">{LANDING_COPY.lede}</p>
          <div className="mt-[34px] flex flex-wrap gap-3">
            <Link
              href="/buy"
              className="border border-ink bg-fill px-[26px] py-[13px] font-mono text-[10px] uppercase tracking-[0.16em] text-onfill transition-opacity hover:opacity-[0.82]"
            >
              Buy AMPS
            </Link>
            <a
              href="#floor"
              className="border border-ink px-[26px] py-[13px] font-mono text-[10px] uppercase tracking-[0.16em] transition-colors hover:bg-fill hover:text-onfill"
            >
              How the floor works
            </a>
          </div>
        </div>

        <div className="border-t-2 border-ink pt-[18px]">
          <p className="ledger-label">NAV per share</p>
          <p className="ledger-hero-stat mt-1.5">
            <Value unavailable={nav === undefined} reason="The vault checkpoint could not be read">
              {nav}
            </Value>
          </p>
          <p className="mt-4 text-[16px] leading-[1.5] text-dim">
            The vault’s own accounting of what it holds, per share. Recomputed from live balances by anyone who pays the
            gas.
          </p>
          <div className="mt-[22px] border-t border-rule">
            {[
              {k: 'Market price', v: market, reason: 'Not enough observation history yet'},
              {k: 'Premium to NAV', v: premium, reason: 'The vault checkpoint could not be read'},
              {
                k: 'Redemption fee',
                v: vault.redeemFeeBps !== undefined ? formatBps(vault.redeemFeeBps) : undefined,
                reason: 'The vault could not be read',
              },
            ].map((r) => (
              <div key={r.k} className="flex items-baseline justify-between gap-4 border-b border-hair py-[9px]">
                <span className="font-mono text-[10px] uppercase tracking-[0.12em] text-dim">{r.k}</span>
                <span className="text-[17px] tabular-nums">
                  <Value unavailable={r.v === undefined} reason={r.reason}>
                    {r.v}
                  </Value>
                </span>
              </div>
            ))}
          </div>
        </div>
      </section>

      {/* --- Three pillars ----------------------------------------------------------------- */}
      <section className="border-y border-ink border-b-rule">
        <div className="mx-auto grid w-full max-w-[1200px] px-5 sm:px-7 lg:grid-cols-3">
          {LANDING_COPY.pillars.map((p) => (
            <div key={p.n} className="border-r border-hair py-11 pr-[34px] last:border-r-0">
              <Kicker className="mb-3.5">{p.n}</Kicker>
              <h2 className="mb-3 text-[30px] font-normal leading-[1.1] tracking-[-0.02em]">{p.h}</h2>
              <p className="text-[17px] leading-[1.55] text-dim">{p.b}</p>
            </div>
          ))}
        </div>
      </section>

      {/* --- Holdings ---------------------------------------------------------------------- */}
      <section id="holdings" className="mx-auto w-full max-w-[1200px] scroll-mt-24 px-5 py-[72px] sm:px-7">
        <SectionHead
          kicker="Thirty Uniswap v4 positions"
          title="What the vault holds"
          className="[&_h2]:ledger-section-title"
          aside={
            <span>
              <Value unavailable={registry.poolCount === undefined}>
                {registry.poolCount !== undefined ? `${registry.poolCount} pools` : null}
              </Value>
            </span>
          }
        />
        <p className="mt-4 max-w-[46ch] text-[16px] leading-[1.5] text-dim">
          Not a wallet of tokens sitting still. Every holding <em>is</em> a concentrated-liquidity position in that
          stock’s own AMPS pool — quoting a two-sided market and taking the fee on every trade that crosses it.
        </p>

        {constituents.records.length === 0 ? (
          <p className="mt-7 border-t border-rule pt-5 text-[15px] text-dim" data-testid="landing-holdings-empty">
            The registry has not answered on this chain, so there is nothing to list. Weights are read from
            <code className="mx-1 font-mono text-[13px]">PoolRegistry</code>, never written down here.
          </p>
        ) : (
          <div
            className="mt-7 grid border-l border-t border-hair"
            style={{gridTemplateColumns: 'repeat(auto-fill, minmax(148px, 1fr))'}}
            data-testid="landing-holdings"
          >
            {constituents.records.map((c) => {
              const symbol = symbolForCounter(c.token)
              const bar = maxTarget > 0 ? Math.round((c.targetWeightBps / maxTarget) * 100) : 0
              return (
                <div
                  key={c.id}
                  className="flex min-h-[112px] flex-col gap-3 border-b border-r border-hair px-3.5 pb-3.5 pt-4 transition-colors hover:bg-hair"
                >
                  <div className="flex h-[30px] items-center">
                    <AssetMark symbol={symbol} size={30} />
                  </div>
                  <div className="mt-auto">
                    <div className="font-mono text-[12px] tracking-[0.06em]">{symbol}</div>
                    <div className="mt-0.5 text-[17px] tabular-nums">
                      <Value
                        unavailable={c.currentWeightBps === undefined}
                        reason="The registry could not price this constituent"
                      >
                        {c.currentWeightBps !== undefined ? formatBps(c.currentWeightBps) : null}
                      </Value>
                    </div>
                    <div className="text-[14px] tabular-nums text-dim">{formatBps(c.targetWeightBps)} target</div>
                  </div>
                  <div className="h-0.5 bg-rule">
                    <div className="h-0.5 bg-ink" style={{width: `${bar}%`}} />
                  </div>
                </div>
              )
            })}
          </div>
        )}
        <p className="mt-4 max-w-[88ch] text-[13px] leading-[1.55] text-dim">
          Upper figure = realised index weight, read from{' '}
          <code className="font-mono">PoolRegistry.currentWeightBps</code>. Lower figure and bar = the target weight
          governance set. They differ because the rollout moves inventory on a daily cap.
        </p>

        {/* What NAV is made of */}
        <div className="mt-14 grid gap-14 lg:grid-cols-[minmax(0,0.7fr)_minmax(0,1.3fr)]">
          <div>
            <h3 className="text-[30px] font-light leading-[1.1] tracking-[-0.025em]">What NAV is made of</h3>
            <p className="mt-4 text-[16px] leading-[1.55] text-dim">
              Assets are marked from live balances at the reference price. The AMPS the vault is holding as ask inventory
              is deliberately not among them.
            </p>
          </div>
          <RowGroup rule="ink">
            {[
              {
                k: 'Assets the vault holds',
                v: assets,
                b: 'Marked from live balances at the reference price, across every line in the vault.',
                reason: 'The vault could not be read',
              },
              {
                k: 'Distinct assets',
                v: vault.assetCount !== undefined ? String(vault.assetCount) : undefined,
                b: 'Every one of them is paid out pro rata on redemption. No netting, no substitution.',
                reason: 'The vault could not be read',
              },
              {
                k: 'AMPS ask inventory',
                v: vault.inventoryAmps !== undefined ? `${formatAmount(vault.inventoryAmps, 18)} AMPS` : undefined,
                b: 'Across every pool. Not an asset and not counted in NAV. Finite, never minted, burned rather than re-placed when bought back.',
                reason: 'The vault could not be read',
              },
              {
                k: 'Live ladder cells',
                v: vault.liveCells !== undefined ? String(vault.liveCells) : undefined,
                b: 'The count that bounds the gas of a redemption, which is why it is capped in the contract.',
                reason: 'The vault could not be read',
              },
            ].map((r) => (
              <div key={r.k} className="border-b border-hair py-4">
                <div className="flex items-baseline justify-between gap-4">
                  <span className="text-[19px]">{r.k}</span>
                  <span className="font-mono text-[16px] tabular-nums">
                    <Value unavailable={r.v === undefined} reason={r.reason}>
                      {r.v}
                    </Value>
                  </span>
                </div>
                <div className="mt-1 text-[15px] leading-[1.5] text-dim">{r.b}</div>
              </div>
            ))}
          </RowGroup>
        </div>
      </section>

      {/* --- The floor, inverted ----------------------------------------------------------- */}
      <Inverted id="floor" className="scroll-mt-24 border-t border-ink">
        <div className="mx-auto grid w-full max-w-[1200px] gap-x-16 gap-y-12 px-5 py-[76px] sm:px-7 lg:grid-cols-[minmax(0,1fr)_minmax(0,1.1fr)]">
          <div>
            <p className="mb-5 font-mono text-[10px] uppercase tracking-[0.18em] opacity-60">The floor</p>
            <h2 className="text-[clamp(2.25rem,4.4vw,3.75rem)] font-light leading-[1.02] tracking-[-0.03em]">
              Redemption pays assets, not a price.
            </h2>
            <p className="mt-[26px] max-w-[46ch] text-[19px] leading-[1.5] opacity-90">
              Burn your AMPS and the vault sends you a pro-rata slice of every asset it holds — every stock token, every
              idle balance, every position — less the redemption fee, which is{' '}
              <span className="tabular-nums">
                <Value
                  unavailable={vault.redeemFeeBps === undefined}
                  reason="The vault could not be read"
                  className="opacity-70"
                >
                  {vault.redeemFeeBps !== undefined ? formatBps(vault.redeemFeeBps) : null}
                </Value>
              </span>{' '}
              right now and is read from the vault every time this page loads. The code path reads no price feed,
              consults no gate, and cannot be paused by governance, the guardian or the timelock.
            </p>
            <p className="mt-5 max-w-[46ch] text-[16px] leading-[1.55] opacity-60">
              What it does not do is pay you a price. Their market value is whatever those assets are worth when you
              sell them, which may be less than the NAV shown when you redeemed.
            </p>
          </div>
          <div>
            <div className="border-y border-onfill-rule py-1.5">
              {LANDING_COPY.floorSteps.map((s) => (
                <Step key={s.n} n={s.n} head={s.h} body={s.b} tone="onfill" />
              ))}
            </div>
            <p className="mt-[18px] font-mono text-[10px] uppercase tracking-[0.1em] opacity-50">
              One dependency it cannot survive: the chain not producing blocks. Disclosed, not argued away.
            </p>
          </div>
        </div>
      </Inverted>

      {/* --- How NAV grows ----------------------------------------------------------------- */}
      <section id="growth" className="mx-auto w-full max-w-[1200px] scroll-mt-24 px-5 pb-16 pt-[72px] sm:px-7">
        <SectionHead
          kicker="Uniswap v4 · concentrated liquidity"
          title="How NAV grows"
          className="[&_h2]:ledger-section-title"
        />
        <p className="mt-4 max-w-[46ch] text-[16px] leading-[1.5] text-dim">
          The vault is the market maker. Every AMPS trade crosses a concentrated-liquidity range the protocol owns, and
          the fee it pays lands in the vault — not with an outside liquidity provider.
        </p>

        <StatBand rule="none" min={210} className="mt-7">
          <StatCell
            label="Pools running a ladder"
            size="big"
            note="Uniswap v4, every one protocol-owned."
          >
            <Value unavailable={registry.poolCount === undefined} reason="The registry could not be read">
              {registry.poolCount !== undefined ? String(registry.poolCount) : null}
            </Value>
          </StatCell>
          <StatCell label="Live ladder cells" size="big" note="Placed once, and only ever removed — never re-centred.">
            <Value unavailable={vault.liveCells === undefined} reason="The vault could not be read">
              {vault.liveCells !== undefined ? String(vault.liveCells) : null}
            </Value>
          </StatCell>
          <StatCell
            label="Fees earned, 30 days"
            size="big"
            note="Swap fees paid to the vault’s own positions. Served by the indexer."
          >
            <Value unavailable reason={navHistory.configured ? 'The indexer did not answer' : 'No indexer configured'} />
          </StatCell>
          <StatCell
            label="NAV per share, 30 days"
            size="big"
            note="From fees and asset moves. Bonds and redemptions both raise it."
          >
            <Value unavailable reason={navHistory.configured ? 'The indexer did not answer' : 'No indexer configured'} />
          </StatCell>
        </StatBand>

        <div className="mt-[52px] grid gap-14 lg:grid-cols-[minmax(0,1.15fr)_minmax(0,0.85fr)]">
          <div>
            <p className="ledger-label mb-1">The loop</p>
            <div className="border-t border-ink">
              {LANDING_COPY.feeFlow.map((s) => (
                <Step key={s.n} n={s.n} head={s.h} body={s.b} />
              ))}
            </div>
          </div>
          <div>
            <p className="ledger-label mb-1">Where each fee goes</p>
            <div className="border-t border-ink">
              <div className="border-b border-hair py-4">
                <div className="flex items-baseline justify-between gap-4">
                  <span className="text-[18px]">Creator slice</span>
                  <span className="font-mono text-[16px] tabular-nums">
                    <Value unavailable={creator.creatorBps === undefined} reason="The vault could not be read">
                      {creator.creatorBps !== undefined ? formatBps(creator.creatorBps) : null}
                    </Value>
                  </span>
                </div>
                <div className="mt-1 text-[14px] leading-[1.5] text-dim">
                  Of trade volume, decaying to exactly zero at day 30. Immutable schedule with no setter.
                </div>
              </div>
              {LANDING_COPY.feeSplit.map((r) => (
                <div key={r.k} className="border-b border-hair py-4">
                  <div className="flex items-baseline justify-between gap-4">
                    <span className="text-[18px]">{r.k}</span>
                    <span className="font-mono text-[16px]">{r.v}</span>
                  </div>
                  <div className="mt-1 text-[14px] leading-[1.5] text-dim">{r.b}</div>
                </div>
              ))}
            </div>
            <p className="mt-[18px] text-[15px] leading-[1.55] text-dim">
              Ladders are static. A cell is placed once and only ever removed by a redemption, the daily rollout, a
              high-water buyback burn or a migration — nothing is re-centred or re-widened, so what a cell has taken is a
              real measure of what the market bought.
            </p>
          </div>
        </div>

        {/* The ladders */}
        <div className="mt-[52px]">
          <SectionHead
            title="The ladders, pool by pool"
            aside={
              <span>
                <Value unavailable={pools.length === 0}>{pools.length > 0 ? `${pools.length} pools` : null}</Value>
              </span>
            }
          />
          {pools.length === 0 ? (
            <p className="mt-5 text-[15px] text-dim">
              The quoter has not answered on this chain, so there are no pools to list.
            </p>
          ) : (
            <Table className="mt-1">
              <TableHeader>
                <TableRow>
                  <TableHead>Pool</TableHead>
                  <TableHead align="right">Bid depth</TableHead>
                  <TableHead align="right">Ask inventory</TableHead>
                  <TableHead align="right">Cells</TableHead>
                  <TableHead align="right">Gate</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {pools.map((pool) => {
                  const amounts = pol.amounts.get(pool.poolId)
                  const cells = ladderLengths.lengths.get(pool.poolId)
                  const decimals = pool.symbol === 'USDG' || pool.symbol === 'USDC' ? 6 : 18
                  return (
                    <TableRow key={pool.poolId}>
                      <TableCell>
                        <span className="flex items-center gap-3">
                          <AssetMark symbol={pool.symbol} />
                          <span className="whitespace-nowrap tracking-[0.05em]">AMPS / {pool.symbol}</span>
                        </span>
                      </TableCell>
                      <TableCell align="right">
                        <Value unavailable={amounts === undefined} reason="The valuer could not price this pool">
                          {amounts ? `${formatAmount(amounts.counter, decimals)} ${pool.symbol}` : null}
                        </Value>
                      </TableCell>
                      <TableCell align="right" className="text-dim">
                        <Value unavailable={amounts === undefined} reason="The valuer could not price this pool">
                          {amounts ? formatAmount(amounts.amps, 18) : null}
                        </Value>
                      </TableCell>
                      <TableCell align="right" className="text-dim">
                        <Value unavailable={cells === undefined}>{cells !== undefined ? String(cells) : null}</Value>
                      </TableCell>
                      <TableCell align="right" className="text-[10px] tracking-[0.1em]">
                        {pool.quote.degraded !== 0 ? 'DEGRADED' : pool.quote.gateState === 0 ? 'OK' : 'GATED'}
                      </TableCell>
                    </TableRow>
                  )
                })}
              </TableBody>
            </Table>
          )}
          <p className="mt-4 max-w-[88ch] text-[13px] leading-[1.55] text-dim">
            Bid depth is the counter asset the vault holds in that pool’s ranges — and because every pool is
            protocol-owned, it is also the entire bid under AMPS there. Ask inventory is AMPS: finite, never minted, and
            not an asset. A pool the valuer could not price is shown as unavailable, never as zero. The cell-by-cell
            fill and the fees each cell has earned are served by the indexer and appear on the Vault surface.
          </p>
        </div>
      </section>

      {/* --- By the numbers ---------------------------------------------------------------- */}
      <section id="numbers" className="mx-auto w-full max-w-[1200px] scroll-mt-24 px-5 py-[72px] sm:px-7">
        <h2 className="ledger-section-title mb-7 border-b-2 border-ink pb-4">By the numbers</h2>
        <StatBand rule="none" min={180}>
          <StatCell label="Vault assets" size="big" note="Marked from live balances at the reference price.">
            <Value unavailable={assets === undefined} reason="The vault could not be read">
              {assets}
            </Value>
          </StatCell>
          <StatCell label="Constituents" size="big" note="Changed only through a seven-day timelock.">
            <Value unavailable={registry.activeConstituentCount === undefined} reason="The registry could not be read">
              {registry.activeConstituentCount !== undefined ? String(registry.activeConstituentCount) : null}
            </Value>
          </StatCell>
          <StatCell label="Pools" size="big" note="Every one of them protocol-owned.">
            <Value unavailable={registry.poolCount === undefined} reason="The registry could not be read">
              {registry.poolCount !== undefined ? String(registry.poolCount) : null}
            </Value>
          </StatCell>
          <StatCell
            label="Redemption fee"
            size="big"
            note="Read from the vault on every load. The ceiling is hardcoded and cannot be widened."
          >
            <Value unavailable={vault.redeemFeeBps === undefined} reason="The vault could not be read">
              {vault.redeemFeeBps !== undefined ? formatBps(vault.redeemFeeBps) : null}
            </Value>
          </StatCell>
          <StatCell label="AMPS supply" size="big" note="Minted only by the bond shell. No other route exists.">
            <Value unavailable={supply.data === undefined} reason="The token could not be read">
              {supply.data !== undefined ? formatAmount(supply.data as bigint, 18) : null}
            </Value>
          </StatCell>
          <StatCell
            label="Public LP tier"
            size="big"
            note="And there will not be one. The vault is the only entity placing liquidity."
          >
            None
          </StatCell>
        </StatBand>
      </section>
    </div>
  )
}
