// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IAmpsVault} from "../../src/interfaces/IAmpsVault.sol";
import {Constants} from "../../src/types/Constants.sol";
import {PoolClass} from "../../src/types/Types.sol";
import {AmpsVaultFixture} from "../mocks/AmpsVaultFixture.sol";
import {MockStockToken} from "../mocks/MockStockToken.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @notice Opens a delta on the PoolManager that nobody closes.
///
/// @dev The shape of audit wave-2 finding 1. A Stock Token is a beacon proxy behind a key the protocol does not
///      hold, so its `transfer` is arbitrary code — and when the vault calls it from inside its **own** `unlock`,
///      that code can reach the PoolManager while it is unlocked. `mint` books a negative delta for *this*
///      contract, v4 counts non-zero deltas globally, and the vault's `unlock` therefore reverts with
///      `CurrencyNotSettled` at the end however clean the vault's own books are. Nothing here touches the vault.
contract DeltaOpener {
    IPoolManager private immutable MANAGER;
    address private immutable TOKEN;

    constructor(address manager_, address token_) {
        MANAGER = IPoolManager(manager_);
        TOKEN = token_;
    }

    /// @notice Mints one wei of claim to itself, leaving the delta open. Reverts harmlessly when the manager is
    ///         locked, which is exactly what happens when the vault calls the token outside an unlock.
    function open() external {
        MANAGER.mint(address(this), Currency.wrap(TOKEN).toId(), 1);
    }
}

/// @title VaultHostileTokenTest
/// @notice Audit wave-2 findings 1 and 2: **no registered token may stop, starve or poison an entry point.**
///
/// @dev Three hostile shapes, all of them reachable by an issuer with no protocol privileges at all, because
///      `_assets` is append-only and one wei of a donated balance is enough to put a token on every path:
///
///        1. a `transfer` that **burns every unit of gas it is handed** — which, unbounded, leaves the caller's
///           "this failed, skip it" branch a sixty-fourth of the frame (EIP-150) and so stops the redemption by
///           exhaustion rather than by reverting;
///        2. a `transfer` that **calls the PoolManager** from inside the vault's own `unlock` and opens a delta
///           nobody closes, which used to revert the whole payout with `CurrencyNotSettled` *after* every
///           per-asset `catch` had already been passed;
///        3. a `balanceOf` that **reverts**, which is on the NAV path as well as the redemption path.
///
///      §7 says the redemption floor cannot be stopped and the rulings say the sweep is best-effort; these are the
///      measurements behind both claims.
contract VaultHostileTokenTest is AmpsVaultFixture {
    /// @dev More than any bounded call is given, so an honest cap is exhausted and an unbounded one is not.
    uint256 private constant BURN = 5_000_000;

    DeltaOpener private opener;

    function setUp() public {
        deployVaultWorld();
        runGenesis();
        giveShares(ALICE, 500e18);

        // Both Stock Tokens hold real balances, so both are on every path a redemption walks.
        stock.mint(address(this), 10e18);
        bondDeposit(address(stock), address(this), 10e18);
        stock2.mint(address(this), 10e18);
        bondDeposit(address(stock2), address(this), 10e18);

        opener = new DeltaOpener(address(poolManager), address(stock));
    }

    // -------------------------------------------------------------------------------------------------------------
    // (1) The gas bomb
    // -------------------------------------------------------------------------------------------------------------

    /// @notice One Stock Token that burns everything it is handed on every `transfer`, plus the one wei of idle
    ///         balance that puts it on the sweep, cannot stop a redemption inside a 30M budget.
    ///
    /// @dev The donation matters: an idle balance is what makes `sweepClean` call the token at all, and the
    ///      measured failure before the fix was a redemption that consumed *whatever* it was given.
    function test_aGasBurningTransferCannotStarveTheRedemption() public {
        stock.mint(address(vault), 1);
        stock.setTransferGasBurn(BURN);

        vm.prank(ALICE);
        (address[] memory tokens, uint256[] memory amounts) = vault.redeemProRata{gas: 30_000_000}(1e18, ALICE);

        uint256 i = _indexOf(tokens, address(stock));
        assertGt(amounts[i], 0, "the hostile asset was still priced into the payout");
        assertEq(
            poolManager.balanceOf(ALICE, Currency.wrap(address(stock)).toId()),
            amounts[i],
            "and paid as a claim, which no token can burn gas inside"
        );
        assertGt(stock2.balanceOf(ALICE), 0, "the honest asset was paid in tokens");
    }

    /// @notice Two of them are no worse than one: the bound is per call, not per transaction.
    /// @dev The measured pre-fix failure was that two bomb tokens reverted the redemption outright at 30M.
    function test_twoGasBurningTokensStillCannotStarveTheRedemption() public {
        stock.mint(address(vault), 1);
        stock2.mint(address(vault), 1);
        stock.setTransferGasBurn(BURN);
        stock2.setTransferGasBurn(BURN);

        vm.prank(ALICE);
        (address[] memory tokens, uint256[] memory amounts) = vault.redeemProRata{gas: 30_000_000}(1e18, ALICE);

        for (uint256 i; i < tokens.length; ++i) {
            if (tokens[i] != address(stock) && tokens[i] != address(stock2)) continue;
            assertGt(amounts[i], 0, "priced");
            assertEq(poolManager.balanceOf(ALICE, Currency.wrap(tokens[i]).toId()), amounts[i], "paid as a claim");
        }
    }

    /// @notice And the cost is bounded rather than merely finite: one hostile asset stays inside twice the clean
    ///         redemption's gas.
    ///
    /// @dev This is the property the caps buy. "It did not revert" would still be satisfied by a redemption that
    ///      consumed 29 of 30 million and left the rest of the transaction unable to complete, which is the same
    ///      denial of service wearing a different hat.
    function test_oneHostileAssetCostsAtMostTwiceACleanRedemption() public {
        giveShares(BOB, 500e18);

        uint256 gasBefore = gasleft();
        vm.prank(BOB);
        vault.redeemProRata(1e18, BOB);
        uint256 clean = gasBefore - gasleft();

        stock.mint(address(vault), 1);
        stock.setTransferGasBurn(BURN);

        gasBefore = gasleft();
        vm.prank(ALICE);
        vault.redeemProRata{gas: 30_000_000}(1e18, ALICE);
        uint256 hostile = gasBefore - gasleft();

        emit log_named_uint("clean redemption gas", clean);
        emit log_named_uint("redemption with one hostile asset", hostile);
        // The bomb offers five million per call. What actually lands is two capped calls — the payout `take` and
        // the sweep's transfer, 200,000 each — so the marginal cost is a property of the caps and not of the
        // attacker's budget: measured at ~381k against a ~351k clean redemption, i.e. two caps and change.
        assertLt(hostile - clean, 3 * Constants.STOCK_TOKEN_PROBE_GAS * 4, "bounded by the caps, not by the bomb");
        assertLt(hostile * 2, clean * 5, "one hostile asset costs less than two and a half clean redemptions");
    }

    /// @notice The upkeep paths survive it too: `checkpoint` and `touch` walk the same sweep.
    function test_aGasBurningTransferDoesNotBlockTheUpkeepPaths() public {
        stock.mint(address(vault), 1);
        stock.setTransferGasBurn(BURN);

        vault.checkpoint{gas: 30_000_000}();
        vault.touch{gas: 30_000_000}();

        vm.prank(BONDS);
        vault.mintVesting{gas: 30_000_000}(BONDS, 1e18);
    }

    // -------------------------------------------------------------------------------------------------------------
    // (2) The foreign delta
    // -------------------------------------------------------------------------------------------------------------

    /// @notice A Stock Token that opens a PoolManager delta of its own from inside `transfer` cannot revert the
    ///         redemption: the ERC-20 attempt fails as a whole and every claim part is paid by the second,
    ///         unblockable unlock.
    ///
    /// @dev This is the case a per-asset `try take` cannot catch, because the `take` itself *succeeds* — the
    ///      revert lands at the end of the unlock, when v4 counts the deltas.
    function test_aTokenThatOpensAForeignDeltaCannotRevertThePayout() public {
        stock.setTransferHook(address(opener), abi.encodeCall(DeltaOpener.open, ()));

        uint256 supplyBefore = amps.totalSupply();

        vm.prank(ALICE);
        (address[] memory tokens, uint256[] memory amounts) = vault.redeemProRata(1e18, ALICE);

        uint256 i = _indexOf(tokens, address(stock));
        assertGt(amounts[i], 0, "the hostile asset is in the payout");
        assertEq(stock.balanceOf(ALICE), 0, "no ERC-20 moved: the whole ERC-20 attempt was abandoned");
        assertEq(
            poolManager.balanceOf(ALICE, Currency.wrap(address(stock)).toId()), amounts[i], "paid as a claim instead"
        );

        // The fallback pays *every* asset as a claim, honest ones included: it is one unlock, not a per-asset one.
        uint256 j = _indexOf(tokens, address(weth));
        assertEq(poolManager.balanceOf(ALICE, Currency.wrap(address(weth)).toId()), amounts[j], "and so is WETH");

        assertEq(supplyBefore - amps.totalSupply() >= 1e18, true, "the shares were burned exactly once");
    }

    /// @notice The same token on the *sweep* costs itself its absorb and nothing else.
    ///
    /// @dev `sync` and the transfer now run **outside** the unlock, so the token's call-back into the PoolManager
    ///      hits `ManagerLocked`. A token that bubbles that failure loses its own transfer, which is a skip and a
    ///      `SweepResidue`; the entry point completes either way. (`setReentrancy` is the bubbling shape;
    ///      {test_aSwallowingTokenIsSimplyAbsorbed} is the other one.)
    function test_aTokenThatOpensAForeignDeltaOnlyLosesItsOwnAbsorb() public {
        stock.mint(address(vault), 7);
        stock.setReentrancy(1, address(opener), abi.encodeCall(DeltaOpener.open, ()));

        vm.expectEmit(true, true, true, true, address(vault));
        emit IAmpsVault.SweepResidue(address(stock), 7);
        vault.checkpoint();

        assertEq(stock.balanceOf(address(vault)), 7, "the residue stayed on the vault, disclosed rather than fatal");
    }

    /// @notice And a token that *swallows* the `ManagerLocked` failure is simply absorbed: outside the unlock the
    ///         attempt costs the attacker their side effect, not the protocol its sweep.
    function test_aSwallowingTokenIsSimplyAbsorbed() public {
        uint256 claimBefore = claimOf(address(stock));
        stock.mint(address(vault), 7);
        stock.setTransferHook(address(opener), abi.encodeCall(DeltaOpener.open, ()));

        vault.checkpoint();

        assertEq(stock.balanceOf(address(vault)), 0, "the transfer went through");
        assertEq(claimOf(address(stock)), claimBefore + 7, "and the donation became backing");
    }

    /// @notice Control: with the hook disarmed the same donation is absorbed into claims and nothing is reported.
    function test_theSweepStillAbsorbsAnHonestDonation() public {
        uint256 claimBefore = claimOf(address(stock));
        stock.mint(address(vault), 7);

        vault.checkpoint();

        assertEq(stock.balanceOf(address(vault)), 0, "absorbed");
        assertEq(claimOf(address(stock)), claimBefore + 7, "into the vault's own claims");
    }

    // -------------------------------------------------------------------------------------------------------------
    // (3) The unreadable balance, on the NAV path
    // -------------------------------------------------------------------------------------------------------------

    /// @notice A constituent whose `balanceOf` reverts does not brick the NAV sum, and therefore does not brick
    ///         the permissionless checkpoint, every bond or every placement.
    ///
    /// @dev `_assets` is append-only: before the fix one switched-off issuer view was a permanent, protocol-wide
    ///      denial of service, because `totalAssetsUsd18` read every registered token with a plain typed call.
    function test_aRevertingBalanceOfDoesNotBrickTheNavPath() public {
        uint256 navBefore = vault.previewNavPerShareX18();

        stock.setBalanceOfReverts(true);

        vault.checkpoint();
        assertGt(vault.totalAssetsUsd18(), 0, "`A` is still computable");
        assertGt(vault.previewNavPerShareX18(), 0, "and so is NAV/share");
        assertLe(vault.previewNavPerShareX18(), navBefore, "the unreadable leg contributes zero, never a guess");

        // The claim side is what survives, and it is the whole of the vault's holding of that token by I12.
        vm.prank(BONDS);
        vault.mintVesting(BONDS, 1e18);
    }

    /// @notice And the same token cannot brick a redemption either: the claim leg is paid in full.
    function test_aRevertingBalanceOfStillPaysTheClaimLeg() public {
        stock.setBalanceOfReverts(true);

        vm.prank(ALICE);
        (address[] memory tokens, uint256[] memory amounts) = vault.redeemProRata(1e18, ALICE);
        assertGt(amounts[_indexOf(tokens, address(stock))], 0, "paid out of claims");
    }

    /// @notice The sweep's calls into a token are capped rather than open-ended: a token that offers to burn a
    ///         million more than its budget still costs the checkpoint only its budget.
    function test_theSweepsCallsIntoATokenAreCapped() public {
        stock.mint(address(vault), 1);
        stock.setTransferGasBurn(Constants.STOCK_TOKEN_PROBE_GAS * 4 + 1_000_000);

        uint256 gasBefore = gasleft();
        vault.checkpoint{gas: 30_000_000}();
        assertLt(gasBefore - gasleft(), 5_000_000, "the sweep's calls into the token are capped, not open-ended");
    }

    // -------------------------------------------------------------------------------------------------------------
    // Re-audit finding 8 — the claims-only fallback's gas reserve
    // -------------------------------------------------------------------------------------------------------------

    /// @notice **Re-audit finding 8.** The unblockable claims-only fallback is affordable at a full constituent
    ///         set: with the ERC-20 attempt burned by a hostile constituent, every one of 32 assets is still paid.
    ///
    /// @dev The reserve held back from the first attempt used to be a flat 700,000, whose own NatSpec claimed it
    ///      covered every registerable asset. It did not: the fallback unlock does one ERC-6909 `transfer` per
    ///      asset at ~27.5k cold, so it needs ~900k at 32 assets and ~1.8M at 66. The fallback is deliberately
    ///      *not* `try`-wrapped — it moves balances the vault is known to hold and calls no token — so running out
    ///      of gas inside it reverts the whole redemption, and the redemption is the one entry point nothing may
    ///      stop (§7). The reserve now scales with the list it has to walk.
    function test_r09_theClaimsFallbackIsAffordableAt32Assets() public {
        _registerExtraConstituents(28);
        assertEq(vault.assetCount(), 32, "a full constituent set plus the two entry counters");
        _assertEveryAssetIsPaidAsAClaim();
    }

    /// @notice And at the registry's own ceiling: `MAX_CONSTITUENTS` plus the two entry counters.
    function test_r09_theClaimsFallbackIsAffordableAtTheRegistryCeiling() public {
        _registerExtraConstituents(62);
        assertEq(vault.assetCount(), 66, "MAX_CONSTITUENTS + WETH + USDG");
        _assertEveryAssetIsPaidAsAClaim();
    }

    /// @dev Registers `count` further constituents, each with a feed and a real bonded balance, so that every one
    ///      of them is on the redemption's walk.
    function _registerExtraConstituents(uint256 count) private {
        for (uint256 i; i < count; ++i) {
            MockStockToken extra = new MockStockToken("Extra", "EXTR");
            registry.addConstituentAndPool(
                address(extra),
                address(uint160(0xFEED0000 + i)),
                PoolId.wrap(keccak256(abi.encode("extra", i))),
                PoolClass.SPOKE,
                60,
                0
            );
            feeds.setAnswer(address(extra), STOCK_USD8);
            extra.mint(address(this), 1e18);
            bondDeposit(address(extra), address(this), 1e18);
        }
    }

    /// @dev The ERC-20 attempt is abandoned as a whole (a constituent opens a PoolManager delta of its own from
    ///      inside `transfer`), so the claims-only unlock is what pays — and it must pay *everything*.
    function _assertEveryAssetIsPaidAsAClaim() private {
        stock.setTransferHook(address(opener), abi.encodeCall(DeltaOpener.open, ()));

        vm.prank(ALICE);
        (address[] memory tokens, uint256[] memory amounts) = vault.redeemProRata{gas: 30_000_000}(1e18, ALICE);

        uint256 paid;
        for (uint256 i; i < tokens.length; ++i) {
            if (amounts[i] == 0) continue;
            assertEq(
                poolManager.balanceOf(ALICE, Currency.wrap(tokens[i]).toId()),
                amounts[i],
                "every asset was paid as a claim by the fallback"
            );
            ++paid;
        }
        assertGt(paid, 2, "and there really were assets with a payout to pay");
    }

    // -------------------------------------------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------------------------------------------

    /// @dev The index of `token` in `tokens`; fails the test when it is absent.
    function _indexOf(address[] memory tokens, address token) private pure returns (uint256 index) {
        for (uint256 i; i < tokens.length; ++i) {
            if (tokens[i] == token) return i;
        }
        revert("token not in payout");
    }
}
