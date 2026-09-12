// SPDX-License-Identifier: MIT
pragma solidity >=0.6.2 <0.9.0;

import {IFeedRegistry} from "../../../src/interfaces/IFeedRegistry.sol";
import {PriceLib} from "../../../src/lib/PriceLib.sol";
import {Checkpoint, PoolConfig} from "../../../src/types/Types.sol";
import "../Base.sol";
import {Properties} from "../Properties.sol";

/// @notice Handles the interaction with `AmpsVault`: the ungated redemption floor, the three permissionless
///         bountied upkeep paths, the two stamps, and — behind the dispatcher — the governed placements and the
///         banded setters.
///
/// @dev **Roles matter here.** `compound`, `rollout` and `deployBonded` are permissionless *and bountied*, so they
///      are called as `KEEPER` (the address the `BountyPot` pays) rather than as a trader; `checkpoint` and `touch`
///      are permissionless and called as the actor; `redeemProRata` burns the caller's own shares, so it is the
///      actor; `place` is timelock-or-registry and `withdrawRetiredBids` is registry-only, so it is driven through
///      `PoolRegistry.withdrawRetiredBids` as the timelock.
///
/// @dev **`place` is budget-clamped, deliberately.** The ask side can only be placed out of the vault's idle AMPS
///      and the bid side out of what the vault holds of the counter asset (claims plus idle), so an unclamped
///      amount reverts on the inventory bound of §3.8 before any of the gauntlet behind it runs.
///
/// @dev **Every mutative entry point takes its "before" readings and *then* arms a single-shot `vm.prank`.** A
///      prank is consumed by the next external call the harness makes, and a `staticcall` into a view counts, so
///      the acting modifiers cannot survive a handler that has to read state first. See the same note on
///      `AmpsBondsHandler`.
abstract contract AmpsVaultHandler is Properties {
    /// @dev The ERC-6909 claim id of a currency is its address, which is all `Currency.toId()` does. Reading the
    ///      PoolManager through a low-level `staticcall` keeps the v4 type imports out of this file entirely.
    /// @param who The holder.
    /// @param token The currency.
    /// @return amount The claim balance, or zero if the read did not answer.
    function _claim6909(address who, address token) internal view returns (uint256 amount) {
        (bool ok, bytes memory data) = address(poolManager)
            .staticcall(abi.encodeWithSignature("balanceOf(address,uint256)", who, uint256(uint160(token))));
        if (!ok || data.length < 32) return 0;
        return abi.decode(data, (uint256));
    }

    // ――――――――――――――――――――――――― Clamped ――――――――――――――――――――――――――

    /// @notice Recomputes NAV, `P_ref` and `P_mkt`.
    function ampsVault_checkpoint_clamped() public {
        ampsVault_checkpoint();
    }

    /// @notice Stamps layer A alive without recomputing NAV.
    function ampsVault_touch_clamped() public {
        ampsVault_touch();
    }

    /// @notice Compounds one pool: collect, pay the creator, buy back, burn the AMPS side, re-place the counter
    ///         side as bids.
    /// @param poolSeed Chooses the pool.
    function ampsVault_compound_clamped(uint256 poolSeed) public {
        ampsVault_compound(PoolId.unwrap(poolFrom(poolSeed)));
    }

    /// @notice Rolls POL out of the entry pools into one spoke.
    /// @param idSeed Chooses the constituent.
    function ampsVault_rollout_clamped(uint256 idSeed) public {
        ampsVault_rollout(constituentFrom(idSeed));
    }

    /// @notice Places idle bonded collateral as a bid ladder.
    /// @param idSeed Chooses the constituent.
    function ampsVault_deployBonded_clamped(uint256 idSeed) public {
        ampsVault_deployBonded(constituentFrom(idSeed));
    }

    /// @notice Redeems pro-rata out of the actor's own shares — the one path that must never be gated.
    /// @param sharesSeed Chooses the size, bounded by the actor's balance.
    /// @param toSeed Chooses the recipient among the actors.
    function ampsVault_redeemProRata_clamped(uint256 sharesSeed, address toSeed) public {
        uint256 balance = amps.balanceOf(actor);
        if (balance == 0) return;
        uint256 shares = clampBetween(sharesSeed, 1, balance);

        ampsVault_redeemProRata(shares, toActor(toSeed));
    }

    /// @notice The full-balance redemption: every share the actor holds, in one call.
    /// @dev The one handler whose external call is wrapped: SP-16 is a statement about the *catch* arm, and
    ///      `vm.snapshotState` / `vm.revertToState` — the shape a Foundry test would use — are not implemented in
    ///      Medusa 1.5.1.
    function ampsVault_redeemProRata_full() public {
        uint256 balance = amps.balanceOf(actor);
        if (balance == 0) return;

        uint256 navBefore = _tryNavPerShare();
        bool ok = true;
        try this.ampsVault_redeemProRata(balance, actor) {}
        catch {
            ok = false;
            ghosts.livenessReverts[keccak256("redeemFull")] += 1;
        }

        property_fullRedemptionNeverReverts(ok);
        property_fullAmountOpsStayReenterable(_disclosureAnswers(), navBefore, _tryNavPerShare());
    }

    /// @notice A dust redemption. `floor(L * shares / T)` is removed from every record, so a few wei of shares is
    ///         where the removal rounds to nothing in every pool at once.
    /// @param sharesSeed Chooses the dust, 1 wei to 1e9.
    function ampsVault_redeemProRata_dust(uint256 sharesSeed) public {
        uint256 balance = amps.balanceOf(actor);
        if (balance == 0) return;
        uint256 shares = clampBetween(sharesSeed, 1, balance < 1e9 ? balance : 1e9);

        ampsVault_redeemProRata(shares, actor);
    }

    /// @notice Places the vault's **entire** idle side of one pool in one call, so the placement clamp binds at
    ///         `available == amount` rather than under it.
    /// @dev New in this pass — see the "Handlers to add" table of `fizz_data/property-plan.md`.
    /// @param poolSeed Chooses the pool.
    /// @param above Chooses the side.
    function ampsVault_place_full(uint256 poolSeed, bool above) public {
        PoolId poolId = poolFrom(poolSeed);
        uint256 budget = above ? amps.balanceOf(address(vault)) : heldBalance(counterOf(poolId));
        if (budget == 0) return;

        uint256 navBefore = _tryNavPerShare();
        _place(poolId, above, budget);

        property_fullAmountOpsStayReenterable(_disclosureAnswers(), navBefore, _tryNavPerShare());
    }

    /// @notice Buys AMPS out of one pool and immediately redeems every wei of it, in one transaction.
    /// @dev New in this pass — see "Handlers to add". Both legs are wrapped: a refused buy is an ordinary outcome
    ///      (the rail, a dry ladder) and must not take the property down with it.
    /// @param poolSeed Chooses the pool.
    /// @param amountSeed Chooses the size, 1–20 counter units.
    function ampsVault_buyRedeemRoundTrip(uint256 poolSeed, uint256 amountSeed) public {
        PoolId poolId = poolFrom(poolSeed);
        address counter = counterOf(poolId);
        uint256 amountIn = counterUnit(poolId) * clampBetween(amountSeed, 1, 20);
        fundActor(counter, amountIn);
        if (IERC20(counter).balanceOf(actor) < amountIn) return;

        uint256 counterBefore = IERC20(counter).balanceOf(actor);

        uint256 ampsOut;
        vm.prank(actor);
        try ampsRouter.buy(poolId, amountIn, 0, actor, block.timestamp + 1) returns (uint256 out) {
            ampsOut = out;
        } catch {
            return;
        }
        if (ampsOut == 0) return;
        // The floor arbitrage: a redemption that would hand back more counter than the buy paid is the vault
        // working as designed (the buyer forgoes the other 31 slices), not rounding; SP-45 is about rounding.
        bool armed = _previewCounterOut(ampsOut, counter) <= amountIn;

        vm.prank(actor);
        try vault.redeemProRata(ampsOut, actor) returns (address[] memory, uint256[] memory) {
            ghosts.burnedTotal += ampsOut;
        } catch {}

        // SP-45.
        if (armed) property_buyRedeemRoundTripNoProfit(counterBefore, IERC20(counter).balanceOf(actor));
    }

    /// @notice **[C2]** `N ∈ [2, 8]` chained `buy -> redeemProRata` cycles in one transaction, each cycle feeding
    ///         the previous cycle's counter output back in.
    /// @dev New in this pass — the dedicated repeated-cycle dust-extraction handler `fizz_data/property-plan.md`
    ///      requires for SP-46. It is *not* SP-45 with a loop bolted on: the question is whether rounding that is
    ///      invisible on one cycle compounds when the output of one cycle is the input of the next.
    /// @param poolSeed Chooses the pool.
    /// @param amountSeed Chooses the first cycle's size.
    /// @param cyclesSeed Chooses `N`.
    function ampsVault_buyRedeemCycles(uint256 poolSeed, uint256 amountSeed, uint256 cyclesSeed) public {
        PoolId poolId = poolFrom(poolSeed);
        address counter = counterOf(poolId);
        uint256 cycles = clampBetween(cyclesSeed, 2, 8);
        uint256 amountIn = counterUnit(poolId) * clampBetween(amountSeed, 1, 10);
        fundActor(counter, amountIn);
        if (IERC20(counter).balanceOf(actor) < amountIn) return;

        uint256 counterBefore = IERC20(counter).balanceOf(actor);
        uint256 firstIn = amountIn;
        bool armed = true;

        for (uint256 c; c < cycles; ++c) {
            if (amountIn == 0) break;

            uint256 ampsOut;
            vm.prank(actor);
            try ampsRouter.buy(poolId, amountIn, 0, actor, block.timestamp + 1) returns (uint256 out) {
                ampsOut = out;
            } catch {
                break;
            }
            if (ampsOut == 0) break;
            // A cycle the floor arbitrage would pay is not a rounding cycle (see {ampsVault_buyRedeemRoundTrip}).
            if (_previewCounterOut(ampsOut, counter) > amountIn) armed = false;

            uint256 counterMid = IERC20(counter).balanceOf(actor);
            vm.prank(actor);
            try vault.redeemProRata(ampsOut, actor) returns (address[] memory, uint256[] memory) {
                ghosts.burnedTotal += ampsOut;
            } catch {
                break;
            }

            uint256 counterAfterCycle = IERC20(counter).balanceOf(actor);
            amountIn = counterAfterCycle > counterMid ? counterAfterCycle - counterMid : 0;
        }

        // SP-46.
        if (armed) property_repeatedCycleExtractsNothing(firstIn, counterBefore, IERC20(counter).balanceOf(actor));
    }

    /// @dev The counter asset `previewRedeem(shares)` would pay, or zero when the preview is unreadable or does not
    ///      list the token.
    function _previewCounterOut(uint256 shares, address counter) private view returns (uint256 amount) {
        try vault.previewRedeem(shares) returns (address[] memory tokens, uint256[] memory amounts, uint256) {
            for (uint256 i; i < tokens.length; ++i) {
                if (tokens[i] == counter) return amounts[i];
            }
        } catch {}
        return 0;
    }

    /// @notice Donates an ERC-20 straight to a protocol contract, which is the adversarial input to I12's
    ///         "nothing rests on an idle balance" and to every `sweepClean` on the placement paths.
    /// @param targetSeed Chooses the recipient: the vault, the hook or the bond shell.
    /// @param tokenSeed Chooses the token: AMPS, USDG, WETH or one stock.
    /// @param amountSeed Chooses the amount.
    function ampsVault_donateERC20(uint256 targetSeed, uint256 tokenSeed, uint256 amountSeed) public {
        ghosts.navClass = NAV_CLASS_MANAGEMENT;
        address target = targetSeed % 3 == 0 ? address(vault) : (targetSeed % 3 == 1 ? address(hook) : address(bonds));
        address token;
        uint256 kind = tokenSeed % 4;
        if (kind == 0) token = address(amps);
        else if (kind == 1) token = address(usdg);
        else if (kind == 2) token = address(weth);
        else token = address(stocks[tokenSeed % stocks.length]);

        uint256 amount = clampBetween(amountSeed, 1, 1e18);
        if (token != address(amps)) fundActor(token, amount);
        if (IERC20(token).balanceOf(actor) < amount) return;

        snapshotBefore();
        uint256 supplyBefore = amps.totalSupply();
        uint256 donorBefore = IERC20(token).balanceOf(actor);

        vm.prank(actor);
        IERC20(token).transfer(target, amount);

        snapshotAfter();
        if (target == address(hook)) ghosts.hookDonated[token] += amount;

        // SP-01 and SP-59.
        property_mintAttribution(supplyBefore, amps.totalSupply(), 0);
        property_donationBricksNothing(donorBefore, IERC20(token).balanceOf(actor), amount, _disclosureAnswers());
    }

    /// @notice Force-sends native value to a protocol contract. None of them accept ether through a payable
    ///         function, so this is the only way the balance can appear at all.
    /// @param targetSeed Chooses the recipient.
    /// @param amountSeed Chooses the amount.
    function ampsVault_donateETH(uint256 targetSeed, uint256 amountSeed) public {
        ghosts.navClass = NAV_CLASS_MANAGEMENT;
        if (actor.balance == 0) return;
        address target = targetSeed % 3 == 0 ? address(vault) : (targetSeed % 3 == 1 ? address(hook) : address(pot));
        uint256 amount = clampBetween(amountSeed, 1, actor.balance);

        snapshotBefore();
        uint256 supplyBefore = amps.totalSupply();
        uint256 donorBefore = actor.balance;

        Actor(payable(actor)).forceSendETH(target, amount);

        snapshotAfter();

        // SP-01 and SP-59.
        property_mintAttribution(supplyBefore, amps.totalSupply(), 0);
        property_donationBricksNothing(donorBefore, actor.balance, amount, _disclosureAnswers());
    }

    /// @notice The secondary surface: the governed placement and the three banded setters, plus the registry's
    ///         retired-bid withdrawal (the only legitimate caller of `AmpsVault.withdrawRetiredBids`).
    /// @param selector Chooses the action.
    /// @param arg0 First argument seed.
    /// @param arg1 Second argument seed.
    /// @param arg2 Third argument seed.
    /// @param arg3 Fourth argument seed.
    function ampsVault_secondary(uint8 selector, uint256 arg0, uint256 arg1, uint256 arg2, uint256 arg3) public {
        selector = uint8(selector % 5);
        if (selector == 0) {
            _ampsVault_place(arg0, arg1 % 2 == 0, arg2);
        } else if (selector == 4) {
            _ampsVault_withdrawRetiredBids(arg0);
        } else {
            _ampsVault_setter(selector, arg0, arg1, arg2, arg3);
        }
    }

    // ―――――――――――――――――――――――― Unclamped ―――――――――――――――――――――――――

    /// @notice `AmpsVault.checkpoint`, permissionless.
    function ampsVault_checkpoint() public {
        ghosts.navClass = NAV_CLASS_MANAGEMENT;
        snapshotBefore();
        uint256 supplyBefore = amps.totalSupply();

        vm.prank(actor);
        vault.checkpoint();

        snapshotAfter();
        (uint32 ts, uint32 blk) = _checkpointStamp();

        // SP-01 and SP-26. `checkpoint` does not sweep, so SP-27 is not asserted here.
        property_mintAttribution(supplyBefore, amps.totalSupply(), 0);
        property_checkpointIsStamped(true, ts, ts, blk, blk);
    }

    /// @notice `AmpsVault.touch`, permissionless.
    function ampsVault_touch() public {
        ghosts.navClass = NAV_CLASS_MANAGEMENT;
        snapshotBefore();
        uint256 supplyBefore = amps.totalSupply();
        (uint32 tsBefore, uint32 blkBefore) = _checkpointStamp();

        vm.prank(actor);
        vault.touch();

        snapshotAfter();
        (uint32 tsAfter, uint32 blkAfter) = _checkpointStamp();

        // SP-01 and SP-26: `touch` stamps layer A, never the checkpoint.
        property_mintAttribution(supplyBefore, amps.totalSupply(), 0);
        property_checkpointIsStamped(false, tsBefore, tsAfter, blkBefore, blkAfter);
    }

    /// @notice `AmpsVault.compound` as the bountied keeper.
    /// @param poolId The pool.
    function ampsVault_compound(bytes32 poolId) public {
        ghosts.navClass = NAV_CLASS_PLACEMENT;
        snapshotBefore();

        PoolId id = PoolId.wrap(poolId);
        PlacementRecord[] memory ladderBefore = ladderOf(id);
        int24 highWaterBefore = _highWater(id);
        uint256 creatorBefore = amps.balanceOf(vault.creator());
        uint256 potBefore = pot.balance();
        uint256 budgetBefore = _budgetLeftRaw();
        uint256 keeperBefore = usdg.balanceOf(keeper);
        PlaceObs memory o = _placeBefore(id, true);
        o.vaultAmpsBefore = 0; // SP-18's ask leg is asserted on `place`, where the side is unambiguous
        uint256 supplyBefore = amps.totalSupply();

        uint256 ampsFees;
        uint256 burned;
        vm.prank(keeper);
        (ampsFees, burned) = vault.compound(id);

        snapshotAfter();

        // ── ghosts ──
        ghosts.lastCompoundBurned = burned;
        ghosts.burnedTotal += burned;
        ghosts.burnedAmpsTotal += burned;
        ghosts.creatorAmpsGain += amps.balanceOf(vault.creator()) - creatorBefore;
        _notePayout(potBefore, keeperBefore);
        _noteTickAtPlacement(id);

        // ── specific properties ──
        PlacementRecord[] memory ladderAfter = ladderOf(id);
        o.placed = 0;
        o.lastPlacementAfter = vault.lastPlacementAt(id);
        o.navAfter = _tryNavPerShare();
        property_mintAttribution(supplyBefore, amps.totalSupply(), 0);
        property_compoundBurnIsExact(supplyBefore, amps.totalSupply(), burned);
        property_creatorSlicePerCompound(creatorBefore, amps.balanceOf(vault.creator()), ampsFees);
        property_placementBleedBound(o.navBefore, o.navAfter);
        property_sidednessAtPlacement(ladderBefore, ladderAfter, tickOf(id));
        property_placementDivergenceBand(tickOf(id), o);
        property_aboveChangesOnlyWhenEmpty(ladderBefore, ladderAfter);
        property_burnbackBurnsOnlyCrossedAsks(ladderBefore, ladderAfter, highWaterBefore);
        _keeperPayoutProperties(potBefore, budgetBefore, keeperBefore);
        (uint32 cpTs, uint32 cpBlk) = _checkpointStamp();
        property_checkpointIsStamped(true, cpTs, cpTs, cpBlk, cpBlk);
        property_sweepCleanHolds();
    }

    /// @notice `AmpsVault.rollout` as the bountied keeper.
    /// @param constituentId The constituent.
    function ampsVault_rollout(uint16 constituentId) public {
        ghosts.navClass = NAV_CLASS_PLACEMENT;
        snapshotBefore();

        PoolId id = registry.poolIdOf(constituentId);
        PlacementRecord[] memory ladderBefore = ladderOf(id);
        uint256 potBefore = pot.balance();
        uint256 budgetBefore = _budgetLeftRaw();
        uint256 keeperBefore = usdg.balanceOf(keeper);
        PlaceObs memory o = _placeBefore(id, false);
        uint256 supplyBefore = amps.totalSupply();

        vm.prank(keeper);
        uint256 moved = vault.rollout(constituentId);

        snapshotAfter();

        // ── ghosts ──
        ghosts.lastPlaced = moved;
        ghosts.rolloutMovedInWindow += moved;
        if (ghosts.rolloutWindowStart == 0) ghosts.rolloutWindowStart = uint32(block.timestamp);
        _notePayout(potBefore, keeperBefore);
        _noteTickAtPlacement(id);

        // ── specific properties ──
        o.placed = moved;
        o.lastPlacementAfter = vault.lastPlacementAt(id);
        o.navAfter = _tryNavPerShare();
        property_mintAttribution(supplyBefore, amps.totalSupply(), 0);
        property_placementBleedBound(o.navBefore, o.navAfter);
        property_sidednessAtPlacement(ladderBefore, ladderOf(id), tickOf(id));
        property_placementDivergenceBand(tickOf(id), o);
        property_zeroWorkTakesNothing(o);
        _keeperPayoutProperties(potBefore, budgetBefore, keeperBefore);
        (uint32 cpTs, uint32 cpBlk) = _checkpointStamp();
        property_checkpointIsStamped(true, cpTs, cpTs, cpBlk, cpBlk);
        property_sweepCleanHolds();
    }

    /// @notice `AmpsVault.deployBonded` as the bountied keeper.
    /// @param constituentId The constituent.
    function ampsVault_deployBonded(uint16 constituentId) public {
        ghosts.navClass = NAV_CLASS_PLACEMENT;
        snapshotBefore();

        PoolId id = registry.poolIdOf(constituentId);
        PlacementRecord[] memory ladderBefore = ladderOf(id);
        uint256 potBefore = pot.balance();
        uint256 budgetBefore = _budgetLeftRaw();
        uint256 keeperBefore = usdg.balanceOf(keeper);
        PlaceObs memory o = _placeBefore(id, false);
        uint256 supplyBefore = amps.totalSupply();

        vm.prank(keeper);
        uint256 placed = vault.deployBonded(constituentId);

        snapshotAfter();

        // ── ghosts ──
        ghosts.lastPlaced = placed;
        ghosts.bidPlacedRaw[constituentId] += placed;
        _notePayout(potBefore, keeperBefore);
        _noteTickAtPlacement(id);

        // ── specific properties ──
        o.placed = placed;
        o.lastPlacementAfter = vault.lastPlacementAt(id);
        o.navAfter = _tryNavPerShare();
        property_mintAttribution(supplyBefore, amps.totalSupply(), 0);
        property_placementBleedBound(o.navBefore, o.navAfter);
        property_sidednessAtPlacement(ladderBefore, ladderOf(id), tickOf(id));
        property_placementDivergenceBand(tickOf(id), o);
        property_zeroWorkTakesNothing(o);
        _keeperPayoutProperties(potBefore, budgetBefore, keeperBefore);
        (uint32 cpTs, uint32 cpBlk) = _checkpointStamp();
        property_checkpointIsStamped(true, cpTs, cpTs, cpBlk, cpBlk);
        property_sweepCleanHolds();
    }

    /// @notice `AmpsVault.redeemProRata` from the current actor.
    /// @param shares Shares to burn.
    /// @param to Recipient of the basket.
    function ampsVault_redeemProRata(uint256 shares, address to) public {
        ghosts.navClass = NAV_CLASS_REDEEM;
        snapshotBefore();

        RedeemObs memory o;
        o.shares = shares;
        o.feeBps = vault.redeemFeeBps();
        o.supplyBefore = amps.totalSupply();
        o.callerAmpsBefore = amps.balanceOf(actor);
        o.navBefore = _tryNavPerShare();
        o.aBefore = _tryTotalAssets();

        address[] memory tokens;
        uint256[] memory predicted;
        (tokens, predicted, o.previewInventoryBurned) = _tryPreview(shares);
        uint256[] memory recipBefore = _holdingsOf(tokens, to);
        uint256[] memory ampsBefore = _actorAmps();
        uint256[] memory callerBefore = to == actor ? new uint256[](0) : _holdingsOf(tokens, actor);

        PoolId probe = poolFrom(shares);
        PlacementRecord[] memory ladderBefore = ladderOf(probe);

        vm.prank(actor);
        (address[] memory paidTokens, uint256[] memory paidAmounts) = vault.redeemProRata(shares, to);

        snapshotAfter();

        // ── ghosts ──
        ghosts.previewTokens = tokens;
        ghosts.previewAmounts = predicted;
        ghosts.previewInventoryBurned = o.previewInventoryBurned;
        ghosts.lastRedeemTokens = paidTokens;
        ghosts.lastRedeemAmounts = paidAmounts;
        ghosts.burnedTotal += shares + o.previewInventoryBurned;
        noteAmpsHolder(to);

        // ── specific properties ──
        o.supplyAfter = amps.totalSupply();
        o.callerAmpsAfter = amps.balanceOf(actor);
        o.navAfter = _tryNavPerShare();
        o.aAfter = _tryTotalAssets();

        property_mintAttribution(o.supplyBefore, o.supplyAfter, 0);
        property_redemptionBurnIsExact(o);
        property_previewIsThePayout(predicted, _gains(recipBefore, _holdingsOf(tokens, to)));
        property_onlyTheCallersOwnPosition(
            ampsBefore, _actorAmps(), actor, to, "SP-12: a redemption moved a third party's AMPS"
        );
        property_redemptionIsAccretive(o);
        property_redemptionPaysAtMostProRata(o);
        property_redemptionKeepsLadderGeometry(ladderBefore, ladderOf(probe));
        property_sweepCleanHolds();
        if (to != actor) {
            // SP-63: the basket went to `to`. SP-11 above already proved the recipient got the whole preview;
            // what is left to show is that the caller got none of it.
            uint256[] memory callerGain = _gains(callerBefore, _holdingsOf(tokens, actor));
            for (uint256 i; i < callerGain.length; ++i) {
                property_toParameterCreditsTo(0, 0, callerGain[i]);
            }
        }
    }

    /// @dev `place`, sized to what the vault can actually put to work on the chosen side.
    function _ampsVault_place(uint256 poolSeed, bool above, uint256 amountSeed) internal {
        PoolId poolId = poolFrom(poolSeed);
        uint256 budget = above ? amps.balanceOf(address(vault)) : heldBalance(counterOf(poolId));
        if (budget == 0) return;

        _place(poolId, above, clampBetween(amountSeed, 1, budget));
    }

    /// @dev The governed placement itself, with every reading SP-17..SP-23 need around it.
    function _place(PoolId poolId, bool above, uint256 amount) internal {
        ghosts.navClass = NAV_CLASS_PLACEMENT;
        snapshotBefore();

        PlacementRecord[] memory ladderBefore = ladderOf(poolId);
        int24 highWaterBefore = _highWater(poolId);
        PlaceObs memory o = _placeBefore(poolId, above);
        uint256 supplyBefore = amps.totalSupply();

        vm.prank(admin);
        uint256 placed = vault.place(poolId, above, amount);

        snapshotAfter();

        // ── ghosts ──
        ghosts.lastPlaced = placed;
        if (!above) {
            uint16 cid = registry.constituentOfPool(poolId);
            if (cid != 0) ghosts.bidPlacedRaw[cid] += placed;
        }
        _noteTickAtPlacement(poolId);

        // ── specific properties ──
        o.placed = placed;
        o.lastPlacementAfter = vault.lastPlacementAt(poolId);
        o.navAfter = _tryNavPerShare();
        o.vaultAmpsAfter = heldBalance(address(amps));

        PlacementRecord[] memory ladderAfter = ladderOf(poolId);
        property_mintAttribution(supplyBefore, amps.totalSupply(), 0);
        property_placementBleedBound(o.navBefore, o.navAfter);
        property_placementConservesInventoryAndShape(o);
        property_sidednessAtPlacement(ladderBefore, ladderAfter, tickOf(poolId));
        property_placementDivergenceBand(tickOf(poolId), o);
        property_zeroWorkTakesNothing(o);
        property_aboveChangesOnlyWhenEmpty(ladderBefore, ladderAfter);
        property_burnbackBurnsOnlyCrossedAsks(ladderBefore, ladderAfter, highWaterBefore);
        (uint32 cpTs, uint32 cpBlk) = _checkpointStamp();
        property_checkpointIsStamped(true, cpTs, cpTs, cpBlk, cpBlk);
        property_sweepCleanHolds();
    }

    /// @dev The three banded setters behind one value-neutrality check (SP-58).
    function _ampsVault_setter(uint8 selector, uint256 arg0, uint256 arg1, uint256 arg2, uint256 arg3) internal {
        ghosts.navClass = NAV_CLASS_MANAGEMENT;
        snapshotBefore();

        uint256 supplyBefore = amps.totalSupply();
        uint256[] memory actorsBefore = _actorAmps();
        uint256 navBefore = _tryNavPerShare();

        if (selector == 1) _ampsVault_setLadderShape(arg0, arg1, arg2, arg3);
        else if (selector == 2) _ampsVault_setRedeemFeeBps(arg0);
        else _ampsVault_setRolloutParams(arg0, arg1);

        snapshotAfter();

        property_mintAttribution(supplyBefore, amps.totalSupply(), 0);
        property_governedSetterIsValueNeutral(
            supplyBefore, amps.totalSupply(), actorsBefore, _actorAmps(), navBefore, _tryNavPerShare()
        );
    }

    /// @dev The ladder shape, every field inside its own hard band (`Constants`), so the setter exercises the
    ///      shape rather than the band check.
    function _ampsVault_setLadderShape(uint256 tiltSeed, uint256 doublingsSeed, uint256 seedSeed, uint256 bondSeed)
        internal
        asAdmin
    {
        vault.setLadderShape(
            uint64(clampBetween(tiltSeed, Constants.LADDER_TILT_X18_MIN, Constants.LADDER_TILT_X18_MAX)),
            uint8(clampBetween(doublingsSeed, Constants.LADDER_DOUBLINGS_MIN, Constants.LADDER_DOUBLINGS_MAX)),
            uint8(clampBetween(seedSeed, Constants.HALVINGS_MIN, Constants.HALVINGS_MAX)),
            uint8(clampBetween(bondSeed, Constants.HALVINGS_MIN, Constants.HALVINGS_MAX))
        );
    }

    /// @dev `redeemFeeBps` inside `[0, REDEEM_FEE_BPS_MAX]`.
    function _ampsVault_setRedeemFeeBps(uint256 valueSeed) internal asAdmin {
        vault.setRedeemFeeBps(uint16(clampBetween(valueSeed, 0, Constants.REDEEM_FEE_BPS_MAX)));
    }

    /// @dev The rollout schedule and the entry-pool floor, both inside their hard bands.
    function _ampsVault_setRolloutParams(uint256 bpsPerDaySeed, uint256 floorSeed) internal asAdmin {
        vault.setRolloutParams(
            uint16(clampBetween(bpsPerDaySeed, 0, Constants.ROLLOUT_BPS_PER_DAY_MAX)),
            uint16(clampBetween(floorSeed, 0, Constants.ENTRY_FLOOR_BPS_MAX))
        );
    }

    /// @dev Through the registry, which is the only caller `AmpsVault.withdrawRetiredBids` accepts. It only has
    ///      anything to do once the dispatcher in `PoolRegistryHandler` has retired the name.
    function _ampsVault_withdrawRetiredBids(uint256 idSeed) internal {
        ghosts.navClass = NAV_CLASS_PLACEMENT;
        snapshotBefore();

        uint16 constituentId = constituentFrom(idSeed);
        uint256 supplyBefore = amps.totalSupply();
        uint256 navBefore = _tryNavPerShare();

        uint256 heldBefore = heldBalance(counterOf(registry.poolIdOf(constituentId)));

        vm.prank(admin);
        registry.withdrawRetiredBids(constituentId);

        snapshotAfter();
        // `PoolRegistry.withdrawRetiredBids` returns nothing, so what moved is read off the vault's own holding of
        // the retired name's counter asset — which is where the withdrawn bids land.
        uint256 heldAfter = heldBalance(counterOf(registry.poolIdOf(constituentId)));
        ghosts.bidWithdrawnRaw[constituentId] += heldAfter > heldBefore ? heldAfter - heldBefore : 0;

        property_mintAttribution(supplyBefore, amps.totalSupply(), 0);
        property_placementBleedBound(navBefore, _tryNavPerShare());
        (uint32 cpTs, uint32 cpBlk) = _checkpointStamp();
        property_checkpointIsStamped(true, cpTs, cpTs, cpBlk, cpBlk);
        property_sweepCleanHolds();
    }

    // ―――――――――――――――――――― Observation helpers ――――――――――――――――――

    /// @dev The readings every placement-class handler needs from before its call.
    function _placeBefore(PoolId poolId, bool above) private view returns (PlaceObs memory o) {
        o.fairBefore = _fairTick(poolId);
        o.above = above;
        o.navBefore = _tryNavPerShare();
        o.vaultAmpsBefore = heldBalance(address(amps));
        o.lastPlacementBefore = vault.lastPlacementAt(poolId);
    }

    /// @dev The keeper-payout half of every bountied path: SP-29, SP-30's `A`-neutral leg is left to the pot's own
    ///      handler (a keeper call moves `A` for placement reasons), and SP-31.
    function _keeperPayoutProperties(uint256 potBefore, uint256 budgetBefore, uint256 keeperBefore) private {
        uint256 keeperAfter = usdg.balanceOf(keeper);
        property_potChargesWhatItTransfers(potBefore, pot.balance(), keeperBefore, keeperAfter, budgetBefore);
        property_emptyPotDoesNotRevertKeepers(potBefore, keeperBefore, keeperAfter);
    }

    /// @dev `ghosts.potPaidRaw` and the rolling pay ring GL-60 reads.
    function _notePayout(uint256 potBefore, uint256 keeperBefore) private {
        uint256 keeperAfter = usdg.balanceOf(keeper);
        uint256 paid = keeperAfter > keeperBefore ? keeperAfter - keeperBefore : 0;
        potBefore;
        if (paid == 0) return;
        ghosts.potPaidRaw += paid;
        uint256 head = ghosts.payRingHead;
        ghosts.payRingAmount[head] = paid;
        ghosts.payRingStamp[head] = uint32(block.timestamp);
        ghosts.payRingHead = (head + 1) % PAY_RING;
    }

    /// @dev Records the tick each freshly written cell of `poolId` was placed against, for GL-43.
    function _noteTickAtPlacement(PoolId poolId) private {
        bytes32 key = PoolId.unwrap(poolId);
        int24 tick = tickOf(poolId);
        uint256 n = vault.ladderLength(poolId);
        for (uint256 i; i < n && i < 24; ++i) {
            if (ghosts.tickAtPlacementSet[key][i]) continue;
            ghosts.tickAtPlacement[key][i] = tick;
            ghosts.tickAtPlacementSet[key][i] = true;
        }
        ghosts.lastPool = key;
    }

    /// @dev `previewRedeem`, or three empty answers.
    function _tryPreview(uint256 shares)
        private
        view
        returns (address[] memory tokens, uint256[] memory amounts, uint256 inventoryBurned)
    {
        try vault.previewRedeem(shares) returns (address[] memory t, uint256[] memory a, uint256 b) {
            return (t, a, b);
        } catch {
            return (new address[](0), new uint256[](0), 0);
        }
    }

    /// @dev What `who` holds of each token: ERC-20 balance plus ERC-6909 claim, which is what the redemption
    ///      payout may fall back to.
    function _holdingsOf(address[] memory tokens, address who) private view returns (uint256[] memory holdings) {
        holdings = new uint256[](tokens.length);
        for (uint256 i; i < tokens.length; ++i) {
            holdings[i] = IERC20(tokens[i]).balanceOf(who) + _claim6909(who, tokens[i]);
        }
    }

    /// @dev Element-wise `after - before`, floored at zero.
    function _gains(uint256[] memory before, uint256[] memory afterv) private pure returns (uint256[] memory gain) {
        gain = new uint256[](before.length);
        for (uint256 i; i < before.length && i < afterv.length; ++i) {
            gain[i] = afterv[i] > before[i] ? afterv[i] - before[i] : 0;
        }
    }

    /// @dev `hook.highWaterTick`, or zero.
    function _highWater(PoolId poolId) private view returns (int24 tick) {
        try hook.highWaterTick(poolId) returns (int24 v) {
            return v;
        } catch {
            return 0;
        }
    }

    /// @dev `hook.fairTick`, or zero (which SP-20 reads as "no band to be inside of").
    /// @dev The fair tick the vault's own divergence guard measures against (`VaultPlacementLib._requireConverged`):
    ///      `PriceLib.fairTick(pMkt or pRef, feed answer, decimals, spacing)`. The hook's cached `fairTick` is a
    ///      different quantity (refreshed on swaps, on a TTL), and comparing against it fired SP-20 on a feed walk
    ///      the cache had not seen (2026-09-10 campaign). Zero means "no usable price": the guard skips, so do we.
    function _fairTick(PoolId poolId) private view returns (int24 tick) {
        uint256 priceUsd18;
        try vault.checkpointData() returns (Checkpoint memory c) {
            priceUsd18 = c.pMktX18 != 0 ? c.pMktX18 : c.pRefX18;
        } catch {
            return 0;
        }
        PoolConfig memory config;
        try registry.poolConfig(poolId) returns (PoolConfig memory cfg) {
            config = cfg;
        } catch {
            return 0;
        }
        if (priceUsd18 == 0 || config.counter == address(0) || config.counterDecimals > PriceLib.MAX_COUNTER_DECIMALS) {
            return 0;
        }
        // The guard reads the answer through `_probeWord`: one `staticcall` capped at `COMPOSITE_READ_GAS`, zero
        // unless at least 96 bytes came back. Mirrored exactly, so a read the guard treats as "no answer" (and
        // skips on) is one the harness skips on too.
        (bool ok, bytes memory ret) = address(feeds).staticcall{gas: Constants.COMPOSITE_READ_GAS}(
            abi.encodeCall(IFeedRegistry.latestAnswer, (config.counter))
        );
        if (!ok || ret.length < 96) return 0;
        uint256 answerUsd8 = abi.decode(ret, (uint256));
        if (answerUsd8 == 0) return 0;
        return PriceLib.fairTick(priceUsd18, answerUsd8, config.counterDecimals, config.tickSpacing);
    }

    /// @dev `pot.budgetLeftRaw`, or zero.
    function _budgetLeftRaw() private view returns (uint256 amount) {
        try pot.budgetLeftRaw() returns (uint256 v) {
            return v;
        } catch {
            return 0;
        }
    }
}
