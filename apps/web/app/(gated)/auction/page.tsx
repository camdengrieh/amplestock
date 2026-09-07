// SPDX-License-Identifier: MIT
import {AuctionSurface} from '@/components/surfaces/auction'

export const metadata = {
  title: 'Auction — Amplestocks',
  description: 'The genesis Continuous Clearing Auction: one uniform clearing price, and a full refund if it does not graduate.',
}

export default function AuctionPage() {
  return <AuctionSurface />
}
