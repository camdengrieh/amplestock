// SPDX-License-Identifier: MIT
import {describe, expect, it} from 'vitest'

import {ccaAbi} from '@/lib/abi/cca'
// The indexer's copy is imported **relatively**, not through a fixture or a package: the point of
// this test is that the two hand-written transcriptions of the same upstream contract have not
// drifted, and a shared fixture would only prove that both agree with a third copy somebody could
// forget to update. There is no artefact to check either of them against — the Continuous Clearing
// Auction is a third-party contract with no Solidity source in this repository, which is exactly
// why the two files exist and exactly why they need pinning to each other.
import {continuousClearingAuctionAbi} from '../../../indexer/src/abi/external'

/** An ABI entry, narrowed to the shape both files actually write. */
type AbiInput = {readonly name: string; readonly type: string; readonly indexed?: boolean}
type AbiEvent = {readonly type: string; readonly name: string; readonly inputs: readonly AbiInput[]}

const eventsOf = (abi: readonly unknown[]): AbiEvent[] =>
  (abi as AbiEvent[]).filter((entry) => entry.type === 'event')

/** The canonical `name(type,type,…)` signature, which is what the topic hashes. */
const signatureOf = (event: AbiEvent): string => `${event.name}(${event.inputs.map((i) => i.type).join(',')})`

const webEvents = eventsOf(ccaAbi)
const indexerEvents = eventsOf(continuousClearingAuctionAbi)

describe('the two hand-written CCA ABIs', () => {
  it('declare the same five events, and only those five', () => {
    const names = webEvents.map((e) => e.name).sort()
    expect(names).toEqual(['BidExited', 'BidSubmitted', 'CheckpointUpdated', 'ClearingPriceUpdated', 'TokensClaimed'])
    expect(indexerEvents.map((e) => e.name).sort()).toEqual(names)
    // The indexer subscribes to the auctions as a factory and needs the topics and nothing else,
    // so its file is events only. If it ever grows a function, this is where that is noticed.
    expect(continuousClearingAuctionAbi).toHaveLength(5)
  })

  it('agree fragment for fragment: name, argument names, types and indexing', () => {
    for (const web of webEvents) {
      const mirror = indexerEvents.find((e) => e.name === web.name)
      expect(mirror, `${web.name} is missing from apps/indexer/src/abi/external.ts`).toBeDefined()
      // Normalised so a missing `indexed: false` cannot pass for a declared one: an event whose
      // indexing differs has a different topic layout and would decode to the wrong arguments.
      const normalise = (event: AbiEvent) => ({
        name: event.name,
        inputs: event.inputs.map((input) => ({
          name: input.name,
          type: input.type,
          indexed: input.indexed === true,
        })),
      })
      expect(normalise(web)).toEqual(normalise(mirror as AbiEvent))
    }
  })

  it('hash to the same topic, which is the only thing a node actually matches on', () => {
    const webSigs = webEvents.map(signatureOf).sort()
    const indexerSigs = indexerEvents.map(signatureOf).sort()
    expect(webSigs).toEqual(indexerSigs)
  })

  it('keeps ClearingPriceUpdated in both, because the indexer now subscribes to it', () => {
    // Revision 8 subscribes the indexer to `ClearingPriceUpdated` as well as `CheckpointUpdated`,
    // so the clearing-price series is dense rather than one point per paid checkpoint. A fragment
    // that existed in only one of the two files would have made that subscription silently dead.
    const web = webEvents.find((e) => e.name === 'ClearingPriceUpdated')
    const indexer = indexerEvents.find((e) => e.name === 'ClearingPriceUpdated')
    expect(signatureOf(web as AbiEvent)).toBe('ClearingPriceUpdated(uint256,uint256)')
    expect(signatureOf(indexer as AbiEvent)).toBe('ClearingPriceUpdated(uint256,uint256)')
    // No indexed argument on either: the whole payload is in the data word.
    expect((web as AbiEvent).inputs.every((i) => i.indexed !== true)).toBe(true)
  })

  it('keeps the argument names the handlers read off the decoded log', () => {
    // `handlers/genesis.ts` reads `event.args.id`, `.priceQ96`, `.amount`, `.clearingPriceQ96`,
    // `.cumulativeMps`, `.bidId`, `.tokensFilled`, `.currencyRefunded`. A rename on either side is
    // a silent `undefined` in a row the dApp then renders, so the names are part of the contract.
    const named = (abi: AbiEvent[], name: string) => abi.find((e) => e.name === name)?.inputs.map((i) => i.name)
    for (const [event, args] of [
      ['BidSubmitted', ['id', 'owner', 'priceQ96', 'amount']],
      ['CheckpointUpdated', ['blockNumber', 'clearingPriceQ96', 'cumulativeMps']],
      ['ClearingPriceUpdated', ['blockNumber', 'clearingPriceQ96']],
      ['BidExited', ['bidId', 'owner', 'tokensFilled', 'currencyRefunded']],
      ['TokensClaimed', ['bidId', 'owner', 'tokensFilled']],
    ] as const) {
      expect(named(webEvents, event), `${event} (web)`).toEqual([...args])
      expect(named(indexerEvents, event), `${event} (indexer)`).toEqual([...args])
    }
  })
})
