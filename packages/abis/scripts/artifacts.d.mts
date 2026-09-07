// SPDX-License-Identifier: MIT
// Hand-written declarations for `artifacts.mjs`. The loader is plain ESM JavaScript so the `@wagmi/cli` config
// loader can import it without a transpile step; this is what keeps `tsc --noEmit` honest about it.
import type {Abi} from 'abitype'

export interface ExportedContract {
  readonly name: string
  readonly source: string
  readonly contract: string
}

export declare const packageRoot: string
export declare const contractsRoot: string
export declare const OUT_DIR_CANDIDATES: readonly string[]
export declare const EXPORTED_CONTRACTS: readonly ExportedContract[]
export declare function resolveOutDir(): string
export declare function readArtifact(outDir: string, entry: ExportedContract): {abi: Abi; files: string[]}
export declare function loadContracts(): {name: string; abi: Abi}[]
