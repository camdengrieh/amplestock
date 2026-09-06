<!-- SPDX-License-Identifier: MIT -->

# The end-to-end suite

`AMPS_E2E=1 pnpm --filter @amplestocks/indexer test:e2e`

Starts a local `anvil`, deploys the whole Amplestocks system onto it through
`test/contracts/AmpsE2E.s.sol`, drives genesis, a buy, a sell, a bond, a compound, a redemption and
a simulated beacon-level `blockAccounts` call, then runs this indexer over the result and asserts
the Phase 5 exit criterion: the indexed NAV/share and `P_ref` reconcile with the on-chain reads at
every block inside the dust bound, and the denylist alarm fires within one block.

Skipped unless `AMPS_E2E=1` **and** a Foundry toolchain is on disk, so `pnpm test` stays offline and
CI's `node` job needs neither `anvil` nor `forge`.

Everything is localhost. Nothing here reaches the network.
