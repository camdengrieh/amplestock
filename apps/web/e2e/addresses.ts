// SPDX-License-Identifier: MIT

/**
 * The deployment the end-to-end run pretends exists.
 *
 * Obvious placeholders, all lower case (EIP-55 treats an unmixed-case address as unchecksummed,
 * which is what viem's `isAddress` accepts), never real addresses: a smoke test that starts asserting against
 * `@amplestocks/config`'s reference data would fail for the wrong reason the moment Phase 0
 * re-verifies it on chain.
 */
export const E2E = {
  amps: '0x00000000000000000000000000000000000a0001',
  vault: '0x00000000000000000000000000000000000a0002',
  quoter: '0x00000000000000000000000000000000000a0003',
  bonds: '0x00000000000000000000000000000000000a0004',
  bondsLens: '0x00000000000000000000000000000000000a0005',
  staking: '0x00000000000000000000000000000000000a0006',
  registry: '0x00000000000000000000000000000000000a0007',
  registryLens: '0x00000000000000000000000000000000000a0008',
  hook: '0x00000000000000000000000000000000000038c0',
  oracleGate: '0x00000000000000000000000000000000000a0009',
  timelock: '0x00000000000000000000000000000000000a000a',
} as const

export const RPC_URL = 'http://127.0.0.1:8545'
export const MULTICALL3 = '0xca11bde05977b3631167028862be2a173976ca11'
