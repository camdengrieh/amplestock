// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IFeedRegistry} from "../../src/interfaces/IFeedRegistry.sol";
import {IMarketReference} from "../../src/interfaces/IMarketReference.sol";
import {IOracleGate} from "../../src/interfaces/IOracleGate.sol";
import {Constants} from "../../src/types/Constants.sol";
import {GateState} from "../../src/types/Types.sol";
import {AmpsVaultFixture} from "../mocks/AmpsVaultFixture.sol";

/// @title VaultNavResilienceTest
/// @notice Audit wave-2 finding 3: **every untrusted read on the checkpoint path is a bounded, hand-decoded
///         `staticcall`, and a typed `try` was never enough.**
///
/// @dev Fix 18 replaced the vault's own gate reads. Three reads inside `VaultNavLib` kept their typed `try`, and a
///      `try` catches a callee that *reverts* and nothing else: Solidity decodes a **successful** call's
///      returndata in the caller's frame, so
///
///        * `referenceOverridden` — `snapshotByPool` returns a thirteen-word struct with two enums; an ordinal
///          above `type(GateState).max`, or a buffer shorter than the struct, is a `Panic` here;
///        * `marketPrice`/`_poolPriceUsd18` — `observationCoverage` and `twapTick`; an `int24` outside its range
///          is a `Panic` on decode;
///        * `answer` — `latestAnswer` returns `(uint256, uint32, bool)`; a third word that is neither 0 nor 1 is a
///          `Panic`.
///
///      All three sit on `checkpoint()`, which is permissionless, and on `depositBonded`, which every bond runs
///      through. Each case below forces one malformed answer from a pointer that *has code* — the only way to
///      reach these shapes at all, since `setPolicyPointer` refuses a codeless target — and asserts that the
///      checkpoint degrades instead of reverting.
contract VaultNavResilienceTest is AmpsVaultFixture {
    function setUp() public {
        deployVaultWorld();
        runGenesis();
        // Every read below is only reached for an asset that actually contributes to `A`.
        stock.mint(address(this), 10e18);
        bondDeposit(address(stock), address(this), 10e18);
        seedHubPrice(Constants.WAD);
    }

    // -------------------------------------------------------------------------------------------------------------
    // referenceOverridden: the gate snapshot
    // -------------------------------------------------------------------------------------------------------------

    /// @notice A snapshot shorter than the struct it declares is "unknown", not a `Panic`.
    function test_aShortGateSnapshotDoesNotBrickTheCheckpoint() public {
        vm.mockCall(address(gate), abi.encodeWithSelector(IOracleGate.snapshotByPool.selector), hex"01");
        vault.checkpoint();
        assertGt(vault.pMktX18(), 0, "and the market price still landed: the read degraded, it did not refuse");
    }

    /// @notice A `GateState` ordinal above the enum's maximum is "unknown" too, and unknown is not evidence of
    ///         divergence: the reference is not pinned by a word nobody can interpret.
    function test_anOutOfRangeGateStateInTheSnapshotIsUnknownRatherThanFatal() public {
        vm.mockCall(address(gate), abi.encodeWithSelector(IOracleGate.snapshotByPool.selector), _snapshot(77, 0));
        vault.checkpoint();
        assertGt(vault.pMktX18(), 0, "the checkpoint completed");
        assertGt(vault.pRefX18(), 0, "and wrote a reference");
    }

    /// @notice A non-canonical `watchdogTripped` — the word `2` — is `true`, which is what a hand-decoded bool
    ///         must mean, and it pins the reference at NAV exactly as an honest `true` does.
    function test_aNonCanonicalWatchdogBoolStillPinsTheReferenceAtNav() public {
        _armAMarketPriceAboveNav();
        vm.mockCall(address(gate), abi.encodeWithSelector(IOracleGate.snapshotByPool.selector), _snapshot(0, 2));

        vault.checkpoint();

        assertEq(vault.pRefX18(), vault.navPerShareX18(), "the override landed on a word `abi.decode` would reject");
        assertGt(vault.pMktX18(), vault.navPerShareX18(), "and the market price it overrode really was above NAV");
    }

    /// @notice And the honest path still works: a `REF_DIVERGED` snapshot pins the reference.
    function test_aReadableRefDivergedSnapshotStillPinsTheReference() public {
        _armAMarketPriceAboveNav();
        vm.mockCall(
            address(gate),
            abi.encodeWithSelector(IOracleGate.snapshotByPool.selector),
            _snapshot(uint256(uint8(GateState.REF_DIVERGED)), 0)
        );

        vault.checkpoint();
        assertEq(vault.pRefX18(), vault.navPerShareX18(), "pinned at NAV");
    }

    /// @notice The control that makes the two above mean something: with a readable, `GREEN`, untripped snapshot
    ///         the reference follows the market price rather than NAV.
    function test_theControlWithoutAnOverrideFollowsTheMarketPrice() public {
        _armAMarketPriceAboveNav();

        vault.checkpoint();
        assertEq(vault.pRefX18(), vault.pMktX18(), "no override, so the reference is the market price");
        assertGt(vault.pRefX18(), vault.navPerShareX18(), "which is above NAV");
    }

    // -------------------------------------------------------------------------------------------------------------
    // marketPrice: the observation ring
    // -------------------------------------------------------------------------------------------------------------

    /// @notice Short returndata from `observationCoverage` reads as "no coverage", which degrades `P_mkt` to zero
    ///         and the reference to the NAV anchor — never a revert of the permissionless checkpoint.
    function test_shortObservationCoverageDegradesTheMarketPrice() public {
        vm.mockCall(
            address(marketRef), abi.encodeWithSelector(IMarketReference.observationCoverage.selector), hex"beef"
        );
        vault.checkpoint();
        assertEq(vault.pMktX18(), 0, "no usable market price");
        assertEq(vault.pRefX18(), vault.navPerShareX18(), "so the reference falls back to NAV");
    }

    /// @notice A `twapTick` outside the tick range is refused as a price rather than truncated into one, and
    ///         refusing it is a degrade rather than a `Panic`.
    function test_anOutOfRangeTwapTickDegradesTheMarketPrice() public {
        vm.mockCall(
            address(marketRef),
            abi.encodeWithSelector(IMarketReference.twapTick.selector),
            abi.encode(int256(type(int24).max))
        );
        vault.checkpoint();
        assertEq(vault.pMktX18(), 0, "an impossible tick is no price at all");
    }

    /// @notice A market reference that reverts is the case the old `try` did cover, and it must keep working.
    function test_aRevertingMarketReferenceStillDegrades() public {
        vm.mockCallRevert(address(marketRef), abi.encodeWithSelector(IMarketReference.twapTick.selector), "down");
        vault.checkpoint();
        assertEq(vault.pMktX18(), 0, "degraded");
    }

    // -------------------------------------------------------------------------------------------------------------
    // answer: the feed registry
    // -------------------------------------------------------------------------------------------------------------

    /// @notice A `latestAnswer` whose `fresh` word is neither 0 nor 1 is still an answer: only the first word is
    ///         needed, so only the first word is read, and a dirty third word cannot `Panic` the NAV sum.
    function test_aDirtyBoolFromTheFeedRegistryDoesNotBrickTheNavSum() public {
        vm.mockCall(
            address(feeds),
            abi.encodeCall(IFeedRegistry.latestAnswer, (address(stock))),
            abi.encode(uint256(STOCK_USD8), uint256(block.timestamp), uint256(2))
        );
        uint256 assets = vault.totalAssetsUsd18();
        vault.checkpoint();
        assertGt(assets, 0, "`A` was computed from the answer's first word");
    }

    /// @notice An answer shorter than the declared tuple is still an answer when the word is there, and no answer
    ///         at all when it is not — and "no answer" is `FeedNotSet`, the deliberate conservative failure, not a
    ///         `Panic` in the vault's frame.
    function test_aTruncatedFeedAnswerIsReadAsAWordOrAsNothing() public {
        vm.mockCall(
            address(feeds),
            abi.encodeCall(IFeedRegistry.latestAnswer, (address(stock))),
            abi.encode(uint256(STOCK_USD8))
        );
        vault.checkpoint();

        vm.mockCall(address(feeds), abi.encodeCall(IFeedRegistry.latestAnswer, (address(stock))), hex"01");
        vm.expectRevert(abi.encodeWithSelector(IFeedRegistry.FeedNotSet.selector, address(stock)));
        vault.checkpoint();
    }

    // -------------------------------------------------------------------------------------------------------------
    // Finding 4: the held-back answer reaches the bond floor
    // -------------------------------------------------------------------------------------------------------------

    /// @notice A held-back jump on **one** asset marks the whole checkpoint unconfirmed.
    ///
    /// @dev `FeedRegistry` reports `min(held, candidate)` with `unconfirmed = true` while a >10% single-round move
    ///      waits for its second confirmation, and `VaultNavLib.answer` deliberately drops the flag: it is a
    ///      valuation read. That understates `A`, so it understates `navPerShareX18` — the **denominator** of
    ///      `AmpsBonds._qFloorX18` — and a bond on any *other* collateral would mint below the protocol's true
    ///      backing for as long as the hold lasts. The vault is the only contract that knows which assets entered
    ///      `A`, so it is the only one that can say so.
    function test_aHeldBackJumpOnOneAssetSetsTheNavFlag() public {
        assertFalse(vault.navUnconfirmed(), "nothing is held back to begin with");

        feeds.setUnconfirmed(address(stock), true);
        vault.checkpoint();
        assertTrue(vault.navUnconfirmed(), "the checkpoint recorded that its NAV rests on a held-back answer");
    }

    /// @notice And a confirmed answer clears it at the next checkpoint: the flag describes the live checkpoint,
    ///         not the history.
    function test_aConfirmedAnswerClearsTheNavFlag() public {
        feeds.setUnconfirmed(address(stock), true);
        vault.checkpoint();
        assertTrue(vault.navUnconfirmed(), "set");

        feeds.setUnconfirmed(address(stock), false);
        vault.checkpoint();
        assertFalse(vault.navUnconfirmed(), "cleared");
    }

    /// @notice A stale answer sets it for the same reason: `!fresh` is also a price the registry is holding below
    ///         the market, and NAV built on it is understated in the same direction.
    function test_aStaleAnswerAlsoSetsTheNavFlag() public {
        feeds.setFresh(address(stock), false);
        vault.checkpoint();
        assertTrue(vault.navUnconfirmed(), "stale is held back too");
    }

    /// @notice An asset the vault holds **nothing** of cannot set the flag: it never entered `A`.
    function test_anUnheldAssetsHeldBackAnswerIsNotTheVaultsProblem() public {
        assertEq(heldBalance(address(stock2)), 0, "the second stock is registered but unheld");
        feeds.setUnconfirmed(address(stock2), true);
        vault.checkpoint();
        assertFalse(vault.navUnconfirmed(), "an answer nothing was priced at cannot understate `A`");
    }

    /// @notice A `feedStatus` the vault cannot read is treated as held back, not as confirmed. The read can only
    ///         ever stop a bond pricing, so the conservative direction is the safe one.
    function test_anUnreadableFeedStatusReadsAsHeldBack() public {
        vm.mockCallRevert(address(feeds), abi.encodeWithSelector(IFeedRegistry.feedStatus.selector), "down");
        vault.checkpoint();
        assertTrue(vault.navUnconfirmed(), "unreadable is held back");
    }

    /// @notice The flag is a checkpoint property: `genesis()` wrote one, and every later checkpoint rewrites it.
    function test_theFlagFollowsTheCheckpointAndNotTheCall() public {
        feeds.setUnconfirmed(address(weth), true);
        assertFalse(vault.navUnconfirmed(), "the stored flag still describes the genesis checkpoint");
        vault.checkpoint();
        assertTrue(vault.navUnconfirmed(), "and the new one describes this checkpoint");
    }

    // -------------------------------------------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------------------------------------------

    /// @dev Puts `P_mkt` above NAV and far enough past the last checkpoint that the 10%-an-hour upward rate limit
    ///      does not bind, so that "the reference is NAV" is a statement about the override and not an artefact of
    ///      `max(nav, ...)`.
    function _armAMarketPriceAboveNav() private {
        vm.warp(block.timestamp + 200 hours);
        seedHubPrice(2e18);
    }

    /// @dev A thirteen-word `GateSnapshot` with the two fields the vault reads set by hand, so that a word no
    ///      `abi.decode` would accept can be placed in either of them.
    /// @param state_ Word 0, the `GateState` ordinal.
    /// @param watchdogTripped Word 5.
    function _snapshot(uint256 state_, uint256 watchdogTripped) private pure returns (bytes memory encoded) {
        uint256[13] memory words;
        words[0] = state_;
        words[5] = watchdogTripped;
        encoded = abi.encodePacked(
            words[0],
            words[1],
            words[2],
            words[3],
            words[4],
            words[5],
            words[6],
            words[7],
            words[8],
            words[9],
            words[10],
            words[11],
            words[12]
        );
    }
}

/// @title VaultSpokeWeightTest
/// @notice Audit wave-2 finding 5: the **realised** index weight, which `PoolRegistry.currentWeightBps` reports
///         and which the bond discount's deficit term and the rollout schedule are both built on.
///
/// @dev Phase 2 answered the target weight, so `k_w x (target - current) / target` was identically zero however
///      far under-weight a name was. `AmpsVault.spokeWeightBps` is the number that makes it real: the value of
///      what the protocol holds *of that name* — the counter-side position at the reference price, plus the idle
///      and claim balances — over the last checkpointed `A` (a live walk would cost ~150k gas per valued pool and
///      fail every probe budget at 32 pools while passing here, so the denominator is the checkpoint by design).
contract VaultSpokeWeightTest is AmpsVaultFixture {
    /// @dev $2,500 of the Stock Token at $100, against the $5,000 seed: a third of a $7,500 index.
    uint256 private constant STOCK_AMOUNT = 25e18;

    function setUp() public {
        deployVaultWorld();
        runGenesis();
        stock.mint(address(this), STOCK_AMOUNT);
        bondDeposit(address(stock), address(this), STOCK_AMOUNT);
        // `depositBonded` checkpoints *before* the collateral lands (the bond prices against the pre-deposit NAV),
        // and the realised weight is measured against the last checkpointed `A`, so refresh it once the stock is in.
        vault.checkpoint();
    }

    /// @notice A spoke holding half of what its target calls for reports half of it.
    function test_aSpokeAtHalfItsTargetReportsHalfTheWeight() public {
        // $2,500 of stock in a $7,500 index is 3,333 bp; a target of 6,666 bp is exactly twice that.
        registry.setTargetWeightBps(1, 6666);

        uint16 realised = vault.spokeWeightBps(1);
        assertEq(vault.totalAssetsUsd18(), 7500e18, "the index is the $5,000 seed plus $2,500 of the name");
        assertEq(realised, 3333, "and the name is a third of it");
        assertApproxEqAbs(uint256(realised) * 2, uint256(registry.constituent(1).targetWeightBps), 1, "half target");
    }

    /// @notice It follows the holding: doubling what the protocol holds of the name raises its weight.
    function test_theWeightFollowsTheHolding() public {
        uint16 before = vault.spokeWeightBps(1);

        stock.mint(address(this), STOCK_AMOUNT);
        bondDeposit(address(stock), address(this), STOCK_AMOUNT);
        vault.checkpoint();

        assertGt(vault.spokeWeightBps(1), before, "more of the name is more weight");
        assertEq(vault.spokeWeightBps(1), 5000, "$5,000 of a $10,000 index");
    }

    /// @notice A name the protocol holds nothing of is zero, not "unknown": zero is the honest realised weight,
    ///         and it is also the largest deficit, which is the point of the term.
    function test_anUnheldSpokeIsZero() public view {
        assertEq(vault.spokeWeightBps(2), 0, "nothing held of the second name");
    }

    /// @notice And an unpriceable name is zero rather than a revert or a guess, so a bond on it still prices.
    function test_anUnpriceableSpokeIsZero() public {
        feeds.clearAnswer(address(stock));
        assertEq(vault.spokeWeightBps(1), 0, "no answer, no weight");
    }

    /// @notice An id nobody registered is zero too.
    function test_anUnknownIdIsZero() public view {
        assertEq(vault.spokeWeightBps(0), 0, "zero is never a constituent");
        assertEq(vault.spokeWeightBps(99), 0, "and neither is 99");
    }
}
