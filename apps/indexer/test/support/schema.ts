// SPDX-License-Identifier: MIT

/**
 * A stand-in for Ponder's `ponder:schema` virtual module: the real `ponder.schema.ts`, re-exported
 * both as a namespace default (which is how the indexing functions import it) and by name (which is
 * how the tests reach individual tables).
 */

import * as schema from '../../ponder.schema'

export * from '../../ponder.schema'
export default schema
