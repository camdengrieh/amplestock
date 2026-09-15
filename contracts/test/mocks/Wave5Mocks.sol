// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IAmpsVault} from "../../src/interfaces/IAmpsVault.sol";
import {IPositionValuer} from "../../src/interfaces/IPositionValuer.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @title ShavingValuer
/// @notice A position valuer that reports the truth until the pool it is watching has been placed into **in this
///         block**, and then reports a fixed number of counter wei less.
///
/// @dev It exists for one test: `AmpsVault._afterPlacement`'s R1 bound compares a NAV read before the placement
///      with a NAV read after it, and the only way to assert the bound's *width* deterministically is to make a
///      placement bleed a known amount. Every real mechanism available in the fixture bleeds a few thousandths of
///      a basis point — the creator's counter-side slice of a $100 swap's fee is $0.06 against an `A` of $20,000
///      — which is three orders of magnitude below the 2 bp bound.
///
/// @dev **Why `lastPlacementAt` is the trigger.** It has to be something the *placement* moves and the burn
///      stream's settlement does not, or the two readings would shave alike and the bleed would vanish.
///      `VaultPlacementLib.compound` writes the pool's cooldown at step 8, before the vault's forwarder reaches
///      `_afterPlacement`, so `lastPlacementAt(poolId) == block.timestamp` is false for the first reading and
///      true for the second. `totalSupply` would not do: the settle burns AMPS too.
///
/// @dev Every function is `view`, because `IPositionValuer` declares them so and the vault reads the pointer with
///      a bounded `staticcall`.
contract ShavingValuer is IPositionValuer {
    /// @dev The real valuer this one speaks for.
    IPositionValuer public immutable INNER;
    /// @dev The vault whose `lastPlacementAt` is the trigger.
    IAmpsVault public immutable VAULT;

    /// @dev The pool to shave.
    PoolId private _pool;
    /// @dev How many counter wei to take off it.
    uint256 private _shaveWei;

    /// @param inner The real valuer.
    /// @param vault The vault.
    constructor(address inner, address vault) {
        INNER = IPositionValuer(inner);
        VAULT = IAmpsVault(vault);
    }

    /// @notice Arms the shave.
    /// @param poolId The pool whose counter side is under-reported once it has been placed into this block.
    /// @param shaveWei How many counter wei to subtract.
    function arm(PoolId poolId, uint256 shaveWei) external {
        _pool = poolId;
        _shaveWei = shaveWei;
    }

    /// @inheritdoc IPositionValuer
    function valuePool(PoolId poolId, uint160 sqrtPriceRefX96)
        external
        view
        returns (uint256 amount0, uint256 amount1)
    {
        (amount0, amount1) = INNER.valuePool(poolId, sqrtPriceRefX96);
        if (PoolId.unwrap(poolId) != PoolId.unwrap(_pool)) return (amount0, amount1);
        if (VAULT.lastPlacementAt(poolId) != uint32(block.timestamp)) return (amount0, amount1);
        amount1 = amount1 > _shaveWei ? amount1 - _shaveWei : 0;
    }

    /// @inheritdoc IPositionValuer
    function totalLiquidity(PoolId poolId) external view returns (uint128 liquidity) {
        return INNER.totalLiquidity(poolId);
    }

    /// @inheritdoc IPositionValuer
    function version() external pure returns (bytes32 id) {
        return bytes32("ShavingValuer");
    }
}

/// @title GasBurningGate
/// @notice An oracle-gate pointer whose `checkPlacement` burns a set amount of gas and then returns.
///
/// @dev The gate is the one pointer on the placement path that refuses **by reverting**, so "the call failed" has
///      to keep meaning "refused" and the only defence against a hostile or upgraded implementation is a gas cap.
///      This is what the cap is measured against: a gate that burns less than the budget must not disturb a
///      placement, and one that burns more must fail it rather than taking the caller's whole frame.
///
/// @dev Everything other than `checkPlacement` answers with empty returndata, which every other read of the gate
///      in the vault treats as "cannot be read" and therefore as absent — the deliberate fail-open of
///      `AmpsVault._requireGate`.
contract GasBurningGate {
    /// @dev How much gas `checkPlacement` consumes before returning.
    uint256 public immutable BURN;

    /// @param burn The gas to consume.
    constructor(uint256 burn) {
        BURN = burn;
    }

    /// @notice `IOracleGate.checkPlacement`, with the burn. `PoolId` is a `bytes32` value type, so this is the
    ///         same selector the placement path calls.
    function checkPlacement(bytes32) external view returns (bool anchorAtNav) {
        uint256 start = gasleft();
        uint256 sink;
        while (start - gasleft() < BURN) {
            unchecked {
                sink += 1;
            }
        }
        return sink == type(uint256).max;
    }

    /// @dev Everything else: readable as "no answer".
    fallback() external {}
}

/// @title MalformedLadderPolicy
/// @notice A ladder policy that answers `weights` with bytes of the caller's choosing.
///
/// @dev A `uint256[]` return is a dynamic type, so a typed `try` in the caller's frame decodes an offset, a
///      length and a bounds check — and every one of those is a `Panic` the `catch` cannot reach. This produces
///      each of those shapes so `VaultPlacementLib._weights` can be shown to fall through to `LadderLib` for all
///      of them instead of reverting the placement.
contract MalformedLadderPolicy {
    /// @dev The raw bytes `weights` answers with.
    bytes private _answer;
    /// @dev Whether `weights` reverts outright.
    bool private _reverts;

    /// @notice Sets the raw answer.
    /// @param answer The bytes to return from `weights`.
    function setAnswer(bytes calldata answer) external {
        _answer = answer;
        _reverts = false;
    }

    /// @notice Makes `weights` revert.
    function setReverts() external {
        _reverts = true;
    }

    /// @dev `ILadderPolicy.weights(uint64,uint8)`, answering raw bytes.
    fallback(bytes calldata) external returns (bytes memory) {
        require(!_reverts, "policy down");
        return _answer;
    }
}
