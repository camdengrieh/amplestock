// SPDX-License-Identifier: MIT
pragma solidity >=0.6.2 <0.9.0;

import "../Base.sol";
import {AdversaryHandler} from "./AdversaryHandler.sol";
import {AmpsBondsHandler} from "./AmpsBondsHandler.sol";
import {AmpsHandler} from "./AmpsHandler.sol";
import {AmpsHookHandler} from "./AmpsHookHandler.sol";
import {AmpsRouterHandler} from "./AmpsRouterHandler.sol";
import {AmpsVaultHandler} from "./AmpsVaultHandler.sol";
import {BountyPotHandler} from "./BountyPotHandler.sol";
import {FeedRegistryHandler} from "./FeedRegistryHandler.sol";
import {OracleGateHandler} from "./OracleGateHandler.sol";
import {PoolRegistryHandler} from "./PoolRegistryHandler.sol";

/// @notice Inherits from all the handlers to expose all entry points in a single contract.
///         Manages environment changes (e.g. current actor, current token, mocks setup, etc.).
///
/// @dev The clock, the Chainlink answers, the display multipliers and the issuer-side oracle pause live in
///      `OracleGateHandler.env_secondary` rather than here: every one of them exists to move the gate off `OK`, and
///      keeping them in their own dispatcher next to the gate's own surface is what documents that.
///
/// @dev `AdversaryHandler` is the one file that is not named after a contract: it holds the two probes that are
///      about what an *unprivileged* account cannot do, which belong to no single contract's surface.
abstract contract Handlers is
    AdversaryHandler,
    AmpsBondsHandler,
    AmpsHookHandler,
    BountyPotHandler,
    FeedRegistryHandler,
    OracleGateHandler,
    AmpsRouterHandler,
    PoolRegistryHandler,
    AmpsHandler,
    AmpsVaultHandler
{
    /// @notice Switches which of the three actors the next handler acts as.
    /// @dev Called by the fuzzer like any other entry point. Every handler reads `actor` rather than `msg.sender`,
    ///      so this — not the fuzzer's sender rotation — is what spreads positions and balances across accounts.
    /// @param entropy Chooses the actor.
    function setCurrentActor(uint256 entropy) public {
        actor = actors[entropy % actors.length];
        // GL-31 measures an actor's value against the basis it carried when it last became the acting account.
        ghosts.actorValueBasis[actor] = actorValueUsd18(actor);
    }
}
