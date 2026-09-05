// SPDX-License-Identifier: MIT

/**
 * Re-exports the wagmi CLI output.
 *
 * `src/generated.ts` is produced by `pnpm generate` from `contracts/out` and is deliberately not
 * committed: `contracts/src` is empty at Phase 1, so there is nothing to generate yet. Once the
 * production contracts exist this file becomes `export * from './generated.js'`.
 */
export const GENERATED = false as const
