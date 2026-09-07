// SPDX-License-Identifier: MIT

/**
 * The slice of the Chainlink CRE TypeScript SDK the mirror uses, declared locally.
 *
 * `@chainlink/cre-sdk` is **not** a dependency of this workspace and is not installed. The workflow in
 * `workflow.ts` is a compiled, typechecked artefact rather than a deployed one — nothing in this environment
 * can reach a CRE node, and the plan puts the testnet deployment behind the network-policy widening. So the
 * SDK arrives as a **parameter**: `buildWorkflow(sdk, …)` takes an object matching {@link CreSdk}, which the
 * real package satisfies and which `workflow.test.ts` satisfies with a fake.
 *
 * That inversion is what keeps the mirror honest. The workflow file imports its decision logic from
 * `../domain/decide.js` — the same module the service runs — so "the CRE workflow mirrors the keeper" is not a
 * claim about two files staying in sync, it is one function called from two places.
 *
 * See `README.md` in this directory for the import to swap in and the deployment steps.
 */

/** A cron trigger definition. */
export interface CronTrigger {
  readonly type: 'cron'
  readonly config: {readonly schedule: string}
}

/** One EVM `eth_call`, as CRE issues it through its own consensus layer. */
export interface EvmReadRequest {
  readonly chainSelector: string
  readonly address: `0x${string}`
  readonly callData: `0x${string}`
}

/** The per-run context the SDK hands a handler. */
export interface CreRuntime {
  readonly logger: {log(message: string): void}
  evm(chainSelector: string): {call(request: EvmReadRequest): Promise<`0x${string}`>}
  /** Emits a report for the on-chain consumer contract to act on. */
  report(payload: Uint8Array): Promise<void>
}

/** A trigger bound to its handler, which is what a workflow is a list of. */
export interface WorkflowBinding<TPayload = unknown> {
  readonly trigger: CronTrigger
  readonly handler: (runtime: CreRuntime, payload: TPayload) => Promise<unknown>
}

/** The SDK functions the workflow uses. `@chainlink/cre-sdk` provides all three. */
export interface CreSdk {
  cron(config: {readonly schedule: string}): CronTrigger
  handler<TPayload>(
    trigger: CronTrigger,
    fn: (runtime: CreRuntime, payload: TPayload) => Promise<unknown>,
  ): WorkflowBinding<TPayload>
  runner(): {run(initialise: () => WorkflowBinding[]): void}
}
