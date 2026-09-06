// SPDX-License-Identifier: MIT
import {defineConfig} from '@wagmi/cli'
import {loadContracts} from './scripts/artifacts.mjs'

/**
 * Codegen for the Amplestocks contract ABIs.
 *
 * Run it with `pnpm --filter @amplestocks/abis generate`, which builds `contracts/` into `out-abis` first and
 * then invokes this. The output, `src/generated.ts`, is **committed**: every other workspace package consumes it
 * as ordinary TypeScript, so a checkout with no Foundry toolchain still typechecks, builds and tests.
 *
 * The contract list is not a glob. It is the explicit export set in `scripts/artifacts.mjs`, resolved across
 * Foundry's per-compiler-profile artefact variants — see the note at the top of that file for why the
 * `@wagmi/cli` `foundry` plugin cannot be pointed at this project directly.
 */
export default defineConfig({
  out: 'src/generated.ts',
  contracts: loadContracts(),
})
