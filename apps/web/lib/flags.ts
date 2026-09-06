// SPDX-License-Identifier: MIT

/**
 * Feature flags. Off by default; a flag that is off renders an explicit "not enabled" state rather
 * than a dead button.
 */

import {publicEnv} from './env'

export interface FeatureFlags {
  /**
   * The Across USDC -> USDG zap on the Buy surface. Stubbed: the entry point, the disclosure and
   * the disabled control exist; the bridge call does not, and the UI says so instead of pretending.
   * `acrossSpokePool` is in `@amplestocks/config` and is the address it would use.
   */
  acrossZap: boolean
  /** The "this is a testnet deployment" banner. */
  testnetBanner: boolean
}

export const featureFlags: FeatureFlags = {
  acrossZap: publicEnv.flags.acrossZap,
  testnetBanner: publicEnv.flags.testnetBanner,
}

export function isEnabled(flag: keyof FeatureFlags, overrides?: Partial<FeatureFlags>): boolean {
  return (overrides?.[flag] ?? featureFlags[flag]) === true
}
