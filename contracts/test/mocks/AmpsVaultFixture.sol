// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IAmpsVault} from "../../src/interfaces/IAmpsVault.sol";
import {PriceLib} from "../../src/lib/PriceLib.sol";
import {Amps} from "../../src/token/Amps.sol";
import {Constants} from "../../src/types/Constants.sol";
import {PoolClass} from "../../src/types/Types.sol";
import {ZeroPositionValuer} from "../../src/valuer/ZeroPositionValuer.sol";
import {AmpsVault} from "../../src/vault/AmpsVault.sol";
import {V4TestBase} from "../utils/V4TestBase.sol";
import {MockFeedRegistry} from "./MockFeedRegistry.sol";
import {MockMarketReference} from "./MockMarketReference.sol";
import {MockOracleGate} from "./MockOracleGate.sol";
import {MockPoolRegistry} from "./MockPoolRegistry.sol";
import {MockStockToken} from "./MockStockToken.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

/// @notice Minimal stand-in for the three contracts that hold a vault pointer and hand it on during an emergency
///         migration: `AmpsBonds`, `AmpsStaking` and `BountyPot`. Only `setVault` is ever reached from the vault.
/// @dev    A contract rather than an EOA because Solidity's high-level calls check `extcodesize`, so an EOA
///         pointer would make `emergencyMigrate` revert for the wrong reason.
contract MockVaultRole {
    /// @notice The current vault: the only address that may hand the role on.
    address public vault;

    /// @notice Emitted on every handover, mirroring `Amps.VaultChanged`.
    event VaultChanged(address indexed previousVault, address indexed newVault);

    /// @notice Thrown when anyone but the vault calls {setVault}.
    error NotVault(address caller);

    /// @param vault_ The initial vault.
    constructor(address vault_) {
        vault = vault_;
    }

    /// @notice Hands the vault role to `newVault`. Vault only.
    /// @param newVault The new vault.
    function setVault(address newVault) external {
        if (msg.sender != vault) revert NotVault(msg.sender);
        emit VaultChanged(vault, newVault);
        vault = newVault;
    }
}

/// @title AmpsVaultFixture
/// @notice The world every `AmpsVault` suite starts from: a local v4 PoolManager, the real `Amps` token deployed at
///         the address the vault was constructed against, the shared registry/gate/feed/market mocks, three assets
///         (WETH, USDG and one Stock Token) and the launch seed.
///
/// @dev The launch vector this fixture reproduces exactly: `S0` = 5,000 AMPS, 250 to the team vesting wallet and
///      4,750 retained as POL, against $2,500 of WETH (1 WETH at $2,500) and $2,500 of USDG (2,500 USDG at $1).
///      `A` is therefore $5,000 and NAV/share is `(5000e18 + 1) * 1e18 / (5000e18 + 1e3)` = 999999999999999999 —
///      $1.00 to the last wei the `VIRTUAL_SHARES` guard can round off.
abstract contract AmpsVaultFixture is V4TestBase {
    /// @dev The governance timelock: the only address that may call a `set*` or `genesis`.
    address internal constant TIMELOCK = address(0x7100E10C);
    /// @dev The guardian Safe: freezes and the predicate-gated migration.
    address internal constant GUARDIAN = address(0x6DA4D1A0);
    /// @dev The pre-registered standby vault an emergency migration may target.
    address internal constant STANDBY = address(0x57A4DB1);
    /// @dev The creator fee recipient set at genesis.
    address internal constant CREATOR = address(0xC12EA704);
    /// @dev The team's OZ `VestingWallet`.
    address internal constant TEAM_WALLET = address(0x7EA11);
    /// @dev An ordinary holder used by the redemption tests.
    address internal constant ALICE = address(0xA11CE);
    /// @dev A second holder.
    address internal constant BOB = address(0xB0B);

    /// @dev WETH at $2,500, 18 decimals.
    uint128 internal constant WETH_USD8 = 2500e8;
    /// @dev USDG at $1.00, 6 decimals.
    uint128 internal constant USDG_USD8 = 1e8;
    /// @dev The Stock Token at $100, 18 decimals.
    uint128 internal constant STOCK_USD8 = 100e8;
    /// @dev The founders' WETH seed: 1 WETH == $2,500.
    uint256 internal constant SEED_WETH = 1e18;
    /// @dev The founders' USDG seed: 2,500 USDG == $2,500.
    uint256 internal constant SEED_USDG = 2500e6;

    Amps internal amps;
    AmpsVault internal vault;
    MockPoolRegistry internal registry;
    MockOracleGate internal gate;
    MockFeedRegistry internal feeds;
    MockMarketReference internal marketRef;
    ZeroPositionValuer internal valuer;

    MockERC20 internal weth;
    MockERC20 internal usdg;
    MockStockToken internal stock;
    MockStockToken internal stock2;

    /// @dev The bonds shell: the only address that may deposit collateral or mint vesting AMPS.
    MockVaultRole internal bondsRole;
    /// @dev The xAMPS staking vault.
    MockVaultRole internal stakingRole;
    /// @dev The keeper bounty pot.
    MockVaultRole internal potRole;
    /// @dev `address(bondsRole)`, for the many `vm.prank`s that speak as the bonds shell.
    address internal BONDS;

    PoolId internal hubPool;
    PoolId internal wethPool;
    PoolId internal spokePool;

    /// @notice Deploys the whole Phase 2 world and wires every pointer, without running {genesis}.
    function deployVaultWorld() internal {
        deployV4();

        weth = deployToken("Wrapped Ether", "WETH", 18);
        usdg = deployToken("Global Dollar", "USDG", 6);
        stock = new MockStockToken("Mock Stock", "MSTK");
        stock2 = new MockStockToken("Mock Stock Two", "MSTK2");

        registry = new MockPoolRegistry();
        gate = new MockOracleGate();
        feeds = new MockFeedRegistry();
        marketRef = new MockMarketReference();
        valuer = new ZeroPositionValuer();

        // `Amps`'s constructor takes the vault and the vault's constructor takes AMPS, which is why production mines
        // the AMPS address first. Here the vault's CREATE address is predicted instead: same shape, no mining.
        address predictedVault = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        amps = new Amps(predictedVault);
        vault = new AmpsVault(address(amps), address(poolManager), TIMELOCK, GUARDIAN);
        assertEq(address(vault), predictedVault, "vault address prediction");

        hubPool = PoolId.wrap(keccak256("AMPS/USDG"));
        wethPool = PoolId.wrap(keccak256("AMPS/WETH"));
        spokePool = PoolId.wrap(keccak256("AMPS/MSTK"));

        registry.setVault(address(vault));
        registry.setHubPoolId(hubPool);
        registry.setWethPoolId(wethPool);
        registry.addEntryPool(hubPool, address(usdg), 6, 60, Constants.BUY_FEE_BPS_ENTRY_DEFAULT);
        registry.addEntryPool(wethPool, address(weth), 18, 60, Constants.BUY_FEE_BPS_ENTRY_DEFAULT);
        registry.addConstituentAndPool(address(stock), address(0xFEED), spokePool, PoolClass.SPOKE, 60, 3000);
        registry.addConstituentAndPool(
            address(stock2), address(0xFEED2), PoolId.wrap(keccak256("AMPS/MSTK2")), PoolClass.SPOKE, 60, 3000
        );

        feeds.setAnswer(address(weth), WETH_USD8);
        feeds.setAnswer(address(usdg), USDG_USD8);
        feeds.setAnswer(address(stock), STOCK_USD8);
        feeds.setAnswer(address(stock2), STOCK_USD8);

        bondsRole = new MockVaultRole(address(vault));
        stakingRole = new MockVaultRole(address(vault));
        potRole = new MockVaultRole(address(vault));
        BONDS = address(bondsRole);

        vm.startPrank(TIMELOCK);
        vault.setPolicyPointer(bytes32("registry"), address(registry));
        vault.setPolicyPointer(bytes32("bonds"), address(bondsRole));
        vault.setPolicyPointer(bytes32("staking"), address(stakingRole));
        vault.setPolicyPointer(bytes32("bountyPot"), address(potRole));
        vault.setPolicyPointer(bytes32("marketReference"), address(marketRef));
        vault.setPolicyPointer(bytes32("oracleGate"), address(gate));
        vault.setPolicyPointer(bytes32("feedRegistry"), address(feeds));
        vault.setPolicyPointer(bytes32("positionValuer"), address(valuer));
        vm.stopPrank();

        vm.label(address(vault), "AmpsVault");
        vm.label(address(amps), "AMPS");
        vm.label(address(stock), "MSTK");
    }

    /// @notice Runs {genesis} with the confirmed launch parameters, funding and approving the timelock first.
    function runGenesis() internal {
        weth.mint(TIMELOCK, SEED_WETH);
        usdg.mint(TIMELOCK, SEED_USDG);

        vm.startPrank(TIMELOCK);
        weth.approve(address(vault), type(uint256).max);
        usdg.approve(address(vault), type(uint256).max);
        vault.genesis(genesisParams());
        vm.stopPrank();
    }

    /// @notice The launch genesis arguments.
    /// @return params The arguments {genesis} is called with.
    function genesisParams() internal view returns (IAmpsVault.GenesisParams memory params) {
        address[] memory seedTokens = new address[](2);
        uint256[] memory seedAmounts = new uint256[](2);
        seedTokens[0] = address(weth);
        seedAmounts[0] = SEED_WETH;
        seedTokens[1] = address(usdg);
        seedAmounts[1] = SEED_USDG;

        params = IAmpsVault.GenesisParams({
            teamVestingWallet: TEAM_WALLET,
            creator: CREATOR,
            teamShares: Constants.TEAM_SHARES,
            polShares: Constants.POL_SHARES,
            seedTokens: seedTokens,
            seedAmounts: seedAmounts
        });
    }

    // -------------------------------------------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------------------------------------------

    /// @notice Moves `amount` of AMPS from the vault's POL inventory to `to`, so a test has a redeemer.
    /// @dev The vault is the only minter and burner, so the fixture moves inventory rather than minting: that keeps
    ///      `totalSupply` at `S0` and leaves I10 true for the whole suite.
    function giveShares(address to, uint256 amount) internal {
        vm.prank(address(vault));
        amps.transfer(to, amount);
    }

    /// @notice Settles `amount` of `token` from `payer` into the vault's claims through the bonds entry point.
    function bondDeposit(address token, address payer, uint256 amount) internal returns (uint256 settled) {
        vm.prank(payer);
        MockERC20(token).approve(address(vault), type(uint256).max);
        vm.prank(BONDS);
        settled = vault.depositBonded(1, token, payer, amount);
    }

    /// @notice The vault's ERC-6909 claim balance for `token`.
    function claimOf(address token) internal view returns (uint256) {
        return IPoolManager(address(poolManager)).balanceOf(address(vault), Currency.wrap(token).toId());
    }

    /// @notice The vault's total holding of `token`: claims plus any idle ERC-20 balance.
    function heldBalance(address token) internal view returns (uint256) {
        return claimOf(token) + MockERC20(token).balanceOf(address(vault));
    }

    /// @notice Seeds the hub ring so that `P_mkt` reads back as (approximately) `priceUsd18`.
    /// @param priceUsd18 The AMPS price in USD, 18 decimals.
    /// @return recorded The exact `P_mkt` the vault will compute from the seeded tick.
    function seedHubPrice(uint256 priceUsd18) internal returns (uint256 recorded) {
        int24 tick = PriceLib.sqrtPriceX96ToTick(PriceLib.ampsPerCounterToSqrtPriceX96(priceUsd18, USDG_USD8, 6));
        marketRef.setObservation(hubPool, tick, tick, Constants.TWAP_WINDOW_DEFAULT);
        recorded = PriceLib.sqrtPriceX96ToAmpsPriceUsd18(PriceLib.tickToSqrtPriceX96(tick), USDG_USD8, 6);
    }

    /// @notice Seeds the `AMPS/WETH` ring so the layer-F cross-check has both legs.
    /// @param priceUsd18 The AMPS price in USD implied by the WETH leg.
    function seedWethPrice(uint256 priceUsd18) internal {
        int24 tick = PriceLib.sqrtPriceX96ToTick(PriceLib.ampsPerCounterToSqrtPriceX96(priceUsd18, WETH_USD8, 18));
        marketRef.setObservation(wethPool, tick, tick, Constants.TWAP_WINDOW_DEFAULT);
    }
}
