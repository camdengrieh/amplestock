// SPDX-License-Identifier: MIT

/**
 * The surface list, in a plain module.
 *
 * It lives here rather than next to the `<Nav />` that renders it because `nav.tsx` is a client
 * component: importing a value out of a `'use client'` module from a server component hands back a
 * client reference, not the array, and the page fails at prerender rather than at type-check.
 */
export interface Surface {
  href: string
  label: string
  blurb: string
}

export const SURFACES: readonly Surface[] = [
  {
    href: '/buy',
    label: 'Buy / Sell',
    blurb: 'AMPS against WETH or USDG, with the sell fee and the rotation-credit rule stated before you sign.',
  },
  {
    href: '/rotate',
    label: 'Rotate',
    blurb: 'Stock to stock through AMPS in one transaction, next to what the same two swaps cost separately.',
  },
  {
    href: '/bond',
    label: 'Bond',
    blurb: 'Discounted issuance against a stock token, vesting linearly. Priced at or above NAV plus a minimum accretion.',
  },
  {
    href: '/redeem',
    label: 'Redeem',
    blurb: 'Pro-rata in every asset the vault holds, less the redemption fee. Reads no oracle and cannot be paused.',
  },
  {
    href: '/stake',
    label: 'Stake',
    blurb: 'xAMPS. Pays out realised sell fees that have already been collected, streamed linearly.',
  },
  {
    href: '/vault',
    label: 'Vault',
    blurb: 'NAV, the reference price, holdings, ladder fill per pool, gate state and burn history.',
  },
  {
    href: '/governance',
    label: 'Governance',
    blurb: 'Read-only: the constituent set, the timelock queue, and every live parameter next to its hard band.',
  },
  {href: '/risk', label: 'Risk', blurb: 'What can go wrong, stated plainly. Read this first.'},
]
