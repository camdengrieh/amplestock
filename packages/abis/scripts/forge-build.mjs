// SPDX-License-Identifier: MIT
/**
 * Builds the contracts workspace into a codegen-private artefact directory.
 *
 * `FOUNDRY_OUT=out-abis FOUNDRY_CACHE_PATH=cache-abis` keeps this build off `contracts/out`, which CI, the gas
 * suite and the invariant campaigns all write; both are covered by the repository `.gitignore`'s
 * `contracts/out-<name>` and `contracts/cache-<name>` rules. `--skip test --skip script` is the whole difference
 * between a one-minute codegen build and a ten-minute one: nothing under `test/` or `script/` is exported.
 */
import {spawnSync} from 'node:child_process'
import {contractsRoot} from './artifacts.mjs'

const forge = process.env.FORGE_BIN ?? 'forge'
const result = spawnSync(forge, ['build', '--skip', 'test', '--skip', 'script'], {
  cwd: contractsRoot,
  stdio: 'inherit',
  env: {...process.env, FOUNDRY_OUT: 'out-abis', FOUNDRY_CACHE_PATH: 'cache-abis'},
})

if (result.error) {
  console.error(`[abis] could not run \`${forge}\`: ${result.error.message}`)
  console.error('[abis] install Foundry 1.8.1, or set FORGE_BIN to its path.')
  process.exit(1)
}
process.exit(result.status ?? 1)
