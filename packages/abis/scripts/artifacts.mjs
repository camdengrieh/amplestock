// SPDX-License-Identifier: MIT
/**
 * Reads Foundry artefacts out of the contracts workspace and hands back one `{name, abi}` entry per
 * exported contract.
 *
 * Why this exists rather than `@wagmi/cli`'s `foundry` plugin: `contracts/foundry.toml` carries three
 * `[[profile.default.compilation_restrictions]]` blocks (`src/vault/*`, `src/bonds/*`, `src/hook/*` compile
 * through the IR pipeline at 200 optimizer runs so `AmpsVault`, `AmpsBonds` and `AmpsHook` fit EIP-170). Foundry
 * writes one artefact **per compiler profile**, so a single build leaves `Amps.json` *and* `Amps.vault.json` side
 * by side, and for a file only ever reached through a restricted profile — `IPoolManager`, which the indexer
 * needs — there is no plain `IPoolManager.json` at all, only `IPoolManager.default.json` and
 * `IPoolManager.vault.json`. The wagmi foundry plugin globs `<Name>.json` and derives the contract name from the
 * file name, so it would both miss `IPoolManager` and emit a contract called `Amps.vault`.
 *
 * This module resolves the variants itself, and asserts that every variant of a contract carries a
 * byte-identical ABI. A profile can change codegen; it must never change the interface, and if it ever does,
 * generation fails loudly instead of silently picking one.
 */
import {readdirSync, readFileSync, existsSync} from 'node:fs'
import {dirname, join, resolve} from 'node:path'
import {fileURLToPath} from 'node:url'

const here = dirname(fileURLToPath(import.meta.url))

/** `packages/abis` */
export const packageRoot = resolve(here, '..')

/** `contracts/` */
export const contractsRoot = resolve(packageRoot, '..', '..', 'contracts')

/**
 * Artefact directory, in precedence order. `out-abis` is this package's own build (see `forge-build.mjs`); it is
 * a dedicated `FOUNDRY_OUT` so codegen never races the contracts workspace's own `out/`, which CI, the gas suite
 * and four concurrent agents all write.
 */
export const OUT_DIR_CANDIDATES = ['out-abis', 'out']

/**
 * Every contract `@amplestocks/abis` exports, in the order they are emitted.
 *
 * `source` is the artefact directory Foundry writes (`<File>.sol/`), which is the *file* name, not the contract
 * name — they differ for `PoolManager`, whose ABI we take from the v4-core interface `IPoolManager` because the
 * indexer subscribes to `Initialize` / `Swap` / `ModifyLiquidity` / `Donate` on the canonical deployment and
 * never deploys one itself.
 */
export const EXPORTED_CONTRACTS = [
  {name: 'Amps', source: 'Amps', contract: 'Amps'},
  {name: 'AmpsVault', source: 'AmpsVault', contract: 'AmpsVault'},
  {name: 'AmpsHook', source: 'AmpsHook', contract: 'AmpsHook'},
  {name: 'AmpsBonds', source: 'AmpsBonds', contract: 'AmpsBonds'},
  {name: 'AmpsStaking', source: 'AmpsStaking', contract: 'AmpsStaking'},
  {name: 'BountyPot', source: 'BountyPot', contract: 'BountyPot'},
  {name: 'PoolRegistry', source: 'PoolRegistry', contract: 'PoolRegistry'},
  {name: 'PoolRegistryLens', source: 'PoolRegistryLens', contract: 'PoolRegistryLens'},
  {name: 'AmpsBondsLens', source: 'AmpsBondsLens', contract: 'AmpsBondsLens'},
  {name: 'OracleGate', source: 'OracleGate', contract: 'OracleGate'},
  {name: 'FeedRegistry', source: 'FeedRegistry', contract: 'FeedRegistry'},
  {name: 'AmpsQuoter', source: 'AmpsQuoter', contract: 'AmpsQuoter'},
  {name: 'BondPolicy', source: 'BondPolicy', contract: 'BondPolicy'},
  {name: 'FeePolicy', source: 'FeePolicy', contract: 'FeePolicy'},
  {name: 'LadderPolicy', source: 'LadderPolicy', contract: 'LadderPolicy'},
  {name: 'RolloutPolicy', source: 'RolloutPolicy', contract: 'RolloutPolicy'},
  {name: 'LadderPositionValuer', source: 'LadderPositionValuer', contract: 'LadderPositionValuer'},
  {name: 'PoolManager', source: 'IPoolManager', contract: 'IPoolManager'},
]

/** @returns {string} the absolute artefact directory to read. */
export function resolveOutDir() {
  const override = process.env.AMPS_FOUNDRY_OUT
  const candidates = override ? [override] : OUT_DIR_CANDIDATES
  for (const candidate of candidates) {
    const dir = resolve(contractsRoot, candidate)
    if (existsSync(dir)) return dir
  }
  throw new Error(
    `no Foundry artefacts found — looked for ${candidates.join(', ')} under ${contractsRoot}. ` +
      'Run `pnpm --filter @amplestocks/abis generate`, which builds them first.',
  )
}

/**
 * Resolves one contract's artefact across compiler-profile variants.
 *
 * @param {string} outDir absolute artefact root
 * @param {{name: string, source: string, contract: string}} entry
 * @returns {{abi: unknown[], files: string[]}}
 */
export function readArtifact(outDir, entry) {
  const dir = join(outDir, `${entry.source}.sol`)
  if (!existsSync(dir)) throw new Error(`missing artefact directory ${dir} for ${entry.name}`)

  // `<Contract>.json`, `<Contract>.<profile>.json`. Sorted so the result never depends on readdir order.
  const files = readdirSync(dir)
    .filter((f) => f === `${entry.contract}.json` || f.startsWith(`${entry.contract}.`))
    .filter((f) => f.endsWith('.json'))
    .sort()
  if (files.length === 0) throw new Error(`no artefact for ${entry.contract} in ${dir}`)

  let abi
  let canonical
  for (const file of files) {
    const parsed = JSON.parse(readFileSync(join(dir, file), 'utf8'))
    if (!Array.isArray(parsed.abi)) throw new Error(`${join(dir, file)} has no ABI array`)
    const serialised = JSON.stringify(parsed.abi)
    if (abi === undefined) {
      abi = parsed.abi
      canonical = serialised
    } else if (serialised !== canonical) {
      throw new Error(
        `${entry.contract} has different ABIs across compiler profiles (${files.join(', ')}). ` +
          'A compilation restriction changed the interface, which is never intended — fix foundry.toml.',
      )
    }
  }
  return {abi, files}
}

/** @returns {{name: string, abi: unknown[]}[]} every exported contract, ready for `@wagmi/cli`. */
export function loadContracts() {
  const outDir = resolveOutDir()
  return EXPORTED_CONTRACTS.map((entry) => ({name: entry.name, abi: readArtifact(outDir, entry).abi}))
}
