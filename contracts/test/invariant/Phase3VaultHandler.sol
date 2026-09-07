// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Amps} from "../../src/token/Amps.sol";
import {AmpsVault} from "../../src/vault/AmpsVault.sol";
import {Phase3Ghosts} from "./Phase3Ghosts.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {CommonBase} from "forge-std/Base.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";

/// @title Phase3VaultHandler
/// @notice The vault-upkeep half of `docs/phase3-state-model.md` §8.2's action space: `redeem`, `compound`,
///         `rollout`, `deployBonded`, `checkpoint` and the bare liquidity removal that proves I18. The
///         market-facing half - swaps, rotations, bonds, the clock, the feeds, the multipliers, the gate and the
///         direct hook probe - is `Phase3Handler`, and `Phase3.invariant.t.sol` targets both.
///
/// @dev **Why the space is split across two contracts.** With every action, the router, Permit2, the bond path
///      and all of the bookkeeping in one handler the runtime came to 31,203 B - past EIP-170, which
///      `forge build --sizes` gates and which Medusa's geth enforces at deploy time, so a single handler could
///      not be fuzzed at all (§8.3). The bookkeeping moved to {Phase3Ghosts} and the actions split here; nothing
///      about the action space, the ghosts or the assertions changed with it.
///
/// @dev **This handler is the redeemer.** It is given shares out of the POL tranche at set-up rather than by a
///      mint, so `totalSupply` is still exactly `S0` when the campaign starts and I3 has a fixed origin.
///
/// @dev **Nothing in here asserts.** Every action is wrapped in `try`/`catch` and every finding is recorded as a
///      ghost, which is what lets the campaign run with `fail_on_revert = false` and still prove something.
contract Phase3VaultHandler is CommonBase, StdCheats, StdUtils {
    AmpsVault internal immutable VAULT;
    Amps internal immutable AMPS;
    Phase3Ghosts internal immutable GHOSTS;
    address internal immutable KEEPER;

    uint16[] internal constituentIds;
    PoolId[] internal pools;

    /// @param vault_ The `AmpsVault`.
    /// @param amps_ The AMPS token.
    /// @param ghosts_ The shared ghost book.
    /// @param keeper_ The keeper the bounty pot pays.
    /// @param constituentIds_ The registry ids of every spoke.
    /// @param pools_ Every pool the campaign drives, hub first.
    constructor(
        AmpsVault vault_,
        Amps amps_,
        Phase3Ghosts ghosts_,
        address keeper_,
        uint16[] memory constituentIds_,
        PoolId[] memory pools_
    ) {
        VAULT = vault_;
        AMPS = amps_;
        GHOSTS = ghosts_;
        KEEPER = keeper_;
        constituentIds = constituentIds_;
        for (uint256 i; i < pools_.length; ++i) {
            pools.push(pools_[i]);
        }
    }

    /// @notice Redeems pro-rata, which is the one path that must never be gated.
    /// @param amountSeed Chooses the size.
    function redeem(uint256 amountSeed) external {
        GHOSTS.open("redeem");
        uint256 balance = AMPS.balanceOf(address(this));
        if (balance > 1e15) {
            uint256 shares = _bound(amountSeed, 1e12, balance / 4);
            try VAULT.redeemProRata(shares, address(this)) {
                GHOSTS.noteSuccess();
            } catch {}
        }
        GHOSTS.close();
    }

    /// @notice Compounds one pool: collect, burn back, split, re-ladder.
    /// @param poolSeed Chooses the pool.
    function compound(uint256 poolSeed) external {
        GHOSTS.open("compound");
        PoolId poolId = pools[poolSeed % pools.length];
        uint256 navBefore = GHOSTS.navNow();
        uint256 pRefBefore = VAULT.pRefX18();
        uint256 creatorBefore = AMPS.balanceOf(VAULT.creator());

        vm.prank(KEEPER);
        try VAULT.compound(poolId) returns (uint256 ampsFees, uint256) {
            GHOSTS.noteCompound(ampsFees, AMPS.balanceOf(VAULT.creator()) - creatorBefore);
            GHOSTS.checkNav(navBefore, pRefBefore);
            GHOSTS.noteSuccess();
        } catch {}
        GHOSTS.close();
    }

    /// @notice Rolls POL out of the entry pools into one spoke.
    /// @param iSeed Chooses the constituent.
    function rollout(uint256 iSeed) external {
        GHOSTS.open("rollout");
        uint256 navBefore = GHOSTS.navNow();
        uint256 pRefBefore = VAULT.pRefX18();
        GHOSTS.rollRolloutWindow();

        vm.prank(KEEPER);
        try VAULT.rollout(constituentIds[iSeed % constituentIds.length]) returns (uint256 moved) {
            GHOSTS.noteRollout(moved);
            GHOSTS.checkNav(navBefore, pRefBefore);
            GHOSTS.noteSuccess();
        } catch {}
        GHOSTS.close();
    }

    /// @notice Places idle bonded collateral as a bid ladder.
    /// @param iSeed Chooses the constituent.
    function deployBonded(uint256 iSeed) external {
        GHOSTS.open("deployBonded");
        uint256 navBefore = GHOSTS.navNow();
        uint256 pRefBefore = VAULT.pRefX18();

        vm.prank(KEEPER);
        try VAULT.deployBonded(constituentIds[iSeed % constituentIds.length]) returns (uint256) {
            GHOSTS.checkNav(navBefore, pRefBefore);
            GHOSTS.noteSuccess();
        } catch {}
        GHOSTS.close();
    }

    /// @notice Recomputes NAV, `P_ref` and `P_mkt`.
    /// @dev **This is a market move, and is labelled as one.** `A` values every position at the *reference*
    ///      sqrt price of the last checkpoint (I7), so taking a new checkpoint after the pools or the feeds have
    ///      moved re-decomposes every ladder cell at a new price and legitimately changes NAV/share in either
    ///      direction. I11 is a statement about *placements* - "navPerShareAfter >= navPerShareBefore x (1 - 2 bp)
    ///      on every placement/compound" - and the vault enforces exactly that itself, reverting `NavBleedExceeded`
    ///      rather than settling, so a successful placement can never set `navEverFell`. Recording a NAV
    ///      comparison here would measure the market, not the protocol.
    function checkpoint() external {
        GHOSTS.open("checkpoint");
        try VAULT.checkpoint() {
            GHOSTS.noteSuccess();
        } catch {}
        GHOSTS.close();
    }

    /// @notice Removes a wei of liquidity from a live cell through the vault's own redemption path, which is the
    ///         only removal that exists - and proves I18: it is never refused, in any gate state.
    /// @param poolSeed Chooses the pool (only used to vary the trace).
    function removeLiquidity(uint256 poolSeed) external {
        GHOSTS.open("removeLiquidity");
        poolSeed;
        if (AMPS.balanceOf(address(this)) > 1e15 && VAULT.liveCells() != 0) {
            try VAULT.redeemProRata(1e12, address(this)) {
                GHOSTS.noteSuccess();
            } catch {
                GHOSTS.noteRemovalBlocked();
            }
        }
        GHOSTS.close();
    }
}
