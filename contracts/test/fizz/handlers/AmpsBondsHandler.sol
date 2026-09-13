// SPDX-License-Identifier: MIT
pragma solidity >=0.6.2 <0.9.0;

import {PriceLib} from "../../../src/lib/PriceLib.sol";
import {Checkpoint} from "../../../src/types/Types.sol";
import "../Base.sol";
import {Properties} from "../Properties.sol";

/// @notice Handles the interaction with `AmpsBonds`, the only path that mints AMPS: deposit a Stock Token, receive
///         AMPS at a discount, claim it over the vesting window.
///
/// @dev **The bond is sized to the market's remaining capacity, deliberately.** `bond` clamps the AMPS it issues to
///      the epoch's remaining capacity but keeps the *whole* deposit — `minAmpsOut` is the bonder's only protection
///      — so a handler that deposits an arbitrary amount silently donates the excess to NAV and poisons every NAV
///      statement downstream. The clamped handler derives the deposit from `quote` exactly as
///      `Phase3Fixture.seedSpokeBids` and `Phase3Handler.bond` do, and sets `minAmpsOut`.
///
/// @dev **Collateral is minted on demand.** Setup does not hand every actor every stock: at the launch shape that
///      is 90 mints and 360 approvals of pure constructor gas. The clamped handlers mint what the call needs, which
///      is also what makes the *deposit* the fuzzed quantity rather than the balance.
///
/// @dev **Why the `asActor` modifier is gone from the mutative entry points.** A `vm.prank` is consumed by the very
///      next external call the harness makes — a `staticcall` into a view counts — so a handler that has to read
///      `totalSupply`, the shell's balance and the market's capacity *before* the call cannot carry the prank in a
///      modifier: the modifier arms it before the reads, and the first read eats it. Every one of these functions
///      therefore takes its "before" readings first and then arms a single-shot `vm.prank(actor)` immediately in
///      front of the protocol call, which is the same discipline `_ampsVault_place` already used.
///
/// @dev **No `try/catch` around the protocol call on the ordinary paths, on purpose.** A revert propagates and the
///      handler's property assertions never run, which is exactly "only assert on the success arm" — with none of
///      the gas of a catch frame and without turning a genuine refusal into a silent success for
///      `FoundryTester.test_sequence`. `try/catch` appears only where a property is *about* the failure arm
///      (`adversary_refreshThenBond`) or where a later leg of a multi-step handler is allowed to refuse.
abstract contract AmpsBondsHandler is Properties {
    // ――――――――――――――――――――――――― Clamped ――――――――――――――――――――――――――

    /// @notice Buys a bond on one market, sized to the epoch's remaining capacity.
    /// @param marketSeed Chooses the market.
    /// @param fractionSeed Chooses how much of the remaining capacity to take.
    function ampsBonds_bond_clamped(uint256 marketSeed, uint256 fractionSeed) public {
        uint256 i = marketSeed % marketIds.length;
        uint16 marketId = marketIds[i];

        uint256 capacity = bonds.capacityRemaining(marketId);
        if (capacity == 0) return;
        uint256 want = clampBetween(fractionSeed, capacity / 10 + 1, capacity);

        uint256 perUnit = _quotePerUnit(marketId);
        if (perUnit == 0) return;
        uint256 collateral = want * 1e18 / perUnit;
        if (collateral == 0) return;

        stocks[i].mint(actor, collateral);
        approveAll(address(stocks[i]), actor);

        ampsBonds_bond(marketId, collateral, want / 2, actor);
    }

    /// @notice A dust bond: one wei of collateral, which is where the AMPS the deposit is worth truncates to zero
    ///         and where `minAccretionBps` decides whether the mint is refused instead.
    /// @param marketSeed Chooses the market.
    /// @param amountSeed Chooses the dust.
    function ampsBonds_bond_dust(uint256 marketSeed, uint256 amountSeed) public {
        uint256 i = marketSeed % marketIds.length;
        uint256 collateral = clampBetween(amountSeed, 1, 1e6);

        stocks[i].mint(actor, collateral);
        approveAll(address(stocks[i]), actor);

        ampsBonds_bond(marketIds[i], collateral, 0, actor);
    }

    /// @notice The full-balance bond: everything the actor holds of that collateral, which is the case that
    ///         over-pays the capacity clamp and hands the surplus to NAV.
    /// @param marketSeed Chooses the market.
    function ampsBonds_bond_full(uint256 marketSeed) public {
        uint256 i = marketSeed % marketIds.length;
        uint256 balance = stocks[i].balanceOf(actor);
        if (balance == 0) return;
        approveAll(address(stocks[i]), actor);

        uint256 navBefore = _tryNavPerShare();
        ampsBonds_bond(marketIds[i], balance, 0, actor);

        // SP-60: the whole balance has gone through in one call; the protocol must still be enterable.
        property_fullAmountOpsStayReenterable(_disclosureAnswers(), navBefore, _tryNavPerShare());
    }

    /// @notice The bond that makes the capacity clamp bind at *equality*: a deposit priced at exactly the market's
    ///         remaining capacity, so `ampsOut == capacityRemaining` before rather than under it.
    /// @dev New in this pass — see the "Handlers to add" table of `fizz_data/property-plan.md`. Without it the
    ///      clamp's boundary (`priced.ampsOut > available`) is only ever approached from one side.
    /// @param marketSeed Chooses the market.
    function ampsBonds_bond_wholeCapacity(uint256 marketSeed) public {
        uint256 i = marketSeed % marketIds.length;
        uint16 marketId = marketIds[i];

        uint256 capacity = bonds.capacityRemaining(marketId);
        if (capacity == 0) return;
        uint256 perUnit = _quotePerUnit(marketId);
        if (perUnit == 0) return;

        // Round the collateral *up*, so the priced AMPS lands at or just past the capacity and the clamp binds.
        uint256 collateral = (capacity * 1e18 + perUnit - 1) / perUnit;
        if (collateral == 0) return;

        stocks[i].mint(actor, collateral);
        approveAll(address(stocks[i]), actor);

        uint256 navBefore = _tryNavPerShare();
        ampsBonds_bond(marketId, collateral, 0, actor);

        // SP-60: a capacity-filling bond leaves the protocol enterable.
        property_fullAmountOpsStayReenterable(_disclosureAnswers(), navBefore, _tryNavPerShare());
    }

    /// @notice A bond whose vesting position is handed to *another* actor, which is the shape an attacker uses to
    ///         grow a victim's position array (GL-15) and the only way to see `to != msg.sender` on this path.
    /// @dev New in this pass — see "Handlers to add".
    /// @param marketSeed Chooses the market.
    /// @param fractionSeed Chooses how much of the remaining capacity to take.
    /// @param victimSeed Chooses the victim among the other actors.
    function ampsBonds_bond_toVictim(uint256 marketSeed, uint256 fractionSeed, address victimSeed) public {
        uint256 i = marketSeed % marketIds.length;
        uint16 marketId = marketIds[i];
        address victim = toActorNotCurrent(victimSeed);
        if (victim == actor) return;

        uint256 capacity = bonds.capacityRemaining(marketId);
        if (capacity == 0) return;
        uint256 want = clampBetween(fractionSeed, 1, capacity);
        uint256 perUnit = _quotePerUnit(marketId);
        if (perUnit == 0) return;
        uint256 collateral = want * 1e18 / perUnit;
        if (collateral == 0) return;

        stocks[i].mint(actor, collateral);
        approveAll(address(stocks[i]), actor);

        uint256 senderCountBefore = bonds.positionCount(actor);
        uint256 victimCountBefore = bonds.positionCount(victim);

        ampsBonds_bond(marketId, collateral, 0, victim);

        // SP-63: the position went to `to`, not to `msg.sender`.
        property_toParameterCreditsTo(
            bonds.positionCount(victim) - victimCountBefore, 1, bonds.positionCount(actor) - senderCountBefore
        );
    }

    /// @notice `vault.checkpoint()`, then `bonds.quote`, then `bonds.bond` — all three in one block, which is the
    ///         only arrangement in which the quote and the bond are required to agree.
    /// @dev New in this pass — see "Handlers to add"; SP-07's same-block precondition is x-ray X-7.
    /// @param marketSeed Chooses the market.
    /// @param fractionSeed Chooses how much of the remaining capacity to take.
    function ampsBonds_quoteMatchesBond(uint256 marketSeed, uint256 fractionSeed) public {
        uint256 i = marketSeed % marketIds.length;
        uint16 marketId = marketIds[i];

        try vault.checkpoint() {}
        catch {
            return; // no checkpoint, no same-block basis to compare on
        }
        try vault.checkpoint() {} catch {} // the second convergence step; see {ampsBonds_bond}

        uint256 capacity = bonds.capacityRemaining(marketId);
        if (capacity == 0) return;
        uint256 want = clampBetween(fractionSeed, capacity / 10 + 1, capacity);
        uint256 perUnit = _quotePerUnit(marketId);
        if (perUnit == 0) return;
        uint256 collateral = want * 1e18 / perUnit;
        if (collateral == 0) return;

        stocks[i].mint(actor, collateral);
        approveAll(address(stocks[i]), actor);

        uint256 navQuoteBasis = _storedNavPerShare();
        (uint256 quoted,, uint16 discountBps,,, bytes32 reason) = bonds.quote(marketId, collateral);
        if (discountBps > ghosts.maxDiscountSeen[marketId]) ghosts.maxDiscountSeen[marketId] = discountBps;

        ampsBonds_bond(marketId, collateral, 0, actor);

        // SP-07: reached only when the bond above did not revert. The bond's own checkpoint may have moved the
        // basis between the quote and the pricing; the property rescales by exactly that.
        property_quoteMatchesBond(quoted, ghosts.lastBondIssued, reason, navQuoteBasis, _storedNavPerShare());
    }

    /// @notice `feeds.refresh(token)` and `bonds.bond(...)` in one transaction: the shape a bonder would use to try
    ///         to talk the bond side into a price the registry has not confirmed.
    /// @dev New in this pass — see "Handlers to add". The bond leg is wrapped so that the *refusal* is observable,
    ///      which is the half of SP-57 that can be asserted from outside.
    /// @param tokenSeed Chooses the token to refresh.
    /// @param marketSeed Chooses the market to bond.
    /// @param fractionSeed Chooses the size.
    function adversary_refreshThenBond(uint256 tokenSeed, uint256 marketSeed, uint256 fractionSeed) public {
        address[] memory tokens = feedTokens();
        address token = tokens[tokenSeed % tokens.length];

        vm.prank(actor);
        try feeds.refresh(token) {} catch {}

        uint256 i = marketSeed % marketIds.length;
        uint16 marketId = marketIds[i];
        uint256 capacity = bonds.capacityRemaining(marketId);
        if (capacity == 0) return;
        uint256 want = clampBetween(fractionSeed, 1, capacity);
        uint256 perUnit = _quotePerUnit(marketId);
        if (perUnit == 0) return;
        uint256 collateral = want * 1e18 / perUnit;
        if (collateral == 0) return;

        stocks[i].mint(actor, collateral);
        approveAll(address(stocks[i]), actor);

        ghosts.expectedHaircutFloorBps = _haircutBps(marketId);
        ghosts.lastBondCollateralPriceUsd18 = _tryPriceUsd18(bonds.market(marketId).collateral);
        bool held = _navUnconfirmed();

        bool landed = true;
        vm.prank(actor);
        try bonds.bond(marketId, collateral, 0, actor) returns (uint256 ampsOut, uint256) {
            ghosts.mintedByBonds += ampsOut;
            ghosts.bondIssuedTotal += ampsOut;
            noteBonder(actor);
        } catch {
            landed = false;
        }

        // SP-57: a held-back answer must refuse the bond that rode in behind the refresh.
        property_refreshThenBondUsesTheHeldAnswer(held, landed);
    }

    /// @notice `bond`, warp past the vest, `claim`, then redeem the AMPS — the whole life of a position in one
    ///         call, which is the only way to see whether the cycle gives back more than it took.
    /// @dev New in this pass — see "Handlers to add".
    /// @param marketSeed Chooses the market.
    /// @param fractionSeed Chooses the size.
    function ampsBonds_bondClaimRedeemRoundTrip(uint256 marketSeed, uint256 fractionSeed) public {
        uint256 i = marketSeed % marketIds.length;
        uint16 marketId = marketIds[i];

        uint256 capacity = bonds.capacityRemaining(marketId);
        if (capacity == 0) return;
        uint256 want = clampBetween(fractionSeed, capacity / 10 + 1, capacity);
        uint256 perUnit = _quotePerUnit(marketId);
        if (perUnit == 0) return;
        uint256 collateral = want * 1e18 / perUnit;
        if (collateral == 0) return;

        stocks[i].mint(actor, collateral);
        approveAll(address(stocks[i]), actor);

        address collateralToken = address(stocks[i]);
        uint256 collateralBefore = IERC20(collateralToken).balanceOf(actor);
        uint256 navBefore = _tryNavPerShare();

        uint256 ampsOut;
        {
            vm.prank(actor);
            try bonds.bond(marketId, collateral, 0, actor) returns (uint256 out, uint256) {
                ampsOut = out;
                ghosts.mintedByBonds += out;
                ghosts.bondIssuedTotal += out;
                noteBonder(actor);
            } catch {
                return;
            }
        }

        warpBy(uint256(bonds.vestSeconds()) + 1);

        vm.prank(actor);
        try bonds.claimAll(actor) returns (uint256) {} catch {}

        uint256 shares = amps.balanceOf(actor);
        if (shares > ampsOut) shares = ampsOut;
        if (shares != 0) {
            vm.prank(actor);
            try vault.redeemProRata(shares, actor) returns (address[] memory, uint256[] memory) {
                ghosts.burnedTotal += shares;
            } catch {}
        }

        // SP-47: the cycle gave back no more collateral than it put in, and did not bleed NAV/share.
        property_bondClaimRedeemCycle(
            collateralBefore, IERC20(collateralToken).balanceOf(actor), navBefore, _tryNavPerShare()
        );
    }

    /// @notice Claims whatever has vested on one of the actor's positions.
    /// @param idSeed Chooses the position.
    function ampsBonds_claim_clamped(uint256 idSeed) public {
        uint256 count = bonds.positionCount(actor);
        if (count == 0) return;

        ampsBonds_claim(idSeed % count, actor);
    }

    /// @notice Claims every vested wei across all of the actor's positions in one pass.
    function ampsBonds_claimAll_clamped() public {
        if (bonds.positionCount(actor) == 0) return;

        ampsBonds_claimAll(actor);
    }

    /// @notice The secondary surface: the five governed bond parameters, each inside its own hard band.
    /// @param selector Chooses the setter.
    /// @param arg0 First argument seed.
    /// @param arg1 Second argument seed.
    /// @param arg2 Third argument seed.
    /// @param arg3 Fourth argument seed.
    function ampsBonds_secondary(uint8 selector, uint256 arg0, uint256 arg1, uint256 arg2, uint256 arg3) public {
        ghosts.navClass = NAV_CLASS_MANAGEMENT;
        snapshotBefore();

        uint256 supplyBefore = amps.totalSupply();
        uint256[] memory actorsBefore = _actorAmps();
        uint256 navBefore = _tryNavPerShare();

        selector = uint8(selector % 5);
        if (selector == 0) _ampsBonds_setCapBpsPerEpoch(arg0, arg1);
        else if (selector == 1) _ampsBonds_setDailyCapBps(arg0);
        else if (selector == 2) _ampsBonds_setDiscountParams(arg3, arg0, arg1, arg2);
        else if (selector == 3) _ampsBonds_setMarketOpen(arg0, arg1 % 2 == 0);
        else _ampsBonds_setVestSeconds(arg0);

        snapshotAfter();

        // SP-01 and SP-58.
        property_mintAttribution(supplyBefore, amps.totalSupply(), 0);
        property_governedSetterIsValueNeutral(
            supplyBefore, amps.totalSupply(), actorsBefore, _actorAmps(), navBefore, _tryNavPerShare()
        );
    }

    // ―――――――――――――――――――――――― Unclamped ―――――――――――――――――――――――――

    /// @notice `AmpsBonds.bond` with whatever the fuzzer chose, from the current actor.
    /// @param marketId The market.
    /// @param amountIn Collateral in.
    /// @param minAmpsOut Slippage floor.
    /// @param to Recipient of the vesting position.
    function ampsBonds_bond(uint16 marketId, uint256 amountIn, uint256 minAmpsOut, address to) public {
        ghosts.navClass = NAV_CLASS_BOND;
        ghosts.lastBondIssued = 0;
        // Isolate the issuance from the vault's own checkpoint: `depositBonded` runs `_checkpoint()` before the
        // collateral settles (X-7), which latches moved feeds and re-derives `P_ref`. Checkpointing here first, in
        // the same block, leaves that step only the reference's self-referential convergence residue (positions
        // are valued at the previous checkpoint's `P_ref`; SP-05's NatSpec, lead L-1). Twice, so what is left for
        // the bond's own step is ~ratio² of the first (2026-09-10 campaign: a feed walk followed by a dust bond
        // fired SP-05 on that revaluation, not on the bond).
        try vault.checkpoint() {} catch {}
        try vault.checkpoint() {} catch {}
        snapshotBefore();

        BondObs memory o = _bondBefore(marketId, amountIn, minAmpsOut, to);

        vm.prank(actor);
        (o.issued, o.positionId) = bonds.bond(marketId, amountIn, minAmpsOut, to);

        snapshotAfter();
        _bondAfter(o);
    }

    /// @notice `AmpsBonds.claim`, which reads nothing but the caller's own positions (I38).
    /// @param positionId The position.
    /// @param to Recipient.
    function ampsBonds_claim(uint256 positionId, address to) public {
        ghosts.navClass = NAV_CLASS_MANAGEMENT;
        snapshotBefore();

        ClaimObs memory o;
        o.single = true;
        o.recipient = to;
        o.supplyBefore = amps.totalSupply();
        o.shellBefore = amps.balanceOf(address(bonds));
        o.recipBefore = amps.balanceOf(to);
        o.posBefore = bonds.position(actor, positionId);
        uint256[] memory claimableBefore = _actorClaimable();

        uint256 gasBefore = gasleft();
        vm.prank(actor);
        o.paid = bonds.claim(positionId, to);
        uint256 gasUsed = gasBefore - gasleft();

        snapshotAfter();

        o.supplyAfter = amps.totalSupply();
        o.shellAfter = amps.balanceOf(address(bonds));
        o.recipAfter = amps.balanceOf(to);
        o.posAfter = bonds.position(actor, positionId);

        if (gasUsed > ghosts.maxPerIdClaimGas) ghosts.maxPerIdClaimGas = gasUsed;
        ghosts.bondClaimed[actor][positionId] = o.posAfter.claimed;
        noteAmpsHolder(to);

        property_mintAttribution(o.supplyBefore, o.supplyAfter, 0);
        property_claimMovesOnlyTheShellsAmps(o);
        property_onlyTheCallersOwnPosition(
            claimableBefore, _actorClaimable(), actor, to, "SP-12: a claim moved a third party's claimable total"
        );
        if (to != actor) {
            property_toParameterCreditsTo(o.recipAfter - o.recipBefore, o.paid, 0);
        }
    }

    /// @notice `AmpsBonds.claimAll`.
    /// @param to Recipient.
    function ampsBonds_claimAll(address to) public {
        ghosts.navClass = NAV_CLASS_MANAGEMENT;
        snapshotBefore();

        ClaimObs memory o;
        o.recipient = to;
        o.supplyBefore = amps.totalSupply();
        o.shellBefore = amps.balanceOf(address(bonds));
        o.recipBefore = amps.balanceOf(to);
        uint256[] memory claimableBefore = _actorClaimable();

        vm.prank(actor);
        o.paid = bonds.claimAll(to);

        snapshotAfter();

        o.supplyAfter = amps.totalSupply();
        o.shellAfter = amps.balanceOf(address(bonds));
        o.recipAfter = amps.balanceOf(to);
        noteAmpsHolder(to);

        property_mintAttribution(o.supplyBefore, o.supplyAfter, 0);
        property_claimMovesOnlyTheShellsAmps(o);
        property_onlyTheCallersOwnPosition(
            claimableBefore, _actorClaimable(), actor, to, "SP-12: a claimAll moved a third party's claimable total"
        );
        // SP-09's `claimAll` leg: the caller has nothing pending left.
        eq(bonds.claimableTotal(actor), 0, "SP-09: claimAll left the caller with something still claimable");
        if (to != actor) {
            property_toParameterCreditsTo(o.recipAfter - o.recipBefore, o.paid, 0);
        }
    }

    /// @dev The per-market epoch capacity inside `[0, BOND_CAP_BPS_PER_EPOCH_MAX]`.
    function _ampsBonds_setCapBpsPerEpoch(uint256 marketSeed, uint256 valueSeed) internal asAdmin {
        bonds.setCapBpsPerEpoch(
            marketFrom(marketSeed), uint16(clampBetween(valueSeed, 0, Constants.BOND_CAP_BPS_PER_EPOCH_MAX))
        );
    }

    /// @dev The global daily cap inside `[0, BOND_DAILY_CAP_BPS_MAX]`.
    function _ampsBonds_setDailyCapBps(uint256 valueSeed) internal asAdmin {
        bonds.setDailyCapBps(uint16(clampBetween(valueSeed, 0, Constants.BOND_DAILY_CAP_BPS_MAX)));
    }

    /// @dev The three discount coefficients, each inside `[DISCOUNT_BPS_MIN, DISCOUNT_BPS_MAX]` and with
    ///      `dMin <= dMax`, which the setter also enforces.
    function _ampsBonds_setDiscountParams(uint256 marketSeed, uint256 baseSeed, uint256 minSeed, uint256 maxSeed)
        internal
        asAdmin
    {
        uint16 dMin = uint16(clampBetween(minSeed, Constants.DISCOUNT_BPS_MIN, Constants.DISCOUNT_BPS_MAX));
        uint16 dMax = uint16(clampBetween(maxSeed, dMin, Constants.DISCOUNT_BPS_MAX));
        uint16 dBase = uint16(clampBetween(baseSeed, Constants.DISCOUNT_BPS_MIN, Constants.DISCOUNT_BPS_MAX));

        bonds.setDiscountParams(marketFrom(marketSeed), dBase, dMin, dMax);
    }

    /// @dev Opens or closes one market, which is what makes `MarketClosed` reachable on the bond path.
    function _ampsBonds_setMarketOpen(uint256 marketSeed, bool open) internal asAdmin {
        bonds.setMarketOpen(marketFrom(marketSeed), open);
    }

    /// @dev The vesting window inside `[BOND_VEST_SECONDS_MIN, BOND_VEST_SECONDS_MAX]`.
    function _ampsBonds_setVestSeconds(uint256 valueSeed) internal asAdmin {
        bonds.setVestSeconds(
            uint32(clampBetween(valueSeed, Constants.BOND_VEST_SECONDS_MIN, Constants.BOND_VEST_SECONDS_MAX))
        );
    }

    // ―――――――――――――――― The bond observation ――――――――――――――――――

    /// @dev Every reading SP-02..SP-08 need from *before* the bond. Taken before the prank is armed, because a
    ///      `staticcall` would consume it.
    function _bondBefore(uint16 marketId, uint256 amountIn, uint256 minAmpsOut, address to)
        private
        returns (BondObs memory o)
    {
        o.marketId = marketId;
        o.amountIn = amountIn;
        o.minAmpsOut = minAmpsOut;
        o.to = to;
        o.collateral = bonds.market(marketId).collateral;
        o.vestSeconds = bonds.vestSeconds();
        o.supplyBefore = amps.totalSupply();
        o.shellAmpsBefore = amps.balanceOf(address(bonds));
        o.countBefore = bonds.positionCount(to);
        o.capacityBefore = _tryCapacity(marketId);
        o.navBefore = _tryNavPerShare();
        if (o.collateral != address(0)) {
            o.bonderCollBefore = IERC20(o.collateral).balanceOf(actor);
            o.vaultHeldBefore = heldBalance(o.collateral);
            o.shellCollBefore = IERC20(o.collateral).balanceOf(address(bonds));
        }

        ghosts.lastCollateral = o.collateral;
        ghosts.lastHaircutBps = _haircutBps(marketId);
        ghosts.lastBondCollateralPriceUsd18 = _tryPriceUsd18(o.collateral);
    }

    /// @dev The "after" half plus every ghost update and every specific property the wiring plan lists for
    ///      `ampsBonds_bond*`.
    function _bondAfter(BondObs memory o) private {
        o.supplyAfter = amps.totalSupply();
        o.shellAmpsAfter = amps.balanceOf(address(bonds));
        o.navAfter = _tryNavPerShare();
        o.navBondBasis = _storedNavPerShare();
        o.haircutBps = ghosts.lastHaircutBps;
        o.minAccretionBps = bonds.minAccretionBps();
        if (o.collateral != address(0)) {
            o.collateralDecimals = bonds.market(o.marketId).decimals;
            o.collateralPriceUsd18 = _shellCollateralPriceUsd18(o.collateral, o.collateralDecimals);
        }
        if (o.collateral != address(0)) {
            o.bonderCollAfter = IERC20(o.collateral).balanceOf(actor);
            o.vaultHeldAfter = heldBalance(o.collateral);
            o.shellCollAfter = IERC20(o.collateral).balanceOf(address(bonds));
        }

        // ── ghosts ──
        ghosts.lastBondIssued = o.issued;
        ghosts.mintedByBonds += o.issued;
        ghosts.bondIssuedTotal += o.issued;
        ghosts.bondPrincipal[o.to][o.positionId] = o.issued;
        ghosts.principalSeen[o.to][o.positionId] = o.issued;
        ghosts.startSeen[o.to][o.positionId] = block.timestamp;
        ghosts.vestSecondsAtPurchase[o.to][o.positionId] = o.vestSeconds;
        ghosts.marketIdSeen[o.to][o.positionId] = o.marketId;
        ghosts.epochIssuedGhost[o.marketId] += o.issued;
        ghosts.dayIssuedGhost += o.issued;
        if (ghosts.supplyAtEpochStart[o.marketId] == 0) ghosts.supplyAtEpochStart[o.marketId] = o.supplyBefore;
        if (ghosts.supplyAtDayStart == 0) ghosts.supplyAtDayStart = o.supplyBefore;
        noteBonder(o.to);
        noteAmpsHolder(o.to);

        // ── specific properties ──
        property_mintAttribution(o.supplyBefore, o.supplyAfter, o.issued);
        property_bondAppendsOnePosition(o);
        property_bondMintsIntoCustody(o);
        if (o.collateral != address(0)) property_bondDepositConservation(o);
        property_bondIsAccretive(o);
        property_bondWithinCapacityOnOffer(o);
        property_bondSurplusReachesHolders(o);
        (uint32 cpTs, uint32 cpBlk) = _checkpointStamp();
        property_checkpointIsStamped(true, cpTs, cpTs, cpBlk, cpBlk);
        property_sweepCleanHolds();
    }

    // ―――――――――――――――― Reads that must not revert ――――――――――――――――

    /// @dev The AMPS one whole unit of collateral is worth right now, or zero when the market cannot price.
    function _quotePerUnit(uint16 marketId) private view returns (uint256 ampsOut) {
        try bonds.quote(marketId, 1e18) returns (uint256 out, uint256, uint16, bool, uint256, bytes32) {
            return out;
        } catch {
            return 0;
        }
    }

    /// @dev `capacityRemaining`, or zero.
    function _tryCapacity(uint16 marketId) private view returns (uint256 amount) {
        try bonds.capacityRemaining(marketId) returns (uint256 v) {
            return v;
        } catch {
            return 0;
        }
    }

    /// @dev The bond haircut the gate would apply to this market's constituent, or zero.
    function _haircutBps(uint16 marketId) private view returns (uint16 bps) {
        try gate.isBondAllowed(bonds.market(marketId).constituentId) returns (bool, uint16 h) {
            return h;
        } catch {
            return 0;
        }
    }

    /// @dev `checkpointData().navPerShareX18`, or zero: the basis the bond shell prices against.
    function _storedNavPerShare() private view returns (uint256 navPerShareX18) {
        try vault.checkpointData() returns (Checkpoint memory c) {
            return c.navPerShareX18;
        } catch {
            return 0;
        }
    }

    /// @dev Exactly `AmpsBonds._collateralPriceUsd18`: the raw `latestAnswer` scaled by `PriceLib.counterValueUsd18`
    ///      over one whole token, or zero when the answer is.
    function _shellCollateralPriceUsd18(address token, uint8 decimals) private view returns (uint256 price18) {
        if (decimals > PriceLib.MAX_COUNTER_DECIMALS) return 0;
        try feeds.latestAnswer(token) returns (uint256 answerUsd8, uint32, bool) {
            if (answerUsd8 == 0) return 0;
            return PriceLib.counterValueUsd18(10 ** decimals, decimals, answerUsd8);
        } catch {
            return 0;
        }
    }

    /// @dev `feeds.priceUsd18(token)`, or zero.
    function _tryPriceUsd18(address token) private view returns (uint256 price) {
        if (token == address(0)) return 0;
        try feeds.priceUsd18(token) returns (uint256 v) {
            return v;
        } catch {
            return 0;
        }
    }

    /// @dev `vault.navUnconfirmed()`, or false.
    function _navUnconfirmed() private view returns (bool held) {
        try vault.navUnconfirmed() returns (bool v) {
            return v;
        } catch {
            return false;
        }
    }
}
