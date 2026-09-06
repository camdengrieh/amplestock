// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {MockAggregator} from "../test/mocks/MockAggregator.sol";
import {MockStockToken} from "../test/mocks/MockStockToken.sol";
import {MockUsdg} from "../test/mocks/MockUsdg.sol";
import {Registry} from "./05_Registry.s.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Script} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {console2} from "forge-std/console2.sol";

/// @title MockWeth9
/// @notice A WETH9 stand-in for chain 46630: an 18-decimal ERC-20 with `deposit`/`withdraw` and an open `mint`
///         so a faucet can hand test ether out without anyone holding native balance.
/// @dev Lives in the script rather than in `test/mocks/` on purpose: it is deployment fixture code for one
///      testnet, nothing in `src/` or `test/` may reach it, and the production `AMPS/WETH` leg is the real WETH9
///      at `0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73`. Native ETH is deliberately not the counter asset:
///      `address(0)` would always be `currency0` and break the AMPS-is-`currency0` invariant.
contract MockWeth9 is ERC20 {
    event Deposit(address indexed account, uint256 amount);
    event Withdrawal(address indexed account, uint256 amount);

    constructor() ERC20("Wrapped Ether", "WETH") {}

    /// @notice Wraps the ether sent with the call.
    function deposit() public payable {
        _mint(msg.sender, msg.value);
        emit Deposit(msg.sender, msg.value);
    }

    /// @notice Unwraps `amount` back to ether.
    /// @param amount The amount to unwrap.
    function withdraw(uint256 amount) external {
        _burn(msg.sender, amount);
        emit Withdrawal(msg.sender, amount);
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "WETH: send failed");
    }

    /// @notice Testnet faucet: mints unbacked WETH. Deliberately open, deliberately absent from real WETH9.
    /// @param to The recipient.
    /// @param amount The amount.
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    receive() external payable {
        deposit();
    }
}

/// @title TestnetPools
/// @notice Stands the 32-pool launch shape up on Robinhood Chain testnet (46630) against mock counter assets:
///         30 `MockStockToken`s (settable `uiMultiplier`, scheduled multiplier and `effectiveAt`, `oraclePaused`
///         and a beacon-shaped denylist), 30 `MockAggregator`s at the illustrative prices in
///         `script/config/constituents.json`, a `MockUsdg` and a {MockWeth9}. It then hands the whole set to
///         `05_Registry`, which registers and opens all 32 pools.
///
/// @dev **Idempotent and resumable.** Every address it deploys is recorded in `script/config/testnet.json` and a
///      re-run skips anything already there — asset by asset, not all-or-nothing — so a run that dies half way
///      through 30 tokens continues from where it stopped. Registration is idempotent for the same reason:
///      `05_Registry` skips an entry pool whose id is registered and a token that already has a constituent id.
///
/// @dev **Nothing here exists on 4663.** The mocks are fixture code: an open `mint`, an owner-settable multiplier
///      and a settable aggregator answer are exactly what the corporate-action, denylist and stale-feed drills
///      need and exactly what a production deployment must never have. `05_Registry` run against 4663 reads the
///      real Stock Token and Chainlink addresses out of `constituents.json` instead, and refuses any name whose
///      address is still a Phase 0 placeholder.
///
/// @dev **Usage.**
/// ```
///   forge script script/10_TestnetPools.s.sol --broadcast --rpc-url $ROBINHOOD_TESTNET_RPC_URL \
///     --libraries ...   # the four flags from script/config/libraries.json
/// ```
contract TestnetPools is Script {
    using stdJson for string;

    // -----------------------------------------------------------------------------------------------------------
    // Constants
    // -----------------------------------------------------------------------------------------------------------

    /// @notice Robinhood Chain testnet.
    uint256 internal constant TESTNET_CHAIN_ID = 46_630;

    /// @notice Where the deployed mocks are recorded, and re-read on a resume.
    string internal constant TESTNET_PATH = "./script/config/testnet.json";

    /// @notice The launch registration set the mocks stand in for.
    string internal constant CONSTITUENTS_PATH = "./script/config/constituents.json";

    /// @notice USDG's decimals, matching the real token on 4663.
    uint8 internal constant USDG_DECIMALS = 6;

    // -----------------------------------------------------------------------------------------------------------
    // Types
    // -----------------------------------------------------------------------------------------------------------

    /// @notice Everything this script deploys.
    /// @param usdg The `MockUsdg`.
    /// @param usdgFeed Its aggregator, at $1.00.
    /// @param weth9 The {MockWeth9}.
    /// @param wethFeed Its aggregator.
    /// @param stocks The 30 `MockStockToken`s, in `constituents.json` order.
    /// @param feeds Their 30 `MockAggregator`s, parallel to `stocks`.
    struct Assets {
        address usdg;
        address usdgFeed;
        address weth9;
        address wethFeed;
        address[] stocks;
        address[] feeds;
    }

    // -----------------------------------------------------------------------------------------------------------
    // Errors
    // -----------------------------------------------------------------------------------------------------------

    /// @notice The script is pointed at a chain it must never run on. The mocks carry an open mint.
    /// @param chainId The chain it found.
    error WrongChain(uint256 chainId);

    /// @notice `constituents.json` does not name the entry pool this script needs to substitute a mock for.
    /// @param symbol The ticker it looked for.
    error UnknownEntryPool(string symbol);

    /// @notice AMPS does not sort below one of the deployed counters, so its pool key would be rejected by
    ///         `PoolRegistry._validateKeyShape`. On a real deployment the CREATE2 salt is mined so this cannot
    ///         happen; here it means the mocks were deployed before AMPS, or against the wrong AMPS.
    /// @param amps The AMPS address.
    /// @param counter The offending counter.
    error CurrencyOrder(address amps, address counter);

    // -----------------------------------------------------------------------------------------------------------
    // State
    // -----------------------------------------------------------------------------------------------------------

    /// @notice The `05_Registry` instance this script delegates registration to. Deployed on first use, outside
    ///         any broadcast window, so it is a simulation-local helper and never a recorded transaction.
    Registry public registrar;

    // -----------------------------------------------------------------------------------------------------------
    // Entry points
    // -----------------------------------------------------------------------------------------------------------

    /// @notice Deploys whatever is missing, registers the 32 pools, and rewrites `script/config/testnet.json`.
    function run() external {
        if (block.chainid != TESTNET_CHAIN_ID && !vm.envOr("TESTNET_ALLOW_ANY_CHAIN", false)) {
            revert WrongChain(block.chainid);
        }
        Registry.Wiring memory core = _registrar().loadWiring();
        (Assets memory assets, Registry.Result memory result) = execute(core, loadAssets());
        writeAssets(assets);
        _registrar().writePools(core, result);
    }

    /// @notice Deploys the missing mocks and registers every pool that is not registered yet.
    /// @param core The core addresses `05_Registry` calls into.
    /// @param known What a previous run already deployed; zero entries are (re)deployed.
    /// @return assets Every address, old and new.
    /// @return result What the registration did.
    function execute(Registry.Wiring memory core, Assets memory known)
        public
        returns (Assets memory assets, Registry.Result memory result)
    {
        Registry.SpokeSpec[] memory spokes = _registrar().loadSpokes();
        Registry.EntryPoolSpec[] memory entries = _registrar().loadEntryPools();

        assets = deployAssets(core.timelock, known, spokes.length);
        _assertOrdering(core.amps, assets);

        // Substitute the mocks for the 4663 addresses the config carries, name by name. The entry pools are
        // matched by ticker rather than by position, so reordering the config cannot silently swap the hub for
        // the WETH leg — which `PoolRegistry.registerEntryPool` would then reject on `counterDecimals`.
        uint256 usdgIndex = _entryIndex(entries, "USDG");
        uint256 wethIndex = _entryIndex(entries, "WETH");
        entries[usdgIndex].counter = assets.usdg;
        entries[usdgIndex].feed = assets.usdgFeed;
        entries[wethIndex].counter = assets.weth9;
        entries[wethIndex].feed = assets.wethFeed;
        for (uint256 i; i < spokes.length; ++i) {
            spokes[i].token = assets.stocks[i];
            spokes[i].feed = assets.feeds[i];
        }

        result = _registrar().execute(core, entries, spokes);
    }

    /// @notice Deploys the two counter assets, their aggregators and the 30 stock/aggregator pairs, skipping
    ///         anything `known` already carries.
    /// @param sender The deployer (the same account that owns the mocks and can move their multipliers).
    /// @param known What already exists.
    /// @param count How many constituents the config names.
    /// @return assets The full set.
    function deployAssets(address sender, Assets memory known, uint256 count) public returns (Assets memory assets) {
        string memory json = vm.readFile(CONSTITUENTS_PATH);
        assets.stocks = new address[](count);
        assets.feeds = new address[](count);

        vm.startBroadcast(sender);

        assets.usdg = _has(known.usdg) ? known.usdg : address(new MockUsdg("Global Dollar", "USDG", USDG_DECIMALS));
        assets.usdgFeed = _has(known.usdgFeed)
            ? known.usdgFeed
            : address(new MockAggregator("USDG / USD", 8, int256(json.readUint(".entryPools[0].testnetPriceUsd8"))));
        assets.weth9 = _has(known.weth9) ? known.weth9 : address(new MockWeth9());
        assets.wethFeed = _has(known.wethFeed)
            ? known.wethFeed
            : address(new MockAggregator("ETH / USD", 8, int256(json.readUint(".entryPools[1].testnetPriceUsd8"))));

        uint256 deployed;
        for (uint256 i; i < count; ++i) {
            string memory at = string.concat(".constituents[", vm.toString(i), "]");
            string memory symbol = json.readString(string.concat(at, ".symbol"));
            bool haveToken = i < known.stocks.length && _has(known.stocks[i]);
            bool haveFeed = i < known.feeds.length && _has(known.feeds[i]);

            assets.stocks[i] = haveToken
                ? known.stocks[i]
                : address(new MockStockToken(json.readString(string.concat(at, ".name")), symbol));
            assets.feeds[i] = haveFeed
                ? known.feeds[i]
                : address(
                    new MockAggregator(
                        string.concat(symbol, " / USD"),
                        8,
                        int256(json.readUint(string.concat(at, ".testnetPriceUsd8")))
                    )
                );
            if (!haveToken) ++deployed;
        }

        vm.stopBroadcast();
        console2.log("assets ready: usdg %s weth %s", assets.usdg, assets.weth9);
        console2.log("%s of %s stock tokens deployed this run", deployed, count);
    }

    // -----------------------------------------------------------------------------------------------------------
    // Config
    // -----------------------------------------------------------------------------------------------------------

    /// @notice What a previous run deployed, from `script/config/testnet.json`.
    /// @return assets The recorded set; zero addresses mean "not deployed yet".
    function loadAssets() public view returns (Assets memory assets) {
        string memory json = vm.readFile(TESTNET_PATH);
        assets.usdg = json.readAddress(".usdg");
        assets.usdgFeed = json.readAddress(".usdgFeed");
        assets.weth9 = json.readAddress(".weth9");
        assets.wethFeed = json.readAddress(".wethFeed");

        uint256 n = json.readUint(".stockCount");
        assets.stocks = new address[](n);
        assets.feeds = new address[](n);
        for (uint256 i; i < n; ++i) {
            string memory at = string.concat(".stocks[", vm.toString(i), "]");
            assets.stocks[i] = json.readAddress(string.concat(at, ".token"));
            assets.feeds[i] = json.readAddress(string.concat(at, ".feed"));
        }
    }

    /// @notice Rewrites `script/config/testnet.json` so the next run resumes rather than redeploys.
    /// @param assets The set to record.
    function writeAssets(Assets memory assets) public {
        string memory constituents = vm.readFile(CONSTITUENTS_PATH);
        string[] memory items = new string[](assets.stocks.length);
        for (uint256 i; i < assets.stocks.length; ++i) {
            string memory obj = string.concat("amplestocks.testnet.", vm.toString(i));
            vm.serializeString(
                obj, "symbol", constituents.readString(string.concat(".constituents[", vm.toString(i), "].symbol"))
            );
            vm.serializeAddress(obj, "token", assets.stocks[i]);
            items[i] = vm.serializeAddress(obj, "feed", assets.feeds[i]);
        }

        string memory root = "amplestocks.testnet";
        vm.serializeString(
            root,
            "$comment",
            "Written by script/10_TestnetPools.s.sol on chain 46630. Every token here has an open mint and an "
            "owner-settable multiplier; nothing in this file exists on 4663 and nothing on 4663 may read it."
        );
        vm.serializeUint(root, "chainId", block.chainid);
        vm.serializeAddress(root, "usdg", assets.usdg);
        vm.serializeAddress(root, "usdgFeed", assets.usdgFeed);
        vm.serializeAddress(root, "weth9", assets.weth9);
        vm.serializeAddress(root, "wethFeed", assets.wethFeed);
        vm.serializeUint(root, "stockCount", assets.stocks.length);
        string memory json = vm.serializeString(root, "stocks", items);
        vm.writeJson(json, TESTNET_PATH);
        console2.log("wrote %s (%s stocks)", TESTNET_PATH, assets.stocks.length);
    }

    /// @notice Points this script at an existing `05_Registry` instance instead of letting it deploy one.
    /// @param instance The registrar.
    function setRegistrar(Registry instance) external {
        registrar = instance;
    }

    // -----------------------------------------------------------------------------------------------------------
    // Internals
    // -----------------------------------------------------------------------------------------------------------

    /// @dev `05_Registry` as a library of behaviour. Created outside every broadcast window, so it is a
    ///      simulation-local helper and never lands in the broadcast file.
    function _registrar() internal returns (Registry instance) {
        if (address(registrar) == address(0)) registrar = new Registry();
        instance = registrar;
    }

    /// @dev I1's precondition, asserted rather than assumed: AMPS is `currency0` in all 32 pools only because its
    ///      mined address sorts below every counter asset.
    function _assertOrdering(address amps, Assets memory assets) private pure {
        if (uint160(amps) >= uint160(assets.usdg)) revert CurrencyOrder(amps, assets.usdg);
        if (uint160(amps) >= uint160(assets.weth9)) revert CurrencyOrder(amps, assets.weth9);
        for (uint256 i; i < assets.stocks.length; ++i) {
            if (uint160(amps) >= uint160(assets.stocks[i])) revert CurrencyOrder(amps, assets.stocks[i]);
        }
    }

    /// @dev The index of the entry pool with `symbol`, or a revert. Two entries, so a scan is the whole story.
    function _entryIndex(Registry.EntryPoolSpec[] memory entries, string memory symbol)
        private
        pure
        returns (uint256 index)
    {
        for (uint256 i; i < entries.length; ++i) {
            if (keccak256(bytes(entries[i].symbol)) == keccak256(bytes(symbol))) return i;
        }
        revert UnknownEntryPool(symbol);
    }

    function _has(address value) private pure returns (bool) {
        return value != address(0);
    }
}
