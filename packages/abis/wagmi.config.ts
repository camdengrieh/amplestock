// SPDX-License-Identifier: MIT
import {defineConfig} from '@wagmi/cli'
import {foundry} from '@wagmi/cli/plugins'

/**
 * Codegen for the Amplestocks contract ABIs.
 *
 * Reads Foundry artifacts from `contracts/out` — it never invokes `forge` itself, so a build must
 * already exist (`pnpm --filter @amplestocks/contracts build`). Nothing generated is committed
 * while `contracts/src` is still empty; run `pnpm --filter @amplestocks/abis generate` once the
 * production contracts land.
 */
export default defineConfig({
  out: 'src/generated.ts',
  plugins: [
    foundry({
      project: '../../contracts',
      artifacts: 'out',
      // The contracts workspace owns its own build; do not let the CLI shell out to forge.
      forge: {clean: false, build: false, rebuild: false},
      include: [
        'Amps.json',
        'Amps*.json',
        'AmpsVault*.json',
        'AmpsHook*.json',
        'AmpsBonds*.json',
        'AmpsStaking*.json',
        'AmpsQuoter*.json',
        'PoolRegistry*.json',
      ],
    }),
  ],
})
