// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Constants} from "../../src/types/Constants.sol";
import {BondMarket, GateState, Session} from "../../src/types/Types.sol";
import {BondsFixture} from "../unit/AmpsBonds.t.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

/// @notice Fuzz suite for the bond shell: the two capacity caps, the linear vest, and the accretion floor under
///         randomised order flow, prices, sessions and time.
contract AmpsBondsFuzzTest is BondsFixture {
    function setUp() public override {
        super.setUp();
        stock.mint(alice, 1_000_000e18);
        stock.mint(bob, 1_000_000e18);
    }

    /* -------------------------------------------- capacity -------------------------------------------- */

    /// @notice I28, both clauses: per-market issuance never exceeds `capBpsPerEpoch x T` inside an epoch, and
    ///         global issuance never exceeds `dailyCapBps x T` inside a day, whatever the order flow and however
    ///         the clock moves.
    function testFuzz_issuanceNeverExceedsEitherCap(uint256[6] memory amounts, uint32[6] memory waits) public {
        for (uint256 i; i < amounts.length; ++i) {
            uint256 amountIn = bound(amounts[i], 1e12, 5e18);
            uint32 wait = uint32(bound(waits[i], 0, 2 days));

            vm.warp(block.timestamp + wait);
            vaultMock.touchCheckpoint();

            vm.prank(alice);
            try bonds.bond(marketId, amountIn, 0, alice) returns (uint256 ampsOut, uint256) {
                assertGt(ampsOut, 0, "an accepted bond always issues something");
            } catch {
                // A full epoch or a full day refuses; nothing else may.
                assertEq(bonds.capacityRemaining(marketId), 0, "the only reason a bond is refused is capacity");
            }

            uint256 supply = amps.totalSupply();
            BondMarket memory record = bonds.market(marketId);
            (uint256 dailyIssued, uint256 dailyCapacity) = bonds.dailyIssuance();

            assertLe(
                record.issuedThisEpoch,
                FullMath.mulDiv(supply, record.capBpsPerEpoch, Constants.BPS),
                "per-epoch issuance <= capBpsPerEpoch x T"
            );
            assertLe(dailyIssued, dailyCapacity, "daily issuance <= dailyCapBps x T");
            assertEq(dailyCapacity, FullMath.mulDiv(supply, bonds.dailyCapBps(), Constants.BPS), "the daily cap");
        }
    }

    /// @notice The epoch tally resets exactly once per elapsed epoch and never carries issuance across a boundary.
    function testFuzz_epochRollsForwardOnItsOwnGrid(uint32 wait, uint256 amountIn) public {
        amountIn = bound(amountIn, 1e12, 1e17);
        uint32 epoch = bonds.epochSeconds();
        uint32 start = bonds.market(marketId).epochStart;

        vm.prank(alice);
        bonds.bond(marketId, amountIn, 0, alice);
        uint128 issuedBefore = bonds.market(marketId).issuedThisEpoch;
        assertGt(issuedBefore, 0);

        wait = uint32(bound(wait, 0, 30 days));
        vm.warp(block.timestamp + wait);
        vaultMock.touchCheckpoint();

        vm.prank(alice);
        bonds.bond(marketId, amountIn, 0, alice);

        BondMarket memory record = bonds.market(marketId);
        uint32 elapsed = uint32(block.timestamp) - start;
        if (elapsed < epoch) {
            assertEq(record.epochStart, start, "the epoch has not rolled");
            assertGt(record.issuedThisEpoch, issuedBefore, "and the tally accumulates");
        } else {
            assertEq(record.epochStart, start + (elapsed / epoch) * epoch, "the epoch rolls onto its own grid");
            assertLe(uint256(record.epochStart) + epoch, block.timestamp + epoch, "and lands on the live epoch");
            assertLt(record.issuedThisEpoch, issuedBefore + issuedBefore, "the tally restarted");
        }
        assertGe(record.totalIssued, issuedBefore, "the lifetime tally never resets");
    }

    /* --------------------------------------------- vesting --------------------------------------------- */

    /// @notice I28's vesting clause: `claimable(t)` is monotone non-decreasing in `t` and never above the
    ///         principal, and is exact at 0%, 50% and 100% of the vest.
    function testFuzz_vestIsMonotoneAndBounded(uint256 amountIn, uint32 first, uint32 second) public {
        amountIn = bound(amountIn, 1e12, 1e17);
        vm.prank(alice);
        (uint256 principal, uint256 positionId) = bonds.bond(marketId, amountIn, 0, alice);

        uint32 vest = bonds.vestSeconds();
        // Read the anchor out of the position rather than out of `block.timestamp`: solc is entitled to
        // re-materialise a `TIMESTAMP` read after an external call, and `vm.warp` is exactly the cheatcode that
        // makes that assumption false, so a captured `block.timestamp` silently tracks the warps.
        uint256 start = bonds.position(alice, positionId).start;
        first = uint32(bound(first, 0, 2 * vest));
        second = uint32(bound(second, first, 2 * vest));

        assertEq(bonds.claimable(alice, positionId), 0, "nothing has vested at t = 0");

        vm.warp(start + first);
        uint256 atFirst = bonds.claimable(alice, positionId);
        vm.warp(start + second);
        uint256 atSecond = bonds.claimable(alice, positionId);

        assertLe(atFirst, atSecond, "claimable is monotone in time");
        assertLe(atSecond, principal, "and never exceeds what was purchased");
        assertEq(atFirst, FullMath.mulDiv(principal, first < vest ? first : vest, vest), "the exact linear vest");

        vm.warp(start + vest / 2);
        assertEq(bonds.claimable(alice, positionId), principal / 2, "exactly half at the midpoint");

        vm.warp(start + vest);
        assertEq(bonds.claimable(alice, positionId), principal, "exactly all at the end");
        vm.warp(start + 2 * vest);
        assertEq(bonds.claimable(alice, positionId), principal, "and never more");
    }

    /// @notice However a bonder splits their claims in time, they receive exactly the principal and never a wei
    ///         more, and the shell keeps nothing.
    function testFuzz_claimsSumToThePrincipal(uint256 amountIn, uint32[4] memory waits) public {
        amountIn = bound(amountIn, 1e12, 1e17);
        vm.prank(alice);
        (uint256 principal, uint256 positionId) = bonds.bond(marketId, amountIn, 0, alice);

        uint256 claimed;
        for (uint256 i; i < waits.length; ++i) {
            vm.warp(block.timestamp + bound(waits[i], 0, bonds.vestSeconds()));
            uint256 pending = bonds.claimable(alice, positionId);
            if (pending == 0) continue;
            vm.prank(alice);
            claimed += bonds.claim(positionId, alice);
            assertLe(claimed, principal, "a bonder never over-claims");
        }

        vm.warp(block.timestamp + bonds.vestSeconds());
        if (bonds.claimable(alice, positionId) > 0) {
            vm.prank(alice);
            claimed += bonds.claim(positionId, alice);
        }

        assertEq(claimed, principal, "the whole principal, exactly once");
        assertEq(amps.balanceOf(alice), principal);
        assertEq(bonds.position(alice, positionId).claimed, principal);
        assertEq(amps.balanceOf(address(bonds)), 0, "the shell holds nothing once every vest completes");
    }

    /* ------------------------------------------- the floor ------------------------------------------- */

    /// @notice I27 under randomised prices, sessions and feed states: the bond is always accretive, and NAV/share
    ///         never falls across one.
    function testFuzz_bondIsAlwaysAccretive(uint256 amountIn, uint256 premiumBps, uint8 session, bool fresh) public {
        amountIn = bound(amountIn, 1e12, 1e17);
        premiumBps = bound(premiumBps, 0, 20_000);
        Session sessionValue = Session(uint8(bound(session, 0, 3)));

        gate.setSession(sessionValue);
        feeds.setFresh(address(stock), fresh);
        _setSpokePriceUsd18(NAV_X18 + NAV_X18 * premiumBps / 10_000);
        vaultMock.setAutoNav(true);

        uint16 haircut = gate.hSessionBps(sessionValue);
        uint256 navBefore = vaultMock.previewNavPerShareX18();
        // The checkpointed NAV is what the shell prices against, and with real accounting it sits a hair below
        // $1.00 because of the virtual shares; the floor must be asserted against that number, not against $1.00.
        uint256 navPriced = vaultMock.navPerShareX18();

        vm.prank(alice);
        (uint256 ampsOut,) = bonds.bond(marketId, amountIn, 0, alice);

        // The floor, in its exact form: the AMPS issued is worth no more than the collateral net of the haircut,
        // less the accretion the protocol demands.
        assertLe(
            FullMath.mulDiv(ampsOut, navPriced * (10_000 + uint256(Constants.MIN_ACCRETION_BPS_DEFAULT)), 10_000),
            FullMath.mulDiv(amountIn, STOCK_PRICE_USD8 * 1e10 * (10_000 - uint256(haircut)), 10_000),
            "ampsOut x nav x (1 + a) <= amountIn x P_i x (1 - h)"
        );
        assertGe(vaultMock.previewNavPerShareX18(), navBefore, "NAV/share never falls across a bond (I27)");
    }

    /// @notice The quote view is total: for any amount and any market state it returns rather than reverts, and it
    ///         agrees with what `bond` would issue whenever it reports no reason.
    function testFuzz_quoteNeverReverts(uint256 amountIn, uint256 premiumBps, uint8 session, bool closed) public {
        amountIn = bound(amountIn, 0, 1e30);
        premiumBps = bound(premiumBps, 0, 50_000);
        gate.setSession(Session(uint8(bound(session, 0, 3))));
        _setSpokePriceUsd18(NAV_X18 + NAV_X18 * premiumBps / 10_000);

        if (closed) {
            vm.prank(timelock);
            bonds.setMarketOpen(marketId, false);
        }

        (uint256 ampsOut, uint256 qX18,, bool floorBinding, uint256 capacityLeft, bytes32 reason) =
            bonds.quote(marketId, amountIn);

        assertLe(ampsOut, capacityLeft, "a quote never promises more than the capacity");
        if (closed) {
            assertEq(reason, bytes32("marketClosed"));
            assertEq(ampsOut, 0);
            return;
        }
        if (reason != bytes32(0)) {
            assertEq(ampsOut, 0, "a refused quote issues nothing");
            return;
        }

        uint256 floorX18 = _qFloor(
            STOCK_PRICE_USD8 * 1e10, NAV_X18, gate.hSessionBps(gate.session()), Constants.MIN_ACCRETION_BPS_DEFAULT
        );
        assertLe(qX18, floorX18, "q <= qFloor in every state (I27)");
        assertEq(floorBinding, qX18 == floorX18);

        if (amountIn > 0 && amountIn <= 1e17) {
            vm.prank(alice);
            (uint256 bonded,) = bonds.bond(marketId, amountIn, 0, alice);
            assertEq(bonded, ampsOut, "the view and the transaction agree");
        }
    }

    /* -------------------------------------------- claiming -------------------------------------------- */

    /// @notice I38 under fuzzing: whatever governance and the gate do afterwards, a sold vest still claims in full.
    function testFuzz_claimSurvivesAnyGovernanceAction(uint256 amountIn, uint8 action) public {
        amountIn = bound(amountIn, 1e12, 1e17);
        vm.prank(alice);
        (uint256 principal, uint256 positionId) = bonds.bond(marketId, amountIn, 0, alice);

        uint8 which = uint8(bound(action, 0, 5));
        if (which == 0) {
            vm.prank(timelock);
            bonds.removeCollateral(address(stock));
        } else if (which == 1) {
            vm.prank(timelock);
            bonds.setMarketOpen(marketId, false);
        } else if (which == 2) {
            vm.prank(timelock);
            bonds.setVestSeconds(Constants.BOND_VEST_SECONDS_MAX);
        } else if (which == 3) {
            gate.setBondRefusal(true, GateState.WATCHDOG);
            gate.freezeProtocol(uint32(block.timestamp + 7 days));
        } else if (which == 4) {
            feeds.setReverting(true);
            vaultMock.setReverting(true);
        } else {
            vm.prank(timelock);
            bonds.setMinAccretionBps(Constants.MIN_ACCRETION_BPS_MAX);
        }

        vm.warp(block.timestamp + Constants.BOND_VEST_SECONDS_DEFAULT);
        vm.prank(alice);
        assertEq(bonds.claim(positionId, alice), principal, "a sold vest always completes");
    }
}
