// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {AmpsBonds} from "../../src/bonds/AmpsBonds.sol";
import {BountyPot} from "../../src/keeper/BountyPot.sol";
import {PriceLib} from "../../src/lib/PriceLib.sol";
import {OracleGate} from "../../src/oracle/OracleGate.sol";
import {AmpsStaking} from "../../src/staking/AmpsStaking.sol";
import {Amps} from "../../src/token/Amps.sol";
import {Constants} from "../../src/types/Constants.sol";
import {Checkpoint} from "../../src/types/Types.sol";
import {AmpsVault} from "../../src/vault/AmpsVault.sol";
import {MockAggregator} from "../mocks/MockAggregator.sol";
import {MockMarketReference} from "../mocks/MockMarketReference.sol";
import {MockStockToken} from "../mocks/MockStockToken.sol";
import {MockUsdg} from "../mocks/MockUsdg.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {CommonBase} from "forge-std/Base.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";

/// @notice Everything `Phase2Handler` needs to drive the wired system, gathered into one argument so the
///         constructor does not run into the stack limit.
/// @param vault The `AmpsVault`.
/// @param amps The AMPS token.
/// @param bonds The bonds shell.
/// @param staking xAMPS.
/// @param pot The keeper bounty pot.
/// @param gate The oracle gate.
/// @param marketRef The observation source (`MockMarketReference` until `AmpsHook` exists).
/// @param usdg USDG, the pot's token and the hub's counter.
/// @param wethFeed The ETH/USD aggregator.
/// @param usdgFeed The USDG/USD aggregator.
/// @param timelock The governance timelock.
/// @param guardian The guardian Safe.
/// @param hubPool The `AMPS/USDG` pool id.
/// @param wethPool The `AMPS/WETH` pool id.
/// @param wethUsd8 The ETH/USD answer the rings are seeded against.
/// @param usdgUsd8 The USDG/USD answer the rings are seeded against.
/// @param stocks The constituent Stock Tokens.
/// @param stockFeeds Their aggregators.
/// @param marketIds Their bond markets.
/// @param spokePools Their pools.
/// @param stockUsd8 Their launch prices.
struct Phase2Wiring {
    AmpsVault vault;
    Amps amps;
    AmpsBonds bonds;
    AmpsStaking staking;
    BountyPot pot;
    OracleGate gate;
    MockMarketReference marketRef;
    MockUsdg usdg;
    MockAggregator wethFeed;
    MockAggregator usdgFeed;
    address timelock;
    address guardian;
    PoolId hubPool;
    PoolId wethPool;
    uint128 wethUsd8;
    uint128 usdgUsd8;
    address[] stocks;
    address[] stockFeeds;
    uint16[] marketIds;
    PoolId[] spokePools;
    uint128[] stockUsd8;
}

/// @title Phase2Handler
/// @notice The bounded action space the Phase 2 invariant campaign drives: real bonds on real markets, real
///         claims, real redemptions, real checkpoints, feeds that move, go stale and die, a hub TWAP that runs a
///         premium and gives it back, guardian freezes, gate pokes, the staker stream and the bounty pot.
///
/// @dev **Nothing in here asserts.** Every action is wrapped in `try`/`catch` and every finding is recorded as a
///      ghost flag or a running total, which is what lets the campaign run with `fail_on_revert = false` and
///      still prove something: a revert is a legitimate outcome of a bounded action space (a closed epoch, a
///      frozen gate, an empty balance), while a *silent* violation is not, and only the ghosts can tell them
///      apart. The invariant functions in `Phase2.invariant.t.sol` read the ghosts.
///
/// @dev **Market moves are labelled.** I8 ("NAV/share is monotone non-decreasing ex market moves") is only
///      checkable if the handler knows which of its own actions is a market move. The three that are —
///      {moveFeed}, {breakFeed} and {moveHub} — do not record a NAV comparison; every other action does.
contract Phase2Handler is CommonBase, StdCheats, StdUtils {
    // -------------------------------------------------------------------------------------------------------------
    // Wiring
    // -------------------------------------------------------------------------------------------------------------

    AmpsVault internal immutable VAULT;
    Amps internal immutable AMPS;
    AmpsBonds internal immutable BONDS;
    AmpsStaking internal immutable STAKING;
    BountyPot internal immutable POT;
    OracleGate internal immutable GATE;
    MockMarketReference internal immutable MARKET_REF;
    MockUsdg internal immutable USDG;
    MockAggregator internal immutable WETH_FEED;
    MockAggregator internal immutable USDG_FEED;
    address internal immutable TIMELOCK;
    address internal immutable GUARDIAN;
    PoolId internal immutable HUB_POOL;
    PoolId internal immutable WETH_POOL;
    uint128 internal immutable WETH_USD8;
    uint128 internal immutable USDG_USD8;

    address[] internal stocks;
    address[] internal stockFeeds;
    uint16[] internal marketIds;
    PoolId[] internal spokePools;
    uint128[] internal stockUsd8;

    // -------------------------------------------------------------------------------------------------------------
    // Ghosts
    // -------------------------------------------------------------------------------------------------------------

    /// @notice AMPS wei minted through `AmpsVault.mintVesting`, i.e. by bonds — the only mint path after the
    ///         genesis latch (I3, I10).
    uint256 public mintedVesting;
    /// @notice AMPS wei burned from redeemers.
    uint256 public burnedShares;
    /// @notice AMPS wei burned from the vault's released inventory during redemptions.
    uint256 public burnedInventory;
    /// @notice AMPS wei claimed out of vesting positions.
    uint256 public claimedVesting;
    /// @notice AMPS wei this handler has moved into `AmpsStaking` as the vault's staker slice.
    uint256 public notifiedRewards;

    /// @notice Set the moment a non-market-move action lowers NAV/share (I8).
    bool public navEverFell;
    /// @notice Set the moment a bond lowers NAV/share (I27).
    bool public bondEverDiluted;
    /// @notice Set the moment a fill exceeds the capacity the market disclosed a moment earlier (I28).
    bool public capacityEverExceeded;
    /// @notice Set the moment a redemption pays anything other than the exact pro-rata amount (I23).
    bool public redemptionEverInexact;
    /// @notice Set the moment a `claim()` with something to claim fails (I38).
    bool public claimEverFailed;
    /// @notice Set the moment `P_ref` leaves `[navPerShare, max(navPerShare, rateLimit)]` (I24).
    bool public referenceEverOutOfBand;
    /// @notice Set the moment `AmpsStaking.totalAssets()` falls on an action that is not a withdrawal (I36).
    bool public stakingAssetsEverFell;
    /// @notice Set the moment a vault call returns with a registered asset still resting on the vault as an
    ///         ERC-20 balance (I12).
    bool public sweepEverDirty;

    /// @notice Diagnostics for the first dilutive bond, so a failure names the numbers rather than a flag.
    uint256 public badBondMarket;
    uint256 public badBondAmountIn;
    uint256 public badBondAmpsOut;
    uint256 public badBondNavBefore;
    uint256 public badBondNavAfter;
    /// @notice Diagnostics for the first out-of-band reference.
    uint256 public badRefPRef;
    uint256 public badRefNav;
    uint256 public badRefCeiling;
    uint256 public badRefPrev;
    uint256 public badRefElapsed;
    /// @notice Diagnostics for the first NAV/share fall on a non-market action.
    bytes32 public badNavAction;
    uint256 public badNavBefore;
    uint256 public badNavAfter;

    /// @notice How many actions actually did something, so the invariants can prove the run was not empty.
    uint256 public actionCount;
    /// @notice How many bonds landed.
    uint256 public bondCount;
    /// @notice How many redemptions landed.
    uint256 public redeemCount;
    /// @notice How many checkpoints landed.
    uint256 public checkpointCount;
    /// @notice How many claims landed.
    uint256 public claimCount;

    /// @dev The previous checkpoint's reference price and timestamp, for the I24 rate-limit ghost.
    uint256 internal lastPRefX18;
    uint32 internal lastCheckpointAt;

    /// @dev The vesting positions this handler owns, so {claim} can address one.
    uint256 internal positionCount;

    /// @dev `AmpsStaking.totalAssets()` captured at the start of the action in flight.
    uint256 internal stakingAssetsBefore;

    constructor(Phase2Wiring memory w) {
        VAULT = w.vault;
        AMPS = w.amps;
        BONDS = w.bonds;
        STAKING = w.staking;
        POT = w.pot;
        GATE = w.gate;
        MARKET_REF = w.marketRef;
        USDG = w.usdg;
        WETH_FEED = w.wethFeed;
        USDG_FEED = w.usdgFeed;
        TIMELOCK = w.timelock;
        GUARDIAN = w.guardian;
        HUB_POOL = w.hubPool;
        WETH_POOL = w.wethPool;
        WETH_USD8 = w.wethUsd8;
        USDG_USD8 = w.usdgUsd8;

        stocks = w.stocks;
        stockFeeds = w.stockFeeds;
        marketIds = w.marketIds;
        spokePools = w.spokePools;
        stockUsd8 = w.stockUsd8;

        lastPRefX18 = w.vault.pRefX18();
        lastCheckpointAt = w.vault.checkpointData().timestamp;
    }

    /// @dev Captures what the post-action checks compare against. Every action opens with it.
    /// @param name The action, recorded on the first I8 violation so the failure names its own cause.
    /// @param marketMove Whether the action is allowed to lower NAV/share.
    /// @param withdrawal Whether the action is allowed to lower `AmpsStaking.totalAssets()`.
    modifier action(bytes32 name, bool marketMove, bool withdrawal) {
        uint256 navBefore = _nav();
        stakingAssetsBefore = _stakingAssets();
        _;
        ++actionCount;
        _checkReference();
        uint256 navAfter = _nav();
        if (!marketMove && navBefore != 0 && navAfter != 0 && navAfter < navBefore) {
            if (!navEverFell) {
                badNavAction = name;
                badNavBefore = navBefore;
                badNavAfter = navAfter;
            }
            navEverFell = true;
        }
        uint256 stakingAfter = _stakingAssets();
        if (!withdrawal && stakingAfter < stakingAssetsBefore) stakingAssetsEverFell = true;
    }

    // -------------------------------------------------------------------------------------------------------------
    // Actions — bonds
    // -------------------------------------------------------------------------------------------------------------

    /// @notice Bonds a random amount of a random constituent, respecting nothing: the shell's own capacity,
    ///         gate and floor logic is what decides whether the call lands.
    /// @param seed Picks the market.
    /// @param amount The raw collateral amount, bounded into a plausible range.
    function bond(uint256 seed, uint256 amount) external action("bond", false, false) {
        uint256 i = _pick(seed, 0, stocks.length - 1);
        uint256 amountIn = bound(amount, 1e12, 20e18);

        MockStockToken(stocks[i]).mint(address(this), amountIn);
        MockStockToken(stocks[i]).approve(address(VAULT), type(uint256).max);

        uint256 capacityLeft = type(uint256).max;
        try BONDS.quote(marketIds[i], amountIn) returns (uint256, uint256, uint16, bool, uint256 left, bytes32) {
            capacityLeft = left;
        } catch {}

        // No keeper refresh on purpose: the bond path prices against a same-block checkpoint that `depositBonded`
        // writes before it settles, whatever age the standing checkpoint has and whatever the gate says. A
        // dilutive bond here is therefore the bond path's fault, never a stale reader's.
        uint256 navBefore = _nav();
        try BONDS.bond(marketIds[i], amountIn, 0, address(this)) returns (uint256 ampsOut, uint256) {
            mintedVesting += ampsOut;
            ++positionCount;
            ++bondCount;
            if (ampsOut > capacityLeft) capacityEverExceeded = true;
            uint256 navAfter = _nav();
            if (navBefore != 0 && navAfter != 0 && navAfter < navBefore) {
                if (!bondEverDiluted) {
                    badBondMarket = i;
                    badBondAmountIn = amountIn;
                    badBondAmpsOut = ampsOut;
                    badBondNavBefore = navBefore;
                    badBondNavAfter = navAfter;
                }
                bondEverDiluted = true;
            }
            _checkSwept();
        } catch {}
    }

    /// @notice Claims from one of this handler's vesting positions. I38: whenever anything is claimable the call
    ///         must succeed, whatever the gate, the market or the policy is doing.
    /// @param seed Picks the position.
    function claim(uint256 seed) external action("claim", false, false) {
        if (positionCount == 0) return;
        uint256 id = _pick(seed, 0, positionCount - 1);

        uint256 claimable;
        try BONDS.claimable(address(this), id) returns (uint256 value) {
            claimable = value;
        } catch {
            return;
        }
        if (claimable == 0) return;

        try BONDS.claim(id, address(this)) returns (uint256 amount) {
            claimedVesting += amount;
            ++claimCount;
            if (amount != claimable) claimEverFailed = true;
        } catch {
            claimEverFailed = true;
        }
    }

    // -------------------------------------------------------------------------------------------------------------
    // Actions — redemption
    // -------------------------------------------------------------------------------------------------------------

    /// @notice Redeems a random fraction of this handler's AMPS and checks I23 exactly: every non-AMPS balance
    ///         pays `floor(floor(b x shares / T) x (BPS - fee) / BPS)` and the released inventory is burned.
    /// @param fraction The fraction of the handler's balance to redeem, in bps.
    function redeem(uint256 fraction) external action("redeem", false, false) {
        uint256 balance = AMPS.balanceOf(address(this));
        if (balance == 0) return;
        uint256 shares = (balance * bound(fraction, 1, Constants.BPS)) / Constants.BPS;
        if (shares == 0) return;

        uint256 supply = AMPS.totalSupply();
        uint256 keepBps = Constants.BPS - VAULT.redeemFeeBps();
        uint256 count = VAULT.assetCount();

        address[] memory tokens = new address[](count);
        uint256[] memory expected = new uint256[](count);
        uint256[] memory heldBefore = new uint256[](count);
        for (uint256 i; i < count; ++i) {
            tokens[i] = VAULT.assetAt(i);
            heldBefore[i] = IERC20(tokens[i]).balanceOf(address(this));
            uint256 vaultHeld = _heldByVault(tokens[i]);
            expected[i] = (((vaultHeld * shares) / supply) * keepBps) / Constants.BPS;
        }
        uint256 expectedBurn = (AMPS.balanceOf(address(VAULT)) * shares) / supply;

        try VAULT.redeemProRata(shares, address(this)) returns (address[] memory paid, uint256[] memory amounts) {
            burnedShares += shares;
            burnedInventory += expectedBurn;
            ++redeemCount;

            if (paid.length != count) redemptionEverInexact = true;
            for (uint256 i; i < count && i < paid.length; ++i) {
                if (paid[i] != tokens[i] || amounts[i] != expected[i]) redemptionEverInexact = true;
                if (IERC20(tokens[i]).balanceOf(address(this)) != heldBefore[i] + expected[i]) {
                    redemptionEverInexact = true;
                }
            }
            if (AMPS.totalSupply() != supply - shares - expectedBurn) redemptionEverInexact = true;
            _checkSwept();
        } catch {}
    }

    // -------------------------------------------------------------------------------------------------------------
    // Actions — time, oracles and the reference
    // -------------------------------------------------------------------------------------------------------------

    /// @notice Advances the clock across sessions and bond epochs, producing one block per second so the layer-A
    ///         watchdog sees a chain that kept running.
    /// @param dt The seconds to advance, bounded to `[1 minute, 3 days]`.
    function warp(uint256 dt) external action("warp", false, false) {
        uint256 step = bound(dt, 1 minutes, 3 days);
        vm.warp(block.timestamp + step);
        vm.roll(block.number + step + 1);
    }

    /// @notice Advances the clock with *no* blocks at all, which is exactly the layer-A watchdog's trigger.
    /// @param dt The seconds to advance.
    function stall(uint256 dt) external action("stall", false, false) {
        vm.warp(block.timestamp + bound(dt, Constants.GRACE_SECONDS_DEFAULT, 2 days));
    }

    /// @notice Republishes one constituent's answer at a random multiple of its launch price. A market move: NAV
    ///         may legitimately fall, so this action records no NAV comparison.
    /// @param seed Picks the feed.
    /// @param pct The new answer as a percentage of the launch price, in `[25, 400]`.
    function moveFeed(uint256 seed, uint256 pct) external action("moveFeed", true, false) {
        uint256 i = _pick(seed, 0, stockFeeds.length - 1);
        uint256 answer = (uint256(stockUsd8[i]) * bound(pct, 25, 400)) / 100;
        if (answer == 0) answer = 1;
        MockAggregator(stockFeeds[i]).setAnswer(int256(answer));
    }

    /// @notice Makes one feed stale or outright dead, and undoes it. Also a market move.
    /// @param seed Picks the feed.
    /// @param mode 0 healthy, 1 stale, 2 reverting.
    function breakFeed(uint256 seed, uint256 mode) external action("breakFeed", true, false) {
        uint256 i = _pick(seed, 0, stockFeeds.length - 1);
        uint256 pick = _pick(mode, 0, 2);
        MockAggregator(stockFeeds[i]).setStale(pick == 1);
        MockAggregator(stockFeeds[i]).setRevert(pick == 2);
    }

    /// @notice Republishes every aggregator at its current answer, which is what a live Chainlink node does.
    function refreshFeeds() external action("refreshFeeds", true, false) {
        WETH_FEED.setAnswer(int256(uint256(WETH_USD8)));
        USDG_FEED.setAnswer(int256(uint256(USDG_USD8)));
        for (uint256 i; i < stockFeeds.length; ++i) {
            MockAggregator(stockFeeds[i]).setStale(false);
            MockAggregator(stockFeeds[i]).setRevert(false);
        }
    }

    /// @notice Moves the hub observation, i.e. the AMPS price the whole reference machinery is anchored to. Both
    ///         entry legs and every spoke move together so the layer-F cross-check has a consistent world to read.
    /// @param priceSeed The new AMPS price, bounded to `[$0.20, $5.00]`.
    function moveHub(uint256 priceSeed) external action("moveHub", true, false) {
        uint256 price = bound(priceSeed, 0.2e18, 5e18);
        _observe(HUB_POOL, price, USDG_USD8, 6);
        _observe(WETH_POOL, price, WETH_USD8, 18);
        for (uint256 i; i < spokePools.length; ++i) {
            _observe(spokePools[i], price, stockUsd8[i], 18);
        }
    }

    /// @notice The permissionless checkpoint. The I24 rate-limit ghost lives in {_checkReference}, which every
    ///         action runs, so a checkpoint written from inside another action (a bond refreshes it first) is
    ///         checked too rather than silently moving the ghost's baseline.
    function checkpoint() external action("checkpoint", false, false) {
        try VAULT.checkpoint() returns (Checkpoint memory) {
            _checkSwept();
        } catch {}
    }

    /// @notice The permissionless watchdog stamp, and its per-pool sibling that arms the divergence breaker.
    /// @param seed Picks between the two.
    function poke(uint256 seed) external action("poke", false, false) {
        if (_pick(seed, 0, 1) == 0) {
            try GATE.poke() {} catch {}
        } else {
            try GATE.pokePool(HUB_POOL) {} catch {}
        }
        try VAULT.touch() {
            _checkSwept();
        } catch {}
    }

    // -------------------------------------------------------------------------------------------------------------
    // Actions — guardian
    // -------------------------------------------------------------------------------------------------------------

    /// @notice A guardian freeze, protocol-wide or on one constituent, always inside the 7-day auto-expiry bound.
    /// @param seed Picks the scope and the constituent.
    /// @param duration The freeze length.
    function freeze(uint256 seed, uint256 duration) external action("freeze", false, false) {
        uint32 until = uint32(block.timestamp + bound(duration, 1, Constants.GUARDIAN_FREEZE_MAX_SECONDS));
        vm.startPrank(GUARDIAN);
        if (_pick(seed, 0, 1) == 0) {
            try GATE.freezeProtocol(until) {} catch {}
        } else {
            try GATE.freezeConstituent(uint16(_pick(seed, 1, stocks.length)), until) {} catch {}
        }
        vm.stopPrank();
    }

    /// @notice Clears whatever the guardian froze.
    /// @param seed Picks the scope.
    function unfreeze(uint256 seed) external action("unfreeze", false, false) {
        vm.startPrank(GUARDIAN);
        if (_pick(seed, 0, 1) == 0) {
            try GATE.unfreezeProtocol() {} catch {}
        } else {
            try GATE.unfreezeConstituent(uint16(_pick(seed, 1, stocks.length))) {} catch {}
        }
        vm.stopPrank();
    }

    // -------------------------------------------------------------------------------------------------------------
    // Actions — staking and the bounty pot
    // -------------------------------------------------------------------------------------------------------------

    /// @notice The staker slice, exactly as `compound()` will pay it: the vault transfers the AMPS in and calls
    ///         `notifyReward` in the same transaction.
    /// @param amount The tranche, bounded by the vault's own inventory.
    function notifyReward(uint256 amount) external action("notifyReward", false, false) {
        uint256 inventory = AMPS.balanceOf(address(VAULT));
        if (inventory < 1e18) return;
        uint256 cut = bound(amount, 1e12, inventory / 100);
        if (cut == 0) return;

        vm.startPrank(address(VAULT));
        try AMPS.transfer(address(STAKING), cut) {
            try STAKING.notifyReward(cut) {
                notifiedRewards += cut;
            } catch {}
        } catch {}
        vm.stopPrank();
    }

    /// @notice Stakes some of this handler's AMPS.
    /// @param amount The deposit.
    function stake(uint256 amount) external action("stake", false, false) {
        uint256 balance = AMPS.balanceOf(address(this));
        if (balance < 1e15) return;
        uint256 assets = bound(amount, 1e12, balance / 4);
        AMPS.approve(address(STAKING), type(uint256).max);
        try STAKING.deposit(assets, address(this)) {} catch {}
    }

    /// @notice Unstakes — the one action allowed to lower `AmpsStaking.totalAssets()`.
    /// @param fraction The fraction of the handler's xAMPS to redeem, in bps.
    function unstake(uint256 fraction) external action("unstake", false, true) {
        uint256 shares = (STAKING.balanceOf(address(this)) * bound(fraction, 1, Constants.BPS)) / Constants.BPS;
        if (shares == 0) return;
        try STAKING.redeem(shares, address(this), address(this)) {} catch {}
    }

    /// @notice Funds the keeper bounty pot, which must stay outside the NAV numerator (I21).
    /// @param amount The USDG to add.
    function fundPot(uint256 amount) external action("fundPot", false, false) {
        uint256 raw = bound(amount, 1e6, 1000e6);
        USDG.mint(address(this), raw);
        USDG.approve(address(POT), type(uint256).max);
        try POT.fund(raw) {} catch {}
    }

    /// @notice An outright donation of a Stock Token to the vault, followed by the `touch` that absorbs it into
    ///         claims. A donation raises everyone's backing and creates no claim for the donor.
    /// @param seed Picks the token.
    /// @param amount The donation.
    function donate(uint256 seed, uint256 amount) external action("donate", false, false) {
        uint256 i = _pick(seed, 0, stocks.length - 1);
        MockStockToken(stocks[i]).mint(address(VAULT), bound(amount, 1, 10e18));
        // The donation rests on the vault until a vault call absorbs it, which is exactly what `touch` is for.
        try VAULT.touch() {
            _checkSwept();
        } catch {}
    }

    // -------------------------------------------------------------------------------------------------------------
    // Internals
    // -------------------------------------------------------------------------------------------------------------

    /// @dev I24, checked after every action rather than only after {checkpoint}: several actions refresh the
    ///      checkpoint (a bond does, deliberately), and a ghost that only watched one of them would let the
    ///      others move its own baseline. `P_ref` must be at least NAV and at most
    ///      `max(NAV, prevPRef x (1 + refUpRateBps x elapsed / hour))`; a downward move has no limit at all, and
    ///      is inside that band by construction.
    function _checkReference() internal {
        uint32 at = VAULT.checkpointData().timestamp;
        uint256 pRef = VAULT.pRefX18();
        uint256 nav = VAULT.navPerShareX18();
        if (at == 0) return;

        uint256 elapsed = at > lastCheckpointAt ? at - lastCheckpointAt : 0;
        uint256 cap = lastPRefX18 + (lastPRefX18 * Constants.REF_UP_RATE_BPS_DEFAULT * elapsed)
            / (uint256(Constants.ONE_HOUR) * Constants.BPS);
        uint256 ceiling = nav > cap ? nav : cap;

        if (at != lastCheckpointAt) ++checkpointCount;
        if (pRef < nav || pRef > ceiling + 1) {
            if (!referenceEverOutOfBand) {
                badRefPRef = pRef;
                badRefNav = nav;
                badRefCeiling = ceiling;
                badRefPrev = lastPRefX18;
                badRefElapsed = elapsed;
            }
            referenceEverOutOfBand = true;
        }

        lastPRefX18 = pRef;
        lastCheckpointAt = at;
    }

    /// @dev I12, checked where the invariant actually holds: at the exit of a vault call. A donation that lands
    ///      between two vault calls legitimately rests on the vault until the next one absorbs it, so the
    ///      "no idle balance" property is a post-condition of the vault's own functions, not of every block.
    function _checkSwept() internal {
        uint256 count = VAULT.assetCount();
        for (uint256 i; i < count; ++i) {
            if (IERC20(VAULT.assetAt(i)).balanceOf(address(VAULT)) != 0) sweepEverDirty = true;
        }
    }

    /// @dev NAV/share, or zero when the read itself is unavailable (a feed the protocol cannot price at all).
    function _nav() internal view returns (uint256 nav) {
        try VAULT.previewNavPerShareX18() returns (uint256 value) {
            return value;
        } catch {
            return 0;
        }
    }

    /// @dev `AmpsStaking.totalAssets()`, or zero when unreadable.
    function _stakingAssets() internal view returns (uint256 assets) {
        try STAKING.totalAssets() returns (uint256 value) {
            return value;
        } catch {
            return 0;
        }
    }

    /// @dev The vault's whole holding of `token`: the ERC-6909 claim plus any idle ERC-20 balance.
    function _heldByVault(address token) internal view returns (uint256 held) {
        held = IERC20(token).balanceOf(address(VAULT))
            + IPoolManagerBalance(VAULT.poolManager()).balanceOf(address(VAULT), uint256(uint160(token)));
    }

    /// @dev One full-coverage ring entry for the AMPS/counter pool implied by the two prices.
    function _observe(PoolId poolId, uint256 ampsUsd18, uint256 counterUsd8, uint8 counterDecimals) internal {
        int24 tick;
        try this.tickFor(ampsUsd18, counterUsd8, counterDecimals) returns (int24 value) {
            tick = value;
        } catch {
            return;
        }
        MARKET_REF.setObservation(poolId, tick, tick, Constants.TWAP_WINDOW_DEFAULT);
    }

    /// @notice The tick of the `AMPS/counter` pool implied by an AMPS price and the counter's answer. External so
    ///         that `PriceLib`'s range reverts can be caught rather than aborting the whole action.
    /// @param ampsUsd18 The AMPS price in USD, 18 decimals.
    /// @param counterUsd8 The counter asset's answer, 8 decimals.
    /// @param counterDecimals The counter asset's ERC-20 decimals.
    /// @return tick The pool tick.
    function tickFor(uint256 ampsUsd18, uint256 counterUsd8, uint8 counterDecimals) external pure returns (int24 tick) {
        tick =
            PriceLib.sqrtPriceX96ToTick(PriceLib.ampsPerCounterToSqrtPriceX96(ampsUsd18, counterUsd8, counterDecimals));
    }

    /// @dev An index picker, kept separate from `bound` so the intent reads as "pick one of these", not "clamp".
    function _pick(uint256 seed, uint256 min, uint256 max) internal pure returns (uint256) {
        if (max <= min) return min;
        return min + (seed % (max - min + 1));
    }
}

/// @dev The ERC-6909 slice of `IPoolManager` the handler needs, declared locally so the handler does not pull the
///      whole v4 interface graph in for one `balanceOf`.
interface IPoolManagerBalance {
    /// @notice The ERC-6909 claim balance of `owner` for currency `id`.
    function balanceOf(address owner, uint256 id) external view returns (uint256 amount);
}
