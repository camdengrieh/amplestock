// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IAmpsVault} from "../../src/interfaces/IAmpsVault.sol";
import {Constants} from "../../src/types/Constants.sol";
import {NotPoolManager, Reentrancy, ZeroAddress} from "../../src/types/Errors.sol";
import {AmpsVaultFixture} from "../mocks/AmpsVaultFixture.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @notice Calls back into the vault from inside a Stock Token transfer, which is the shape of every "reentrant
///         Stock Token" case: the token is a beacon proxy behind a codeless admin key, so its `transfer` must be
///         assumed hostile.
contract Reenterer {
    address public immutable VAULT;
    bytes public payload;

    constructor(address vault_) {
        VAULT = vault_;
    }

    /// @notice Arms the callback with the vault call to attempt.
    /// @param payload_ The calldata to re-enter with.
    function arm(bytes calldata payload_) external {
        payload = payload_;
    }

    /// @notice Re-enters the vault, bubbling whatever it reverts with so the test sees the real error.
    function reenter() external {
        (bool ok, bytes memory returndata) = VAULT.call(payload);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(returndata, 0x20), mload(returndata))
            }
        }
    }
}

/// @title VaultAttackTest
/// @notice The named attacks from the plan's verification section that touch the vault: Arrakis-style flash deposit
///         manipulation, a reentrant Stock Token on every vault selector, first-depositor inflation, and
///         `sync -> settle -> take` against AMPS.
contract VaultAttackTest is AmpsVaultFixture {
    Reenterer internal attacker;

    function setUp() public {
        deployVaultWorld();
    }

    // -------------------------------------------------------------------------------------------------------------
    // Arrakis-style flash deposit manipulation
    // -------------------------------------------------------------------------------------------------------------

    /// @notice A large deposit immediately before redeeming buys the attacker nothing: `depositBonded` mints no
    ///         shares, so the deposit is a donation that the attacker recovers only at their own share of supply.
    function test_flashDepositThroughDepositBondedIsALoss() public {
        runGenesis();
        giveShares(address(this), 500e18); // 10% of supply

        uint256 flash = 1000e18; // $100,000 of stock against a $5,000 vault
        stock.mint(address(this), flash);

        uint256 supply = amps.totalSupply();
        bondDeposit(address(stock), address(this), flash);

        uint256 expected =
            ((flash * 500e18) / supply) * (Constants.BPS - Constants.REDEEM_FEE_BPS_DEFAULT) / Constants.BPS;

        vault.redeemProRata(500e18, address(this));

        assertEq(stock.balanceOf(address(this)), expected, "exactly pro rata of the inflated balance, no more");
        assertLt(stock.balanceOf(address(this)), flash, "the attacker is strictly worse off");
        assertApproxEqRel(stock.balanceOf(address(this)), flash / 10, 0.01e18, "they got back their own 10%, less fee");
    }

    /// @notice And the honest holder is never worse off: a flash deposit can only raise what they are owed.
    function test_flashDepositCannotReduceAnotherRedeemersPayout() public {
        runGenesis();
        giveShares(ALICE, 500e18);
        giveShares(address(this), 500e18);

        (, uint256[] memory before,) = vault.previewRedeem(500e18);

        stock.mint(address(this), 1000e18);
        bondDeposit(address(stock), address(this), 1000e18);

        (, uint256[] memory afterDeposit,) = vault.previewRedeem(500e18);
        for (uint256 i; i < before.length; ++i) {
            assertGe(afterDeposit[i], before[i], "no asset's payout fell");
        }

        vm.prank(ALICE);
        (, uint256[] memory paid) = vault.redeemProRata(500e18, ALICE);
        for (uint256 i; i < paid.length; ++i) {
            assertEq(paid[i], afterDeposit[i], "and the preview was exact");
        }
    }

    // -------------------------------------------------------------------------------------------------------------
    // Reentrant Stock Token
    // -------------------------------------------------------------------------------------------------------------

    /// @notice A Stock Token that calls back into the vault mid-transfer is refused on every locked selector.
    /// @dev The redemption is the trigger because it is the one path that pays a Stock Token out to an arbitrary
    ///      address, and it is also the path with no gate to hide behind: if the lock did not hold, this is where it
    ///      would show.
    function test_reentrantStockTokenIsRefusedOnEverySelector() public {
        runGenesis();
        giveShares(ALICE, 500e18);
        stock.mint(address(this), 10e18);
        bondDeposit(address(stock), address(this), 10e18);

        attacker = new Reenterer(address(vault));
        stock.setReentrancy(1, address(attacker), abi.encodeCall(Reenterer.reenter, ()));

        bytes[] memory payloads = _lockedSelectorPayloads();
        for (uint256 i; i < payloads.length; ++i) {
            attacker.arm(payloads[i]);
            vm.prank(ALICE);
            (bool ok, bytes memory returndata) =
                address(vault).call(abi.encodeCall(IAmpsVault.redeemProRata, (1e18, ALICE)));
            assertFalse(ok, "the reentrant call must take the redemption down with it");
            // v4-core's `CurrencyLibrary.transfer` wraps a failing token call, so the lock's error arrives nested.
            assertTrue(_contains(returndata, Reentrancy.selector), "the transient lock refused the reentry");
        }
    }

    /// @notice The one unlocked selector is closed by caller identity instead: the callback belongs to the
    ///         PoolManager, and a reentrant token is not the PoolManager.
    function test_reentrantStockTokenCannotDriveTheUnlockCallback() public {
        runGenesis();
        giveShares(ALICE, 500e18);
        stock.mint(address(this), 10e18);
        bondDeposit(address(stock), address(this), 10e18);

        attacker = new Reenterer(address(vault));
        stock.setReentrancy(1, address(attacker), abi.encodeCall(Reenterer.reenter, ()));
        attacker.arm(abi.encodeWithSignature("unlockCallback(bytes)", ""));

        vm.prank(ALICE);
        (bool ok, bytes memory returndata) =
            address(vault).call(abi.encodeCall(IAmpsVault.redeemProRata, (1e18, ALICE)));
        assertFalse(ok, "refused");
        assertTrue(_contains(returndata, NotPoolManager.selector), "refused by caller identity, not by the lock");
    }

    /// @notice With the callback disarmed the same redemption succeeds, so the tests above are not passing by
    ///         accident.
    function test_reentrancyControl() public {
        runGenesis();
        giveShares(ALICE, 500e18);
        stock.mint(address(this), 10e18);
        bondDeposit(address(stock), address(this), 10e18);

        attacker = new Reenterer(address(vault));
        stock.setReentrancy(0, address(attacker), abi.encodeCall(Reenterer.reenter, ()));

        vm.prank(ALICE);
        vault.redeemProRata(1e18, ALICE);
        assertGt(stock.balanceOf(ALICE), 0, "the honest redemption went through");
    }

    // -------------------------------------------------------------------------------------------------------------
    // First-depositor inflation
    // -------------------------------------------------------------------------------------------------------------

    /// @notice There is no first depositor to be. `S0` is minted once behind a latch and no other mint path exists,
    ///         so the classic share-inflation grief has nothing to attach to.
    function test_firstDepositorInflationIsImpossible() public {
        // Before genesis the denominator is `VIRTUAL_SHARES` alone and NAV/share is finite (I22).
        assertEq(amps.totalSupply(), 0, "no supply yet");
        assertEq(
            vault.previewNavPerShareX18(), (0 + 1) * 1e18 / Constants.VIRTUAL_SHARES, "finite, not a division by zero"
        );

        // A donation before genesis is the classic setup. It is invisible until genesis registers the asset list,
        // and it buys the donor nothing even then.
        stock.mint(address(vault), 100e18);
        assertEq(vault.totalAssetsUsd18(), 0, "nothing is registered before genesis, so nothing is valued");

        // Genesis mints exactly `S0`, split by the two constants, and folds the donation into everyone's backing.
        runGenesis();
        assertEq(amps.totalSupply(), Constants.S0, "exactly S0, whatever the donation was");
        assertEq(vault.totalAssetsUsd18(), 15_000e18, "seed plus donation");
        assertEq(vault.navPerShareX18(), (15_000e18 + 1) * 1e18 / (Constants.S0 + Constants.VIRTUAL_SHARES), "shared");

        // And the latch means there is no second bite.
        vm.prank(TIMELOCK);
        vm.expectRevert(IAmpsVault.GenesisAlreadyDone.selector);
        vault.genesis(genesisParams());
    }

    /// @notice The virtual-share guard keeps NAV/share finite even with every share redeemed.
    function test_virtualSharesKeepNavFiniteAtZeroSupply() public {
        runGenesis();
        giveShares(ALICE, Constants.POL_SHARES);
        vm.prank(TEAM_WALLET);
        amps.transfer(ALICE, Constants.TEAM_SHARES);

        vm.prank(ALICE);
        vault.redeemProRata(Constants.S0, ALICE);

        assertEq(amps.totalSupply(), 0, "supply is zero");
        vault.checkpoint();
        assertGt(vault.navPerShareX18(), 0, "and NAV/share is still a number");
    }

    // -------------------------------------------------------------------------------------------------------------
    // sync -> settle -> take against AMPS
    // -------------------------------------------------------------------------------------------------------------

    /// @notice AMPS can never enter the asset list, so no settle/take round trip can turn the share token into
    ///         backing for itself (I5).
    function test_ampsCanNeverBecomeAnAsset() public {
        runGenesis();

        vm.prank(BONDS);
        vm.expectRevert(ZeroAddress.selector);
        vault.depositBonded(1, address(amps), ALICE, 1e18);

        // Nor through pool registration: `initializePool` registers the counter assets, and AMPS is filtered.
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(amps)),
            currency1: Currency.wrap(address(weth)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        vm.prank(address(registry));
        vault.initializePool(key, 79_228_162_514_264_337_593_543_950_336);
        assertFalse(vault.isAsset(address(amps)), "AMPS is still not an asset");
    }

    /// @dev Whether `data` contains `selector` at any 4-byte-aligned offset. v4-core wraps a failing token call in
    ///      `CustomRevert.WrappedError`, so an inner custom error arrives nested rather than bare.
    function _contains(bytes memory data, bytes4 selector) private pure returns (bool) {
        if (data.length < 4) return false;
        for (uint256 i; i + 4 <= data.length; ++i) {
            if (
                data[i] == selector[0] && data[i + 1] == selector[1] && data[i + 2] == selector[2]
                    && data[i + 3] == selector[3]
            ) {
                return true;
            }
        }
        return false;
    }

    /// @dev Every locked external selector, as calldata for the reentrant attempt.
    function _lockedSelectorPayloads() private view returns (bytes[] memory payloads) {
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(usdg)),
            currency1: Currency.wrap(address(weth)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });

        payloads = new bytes[](26);
        payloads[0] = abi.encodeCall(IAmpsVault.redeemProRata, (1e18, ALICE));
        payloads[1] = abi.encodeCall(IAmpsVault.checkpoint, ());
        payloads[2] = abi.encodeCall(IAmpsVault.touch, ());
        payloads[3] = abi.encodeCall(IAmpsVault.depositBonded, (1, address(stock), BOB, 1e18));
        payloads[4] = abi.encodeCall(IAmpsVault.mintVesting, (BONDS, 1e18));
        payloads[5] = abi.encodeCall(IAmpsVault.genesis, (genesisParams()));
        payloads[6] = abi.encodeCall(IAmpsVault.initializePool, (key, 1 << 96));
        payloads[7] = abi.encodeCall(IAmpsVault.place, (spokePool, true, 1e18));
        payloads[8] = abi.encodeCall(IAmpsVault.compound, (spokePool));
        payloads[9] = abi.encodeCall(IAmpsVault.rollout, (1));
        payloads[10] = abi.encodeCall(IAmpsVault.deployBonded, (1));
        payloads[11] = abi.encodeWithSignature("withdrawRetiredBids(uint16)", 1);
        payloads[12] = abi.encodeCall(IAmpsVault.setRedeemFeeBps, (50));
        payloads[13] = abi.encodeCall(IAmpsVault.setBurnBps, (50));
        payloads[14] = abi.encodeCall(IAmpsVault.setStakerBps, (50));
        payloads[15] = abi.encodeCall(IAmpsVault.setRefUpRateBps, (500));
        payloads[16] = abi.encodeCall(IAmpsVault.setRefDivergenceBps, (500));
        payloads[17] = abi.encodeCall(IAmpsVault.setTwapWindow, (900));
        payloads[18] = abi.encodeCall(IAmpsVault.setLadderShape, (1.25e18, 10, 4, 4));
        payloads[19] = abi.encodeCall(IAmpsVault.setRolloutParams, (200, 3000));
        payloads[20] = abi.encodeCall(IAmpsVault.setSpokeSeedBps, (100));
        payloads[21] = abi.encodeCall(IAmpsVault.setPolicyPointer, (bytes32("positionValuer"), address(valuer)));
        payloads[22] = abi.encodeCall(IAmpsVault.setStandbyVault, (STANDBY));
        payloads[23] = abi.encodeCall(IAmpsVault.setCreator, (BOB));
        payloads[24] = abi.encodeCall(IAmpsVault.emergencyMigrate, (STANDBY));
        payloads[25] = abi.encodeCall(IAmpsVault.setDeployThresholdUsd18, (100e18));
    }
}
