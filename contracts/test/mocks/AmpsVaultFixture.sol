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
import {MockGenesisHolder} from "./MockGenesisHolder.sol";
import {MockMarketReference} from "./MockMarketReference.sol";
import {MockOracleGate} from "./MockOracleGate.sol";
import {MockPoolRegistry} from "./MockPoolRegistry.sol";
import {MockStockToken} from "./MockStockToken.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

/// @notice Minimal stand-in for the three contracts that hold a vault pointer and hand it on during an emergency
///         migration: `AmpsBonds` and `BountyPot`. Only `setVault` is ever reached from the vault.
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
/// @dev The launch vector this fixture reproduces exactly: `S0` = 20,000 AMPS, 1,000 to the team vesting wallet,
///      10,000 to the genesis adapter (standing for the auction tranche, which is in `totalSupply` whoever holds
///      it — decision 14 is fully diluted) and 9,000 retained as POL, against $10,000 of WETH (4 WETH at $2,500)
///      and $10,000 of USDG (10,000 USDG at $1). `A` is therefore $20,000 and NAV/share is
///      `(20000e18 + 1) * 1e18 / (20000e18 + 1e3)` = 999999999999999999 — $1.00 to the last wei the
///      `VIRTUAL_SHARES` guard can round off.
///
/// @dev **The seed is scaled with `S0`, not kept at $5,000.** Revision 7 quadrupled the supply, and a fixture that
///      kept the old $5,000 seed would launch at NAV/share = $0.25 and move every tick, every ladder cell and
///      every redemption vector in the suite for a reason that has nothing to do with what those tests assert.
///      The fixture therefore runs the *fallback* genesis path (the timelock's founders' seed) at a seed sized so
///      that NAV/share is still $1.00; `AmpsGenesis.t.sol` and `VaultGenesis.t.sol` are where the auction path and
///      the `raised / S0` arithmetic are exercised.
abstract contract AmpsVaultFixture is V4TestBase {
    /// @dev The governance timelock: the only address that may call a `set*`, `genesisMint` or the fallback
    ///      `genesisPlace`.
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
    /// @dev The founders' WETH seed: 4 WETH == $10,000.
    uint256 internal constant SEED_WETH = 4e18;
    /// @dev The founders' USDG seed: 10,000 USDG == $10,000.
    uint256 internal constant SEED_USDG = 10_000e6;

    /// @dev The `p0X18` this fixture asks {IAmpsVault-genesisPlace} for. `genesisPlace` floors the launch
    ///      reference at NAV/share, so the smallest legal value asks for exactly that floor and `P_ref` starts at
    ///      NAV — which is what genesis did before revision 7, and what every vector below this line was written
    ///      against. It matters at the last wei: `VIRTUAL_SHARES` puts NAV/share one wei under $1.00 even with a
    ///      seed worth exactly `S0` dollars, so asking for a flat `1e18` here would open a one-wei premium and
    ///      every "the reference is NAV" assertion in the suite would be off by that wei. A launch that really
    ///      does clear above NAV is `test/unit/VaultGenesis.t.sol`'s subject.
    uint256 internal constant GENESIS_P0_AT_NAV = 1;

    Amps internal amps;
    AmpsVault internal vault;
    MockPoolRegistry internal registry;
    MockOracleGate internal gate;
    MockFeedRegistry internal feeds;
    MockMarketReference internal marketRef;
    ZeroPositionValuer internal valuer;

    /// @dev Stands in for the `AmpsGenesis` adapter: the vault's `genesis` pointer and the auction tranche's
    ///      holder. See {MockGenesisHolder} for why the fixtures do not deploy the real adapter. Zero in a suite
    ///      that overrides {deployGenesisAdapter} to put the real one there.
    MockGenesisHolder internal genesisHolder;

    /// @dev Whatever the vault's `genesis` pointer holds, whether that is {genesisHolder} or a real `AmpsGenesis`.
    address internal genesisPointer;

    MockERC20 internal weth;
    MockERC20 internal usdg;
    MockStockToken internal stock;
    MockStockToken internal stock2;

    /// @dev The bonds shell: the only address that may deposit collateral or mint vesting AMPS.
    MockVaultRole internal bondsRole;
    /// @dev The keeper bounty pot.
    MockVaultRole internal potRole;
    /// @dev `address(bondsRole)`, for the many `vm.prank`s that speak as the bonds shell.
    address internal BONDS;

    PoolId internal hubPool;
    PoolId internal wethPool;
    PoolId internal spokePool;

    /// @notice Deploys the whole Phase 2 world and wires every pointer, without running genesis.
    function deployVaultWorld() internal {
        deployV4();

        // `setStandbyVault` refuses a codeless target (audit fix wave 2, finding 6): the standby is the address
        // `emergencyMigrate` hands six `onlyVault` roles to under duress, and an EOA there is unrecoverable. One
        // `STOP` is enough to make it a contract for every purpose the migration path exercises.
        vm.etch(STANDBY, hex"00");

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
        potRole = new MockVaultRole(address(vault));
        BONDS = address(bondsRole);
        genesisPointer = deployGenesisAdapter();

        vm.startPrank(TIMELOCK);
        vault.setPolicyPointer(bytes32("registry"), address(registry));
        vault.setPolicyPointer(bytes32("genesis"), genesisPointer);
        vault.setPolicyPointer(bytes32("bonds"), address(bondsRole));
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

    /// @notice Whatever the vault's `genesis` pointer is wired to. A {MockGenesisHolder} by default, because
    ///         every suite below this fixture is about the *vault*; `unit/AmpsGenesis.t.sol` overrides it to put
    ///         the real adapter and a mock CCA factory there instead.
    /// @return adapter The address the pointer is set to.
    function deployGenesisAdapter() internal virtual returns (address adapter) {
        genesisHolder = new MockGenesisHolder();
        return address(genesisHolder);
    }

    /// @notice Runs both genesis steps with the confirmed launch parameters, funding and approving the timelock
    ///         first. The placement is the fallback (founders' seed) path, called by the timelock.
    function runGenesis() internal {
        weth.mint(TIMELOCK, SEED_WETH);
        usdg.mint(TIMELOCK, SEED_USDG);

        vm.startPrank(TIMELOCK);
        weth.approve(address(vault), type(uint256).max);
        usdg.approve(address(vault), type(uint256).max);
        vault.genesisMint(genesisMintParams());
        vault.genesisPlace(genesisPlaceParams());
        vm.stopPrank();
    }

    /// @notice The step-one arguments.
    /// @return params The arguments `genesisMint` is called with.
    function genesisMintParams() internal view returns (IAmpsVault.GenesisMintParams memory params) {
        params = IAmpsVault.GenesisMintParams({
            teamVestingWallet: TEAM_WALLET,
            creator: CREATOR,
            genesis: genesisPointer,
            teamShares: Constants.TEAM_SHARES,
            auctionShares: Constants.AUCTION_SHARES,
            polShares: Constants.POL_SHARES
        });
    }

    /// @notice The step-two arguments: the founders' seed at the $1.00 fallback price.
    /// @return params The arguments `genesisPlace` is called with.
    function genesisPlaceParams() internal view returns (IAmpsVault.GenesisPlaceParams memory params) {
        address[] memory tokens = new address[](2);
        uint256[] memory amounts = new uint256[](2);
        tokens[0] = address(weth);
        amounts[0] = SEED_WETH;
        tokens[1] = address(usdg);
        amounts[1] = SEED_USDG;

        params =
            IAmpsVault.GenesisPlaceParams({p0X18: GENESIS_P0_AT_NAV, tokens: tokens, amounts: amounts, unsoldAmps: 0});
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
