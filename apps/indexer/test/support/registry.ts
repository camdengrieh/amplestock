// SPDX-License-Identifier: MIT

/**
 * A stand-in for Ponder's `ponder:registry` virtual module.
 *
 * The real one hands the indexing functions a typed `ponder.on`. This one records every
 * registration in a map so a test can fetch a handler by name and call it with a synthetic event —
 * which is the whole point: the handlers are the thing under test, and they should be testable
 * without a chain, a database or a Ponder process.
 */

export type Handler = (args: {event: unknown; context: unknown}) => Promise<void> | void

const handlers = new Map<string, Handler>()

export const ponder = {
  on(name: string, handler: Handler) {
    handlers.set(name, handler)
  },
}

/** The handler registered for `name`. Throws rather than returning undefined, so a typo fails loudly. */
export function handlerFor(name: string): Handler {
  const handler = handlers.get(name)
  if (handler === undefined) {
    throw new Error(`[test] no handler registered for "${name}". Registered: ${[...handlers.keys()].join(', ')}`)
  }
  return handler
}

/** Every registered event name, for the "is everything wired" test. */
export function registeredHandlers(): string[] {
  return [...handlers.keys()].sort()
}

/** Ponder's `Context` type is only meaningful inside its own build; tests supply their own. */
export type Context = never
