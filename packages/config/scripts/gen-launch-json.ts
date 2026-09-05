// SPDX-License-Identifier: MIT
/**
 * Regenerates `launch.json`, the JSON mirror of the typed exports in `src/index.ts`.
 *
 * Non-TypeScript consumers (the Foundry deploy scripts read it with `vm.readFile` + `stdJson`,
 * and `packages/quant` reads it with `json.load`) need the launch data without a TS toolchain, so
 * it is mirrored rather than duplicated. `test/launch-json.test.ts` fails if the mirror drifts.
 *
 * Run with: pnpm --filter @amplestocks/config gen:json
 */
import {writeFileSync} from 'node:fs'
import {fileURLToPath} from 'node:url'
import {dirname, join} from 'node:path'

import {jsonReplacer, launchJsonSource} from '../src/index.ts'

const here = dirname(fileURLToPath(import.meta.url))
const target = join(here, '..', 'launch.json')

writeFileSync(target, `${JSON.stringify(launchJsonSource, jsonReplacer, 2)}\n`, 'utf8')
console.log(`[config] wrote ${target}`)
