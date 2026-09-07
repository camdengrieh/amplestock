// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IAmpsQuoter} from "../../src/interfaces/IAmpsQuoter.sol";
import {IFeePolicy} from "../../src/interfaces/IFeePolicy.sol";
import {IOracleGate} from "../../src/interfaces/IOracleGate.sol";
import {LadderLib} from "../../src/lib/LadderLib.sol";
import {Constants} from "../../src/types/Constants.sol";
import {PlacementRecord, PoolClass, Session} from "../../src/types/Types.sol";
import {Phase3Fixture} from "../integration/Phase3Fixture.sol";
import {Phase3Ghosts} from "./Phase3Ghosts.sol";
import {Phase3Handler, Phase3Wiring} from "./Phase3Handler.sol";
import {Phase3VaultHandler} from "./Phase3VaultHandler.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {console} from "forge-std/console.sol";

/// @title Phase3InvariantTest
/// @notice `docs/phase3-state-model.md` §8.2, run against the fully wired Phase 3 stack rather than against mocks:
///         I9, I11, I13, I15, I16, I18, I19, I26, I29, I31, I32, I33, I34, I35 and I39, plus the live-cell budget
///         of §12 ruling E and its exactness, `AmpsQuoter`'s totality, and a non-vacuity check that every action
///         in the space actually executed.
///
/// @dev Runs and depth come from `foundry.toml` (64 x 64 by default, 256 x 128 under the `ci` profile) with
///      `fail_on_revert = false`; `Phase3Handler` catches every revert itself and records violations as ghosts, so
///      a legitimate refusal - a cooldown, a full epoch, a frozen gate, the outer rail - is never confused with a
///      breach.
contract Phase3InvariantTest is Phase3Fixture {
    Phase3Ghosts internal ghosts;
    Phase3Handler internal handler;
    Phase3VaultHandler internal vaultHandler;

    function setUp() public {
        deployPhase3World();
        placeGenesisLadders();
        fundPot(1_000_000e6);
        warpBy(Constants.PLACEMENT_COOLDOWN_SECONDS + 1);

        // One shared ghost book, two handlers. The action space of §8.2 is unchanged; it is split across two
        // contracts because a single handler carrying all of it plus the bookkeeping was 31,203 B of runtime,
        // past EIP-170 - which `forge build --sizes` gates and Medusa's geth enforces at deploy time.
        ghosts = new Phase3Ghosts(vault, amps, hook, quoter, poolManager, allPools());
        handler = new Phase3Handler(_wiring(), ghosts);
        vaultHandler = new Phase3VaultHandler(vault, amps, ghosts, KEEPER, constituentIds, allPools());
        ghosts.authorize(address(handler));
        ghosts.authorize(address(vaultHandler));

        // The market handler steps display multipliers and pauses issuer oracles, both `onlyOwner` on
        // `MockStockToken`, so it takes ownership of the tokens the way an issuer holds its own beacon.
        for (uint256 i; i < stocks.length; ++i) {
            stocks[i].transferOwnership(address(handler));
        }
        // The vault handler is the redeemer; it gets its shares out of the POL tranche rather than from a mint,
        // so `totalSupply` is still exactly `S0` when the campaign starts and I3 has a fixed origin.
        giveShares(address(vaultHandler), 400e18);

        targetContract(address(handler));
        bytes4[] memory market = new bytes4[](10);
        market[0] = Phase3Handler.swapBuy.selector;
        market[1] = Phase3Handler.swapSell.selector;
        market[2] = Phase3Handler.swapRotate.selector;
        market[3] = Phase3Handler.bond.selector;
        market[4] = Phase3Handler.claim.selector;
        market[5] = Phase3Handler.warp.selector;
        market[6] = Phase3Handler.moveFeed.selector;
        market[7] = Phase3Handler.stepMultiplier.selector;
        market[8] = Phase3Handler.armGate.selector;
        market[9] = Phase3Handler.probeHook.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: market}));

        targetContract(address(vaultHandler));
        bytes4[] memory upkeep = new bytes4[](6);
        upkeep[0] = Phase3VaultHandler.redeem.selector;
        upkeep[1] = Phase3VaultHandler.compound.selector;
        upkeep[2] = Phase3VaultHandler.rollout.selector;
        upkeep[3] = Phase3VaultHandler.deployBonded.selector;
        upkeep[4] = Phase3VaultHandler.checkpoint.selector;
        upkeep[5] = Phase3VaultHandler.removeLiquidity.selector;
        targetSelector(FuzzSelector({addr: address(vaultHandler), selectors: upkeep}));
    }

    // -------------------------------------------------------------------------------------------------------------
    // Supply
    // -------------------------------------------------------------------------------------------------------------

    /// @notice I3, I10 and I33's supply clause: `totalSupply` moves only through `AmpsBonds`' mint and through
    ///         burns, and never rises for any other reason.
    function invariant_I3_I10_I33_supplyMovesOnlyThroughBondsAndBurns() public view {
        assertEq(
            amps.totalSupply(),
            Constants.S0 + ghosts.mintedObserved() - ghosts.burnedTotal(),
            "S0 + everything minted - everything burned"
        );
        assertEq(ghosts.mintedObserved(), ghosts.mintedVesting(), "I10, I33: every wei minted came from AmpsBonds");
        assertEq(amps.vault(), address(vault), "and the vault is still the only minter");
    }

    // -------------------------------------------------------------------------------------------------------------
    // The ladder
    // -------------------------------------------------------------------------------------------------------------

    /// @notice I39 and I34's structural half: every record lies on its pool's canonical doubling grid, is exactly
    ///         one doubling wide, carries a grid index inside `[0, GRID_CELLS)`, and no two records share a cell.
    ///         I9's durable half comes with it: an ask cell strictly above the tick holds AMPS and nothing else.
    function invariant_I9_I34_I39_everyCellIsOnTheGridAndOnItsOwnSide() public view {
        PoolId[] memory ids = allPools();
        int24 width = cellWidth();
        for (uint256 p; p < ids.length; ++p) {
            int24 base = gridBaseOf(ids[p]);
            int24 tick = tickOf(ids[p]);
            PlacementRecord[] memory records = ladderOf(ids[p]);
            assertLe(records.length, Constants.GRID_CELLS, "at most GRID_CELLS records per pool");

            bool[] memory seen = new bool[](Constants.GRID_CELLS);
            for (uint256 i; i < records.length; ++i) {
                int24 offset = records[i].lowerTick - base;
                assertEq(offset % width, 0, "I39: the cell lies on the grid");
                assertEq(records[i].upperTick - records[i].lowerTick, width, "I34: one contiguous doubling");
                assertLt(uint256(records[i].bucketIndex), Constants.GRID_CELLS, "the index is inside the grid");
                assertFalse(seen[records[i].bucketIndex], "I39: no two records share a cell");
                seen[records[i].bucketIndex] = true;

                int24 m = offset / width;
                assertGe(m, Constants.GRID_MIN_M, "inside GRID_MIN_M");
                assertLt(m, Constants.GRID_MAX_M, "inside GRID_MAX_M");

                if (records[i].liquidity == 0) continue;
                (uint256 amount0, uint256 amount1) = liveAmounts(ids[p], records[i]);
                // Strictly above: `tick == lowerTick` means the pool's sqrt price is *inside* the cell's first
                // tick, so the cell is straddled and legitimately holds both sides.
                if (records[i].lowerTick > tick) {
                    assertEq(amount1, 0, "I9: a cell entirely above the tick is AMPS only");
                } else if (records[i].upperTick <= tick) {
                    assertEq(amount0, 0, "I9: a cell entirely below the tick is counter asset only");
                }
            }
        }
    }

    /// @notice I29's durable half: every counter asset the vault holds inside a pool sits in a cell of that pool's
    ///         own grid - it is the proceeds of an ask that filled at those very prices, or a bonded bid ladder,
    ///         and never a position invented somewhere else.
    function invariant_I29_everyBidIsAGridCellOfItsOwnPool() public view {
        PoolId[] memory ids = allPools();
        int24 width = cellWidth();
        for (uint256 p; p < ids.length; ++p) {
            int24 base = gridBaseOf(ids[p]);
            PlacementRecord[] memory records = ladderOf(ids[p]);
            for (uint256 i; i < records.length; ++i) {
                if (records[i].liquidity == 0) continue;
                (, uint256 amount1) = liveAmounts(ids[p], records[i]);
                if (amount1 == 0) continue;
                assertEq((records[i].lowerTick - base) % width, 0, "a bid is a cell of this pool's grid");
                assertEq(records[i].upperTick - records[i].lowerTick, width, "one doubling wide");
            }
        }
    }

    /// @notice §12 ruling E: the vault-wide live-cell budget is never exceeded, and the counter is exact - it is
    ///         what bounds `redeemProRata`'s single-block gas, so a drifting counter would be a silent unbounding.
    function invariant_liveCellBudgetIsRespectedAndExact() public view {
        assertLe(vault.liveCells(), Constants.MAX_LIVE_CELLS, "liveCells <= MAX_LIVE_CELLS");
        assertEq(vault.liveCells(), countLiveCells(), "and the counter matches the book, cell for cell");
        assertLe(ghosts.maxLiveCellsSeen(), Constants.MAX_LIVE_CELLS, "and never did during the campaign");
        assertLe(ghosts.maxRecordsSeen(), Constants.GRID_CELLS, "no pool ever held more than GRID_CELLS records");
    }

    /// @notice I35: positions shrink only through redemption, rollout, the buyback burn and migration - so the
    ///         vault is the only owner of every position that exists, and no path but those four can have moved
    ///         one. The observable form is that every live cell is still the vault's.
    function invariant_I35_thePositionsAreAllStillTheVaults() public view {
        assertEq(vault.liveCells(), countLiveCells(), "the vault owns exactly the cells it records");
        assertEq(IERC20(address(amps)).balanceOf(address(hook)), 0, "and nothing leaked to the hook on the way");
    }

    // -------------------------------------------------------------------------------------------------------------
    // NAV
    // -------------------------------------------------------------------------------------------------------------

    /// @notice I11: no placement, compound, rollout, bonded deployment or checkpoint ever bled NAV/share by more
    ///         than `PLACEMENT_BLEED_BPS_MAX`.
    function invariant_I11_navPerShareNeverBleeds() public view {
        assertFalse(ghosts.navEverFell(), "R1 held across every placement path");
    }

    // -------------------------------------------------------------------------------------------------------------
    // The hook
    // -------------------------------------------------------------------------------------------------------------

    /// @notice I13: the hook holds no ERC-20 and no ERC-6909, at any point in the campaign.
    function invariant_I13_theHookHoldsNothing() public view {
        assertFalse(ghosts.hookEverHeldValue(), "the hook never held value");
        assertEq(IERC20(address(amps)).balanceOf(address(hook)), 0, "no AMPS");
        assertEq(IERC20(address(usdg)).balanceOf(address(hook)), 0, "no USDG");
        assertEq(poolManager.balanceOf(address(hook), Currency.wrap(address(amps)).toId()), 0, "no AMPS claim");
        for (uint256 i; i < stocks.length; ++i) {
            assertEq(IERC20(address(stocks[i])).balanceOf(address(hook)), 0, "no stock");
        }
    }

    /// @notice I15 and §10 ruling 2: the hook refused a swap only for the outer rail, never for a gate reason -
    ///         and never a swap it had told the quoter it would take.
    function invariant_I15_swapsAreOnlyEverRefusedByTheRail() public view {
        assertFalse(ghosts.swapEverReverted(), "no swap was refused for anything but the rail");
    }

    /// @notice I16: every fee decomposes as `base + dyn` with `base` the pool's own buy fee or the protocol sell
    ///         fee, `sellFeeBps` inside `[100, 600]`, `dyn` inside the state's cap, and the total under
    ///         `TOTAL_FEE_BPS_MAX`.
    function invariant_I16_everyFeeDecomposes() public view {
        assertFalse(ghosts.feeEverMalformed(), "every fee decomposed inside its bands");
        assertGe(hook.sellFeeBps(), 100, "sellFeeBps floor");
        assertLe(hook.sellFeeBps(), 600, "sellFeeBps ceiling");
    }

    /// @notice I18: the deployed hook carries no `BEFORE_REMOVE_LIQUIDITY` bit, so a removal cannot be blocked -
    ///         and none ever was, in any gate state the campaign reached.
    function invariant_I18_removalsAreNeverBlocked() public view {
        uint160 flags = uint160(address(hook)) & uint160(Constants.HOOK_ADDRESS_MASK);
        assertEq(flags & uint160(Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG), 0, "no beforeRemoveLiquidity bit");
        assertEq(flags & uint160(Hooks.AFTER_REMOVE_LIQUIDITY_FLAG), 0, "no afterRemoveLiquidity bit");
        assertFalse(ghosts.removalEverBlocked(), "and no removal was ever refused");
    }

    /// @notice I19: the inner band is monotone non-decreasing in how closed the session is, for every pool class,
    ///         and the entry pools never widen at all. Read off the policy the hook actually calls.
    function invariant_I19_bandIsMonotoneInClosedness() public view {
        for (uint256 c; c < 3; ++c) {
            PoolClass class = PoolClass(c + 1);
            int24 previous;
            for (uint256 s; s < 4; ++s) {
                int24 band = feePolicy.innerBandTicks(class, Session(s), 0);
                if (s != 0) assertGe(band, previous, "the band never narrows as the session closes");
                previous = band;
            }
        }
        assertEq(
            feePolicy.innerBandTicks(PoolClass.ENTRY, Session.CLOSED, 24),
            feePolicy.innerBandTicks(PoolClass.ENTRY, Session.REGULAR, 0),
            "an entry pool's band never moves"
        );
    }

    /// @notice I26: the rotation credit is zero at the start of every transaction, structurally.
    function invariant_I26_rotationCreditIsZeroAtEveryBoundary() public view {
        assertFalse(ghosts.creditEverLeaked(), "no credit ever survived a transaction boundary");
        assertEq(hook.rotationCredit(), 0, "and it is zero now");
    }

    // -------------------------------------------------------------------------------------------------------------
    // The flywheel
    // -------------------------------------------------------------------------------------------------------------

    /// @notice I31: the creator was never paid more than `creatorBps(t) / sellFeeBps` of the AMPS-side fees, and
    ///         the schedule is monotone non-increasing and zero after thirty days.
    function invariant_I31_creatorPayoutIsBounded() public view {
        assertLe(
            ghosts.creatorPaid() * uint256(hook.sellFeeBps()),
            ghosts.feesSplit() * uint256(Constants.CREATOR_FEE_BPS) + uint256(hook.sellFeeBps()),
            "creatorPaid <= ampsFees * creatorBps / sellFeeBps, summed"
        );
        assertEq(
            vault.creatorBpsAt(uint256(vault.genesisTimestamp()) + Constants.CREATOR_DECAY_SECONDS),
            0,
            "and the schedule ends at day thirty"
        );
    }

    /// @notice I32: rollout never moved more than `rolloutBpsPerDay` of the POL tranche in a rolling day, and the
    ///         entry pools never fell below `entryFloorBps` of it.
    function invariant_I32_rolloutStaysInsideItsBudgetAndFloor() public view {
        assertLe(
            ghosts.rolloutMoved(),
            Constants.POL_SHARES * uint256(vault.rolloutBpsPerDay()) / Constants.BPS,
            "the rolling 24 h budget"
        );
        uint256 entryInventory = ladderAskInventory(hubPool) + ladderAskInventory(wethPool);
        uint256 floor = Constants.POL_SHARES * uint256(vault.entryFloorBps()) / Constants.BPS;
        // The floor binds rollout, not redemption: a redeemer takes their pro-rata slice of every position, which
        // is allowed to take the entry pools below it. The bound asserted is the one rollout owns.
        assertGe(entryInventory + ghosts.burnedTotal(), floor, "entryFloorBps, net of redemptions");
    }

    // -------------------------------------------------------------------------------------------------------------
    // The quoter
    // -------------------------------------------------------------------------------------------------------------

    /// @notice §6: `AmpsQuoter` never reverts, in any state the campaign reached.
    function invariant_quoterNeverReverts() public view {
        assertFalse(ghosts.quoterEverReverted(), "the quoter answered every time");
        IAmpsQuoter.PoolQuote[] memory quotes = quoter.quoteAll();
        assertEq(quotes.length, allPools().length, "and it answers now");
    }

    // -------------------------------------------------------------------------------------------------------------
    // Non-vacuity
    // -------------------------------------------------------------------------------------------------------------

    /// @notice The campaign is worthless if the action space does not execute, so the space is driven once,
    ///         deterministically, action by action, and every one of them is required to have run and to have
    ///         done something. §8.3's first condition - "the handler must never revert on a valid action" - is
    ///         the same statement, and this is where it is checked.
    ///
    /// @dev A `afterInvariant()` non-vacuity check would be flakier than the property it protects: Foundry runs
    ///      it after every run *and* after shrinking, and a shrunk one-call counterexample can never have touched
    ///      sixteen actions. Driving the space explicitly is both deterministic and a stronger statement.
    function test_everyActionInTheSpaceExecutesAndDoesSomething() public {
        for (uint256 seed; seed < 4; ++seed) {
            handler.warp(seed * 977 + 61);
            handler.swapBuy(seed, seed + 3);
            handler.swapSell(seed, seed + 5);
            handler.swapRotate(seed, seed + 1, seed + 2);
            vaultHandler.checkpoint();
            handler.moveFeed(seed, seed * 313 + 7);
            handler.stepMultiplier(seed, seed * 11 + 3);
            handler.bond(seed, seed + 1);
            handler.warp(3600);
            handler.claim(seed);
            vaultHandler.redeem(seed + 1);
            vaultHandler.compound(seed);
            vaultHandler.rollout(seed);
            vaultHandler.deployBonded(seed);
            handler.armGate(seed);
            handler.probeHook(seed, seed);
            vaultHandler.removeLiquidity(seed);
        }

        bytes32[] memory names = ghosts.actionNames();
        for (uint256 i; i < names.length; ++i) {
            assertGt(ghosts.actionCount(names[i]), 0, string.concat("action never ran: ", _toString(names[i])));
        }
        assertGt(ghosts.actionsSucceeded(), names.length, "and the actions did something, not just revert");
        assertFalse(ghosts.swapEverReverted(), "no hook probe failed for anything but the rail");
        assertFalse(ghosts.quoterEverReverted(), "the quoter answered throughout");
        assertFalse(ghosts.navEverFell(), "and R1 held throughout");
        console.log("actions attempted", ghosts.actionsAttempted(), "succeeded", ghosts.actionsSucceeded());
    }

    /// @notice Reports the campaign's reach at the end of every run, so a green campaign says how green.
    function afterInvariant() public view {
        console.log("actions attempted", ghosts.actionsAttempted(), "succeeded", ghosts.actionsSucceeded());
    }

    // -------------------------------------------------------------------------------------------------------------
    // Medusa properties (`contracts/medusa.json`, §8.3)
    // -------------------------------------------------------------------------------------------------------------
    //
    // The same statements as the `invariant_` functions above, in the boolean shape Medusa's property testing
    // wants. `medusa.json` targets this contract with `testPrefixes: ["medusa_"]` and reuses this `setUp()`, so
    // the Foundry campaign and the Medusa campaign drive one fixture and check one set of properties. Every one
    // of these is a `view` over a ghost or a cheap read, per §8.3's second condition.

    /// @notice I3, I10, I33.
    /// @return ok Whether supply moved only through bonds and burns.
    function medusa_supplyMovesOnlyThroughBondsAndBurns() public view returns (bool ok) {
        return amps.totalSupply() == Constants.S0 + ghosts.mintedObserved() - ghosts.burnedTotal()
            && ghosts.mintedObserved() == ghosts.mintedVesting();
    }

    /// @notice I11.
    /// @return ok Whether R1 held on every placement path.
    function medusa_navPerShareNeverBleeds() public view returns (bool ok) {
        return !ghosts.navEverFell();
    }

    /// @notice I13.
    /// @return ok Whether the hook has always held nothing.
    function medusa_hookHoldsNothing() public view returns (bool ok) {
        return !ghosts.hookEverHeldValue() && IERC20(address(amps)).balanceOf(address(hook)) == 0;
    }

    /// @notice I15.
    /// @return ok Whether every refusal was the outer rail's.
    function medusa_swapsOnlyRefusedByTheRail() public view returns (bool ok) {
        return !ghosts.swapEverReverted();
    }

    /// @notice I16.
    /// @return ok Whether every fee decomposed inside its bands.
    function medusa_feesAlwaysDecompose() public view returns (bool ok) {
        return !ghosts.feeEverMalformed() && hook.sellFeeBps() >= 100 && hook.sellFeeBps() <= 600;
    }

    /// @notice I18.
    /// @return ok Whether a removal was ever refused.
    function medusa_removalsNeverBlocked() public view returns (bool ok) {
        return !ghosts.removalEverBlocked();
    }

    /// @notice I26.
    /// @return ok Whether the rotation credit ever survived a transaction boundary.
    function medusa_rotationCreditIsTransient() public view returns (bool ok) {
        return !ghosts.creditEverLeaked() && hook.rotationCredit() == 0;
    }

    /// @notice I31.
    /// @return ok Whether the creator payout stayed inside its share of the AMPS-side fees.
    function medusa_creatorPayoutIsBounded() public view returns (bool ok) {
        return ghosts.creatorPaid() * uint256(hook.sellFeeBps())
            <= ghosts.feesSplit() * uint256(Constants.CREATOR_FEE_BPS) + uint256(hook.sellFeeBps());
    }

    /// @notice I32.
    /// @return ok Whether rollout stayed inside its rolling daily budget.
    function medusa_rolloutStaysInsideItsBudget() public view returns (bool ok) {
        return ghosts.rolloutMoved() <= Constants.POL_SHARES * uint256(vault.rolloutBpsPerDay()) / Constants.BPS;
    }

    /// @notice I39 and §12 ruling E.
    /// @return ok Whether the grid and the live-cell budget both held.
    function medusa_gridAndCellBudgetHold() public view returns (bool ok) {
        return vault.liveCells() <= Constants.MAX_LIVE_CELLS && vault.liveCells() == countLiveCells()
            && ghosts.maxRecordsSeen() <= Constants.GRID_CELLS;
    }

    /// @notice §6.
    /// @return ok Whether `AmpsQuoter` has answered every time.
    function medusa_quoterNeverReverts() public view returns (bool ok) {
        return !ghosts.quoterEverReverted();
    }

    // -------------------------------------------------------------------------------------------------------------
    // The fault-injecting wrapper
    // -------------------------------------------------------------------------------------------------------------

    /// @notice §8.2's last clause: `afterSwap` never reverts and `AmpsQuoter` never reverts "under a
    ///         fault-injecting wrapper that makes the gate, feed registry, registry and stock token revert, run
    ///         out of gas, or return garbage, in every combination".
    ///
    /// @dev The faults are injected with `vm.mockCallRevert` and `vm.mockCall`, which intercept `staticcall` as
    ///      well as `call` and therefore reach exactly the hand-decoded probes §1.5 is built around. All sixteen
    ///      subsets of the four dependencies are exercised, each in both fault modes, on every pool and both
    ///      directions.
    function test_afterSwapAndQuoterNeverRevertUnderInjectedFaults() public {
        PoolId[] memory ids = allPools();
        // The keys are read *before* any fault is injected: the registry is one of the four dependencies being
        // broken, so a test that read a key through it mid-fault would be measuring its own mock.
        PoolKey[] memory keys = new PoolKey[](ids.length);
        for (uint256 i; i < ids.length; ++i) {
            keys[i] = registry.poolKey(ids[i]);
        }

        for (uint256 mask; mask < 16; ++mask) {
            for (uint256 mode; mode < 2; ++mode) {
                _injectFaults(mask, mode == 0);
                for (uint256 i; i < ids.length; ++i) {
                    _probeCallbacks(keys[i]);
                    quoter.quotePool(ids[i]);
                }
                quoter.quoteAll();
                quoter.quoteRotation(ids[0], ids[2], 1e15);
                quoter.bondQuote(marketIds[0]);
                vm.clearMockedCalls();
            }
        }
    }

    /// @dev Both swap callbacks on one pool, in both directions, as the PoolManager. Only `BeyondRail` may throw.
    function _probeCallbacks(PoolKey memory key) private {
        for (uint256 d; d < 2; ++d) {
            SwapParams memory params =
                SwapParams({zeroForOne: d == 0, amountSpecified: -int256(1e15), sqrtPriceLimitX96: 0});
            vm.prank(address(poolManager));
            try hook.afterSwap(address(this), key, params, toBalanceDelta(0, 0), "") returns (bytes4, int128 delta) {
                assertEq(delta, int128(0), "afterSwap returns no delta");
            } catch (bytes memory reason) {
                assertTrue(_isBeyondRail(reason), "afterSwap reverted for something other than the rail");
            }
        }
    }

    /// @dev Applies one subset of faults. Bit 0 the gate, bit 1 the feed registry, bit 2 the pool registry, bit 3
    ///      the stock tokens.
    function _injectFaults(uint256 mask, bool reverting) private {
        if (mask & 1 != 0) _breakContract(address(gate), reverting);
        if (mask & 2 != 0) _breakContract(address(feeds), reverting);
        if (mask & 4 != 0) _breakContract(address(registry), reverting);
        if (mask & 8 != 0) {
            for (uint256 i; i < stocks.length; ++i) {
                _breakContract(address(stocks[i]), reverting);
            }
        }
    }

    /// @dev Makes every call to `target` either revert or return undecodable garbage. Garbage is the harder of the
    ///      two: a `staticcall` that *succeeds* and then fails to decode is not catchable by `try`/`catch`, which
    ///      is exactly why §1.5's probes decode by hand.
    function _breakContract(address target, bool reverting) private {
        if (reverting) {
            vm.mockCallRevert(target, bytes(""), bytes("faulted"));
        } else {
            vm.mockCall(target, bytes(""), hex"c0ffee");
        }
    }

    /// @dev Whether a revert payload carries `Errors.BeyondRail`.
    function _isBeyondRail(bytes memory reason) private pure returns (bool found) {
        bytes4 selector = bytes4(keccak256("BeyondRail(bytes32,int24,int24)"));
        if (reason.length < 4) return false;
        for (uint256 i; i + 4 <= reason.length; ++i) {
            if (
                reason[i] == selector[0] && reason[i + 1] == selector[1] && reason[i + 2] == selector[2]
                    && reason[i + 3] == selector[3]
            ) return true;
        }
    }

    /// @dev A short `bytes32` label as a string, for assertion messages.
    function _toString(bytes32 value) private pure returns (string memory out) {
        bytes memory buffer = new bytes(32);
        uint256 length;
        for (uint256 i; i < 32; ++i) {
            if (value[i] == 0) break;
            buffer[i] = value[i];
            ++length;
        }
        bytes memory trimmed = new bytes(length);
        for (uint256 i; i < length; ++i) {
            trimmed[i] = buffer[i];
        }
        out = string(trimmed);
    }

    // -------------------------------------------------------------------------------------------------------------
    // Wiring
    // -------------------------------------------------------------------------------------------------------------

    /// @dev The handler's whole world, gathered into one argument.
    function _wiring() private view returns (Phase3Wiring memory w) {
        address[] memory stockAddresses = new address[](stocks.length);
        address[] memory feedAddresses = new address[](stocks.length);
        for (uint256 i; i < stocks.length; ++i) {
            stockAddresses[i] = address(stocks[i]);
            feedAddresses[i] = address(stockFeeds[i]);
        }

        w = Phase3Wiring({
            vault: vault,
            amps: amps,
            hook: hook,
            bonds: bonds,
            staking: staking,
            pot: pot,
            gate: gate,
            registry: registry,
            quoter: quoter,
            poolManager: poolManager,
            router: swapRouter,
            permit2: permit2,
            usdg: address(usdg),
            weth: address(weth),
            wethFeed: wethFeed,
            usdgFeed: usdgFeed,
            timelock: TIMELOCK,
            guardian: GUARDIAN,
            keeper: KEEPER,
            hubPool: hubPool,
            wethPool: wethPool,
            tickSpacing: TICK_SPACING,
            stocks: stockAddresses,
            stockFeeds: feedAddresses,
            constituentIds: constituentIds,
            marketIds: marketIds,
            spokePools: spokePools,
            stockUsd8: stockUsd8
        });
    }
}
