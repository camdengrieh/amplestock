// SPDX-License-Identifier: MIT

/**
 * The surface list, in a plain module.
 *
 * It lives here rather than next to the `<Nav />` that renders it because `nav.tsx` is a client
 * component: importing a value out of a `'use client'` module from a server component hands back a
 * client reference, not the array, and the page fails at prerender rather than at type-check.
 *
 * There is no Stake surface. Revision 6 removes staking: there is no xAMPS, no staker slice of the
 * fee and no reward stream. Auction leads the list because it is the one surface with a beginning
 * and an end — it sells the genesis tranche and is then finished.
 */
export interface Surface {
  href: string
  label: string
  /** The mono kicker above the page title. */
  kicker: string
  blurb: string
}

export const SURFACES: readonly Surface[] = [
  {
    href: '/auction',
    label: 'Auction',
    kicker: 'Genesis',
    blurb:
      'The two Continuous Clearing Auctions that sold half the supply and set the launch reference price. One uniform clearing price per leg, and a full refund from a leg that does not graduate.',
  },
  {
    href: '/buy',
    label: 'Buy / Sell',
    kicker: 'Entry',
    blurb:
      'AMPS against WETH or USDG. The AMPS fee is charged in both directions and is stated before you sign, not after.',
  },
  {
    href: '/rotate',
    label: 'Rotate',
    kicker: 'Pass-through',
    blurb:
      'Stock to stock through AMPS in one transaction, through the protocol’s own router — the only route that can prove the round trip.',
  },
  {
    href: '/bond',
    label: 'Bond',
    kicker: 'Issuance',
    blurb:
      'Discounted issuance against a stock token, vesting linearly. Priced at or above NAV plus a minimum accretion.',
  },
  {
    href: '/redeem',
    label: 'Redeem',
    kicker: 'The floor',
    blurb: 'Pro-rata in every asset the vault holds, less the redemption fee. Reads no oracle and cannot be paused.',
  },
  {
    href: '/vault',
    label: 'Vault',
    kicker: 'Disclosure',
    blurb: 'NAV, the reference price, holdings and weights, ladder fill per pool, gate state and every burn.',
  },
  {
    href: '/governance',
    label: 'Governance',
    kicker: 'Read-only',
    blurb: 'The constituent set, the timelock queue, and every live parameter next to its hard band.',
  },
  {
    href: '/docs',
    label: 'Docs',
    kicker: 'Reference',
    blurb: 'How the thing works, with every figure read from the chain rather than written down.',
  },
  {
    href: '/risk',
    label: 'Risk',
    kicker: 'Read first',
    blurb: 'What can go wrong, stated plainly.',
  },
]
