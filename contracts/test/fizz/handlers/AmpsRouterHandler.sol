// SPDX-License-Identifier: MIT
pragma solidity >=0.6.2 <0.9.0;

import "../Base.sol";
import {Properties} from "../Properties.sol";

/// @notice Handles the interaction with `AmpsRouter`, the protocol's own entry, exit and rotation router.
///
/// @dev **Every trade here is a real swap through the real hook.** `buy` and `sell` pay `ampsFeeBps` in the input
///      currency exactly as any other router's swap would; `rotate` is the one shape the hook prices at the
///      pass-through fee, and the audit fix of 2026-09-08 requires at least one leg to be a constituent's spoke,
///      which is why the clamped rotation always draws hop 1 from `spokePools`.
///
/// @dev **Sizing.** The clamped handlers trade in `counterUnit(poolId)` multiples — the sizes
///      `test/invariant/Phase3Handler.sol` settled on — because the hook's outer rail is measured against
///      `fairTick` and refuses a jump larger than the rail: an unbounded amount reverts before it can move
///      anything, and a bounded one walks the ladder a cell at a time, which is what produces coverage.
///
/// @dev **AMPS is `currency0`.** `Base._mineAmpsSaltFor` guarantees it sorts below every counter asset, so a buy is
///      `zeroForOne == false` and a sell is `zeroForOne == true`. That is what lets `AmpsQuoter.quoteExactIn` be
///      pointed at the same leg the router is about to take (SP-37).
///
/// @dev **The conservation and attribution properties are measured on *net* balances after any funding.** The
///      clamped handlers mint the counter asset with `fundActor` inside the same call, and `AmpsRouter._sweep`
///      returns the unspent input to `msg.sender`, so the readings are taken after the mint and the deltas are
///      net of the sweep — which is exactly what `fizz_data/property-plan.md` requires of SP-32 and SP-33.
abstract contract AmpsRouterHandler is Properties {
    // ――――――――――――――――――――――――― Clamped ――――――――――――――――――――――――――

    /// @notice Buys AMPS out of one pool's ask ladder with the pool's counter asset.
    /// @param poolSeed Chooses the pool.
    /// @param amountSeed Chooses the size, 1–40 counter units.
    function ampsRouter_buy_clamped(uint256 poolSeed, uint256 amountSeed) public {
        PoolId poolId = poolFrom(poolSeed);
        uint256 amountIn = counterUnit(poolId) * clampBetween(amountSeed, 1, 40);
        fundActor(counterOf(poolId), amountIn);

        ampsRouter_buy(PoolId.unwrap(poolId), amountIn, 0, actor, block.timestamp + 1);
    }

    /// @notice A sub-unit buy: the input is smaller than one counter unit, which is where the fee split and the
    ///         AMPS conversion can truncate to zero.
    /// @param poolSeed Chooses the pool.
    /// @param amountSeed Chooses the dust, 1 wei to one unit.
    function ampsRouter_buy_dust(uint256 poolSeed, uint256 amountSeed) public {
        PoolId poolId = poolFrom(poolSeed);
        uint256 amountIn = clampBetween(amountSeed, 1, counterUnit(poolId));
        fundActor(counterOf(poolId), amountIn);

        ampsRouter_buy(PoolId.unwrap(poolId), amountIn, 0, actor, block.timestamp + 1);
    }

    /// @notice A buy the quoter was asked about first, in the same block: the only shape in which "the quoter said
    ///         it was executable" is a statement about *this* trade.
    /// @dev New in this pass. The buy is wrapped so the refusal is observable, which is what SP-36 is about.
    /// @param poolSeed Chooses the pool.
    /// @param amountSeed Chooses the size, 1–40 counter units.
    function ampsRouter_quotedBuy(uint256 poolSeed, uint256 amountSeed) public {
        PoolId poolId = poolFrom(poolSeed);
        uint256 amountIn = counterUnit(poolId) * clampBetween(amountSeed, 1, 40);
        fundActor(counterOf(poolId), amountIn);
        if (IERC20(counterOf(poolId)).balanceOf(actor) < amountIn) return;

        (uint256 quoted, bool refused,) = _quoteBuy(poolId, amountIn);

        bool ok = true;
        vm.prank(actor);
        try ampsRouter.buy(poolId, amountIn, 0, actor, block.timestamp + 1) returns (uint256 out) {
            ghosts.lastBuyAmpsOut = out;
            noteAmpsHolder(actor);
        } catch {
            ok = false;
            ghosts.livenessReverts[keccak256("quotedBuy")] += 1;
        }

        // SP-36.
        property_honestTradingNeverReverts(quoted, refused, ok);
    }

    /// @notice Sells AMPS the actor already holds into one pool's bid side.
    /// @param poolSeed Chooses the pool.
    /// @param amountSeed Chooses the size, bounded by the actor's balance.
    function ampsRouter_sell_clamped(uint256 poolSeed, uint256 amountSeed) public {
        uint256 balance = amps.balanceOf(actor);
        if (balance == 0) return;
        PoolId poolId = poolFrom(poolSeed);
        uint256 ampsIn = clampBetween(amountSeed, 1, balance);

        ampsRouter_sell(PoolId.unwrap(poolId), ampsIn, 0, actor, false, block.timestamp + 1);
    }

    /// @notice The full-balance sell: the whole position through one pool in one call.
    /// @param poolSeed Chooses the pool.
    function ampsRouter_sell_full(uint256 poolSeed) public {
        uint256 balance = amps.balanceOf(actor);
        if (balance == 0) return;

        uint256 navBefore = _tryNavPerShare();
        ampsRouter_sell(PoolId.unwrap(poolFrom(poolSeed)), balance, 0, actor, false, block.timestamp + 1);

        // SP-60: after a whole-position exit the protocol is still enterable.
        property_fullAmountOpsStayReenterable(_disclosureAnswers(), navBefore, _tryNavPerShare());
    }

    /// @notice The two-hop rotation `stock -> AMPS -> entry counter` in one transaction. Hop 1 is always a spoke,
    ///         which satisfies the router's "at least one leg must be a constituent's spoke" rule (`NotARotation`
    ///         otherwise) *and* is the side that always has ask depth; hop 2 is always an entry pool, which is the
    ///         only side that carries a bid ladder from genesis.
    /// @dev Getting this the other way round is a dead end and is worth stating: a spoke's genesis ladder is asks
    ///      only (`SPOKE_SEED_AMPS` above the tick, nothing below it), so an AMPS sell *into* a spoke walks straight
    ///      to the tick floor and the hook's outer rail refuses it with `BeyondRail`. Until `deployBonded` has put
    ///      bonded collateral under a spoke's tick, only `spoke -> entry` lands — which is what
    ///      {ampsRouter_rotate_spokeToSpoke} exists to keep probing.
    /// @param aSeed Chooses hop 1's spoke.
    /// @param bSeed Chooses hop 2's entry pool.
    /// @param amountSeed Chooses the size, 1-20 counter units.
    function ampsRouter_rotate_clamped(uint256 aSeed, uint256 bSeed, uint256 amountSeed) public {
        PoolId hop1 = spokeFrom(aSeed);
        PoolId hop2 = bSeed % 2 == 0 ? hubPool : wethPool;

        uint256 amountIn = counterUnit(hop1) * clampBetween(amountSeed, 1, 20);
        fundActor(counterOf(hop1), amountIn);

        ampsRouter_rotate(PoolId.unwrap(hop1), PoolId.unwrap(hop2), amountIn, 0, actor, false, block.timestamp + 1);
    }

    /// @notice The canonical `stock -> AMPS -> stock` rotation, which is the shape the rotation credit exists for
    ///         (I26). It only lands once hop 2's spoke has a bid ladder under its tick — see
    ///         {ampsRouter_rotate_clamped} — so it is deliberately kept as its own handler rather than folded in:
    ///         when it starts succeeding, that is evidence that `deployBonded` worked.
    /// @param aSeed Chooses hop 1's spoke.
    /// @param bSeed Chooses hop 2's spoke.
    /// @param amountSeed Chooses the size, 1-20 counter units.
    function ampsRouter_rotate_spokeToSpoke(uint256 aSeed, uint256 bSeed, uint256 amountSeed) public {
        PoolId hop1 = spokeFrom(aSeed);
        PoolId hop2 = spokeFrom(bSeed);
        if (PoolId.unwrap(hop1) == PoolId.unwrap(hop2)) hop2 = spokeFrom(bSeed + 1);
        if (PoolId.unwrap(hop1) == PoolId.unwrap(hop2)) return;

        uint256 amountIn = counterUnit(hop1) * clampBetween(amountSeed, 1, 20);
        fundActor(counterOf(hop1), amountIn);

        ampsRouter_rotate(PoolId.unwrap(hop1), PoolId.unwrap(hop2), amountIn, 0, actor, false, block.timestamp + 1);
    }

    /// @notice A "rotation" whose two hops are the same pool, which the router must refuse.
    /// @dev New in this pass. The rotation exemption is the cheapest fee in the system; the property that matters
    ///      is that it cannot be bought by dressing an ordinary swap up as a rotation.
    /// @param aSeed Chooses the pool.
    /// @param amountSeed Chooses the size.
    function ampsRouter_rotate_sameHop(uint256 aSeed, uint256 amountSeed) public {
        PoolId hop = spokeFrom(aSeed);
        uint256 amountIn = counterUnit(hop) * clampBetween(amountSeed, 1, 20);
        fundActor(counterOf(hop), amountIn);
        if (IERC20(counterOf(hop)).balanceOf(actor) < amountIn) return;

        bool landed = true;
        vm.prank(actor);
        try ampsRouter.rotate(hop, hop, amountIn, 0, actor, false, block.timestamp + 1) returns (uint256, uint256) {}
        catch {
            landed = false;
        }

        // SP-40.
        property_rotationExemptionNotForSale(landed);
    }

    /// @notice Two rotations over the same pair, in **one transaction**: the shape the transient pass-through
    ///         counter is invisible to when a test splits them.
    /// @dev New in this pass — see the "Handlers to add" table of `fizz_data/property-plan.md`.
    /// @param aSeed Chooses hop 1's spoke.
    /// @param bSeed Chooses hop 2's entry pool.
    /// @param amountSeed Chooses the size, 1-20 counter units.
    function ampsRouter_rotate_twiceInOneTx(uint256 aSeed, uint256 bSeed, uint256 amountSeed) public {
        PoolId hop1 = spokeFrom(aSeed);
        PoolId hop2 = bSeed % 2 == 0 ? hubPool : wethPool;
        address entry = counterOf(hop1);

        uint256 amountIn = counterUnit(hop1) * clampBetween(amountSeed, 1, 20);
        fundActor(entry, amountIn * 2);
        if (IERC20(entry).balanceOf(actor) < amountIn) return;

        uint256 entryBefore = IERC20(entry).balanceOf(actor);

        vm.prank(actor);
        try ampsRouter.rotate(hop1, hop2, amountIn, 0, actor, false, block.timestamp + 1) returns (uint256, uint256) {}
        catch {
            return;
        }

        uint256 second = IERC20(entry).balanceOf(actor);
        if (second > amountIn) second = amountIn;
        if (second != 0) {
            vm.prank(actor);
            try ampsRouter.rotate(hop1, hop2, second, 0, actor, false, block.timestamp + 1) returns (
                uint256, uint256
            ) {}
                catch {}
        }

        uint256 keptBps = entryBefore == 0 ? 0 : IERC20(entry).balanceOf(actor) * Constants.BPS / entryBefore;
        if (keptBps > ghosts.atomicWashBestKeptBps) ghosts.atomicWashBestKeptBps = keptBps;

        // SP-41.
        property_atomicWashPaysTheAmpsFee(entryBefore, IERC20(entry).balanceOf(actor), _rotationCredit(actor));
    }

    /// @notice Buy AMPS out of one pool and sell the whole proceeds straight back into it, in one transaction.
    /// @dev New in this pass — see "Handlers to add".
    /// @param poolSeed Chooses the pool.
    /// @param amountSeed Chooses the size, 1-20 counter units.
    function ampsRouter_buySellRoundTrip(uint256 poolSeed, uint256 amountSeed) public {
        PoolId poolId = poolFrom(poolSeed);
        address counter = counterOf(poolId);
        uint256 amountIn = counterUnit(poolId) * clampBetween(amountSeed, 1, 20);
        fundActor(counter, amountIn);
        if (IERC20(counter).balanceOf(actor) < amountIn) return;

        uint256 counterBefore = IERC20(counter).balanceOf(actor);
        uint256 ampsBefore = amps.balanceOf(actor);

        uint256 ampsOut;
        vm.prank(actor);
        try ampsRouter.buy(poolId, amountIn, 0, actor, block.timestamp + 1) returns (uint256 out) {
            ampsOut = out;
        } catch {
            return;
        }
        if (ampsOut != 0) {
            vm.prank(actor);
            try ampsRouter.sell(poolId, ampsOut, 0, actor, false, block.timestamp + 1) returns (uint256) {}
            catch {
                return; // a refused sell leaves a bare buy behind, which is not a round trip (SP-42 is about one)
            }
        }

        // SP-42.
        property_buySellRoundTripNoProfit(
            counterBefore, IERC20(counter).balanceOf(actor), ampsBefore, amps.balanceOf(actor)
        );
    }

    /// @notice Sell AMPS into one pool and buy back with the whole proceeds, in one transaction.
    /// @dev New in this pass — see "Handlers to add".
    /// @param poolSeed Chooses the pool.
    /// @param amountSeed Chooses the size, bounded by the actor's AMPS.
    function ampsRouter_sellBuyRoundTrip(uint256 poolSeed, uint256 amountSeed) public {
        uint256 balance = amps.balanceOf(actor);
        if (balance == 0) return;
        PoolId poolId = poolFrom(poolSeed);
        address counter = counterOf(poolId);
        uint256 ampsIn = clampBetween(amountSeed, 1, balance);

        uint256 ampsBefore = balance;
        uint256 counterBefore = IERC20(counter).balanceOf(actor);

        uint256 got;
        vm.prank(actor);
        try ampsRouter.sell(poolId, ampsIn, 0, actor, false, block.timestamp + 1) returns (uint256 out) {
            got = out;
        } catch {
            return;
        }
        if (got != 0) {
            vm.prank(actor);
            try ampsRouter.buy(poolId, got, 0, actor, block.timestamp + 1) returns (uint256) {}
            catch {
                // A refused buy-back leaves the actor holding the sale's proceeds — a bare sell, not a round trip.
                // The 2026-09-11 campaign fired SP-43 on exactly this (a pool with no asks left after a full
                // redemption): the property is about the pair, so the pair has to have happened.
                return;
            }
        }

        // SP-43.
        property_sellBuyRoundTripNoProfit(
            ampsBefore, amps.balanceOf(actor), counterBefore, IERC20(counter).balanceOf(actor)
        );
    }

    /// @notice `rotate(A, B)` and then `rotate(B, A)` with the whole proceeds, in one transaction.
    /// @dev New in this pass — see "Handlers to add".
    /// @param aSeed Chooses hop 1's spoke.
    /// @param bSeed Chooses hop 2's entry pool.
    /// @param amountSeed Chooses the size, 1-20 counter units.
    function ampsRouter_rotateRoundTrip(uint256 aSeed, uint256 bSeed, uint256 amountSeed) public {
        PoolId hop1 = spokeFrom(aSeed);
        PoolId hop2 = bSeed % 2 == 0 ? hubPool : wethPool;
        address entry = counterOf(hop1);

        uint256 amountIn = counterUnit(hop1) * clampBetween(amountSeed, 1, 20);
        fundActor(entry, amountIn);
        if (IERC20(entry).balanceOf(actor) < amountIn) return;

        uint256 entryBefore = IERC20(entry).balanceOf(actor);

        uint256 out;
        vm.prank(actor);
        try ampsRouter.rotate(hop1, hop2, amountIn, 0, actor, false, block.timestamp + 1) returns (uint256 o, uint256) {
            out = o;
        } catch {
            return;
        }
        if (out != 0) {
            vm.prank(actor);
            try ampsRouter.rotate(hop2, hop1, out, 0, actor, false, block.timestamp + 1) returns (uint256, uint256) {}
                catch {}
        }

        // SP-44.
        property_rotateThereAndBackNoProfit(entryBefore, IERC20(entry).balanceOf(actor));
    }

    // ―――――――――――――――――――――――― Unclamped ―――――――――――――――――――――――――

    /// @notice `AmpsRouter.buy` with whatever the fuzzer chose, from the current actor.
    /// @param poolId The pool.
    /// @param amountIn Counter asset in.
    /// @param minAmpsOut Slippage floor.
    /// @param to Recipient.
    /// @param deadline Deadline.
    function ampsRouter_buy(bytes32 poolId, uint256 amountIn, uint256 minAmpsOut, address to, uint256 deadline) public {
        ghosts.navClass = NAV_CLASS_SWAP;
        snapshotBefore();

        PoolId id = PoolId.wrap(poolId);
        address counter = counterOf(id);
        TradeObs memory o = _tradeBefore(counter, address(amps), to, amountIn);
        uint256 askBefore = _askInventory(id);
        (uint256 quoted,, bool clean) = _quoteBuy(id, amountIn);

        vm.prank(actor);
        o.reportedOut = ampsRouter.buy(id, amountIn, minAmpsOut, to, deadline);

        snapshotAfter();
        _tradeAfter(o, counter, address(amps), to);

        // ── ghosts ──
        ghosts.lastBuyRealisedIn = o.payerInBefore > o.payerInAfter ? o.payerInBefore - o.payerInAfter : 0;
        ghosts.lastBuyAmpsOut = o.reportedOut;
        ghosts.lastPool = poolId;
        ghosts.swapVolumeUsd18 += _usd18(counter, ghosts.lastBuyRealisedIn);
        noteAmpsHolder(to);

        // ── specific properties ──
        property_mintAttribution(o.supplyBefore, o.supplyAfter, 0);
        property_swapDoesNotMoveSupply(o);
        property_swapNeverTakesMoreThanTheLadderHeld(o.reportedOut, askBefore);
        property_quoteExactInMatchesTheSwap(quoted, o.reportedOut, clean);
        property_noFreeAmpsFromTruncation(o.reportedOut, ghosts.lastBuyRealisedIn);
        if (_isPlainRecipient(to)) {
            property_counterAssetConservation(_inflow(o), _outflow(o));
            property_tradeAttribution(o);
        }
    }

    /// @notice `AmpsRouter.sell` with whatever the fuzzer chose, from the current actor.
    /// @param poolId The pool.
    /// @param ampsIn AMPS in.
    /// @param minOut Slippage floor.
    /// @param to Recipient.
    /// @param unwrap Whether to unwrap the output (the WETH stand-in is a plain ERC-20, so `true` reverts).
    /// @param deadline Deadline.
    function ampsRouter_sell(bytes32 poolId, uint256 ampsIn, uint256 minOut, address to, bool unwrap, uint256 deadline)
        public
    {
        ghosts.navClass = NAV_CLASS_SWAP;
        snapshotBefore();

        PoolId id = PoolId.wrap(poolId);
        address counter = counterOf(id);
        TradeObs memory o = _tradeBefore(address(amps), counter, to, ampsIn);
        uint256 bidBefore = IERC20(counter).balanceOf(address(poolManager));

        vm.prank(actor);
        o.reportedOut = ampsRouter.sell(id, ampsIn, minOut, to, unwrap, deadline);

        snapshotAfter();
        _tradeAfter(o, address(amps), counter, to);

        // ── ghosts ──
        ghosts.lastPool = poolId;
        ghosts.swapVolumeUsd18 += _usd18(counter, o.reportedOut);
        noteAmpsHolder(to);

        // ── specific properties ──
        property_mintAttribution(o.supplyBefore, o.supplyAfter, 0);
        property_swapDoesNotMoveSupply(o);
        property_swapNeverTakesMoreThanTheLadderHeld(o.reportedOut, bidBefore);
        if (_isPlainRecipient(to)) {
            property_counterAssetConservation(_inflow(o), _outflow(o));
            property_tradeAttribution(o);
        }
    }

    /// @notice `AmpsRouter.rotate` with whatever the fuzzer chose, from the current actor.
    /// @param hop1 The pool bought in.
    /// @param hop2 The pool sold into.
    /// @param amountIn Hop-1 counter asset in.
    /// @param minOut Slippage floor.
    /// @param to Recipient.
    /// @param unwrap Whether to unwrap the output.
    /// @param deadline Deadline.
    function ampsRouter_rotate(
        bytes32 hop1,
        bytes32 hop2,
        uint256 amountIn,
        uint256 minOut,
        address to,
        bool unwrap,
        uint256 deadline
    ) public {
        ghosts.navClass = NAV_CLASS_SWAP;
        snapshotBefore();

        PoolId a = PoolId.wrap(hop1);
        PoolId b = PoolId.wrap(hop2);
        address entry = counterOf(a);
        address exit_ = counterOf(b);
        TradeObs memory o = _tradeBefore(entry, exit_, to, amountIn);
        uint256 quoted = _quoteRotation(a, b, amountIn);

        vm.prank(actor);
        (o.reportedOut,) = ampsRouter.rotate(a, b, amountIn, minOut, to, unwrap, deadline);

        snapshotAfter();
        _tradeAfter(o, entry, exit_, to);

        // ── ghosts ──
        ghosts.lastPool = hop2;
        ghosts.swapVolumeUsd18 += _usd18(exit_, o.reportedOut);
        noteAmpsHolder(to);

        // ── specific properties ──
        property_mintAttribution(o.supplyBefore, o.supplyAfter, 0);
        property_swapDoesNotMoveSupply(o);
        property_quoteRotationMatchesTheRotation(quoted, o.reportedOut);
        if (_isPlainRecipient(to)) {
            property_counterAssetConservation(_inflow(o), _outflow(o));
            property_tradeAttribution(o);
        }
        property_rotationFeeSchedule(_chargedFeeBps(a), hook.buyFeeBps(a), _chargedFeeBps(b), hook.buyFeeBps(b));
    }

    // ―――――――――――――――――――― Observation helpers ――――――――――――――――――

    /// @dev Every reading SP-32..SP-49 need from before a trade, taken *after* any `fundActor` mint and before the
    ///      prank is armed.
    function _tradeBefore(address tokenIn, address tokenOut, address to, uint256 amountIn)
        private
        view
        returns (TradeObs memory o)
    {
        o.payer = actor;
        o.recipient = to;
        o.amountIn = amountIn;
        o.supplyBefore = amps.totalSupply();
        o.payerInBefore = IERC20(tokenIn).balanceOf(actor);
        o.recipOutBefore = IERC20(tokenOut).balanceOf(to);
        o.pmInBefore = IERC20(tokenIn).balanceOf(address(poolManager));
        o.routerInBefore = IERC20(tokenIn).balanceOf(address(ampsRouter));
        o.routerOutBefore = IERC20(tokenOut).balanceOf(address(ampsRouter));
    }

    /// @dev The matching "after" half.
    function _tradeAfter(TradeObs memory o, address tokenIn, address tokenOut, address to) private view {
        o.supplyAfter = amps.totalSupply();
        o.payerInAfter = IERC20(tokenIn).balanceOf(actor);
        o.recipOutAfter = IERC20(tokenOut).balanceOf(to);
        o.pmInAfter = IERC20(tokenIn).balanceOf(address(poolManager));
        o.routerInAfter = IERC20(tokenIn).balanceOf(address(ampsRouter));
        o.routerOutAfter = IERC20(tokenOut).balanceOf(address(ampsRouter));
        o.hookAmps = amps.balanceOf(address(hook));
    }

    /// @dev `AmpsQuoter.quoteExactIn` on the buy leg (`zeroForOne == false`, because AMPS is `currency0`).
    /// @return quoted The quoted output.
    /// @return refused Whether the quoter refused.
    /// @return clean Whether the quote came back undegraded and unrefused.
    function _quoteBuy(PoolId poolId, uint256 amountIn)
        private
        view
        returns (uint256 quoted, bool refused, bool clean)
    {
        try quoter.quoteExactIn(poolId, false, amountIn) returns (uint256 out, uint24, bool refuse, uint8 degraded) {
            return (out, refuse, !refuse && degraded == 0);
        } catch {
            return (0, true, false);
        }
    }

    /// @dev `AmpsQuoter.quoteRotation`, or zero.
    function _quoteRotation(PoolId hop1, PoolId hop2, uint256 amountIn) private view returns (uint256 quoted) {
        try quoter.quoteRotation(hop1, hop2, amountIn) returns (uint256 out, uint24, uint24, uint256) {
            return out;
        } catch {
            return 0;
        }
    }

    /// @dev The pool's unfilled ask inventory, or zero.
    function _askInventory(PoolId poolId) private view returns (uint256 amount) {
        try this.viewAskInventory(poolId) returns (uint256 v) {
            return v;
        } catch {
            return 0;
        }
    }

    /// @notice `ladderAskInventory` behind an external boundary, so a revert inside it can be caught rather than
    ///         taking a swap handler down with it.
    /// @dev A `view` with no fuzzing value of its own; it is external only so that `try` can wrap it.
    /// @param poolId The pool.
    /// @return amount The unfilled ask inventory.
    function viewAskInventory(PoolId poolId) external view returns (uint256 amount) {
        return ladderAskInventory(poolId);
    }

    /// @dev What the PoolManager gained of the input currency, floored at zero so a property never reverts on the
    ///      subtraction it was meant to judge.
    function _inflow(TradeObs memory o) private pure returns (uint256 amount) {
        return o.pmInAfter > o.pmInBefore ? o.pmInAfter - o.pmInBefore : 0;
    }

    /// @dev What the payer and the router parted with of the input currency, on the same footing.
    function _outflow(TradeObs memory o) private pure returns (uint256 amount) {
        amount = o.payerInBefore > o.payerInAfter ? o.payerInBefore - o.payerInAfter : 0;
        amount += o.routerInBefore > o.routerInAfter ? o.routerInBefore - o.routerInAfter : 0;
    }

    /// @dev Whether `to` is an ordinary account rather than one of the four protocol addresses whose balances move
    ///      for swap reasons of their own. SP-32 and SP-33 are statements about a four-address closure, and naming
    ///      a member of that closure as the recipient collapses it.
    function _isPlainRecipient(address to) private view returns (bool plain) {
        return to != address(0) && to != address(poolManager) && to != address(ampsRouter) && to != address(vault)
            && to != address(hook) && to != address(bonds);
    }

    /// @dev `hook.chargedFeeBps`, or zero.
    function _chargedFeeBps(PoolId poolId) private view returns (uint16 bps) {
        try hook.chargedFeeBps(poolId) returns (uint16 v) {
            return v;
        } catch {
            return 0;
        }
    }

    /// @dev `hook.rotationCredit`, or zero.
    function _rotationCredit(address who) private view returns (uint256 credit) {
        try hook.rotationCredit(who) returns (uint256 v) {
            return v;
        } catch {
            return 0;
        }
    }

    /// @dev `amount` of `token` in 18-decimal USD, or zero when the feed will not answer.
    function _usd18(address token, uint256 amount) private view returns (uint256 value) {
        if (amount == 0) return 0;
        try feeds.priceUsd18(token) returns (uint256 price) {
            uint8 decimals = _decimalsOf(token);
            return price * amount / (10 ** uint256(decimals));
        } catch {
            return 0;
        }
    }

    /// @dev `IERC20Metadata.decimals`, or 18.
    function _decimalsOf(address token) private view returns (uint8 decimals) {
        (bool ok, bytes memory data) = token.staticcall(abi.encodeWithSignature("decimals()"));
        if (!ok || data.length < 32) return 18;
        return abi.decode(data, (uint8));
    }
}
