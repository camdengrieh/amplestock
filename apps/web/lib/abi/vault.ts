// SPDX-License-Identifier: MIT

/**
 * `AmpsVault`, the parts of it this interface reads, writes or decodes.
 *
 * **Why this ABI is hand-written.** `@amplestocks/abis` has not been regenerated since revision 6
 * deleted staking and rewrote the compound split, so the generated `ampsVaultAbi` still exposes
 * `staking()`, `stakerBps()` and `burnBps()`, and still declares `Compound` with the five-way
 * revision-5 shape. A selector the protocol no longer has is a selector this app must not be able
 * to call by accident, and an event shape that has moved is a decode that silently mislabels every
 * field. This file is transcribed from `contracts/src/interfaces/IAmpsVault.sol`; when the package
 * regenerates, the import in `lib/contracts.ts` moves and this file goes away.
 *
 * **What the fee split is now.** At `compound()` the creator takes `creatorBps(t) / ampsFeeBps` of
 * the fees collected in **each** currency — AMPS by transfer, counter assets in kind — and then
 * the whole AMPS-side remainder is burned. The counter side stays in the pool that earned it, as
 * bids. There is no staker slice, no governed burn share, and no re-ladder of fee AMPS into asks.
 */
export const ampsVaultAbi = [
  // -------------------------------------------------------------------------------------------
  // Reads — the checkpoint and the headline
  // -------------------------------------------------------------------------------------------

  {
    type: 'function',
    name: 'checkpointData',
    stateMutability: 'view',
    inputs: [],
    outputs: [
      {
        name: 'snapshot',
        internalType: 'struct Checkpoint',
        type: 'tuple',
        components: [
          {name: 'navPerShareX18', internalType: 'uint128', type: 'uint128'},
          {name: 'pRefX18', internalType: 'uint128', type: 'uint128'},
          {name: 'pMktX18', internalType: 'uint128', type: 'uint128'},
          {name: 'timestamp', internalType: 'uint32', type: 'uint32'},
          {name: 'blockNumber', internalType: 'uint32', type: 'uint32'},
        ],
      },
    ],
  },
  {type: 'function', name: 'navPerShareX18', stateMutability: 'view', inputs: [], outputs: [{name: 'value', type: 'uint256'}]},
  {type: 'function', name: 'previewNavPerShareX18', stateMutability: 'view', inputs: [], outputs: [{name: 'value', type: 'uint256'}]},
  {type: 'function', name: 'pRefX18', stateMutability: 'view', inputs: [], outputs: [{name: 'value', type: 'uint256'}]},
  {type: 'function', name: 'pMktX18', stateMutability: 'view', inputs: [], outputs: [{name: 'value', type: 'uint256'}]},
  {type: 'function', name: 'premiumX18', stateMutability: 'view', inputs: [], outputs: [{name: 'value', type: 'int256'}]},
  {type: 'function', name: 'totalAssetsUsd18', stateMutability: 'view', inputs: [], outputs: [{name: 'value', type: 'uint256'}]},
  {type: 'function', name: 'navUnconfirmed', stateMutability: 'view', inputs: [], outputs: [{name: 'held', type: 'bool'}]},
  /**
   * AMPS the vault holds and has not committed: the genesis POL tranche less what has been sold,
   * rolled out or burned. Never minted, and since revision 6 never added to by `compound` — the
   * AMPS side of every fee is burned instead of re-laddered.
   */
  {type: 'function', name: 'inventoryAmps', stateMutability: 'view', inputs: [], outputs: [{name: 'amount', type: 'uint256'}]},
  {type: 'function', name: 'liveCells', stateMutability: 'view', inputs: [], outputs: [{name: 'count', type: 'uint32'}]},
  {type: 'function', name: 'initialized', stateMutability: 'view', inputs: [], outputs: [{name: 'done', type: 'bool'}]},
  {type: 'function', name: 'genesisTimestamp', stateMutability: 'view', inputs: [], outputs: [{name: 'timestamp', type: 'uint32'}]},
  {type: 'function', name: 'assetCount', stateMutability: 'view', inputs: [], outputs: [{name: 'count', type: 'uint256'}]},
  {
    type: 'function',
    name: 'assetAt',
    stateMutability: 'view',
    inputs: [{name: 'index', type: 'uint256'}],
    outputs: [{name: 'token', type: 'address'}],
  },

  // -------------------------------------------------------------------------------------------
  // Reads — the creator schedule, which has no setter
  // -------------------------------------------------------------------------------------------

  /**
   * `creatorBps(t) = 100 bp x max(0, 1 - (t - genesis) / 30 days)`, monotone non-increasing and
   * exactly zero from day 30. Paid in kind out of each currency's fees at `compound()`.
   */
  {
    type: 'function',
    name: 'creatorBpsAt',
    stateMutability: 'view',
    inputs: [{name: 'timestamp', type: 'uint256'}],
    outputs: [{name: 'bps', type: 'uint16'}],
  },
  {type: 'function', name: 'CREATOR_FEE_BPS', stateMutability: 'pure', inputs: [], outputs: [{name: 'value', type: 'uint16'}]},
  {type: 'function', name: 'CREATOR_DECAY_SECONDS', stateMutability: 'pure', inputs: [], outputs: [{name: 'value', type: 'uint32'}]},
  {type: 'function', name: 'creator', stateMutability: 'view', inputs: [], outputs: [{name: 'creatorAddress', type: 'address'}]},

  // -------------------------------------------------------------------------------------------
  // Reads — governed parameters and the bands hardcoded beside them
  // -------------------------------------------------------------------------------------------

  {type: 'function', name: 'redeemFeeBps', stateMutability: 'view', inputs: [], outputs: [{name: 'value', type: 'uint16'}]},
  {type: 'function', name: 'REDEEM_FEE_BPS_MAX', stateMutability: 'pure', inputs: [], outputs: [{name: 'value', type: 'uint16'}]},
  {type: 'function', name: 'refUpRateBps', stateMutability: 'view', inputs: [], outputs: [{name: 'value', type: 'uint16'}]},
  {type: 'function', name: 'refDivergenceBps', stateMutability: 'view', inputs: [], outputs: [{name: 'value', type: 'uint16'}]},
  {type: 'function', name: 'twapWindow', stateMutability: 'view', inputs: [], outputs: [{name: 'value', type: 'uint32'}]},
  {type: 'function', name: 'ladderTiltX18', stateMutability: 'view', inputs: [], outputs: [{name: 'value', type: 'uint64'}]},
  {type: 'function', name: 'ladderDoublings', stateMutability: 'view', inputs: [], outputs: [{name: 'value', type: 'uint8'}]},
  {type: 'function', name: 'seedHalvings', stateMutability: 'view', inputs: [], outputs: [{name: 'value', type: 'uint8'}]},
  {type: 'function', name: 'bondBidHalvings', stateMutability: 'view', inputs: [], outputs: [{name: 'value', type: 'uint8'}]},
  {type: 'function', name: 'spokeSeedBps', stateMutability: 'view', inputs: [], outputs: [{name: 'value', type: 'uint16'}]},
  {type: 'function', name: 'rolloutBpsPerDay', stateMutability: 'view', inputs: [], outputs: [{name: 'value', type: 'uint16'}]},
  {type: 'function', name: 'ROLLOUT_BPS_PER_DAY_MAX', stateMutability: 'pure', inputs: [], outputs: [{name: 'value', type: 'uint16'}]},
  {type: 'function', name: 'entryFloorBps', stateMutability: 'view', inputs: [], outputs: [{name: 'value', type: 'uint16'}]},
  {type: 'function', name: 'ENTRY_FLOOR_BPS_MAX', stateMutability: 'pure', inputs: [], outputs: [{name: 'value', type: 'uint16'}]},
  {type: 'function', name: 'deployThresholdUsd18', stateMutability: 'view', inputs: [], outputs: [{name: 'value', type: 'uint256'}]},
  {type: 'function', name: 'S0', stateMutability: 'pure', inputs: [], outputs: [{name: 'value', type: 'uint256'}]},

  // -------------------------------------------------------------------------------------------
  // Reads — pointers
  // -------------------------------------------------------------------------------------------

  {type: 'function', name: 'amps', stateMutability: 'view', inputs: [], outputs: [{name: 'ampsAddress', type: 'address'}]},
  {type: 'function', name: 'registry', stateMutability: 'view', inputs: [], outputs: [{name: 'registryAddress', type: 'address'}]},
  {type: 'function', name: 'bonds', stateMutability: 'view', inputs: [], outputs: [{name: 'bondsAddress', type: 'address'}]},
  {type: 'function', name: 'bountyPot', stateMutability: 'view', inputs: [], outputs: [{name: 'bountyPotAddress', type: 'address'}]},
  {type: 'function', name: 'oracleGate', stateMutability: 'view', inputs: [], outputs: [{name: 'gateAddress', type: 'address'}]},
  {type: 'function', name: 'positionValuer', stateMutability: 'view', inputs: [], outputs: [{name: 'positionValuerAddress', type: 'address'}]},
  {type: 'function', name: 'timelock', stateMutability: 'view', inputs: [], outputs: [{name: 'timelockAddress', type: 'address'}]},
  {type: 'function', name: 'guardian', stateMutability: 'view', inputs: [], outputs: [{name: 'guardianAddress', type: 'address'}]},
  {type: 'function', name: 'standbyVault', stateMutability: 'view', inputs: [], outputs: [{name: 'standbyAddress', type: 'address'}]},

  // -------------------------------------------------------------------------------------------
  // Reads — the ladder (`view`-only; NAV never reads these, the valuer enumerates the grid)
  // -------------------------------------------------------------------------------------------

  {
    type: 'function',
    name: 'ladderLength',
    stateMutability: 'view',
    inputs: [{name: 'poolId', internalType: 'PoolId', type: 'bytes32'}],
    outputs: [{name: 'length', type: 'uint256'}],
  },
  {
    type: 'function',
    name: 'ladderAt',
    stateMutability: 'view',
    inputs: [
      {name: 'poolId', internalType: 'PoolId', type: 'bytes32'},
      {name: 'index', type: 'uint256'},
    ],
    outputs: [
      {name: 'lowerTick', type: 'int24'},
      {name: 'upperTick', type: 'int24'},
      {name: 'liquidity', type: 'uint128'},
      {name: 'bucketIndex', type: 'uint8'},
      {name: 'buckets', type: 'uint8'},
      {name: 'above', type: 'bool'},
      {name: 'placedAt', type: 'uint32'},
      {name: 'amount', type: 'uint128'},
      {name: 'tiltX18', type: 'uint64'},
      {name: 'anchorTick', type: 'int24'},
    ],
  },
  {
    type: 'function',
    name: 'lastPlacementAt',
    stateMutability: 'view',
    inputs: [{name: 'poolId', internalType: 'PoolId', type: 'bytes32'}],
    outputs: [{name: 'timestamp', type: 'uint32'}],
  },
  {
    type: 'function',
    name: 'spokeWeightBps',
    stateMutability: 'view',
    inputs: [{name: 'constituentId', type: 'uint16'}],
    outputs: [{name: 'weightBps', type: 'uint16'}],
  },

  // -------------------------------------------------------------------------------------------
  // Redemption — the structurally ungated path
  // -------------------------------------------------------------------------------------------

  /** Balances only: no oracle, no gate, no price. Never reverts for a live vault. */
  {
    type: 'function',
    name: 'previewRedeem',
    stateMutability: 'view',
    inputs: [{name: 'shares', type: 'uint256'}],
    outputs: [
      {name: 'tokens', type: 'address[]'},
      {name: 'amounts', type: 'uint256[]'},
      {name: 'inventoryBurned', type: 'uint256'},
    ],
  },
  {
    type: 'function',
    name: 'redeemProRata',
    stateMutability: 'nonpayable',
    inputs: [
      {name: 'shares', type: 'uint256'},
      {name: 'to', type: 'address'},
    ],
    outputs: [
      {name: 'tokens', type: 'address[]'},
      {name: 'amounts', type: 'uint256[]'},
    ],
  },

  // -------------------------------------------------------------------------------------------
  // Permissionless upkeep
  // -------------------------------------------------------------------------------------------

  /** Recomputes `A`, NAV/share, `P_mkt` and `P_ref`. Permissionless and unpaid: it costs only gas. */
  {
    type: 'function',
    name: 'checkpoint',
    stateMutability: 'nonpayable',
    inputs: [],
    outputs: [
      {
        name: 'snapshot',
        internalType: 'struct Checkpoint',
        type: 'tuple',
        components: [
          {name: 'navPerShareX18', internalType: 'uint128', type: 'uint128'},
          {name: 'pRefX18', internalType: 'uint128', type: 'uint128'},
          {name: 'pMktX18', internalType: 'uint128', type: 'uint128'},
          {name: 'timestamp', internalType: 'uint32', type: 'uint32'},
          {name: 'blockNumber', internalType: 'uint32', type: 'uint32'},
        ],
      },
    ],
  },
  {type: 'function', name: 'touch', stateMutability: 'nonpayable', inputs: [], outputs: []},
  /**
   * Collects a pool's fees, burns what its own bids bought back, pays the creator in kind, burns the
   * AMPS-side remainder and re-places the counter side as bids. Permissionless and bountied.
   */
  {
    type: 'function',
    name: 'compound',
    stateMutability: 'nonpayable',
    inputs: [{name: 'poolId', internalType: 'PoolId', type: 'bytes32'}],
    outputs: [
      {name: 'ampsFees', type: 'uint256'},
      {name: 'burned', type: 'uint256'},
    ],
  },
  {
    type: 'function',
    name: 'rollout',
    stateMutability: 'nonpayable',
    inputs: [{name: 'constituentId', type: 'uint16'}],
    outputs: [{name: 'moved', type: 'uint256'}],
  },
  {
    type: 'function',
    name: 'deployBonded',
    stateMutability: 'nonpayable',
    inputs: [{name: 'constituentId', type: 'uint16'}],
    outputs: [{name: 'placed', type: 'uint256'}],
  },

  // -------------------------------------------------------------------------------------------
  // Events
  // -------------------------------------------------------------------------------------------

  /**
   * The revision-6 shape: fees collected in each currency, the creator's slice of each, and the
   * AMPS burned — the fee remainder plus whatever the pool's own bids bought back. There is no
   * staker field and no re-laddered field, because neither exists.
   */
  {
    type: 'event',
    name: 'Compound',
    inputs: [
      {name: 'poolId', internalType: 'PoolId', type: 'bytes32', indexed: true},
      {name: 'ampsFees', type: 'uint256', indexed: false},
      {name: 'counterFees', type: 'uint256', indexed: false},
      {name: 'creatorAmps', type: 'uint256', indexed: false},
      {name: 'creatorCounter', type: 'uint256', indexed: false},
      {name: 'burned', type: 'uint256', indexed: false},
    ],
  },
  /** `reason` is one of `buyback`, `compound`, `redeem`, `redeemInventory`. */
  {
    type: 'event',
    name: 'Burn',
    inputs: [
      {name: 'amount', type: 'uint256', indexed: false},
      {name: 'reason', type: 'bytes32', indexed: false},
    ],
  },
  {
    type: 'event',
    name: 'Redeem',
    inputs: [
      {name: 'owner', type: 'address', indexed: true},
      {name: 'to', type: 'address', indexed: true},
      {name: 'shares', type: 'uint256', indexed: false},
      {name: 'inventoryBurned', type: 'uint256', indexed: false},
      {name: 'feeBps', type: 'uint16', indexed: false},
    ],
  },
  {
    type: 'event',
    name: 'NavCheckpoint',
    inputs: [
      {name: 'navPerShareX18', type: 'uint256', indexed: false},
      {name: 'totalAssetsUsd18', type: 'uint256', indexed: false},
      {name: 'totalSupply', type: 'uint256', indexed: false},
    ],
  },
  {
    type: 'event',
    name: 'RefCheckpoint',
    inputs: [
      {name: 'pRefX18', type: 'uint256', indexed: false},
      {name: 'pMktX18', type: 'uint256', indexed: false},
      {name: 'rateLimited', type: 'bool', indexed: false},
      {name: 'navFloored', type: 'bool', indexed: false},
    ],
  },
  {
    type: 'event',
    name: 'Rollout',
    inputs: [
      {name: 'constituentId', type: 'uint16', indexed: true},
      {name: 'poolId', internalType: 'PoolId', type: 'bytes32', indexed: true},
      {name: 'movedAmps', type: 'uint256', indexed: false},
      {name: 'placedAmps', type: 'uint256', indexed: false},
    ],
  },
  {
    type: 'event',
    name: 'SweepResidue',
    inputs: [
      {name: 'token', type: 'address', indexed: true},
      {name: 'balance', type: 'uint256', indexed: false},
    ],
  },
  {
    type: 'event',
    name: 'VaultParameterChanged',
    inputs: [
      {name: 'parameter', type: 'bytes32', indexed: true},
      {name: 'previousValue', type: 'uint256', indexed: false},
      {name: 'newValue', type: 'uint256', indexed: false},
    ],
  },
  {
    type: 'event',
    name: 'CreatorChanged',
    inputs: [
      {name: 'previousCreator', type: 'address', indexed: true},
      {name: 'newCreator', type: 'address', indexed: true},
    ],
  },

  // -------------------------------------------------------------------------------------------
  // Errors — `lib/errors.ts` explains the ones a user can meet
  // -------------------------------------------------------------------------------------------

  {type: 'error', name: 'GateNotHealthy', inputs: [{name: 'state', type: 'uint8'}, {name: 'poolId', type: 'bytes32'}]},
  {type: 'error', name: 'PlacementCooldown', inputs: [{name: 'poolId', type: 'bytes32'}, {name: 'readyAt', type: 'uint32'}]},
  {
    type: 'error',
    name: 'PlacementDiverged',
    inputs: [
      {name: 'poolId', type: 'bytes32'},
      {name: 'poolTick', type: 'int24'},
      {name: 'fairTick', type: 'int24'},
      {name: 'maxTicks', type: 'int24'},
    ],
  },
  {type: 'error', name: 'HighWaterResetFailed', inputs: [{name: 'poolId', type: 'bytes32'}]},
  {type: 'error', name: 'InsufficientInventory', inputs: [{name: 'requested', type: 'uint256'}, {name: 'available', type: 'uint256'}]},
  {type: 'error', name: 'StaleCheckpoint', inputs: [{name: 'age', type: 'uint32'}, {name: 'maxAge', type: 'uint32'}]},
  {
    type: 'error',
    name: 'NavBleedExceeded',
    inputs: [
      {name: 'navBefore', type: 'uint256'},
      {name: 'navAfter', type: 'uint256'},
      {name: 'maxBleedBps', type: 'uint16'},
    ],
  },
  {type: 'error', name: 'ConstituentFrozen', inputs: [{name: 'constituentId', type: 'uint16'}, {name: 'until', type: 'uint32'}]},
  {type: 'error', name: 'UnconfirmedNav', inputs: []},
  {type: 'error', name: 'Reentrancy', inputs: []},
  {type: 'error', name: 'NotInitialized', inputs: []},
  {
    type: 'error',
    name: 'OutOfBand',
    inputs: [
      {name: 'parameter', type: 'bytes32'},
      {name: 'value', type: 'uint256'},
      {name: 'min', type: 'uint256'},
      {name: 'max', type: 'uint256'},
    ],
  },
  {type: 'error', name: 'ZeroAmount', inputs: []},
  {type: 'error', name: 'ZeroAddress', inputs: []},
] as const
