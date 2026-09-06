// SPDX-License-Identifier: MIT
/**
 * Prepends the licence header and the do-not-edit banner to the `@wagmi/cli` output.
 *
 * The CLI has no banner option and every other source file in the repository carries an SPDX line, so codegen
 * adds one here rather than leaving the largest file in the workspace as the single exception. Idempotent: run
 * it twice and the file is unchanged, which is what lets `generate` be re-run safely.
 */
import {readFileSync, writeFileSync} from 'node:fs'
import {resolve} from 'node:path'
import {packageRoot, EXPORTED_CONTRACTS} from './artifacts.mjs'

const target = resolve(packageRoot, 'src/generated.ts')
const banner = `// SPDX-License-Identifier: MIT
//
// GENERATED FILE — DO NOT EDIT.
//
// Produced by \`pnpm --filter @amplestocks/abis generate\`, which runs
// \`FOUNDRY_OUT=out-abis FOUNDRY_CACHE_PATH=cache-abis forge build --skip test --skip script\` in \`contracts/\`
// and then \`wagmi generate\` against \`wagmi.config.ts\`. It is committed on purpose: the indexer, the dApp and
// the keeper consume it as ordinary TypeScript, so a checkout without a Foundry toolchain still typechecks.
//
// ${EXPORTED_CONTRACTS.length} contracts exported. Regenerate after any change to \`contracts/src/**\`.
`

const body = readFileSync(target, 'utf8')
const marker = body.indexOf('//////')
if (marker === -1) throw new Error('src/generated.ts does not look like wagmi CLI output')
writeFileSync(target, `${banner}${body.slice(marker)}`)
console.log(`[abis] banner written to src/generated.ts (${EXPORTED_CONTRACTS.length} contracts)`)
