// SPDX-License-Identifier: MIT
import {LandingSurface} from '@/components/surfaces/landing'

export const metadata = {
  title: 'Amplestocks — one share, thirty companies',
  description:
    'A NAV-floored index share on Robinhood Chain: thirty Uniswap v4 positions in tokenised equities, and a redemption path with no oracle and no pause.',
}

export default function HomePage() {
  return <LandingSurface />
}
