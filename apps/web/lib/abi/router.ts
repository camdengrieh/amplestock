// SPDX-License-Identifier: MIT

/**
 * `AmpsRouter` — the protocol's own router, and the only address in the world whose rotation hops
 * the hook prices at the pass-through fee.
 *
 * **This file used to hold a hand transcription of the ABI**, standing in while `@amplestocks/abis`
 * still carried revision 5 and had no `AmpsRouter` artefact at all. The package has been
 * regenerated from the revision-6 artefacts, so the ABI is re-exported from it and the
 * transcription is gone: a generated ABI cannot drift from the contract, and a transcribed one can.
 * The re-export keeps `@/lib/abi/router` as the import path the rotation surface already uses, and
 * keeps it next to {routerDeadline}, which is the one thing here codegen could never produce.
 *
 * **Why a pass-through needs its own router.** The hook fixes a hop's fee in `beforeSwap`, before
 * the swap runs, so hop 1 of a route cannot know that a hop 2 follows: that is a fact about the
 * caller's intentions, not about the pool. Charging the cheap fee optimistically and refunding
 * would need the hook to hold value, which it never does; letting any caller flag any hop as
 * pass-through would make the AMPS fee voluntary. What is left is a declaration the hook can check
 * — `sender == AmpsHook.router()` **and** `hookData == Constants.ROUTER_ROTATE` — and `rotate` is
 * the only call in this contract that sets it. `buy` and `sell` pass empty `hookData` and pay
 * `ampsFeeBps` like any other swap through any other router: routing an exit through the
 * protocol's own front end must not make the exit cheaper.
 */

export {ampsRouterAbi} from '@amplestocks/abis/generated'

/** A deadline `seconds` from now, in the router's units. */
export function routerDeadline(seconds = 600, now = Math.floor(Date.now() / 1000)): bigint {
  return BigInt(now + seconds)
}
