// SPDX-License-Identifier: MIT

/**
 * Amplestocks labels a lot of things with a `bytes32` short string — `Burn(amount, reason)`,
 * `BountyPaid(..., reason)`, `VaultParameterChanged(parameter, ...)`, `SurgeArmed(..., reason)`,
 * `ConstituentReconfigured(..., field, ...)`. Solidity writes them left-aligned and zero-padded, so
 * decoding is "take bytes up to the first zero, as UTF-8".
 *
 * A value that is not a short string (someone hashed something into the slot) is returned as its
 * hex, never as mojibake — the raw hex is stored alongside the decoded label everywhere, so a
 * consumer can always recover the original.
 */

import {hexToBytes, type Hex} from 'viem'

const PRINTABLE = /^[\x20-\x7e]*$/

export function decodeBytes32String(value: Hex): string {
  let bytes: Uint8Array
  try {
    bytes = hexToBytes(value)
  } catch {
    return value
  }
  let end = bytes.length
  for (let i = 0; i < bytes.length; i++) {
    if (bytes[i] === 0) {
      end = i
      break
    }
  }
  if (end === 0) return ''
  // Everything after the first zero must also be zero for this to be a left-aligned short string.
  for (let i = end; i < bytes.length; i++) {
    if (bytes[i] !== 0) return value
  }
  const text = new TextDecoder('utf-8', {fatal: false}).decode(bytes.subarray(0, end))
  return PRINTABLE.test(text) ? text : value
}
