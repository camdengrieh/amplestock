// SPDX-License-Identifier: MIT
'use client'

import {deployment, deploymentReady, isDeployed, type AmpsContractKey} from '@/lib/deployment'

/**
 * The deployment record, and whether the surface can read anything at all.
 *
 * A surface with no addresses renders `NotDeployed` rather than issuing reads against `0x0` and
 * showing the answers — which would be zeros, and zeros look like data.
 */
export function useDeployment() {
  return {
    deployment,
    ready: deploymentReady(),
    has: (key: AmpsContractKey) => isDeployed(key),
  }
}
