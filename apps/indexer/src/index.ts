// SPDX-License-Identifier: MIT

/**
 * The indexing-function entry point.
 *
 * Ponder loads every module under `src/` (except `src/api/`) and each of them registers its
 * handlers as a side effect of being imported. Importing them here rather than relying on the glob
 * keeps the registration order explicit and makes the dependency graph visible: `vault.ts` calls
 * into `bonds.ts`, `reconcile.ts` and `genesis.ts` (the launch row has a half on each side of the
 * vault/adapter boundary), `poolManager.ts` reads the rows `registry.ts` writes,
 * `router.ts` reads the swap rows `poolManager.ts` wrote earlier in the same transaction, and
 * `denylist.ts` reads the reverse index `registry.ts` materialises.
 *
 * The alert sink is installed once, here, from the environment: a webhook when
 * `AMPS_ALERT_WEBHOOK` is set, and the no-op (record-only) sink otherwise.
 */

import {readEnv} from './config/env'
import {configureAlerts} from './lib/alerts'

const env = readEnv()
configureAlerts(env.alertWebhookUrl, env.alertWebhookTimeoutMs)

import './handlers/registry'
import './handlers/genesis'
import './handlers/vault'
import './handlers/hook'
import './handlers/poolManager'
import './handlers/bonds'
import './handlers/router'
import './handlers/gate'
import './handlers/feeds'
import './handlers/bounty'
import './handlers/denylist'
import './handlers/polling'
