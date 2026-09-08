// SPDX-License-Identifier: MIT

/**
 * `AmpsHook`, the parts of it this interface reads.
 *
 * **Why this ABI is hand-written.** `@amplestocks/abis` is generated from the Foundry artefacts and
 * committed, and it has not been regenerated since revision 6 changed the hook: the generated
 * `ampsHookAbi` has no `router()`, no `setRouter`, and a four-argument `quoteFee`. Reading the app's
 * fee surfaces against it would be reading against last revision's contract. This file is
 * transcribed from `contracts/src/interfaces/IAmpsHook.sol`; when the package regenerates, the
 * import in `lib/contracts.ts` moves and this file goes away.
 *
 * **The fee law, in one paragraph, because every entry below is a consequence of it.** `ampsFeeBps`
 * (500 bp at launch, band [100, 600]) is the base fee on **both** directions of every pool: buying
 * AMPS and selling it are the same trade seen from two sides. `buyFeeBps` (30 bp entry, 5–10 bp
 * spoke) is the **pass-through** base — the price of moving *through* a pool rather than entering
 * or leaving the index through it — and it is charged only on a hop where the PoolManager reports
 * `sender == router()` and the hop's `hookData` is exactly `Constants.ROUTER_ROTATE`. Everything
 * else in the world pays `ampsFeeBps`. That is what {quoteFee}'s fifth argument selects between,
 * and it is why there is a `router` pointer at all.
 */
export const ampsHookAbi = [
  // -------------------------------------------------------------------------------------------
  // Fees
  // -------------------------------------------------------------------------------------------

  /** The protocol-wide AMPS fee in bps: the base fee on both directions of every pool. */
  {type: 'function', name: 'ampsFeeBps', stateMutability: 'view', inputs: [], outputs: [{name: 'value', type: 'uint16'}]},
  /** The pool's pass-through base fee in bps: what one hop of a protocol-router rotation costs. */
  {
    type: 'function',
    name: 'buyFeeBps',
    stateMutability: 'view',
    inputs: [{name: 'poolId', internalType: 'PoolId', type: 'bytes32'}],
    outputs: [{name: 'value', type: 'uint16'}],
  },
  /**
   * The fee a swap would pay right now, without executing it.
   *
   * `passThrough` prices the hop as one leg of an `AmpsRouter.rotate`; **`false` is the honest
   * argument for every caller that is not the protocol router**, which is every caller. It reads no
   * transient storage — a credit belongs to the swap's `sender`, which an `eth_call` is not — so
   * the pass-through case is modelled rather than looked up.
   */
  {
    type: 'function',
    name: 'quoteFee',
    stateMutability: 'view',
    inputs: [
      {name: 'poolId', internalType: 'PoolId', type: 'bytes32'},
      {name: 'zeroForOne', type: 'bool'},
      {name: 'exactInput', type: 'bool'},
      {name: 'amountIn', type: 'uint256'},
      {name: 'passThrough', type: 'bool'},
    ],
    outputs: [
      {name: 'feePips', type: 'uint24'},
      {name: 'baseBps', type: 'uint16'},
      {name: 'dynBps', type: 'uint16'},
      {name: 'refuse', type: 'bool'},
    ],
  },
  /**
   * The rotation credit an account holds, in AMPS wei.
   *
   * EIP-1153 transient storage, keyed by the swap `sender`, so it is **always zero** from a fresh
   * `eth_call`: a quote that consulted it would be wrong in exactly the direction that matters.
   * `AmpsQuoter.quoteRotation` models the credit instead. This entry exists so a debugging trace
   * inside a transaction can read it, not so a surface can price with it.
   */
  {
    type: 'function',
    name: 'rotationCredit',
    stateMutability: 'view',
    inputs: [{name: 'sender', type: 'address'}],
    outputs: [{name: 'credit', type: 'uint256'}],
  },

  // -------------------------------------------------------------------------------------------
  // Bands, compiled into the bytecode — `pure`, so these are the constants and not a mirror
  // -------------------------------------------------------------------------------------------

  {type: 'function', name: 'AMPS_FEE_BPS_MIN', stateMutability: 'pure', inputs: [], outputs: [{name: 'value', type: 'uint16'}]},
  {type: 'function', name: 'AMPS_FEE_BPS_MAX', stateMutability: 'pure', inputs: [], outputs: [{name: 'value', type: 'uint16'}]},
  {type: 'function', name: 'TOTAL_FEE_BPS_MAX', stateMutability: 'pure', inputs: [], outputs: [{name: 'value', type: 'uint16'}]},
  {type: 'function', name: 'HOOK_FLAGS', stateMutability: 'pure', inputs: [], outputs: [{name: 'value', type: 'uint16'}]},

  // -------------------------------------------------------------------------------------------
  // Pointers
  // -------------------------------------------------------------------------------------------

  {type: 'function', name: 'amps', stateMutability: 'view', inputs: [], outputs: [{name: 'ampsAddress', type: 'address'}]},
  {type: 'function', name: 'vault', stateMutability: 'view', inputs: [], outputs: [{name: 'vaultAddress', type: 'address'}]},
  {type: 'function', name: 'registry', stateMutability: 'view', inputs: [], outputs: [{name: 'registryAddress', type: 'address'}]},
  /**
   * The one address whose `ROUTER_ROTATE`-flagged hops are priced at the pass-through fee. Zero
   * disables the exemption entirely, which is a legitimate governance position: every swap then
   * pays `ampsFeeBps`.
   */
  {type: 'function', name: 'router', stateMutability: 'view', inputs: [], outputs: [{name: 'routerAddress', type: 'address'}]},
  {type: 'function', name: 'oracleGate', stateMutability: 'view', inputs: [], outputs: [{name: 'gateAddress', type: 'address'}]},
  {type: 'function', name: 'feePolicy', stateMutability: 'view', inputs: [], outputs: [{name: 'policyAddress', type: 'address'}]},
  {type: 'function', name: 'timelock', stateMutability: 'view', inputs: [], outputs: [{name: 'timelockAddress', type: 'address'}]},

  // -------------------------------------------------------------------------------------------
  // Per-pool state the fee surfaces quote against
  // -------------------------------------------------------------------------------------------

  {type: 'function', name: 'fairTick', stateMutability: 'view', inputs: [{name: 'poolId', type: 'bytes32'}], outputs: [{name: 'tick', type: 'int24'}]},
  {type: 'function', name: 'innerBandTicks', stateMutability: 'view', inputs: [{name: 'poolId', type: 'bytes32'}], outputs: [{name: 'ticks', type: 'int24'}]},
  {type: 'function', name: 'outerRailTicks', stateMutability: 'view', inputs: [{name: 'poolId', type: 'bytes32'}], outputs: [{name: 'ticks', type: 'int24'}]},
  {type: 'function', name: 'gridBaseTick', stateMutability: 'view', inputs: [{name: 'poolId', type: 'bytes32'}], outputs: [{name: 'tick', type: 'int24'}]},
  {type: 'function', name: 'gateCacheSeconds', stateMutability: 'view', inputs: [], outputs: [{name: 'seconds_', type: 'uint32'}]},

  // -------------------------------------------------------------------------------------------
  // Governed setters — declared so the interface can name what a proposal would call, never sent
  // -------------------------------------------------------------------------------------------

  {type: 'function', name: 'setAmpsFeeBps', stateMutability: 'nonpayable', inputs: [{name: 'value', type: 'uint16'}], outputs: []},
  {
    type: 'function',
    name: 'setBuyFeeBps',
    stateMutability: 'nonpayable',
    inputs: [{name: 'poolId', type: 'bytes32'}, {name: 'value', type: 'uint16'}],
    outputs: [],
  },
  {type: 'function', name: 'setFeePolicy', stateMutability: 'nonpayable', inputs: [{name: 'newPolicy', type: 'address'}], outputs: []},
  /** 7-day timelock class: the same class as the fee policy, because it moves the same lever. */
  {type: 'function', name: 'setRouter', stateMutability: 'nonpayable', inputs: [{name: 'newRouter', type: 'address'}], outputs: []},

  // -------------------------------------------------------------------------------------------
  // Events
  // -------------------------------------------------------------------------------------------

  {
    type: 'event',
    name: 'RouterChanged',
    inputs: [
      {name: 'previousRouter', type: 'address', indexed: true},
      {name: 'newRouter', type: 'address', indexed: true},
    ],
  },
  {
    type: 'event',
    name: 'FeePolicyChanged',
    inputs: [
      {name: 'previousPolicy', type: 'address', indexed: true},
      {name: 'newPolicy', type: 'address', indexed: true},
    ],
  },
  {
    type: 'event',
    name: 'RotationCreditConsumed',
    inputs: [
      {name: 'poolId', internalType: 'PoolId', type: 'bytes32', indexed: true},
      {name: 'consumed', type: 'uint256', indexed: false},
      {name: 'blendedFeeBps', type: 'uint16', indexed: false},
    ],
  },
  {
    type: 'event',
    name: 'HighWaterAdvanced',
    inputs: [
      {name: 'poolId', internalType: 'PoolId', type: 'bytes32', indexed: true},
      {name: 'highWaterTick', type: 'int24', indexed: false},
    ],
  },
  {
    type: 'event',
    name: 'HighWaterReset',
    inputs: [
      {name: 'poolId', internalType: 'PoolId', type: 'bytes32', indexed: true},
      {name: 'previousHighWaterTick', type: 'int24', indexed: false},
      {name: 'newHighWaterTick', type: 'int24', indexed: false},
    ],
  },
  {
    type: 'event',
    name: 'SurgeArmed',
    inputs: [
      {name: 'poolId', internalType: 'PoolId', type: 'bytes32', indexed: true},
      {name: 'surgeBps', type: 'uint16', indexed: false},
      {name: 'reason', type: 'bytes32', indexed: false},
    ],
  },
  {
    type: 'event',
    name: 'HookParameterChanged',
    inputs: [
      {name: 'parameter', type: 'bytes32', indexed: true},
      {name: 'poolId', internalType: 'PoolId', type: 'bytes32', indexed: true},
      {name: 'previousValue', type: 'uint256', indexed: false},
      {name: 'newValue', type: 'uint256', indexed: false},
    ],
  },

  // -------------------------------------------------------------------------------------------
  // Errors
  // -------------------------------------------------------------------------------------------

  {type: 'error', name: 'BeyondRail', inputs: [{name: 'poolId', type: 'bytes32'}, {name: 'devTicks', type: 'int24'}, {name: 'outerRailTicks', type: 'int24'}]},
  {type: 'error', name: 'Currency0NotAmps', inputs: []},
  {type: 'error', name: 'FeeNotDynamic', inputs: []},
  {type: 'error', name: 'PoolNotRegistered', inputs: [{name: 'poolId', type: 'bytes32'}]},
  {type: 'error', name: 'PoolKeyMismatch', inputs: [{name: 'field', type: 'bytes32'}]},
  {type: 'error', name: 'NotVault', inputs: [{name: 'caller', type: 'address'}]},
  {type: 'error', name: 'NotTimelock', inputs: [{name: 'caller', type: 'address'}]},
  {type: 'error', name: 'NotInitialized', inputs: []},
  {type: 'error', name: 'OutOfBand', inputs: [{name: 'parameter', type: 'bytes32'}, {name: 'value', type: 'uint256'}, {name: 'min', type: 'uint256'}, {name: 'max', type: 'uint256'}]},
  {type: 'error', name: 'ZeroAddress', inputs: []},
] as const
