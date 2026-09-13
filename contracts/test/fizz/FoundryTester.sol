// SPDX-License-Identifier: MIT
pragma solidity >=0.6.2 <0.9.0;

import {Constants} from "../../src/types/Constants.sol";
import {Handlers} from "./handlers/Handlers.sol";
import {console} from "forge-std/console.sol";

/// @notice Contract to be used for quick testing with Foundry.
///
/// @dev It does **not** inherit `forge-std/Test` itself: `Handlers` already descends from it through
///      `Base -> Phase3Fixture -> V4TestBase -> Test`, and inheriting it twice does not compile.
contract FoundryTester is Handlers {
    /// @dev Identical to {Base-asActor}; see the note there on why it is a single-shot prank.
    modifier asActor() override {
        vm.prank(actor);
        _;
    }

    function setUp() public {
        setup();
    }

    // forge test --match-test test_setupSmoke -vv
    /// @notice The Step 6 gate: `setup()` really built the Phase 3 world and the vault has a NAV to fuzz against.
    function test_setupSmoke() public view {
        assertEq(pools.length, spokeCount() + 2, "every pool is cached: hub, WETH and one per spoke");
        assertTrue(vault.initialized(), "genesis ran");
        assertGt(vault.navPerShareX18(), 0, "NAV/share is positive");
        assertGt(vault.previewNavPerShareX18(), 0, "the live NAV/share is positive too");
        assertGt(vault.pRefX18(), 0, "the launch reference is set");
        assertEq(amps.totalSupply(), Constants.S0, "supply is exactly S0 before any bond");

        for (uint256 i; i < pools.length; ++i) {
            assertTrue(registry.isRegistered(pools[i]), "pool registered");
            assertGt(vault.ladderLength(pools[i]), 0, "pool carries a genesis ladder");
            assertTrue(counterOf(pools[i]) != address(0), "pool has a counter asset");
        }
        assertGt(vault.liveCells(), 0, "the ladder budget is in use");

        assertEq(actors.length, 3, "three actors");
        for (uint256 i; i < actors.length; ++i) {
            assertGt(amps.balanceOf(actors[i]), 0, "actor holds AMPS");
            assertGt(usdg.balanceOf(actors[i]), 0, "actor holds USDG");
            assertGt(weth.balanceOf(actors[i]), 0, "actor holds WETH");
        }
        assertEq(admin, TIMELOCK, "admin is the timelock");
        assertEq(guardian, GUARDIAN, "guardian is the guardian");
        assertEq(keeper, KEEPER, "keeper is the keeper");
        assertGt(usdg.balanceOf(address(pot)), 0, "the bounty pot is funded");
    }

    // forge test --match-test test_setupGas -vv
    /// @notice What `setup()` costs, which is what `medusa.json`'s `blockGasLimit` has to clear: Medusa runs
    ///         `FuzzTester`'s constructor — this exact body — inside a block.
    /// @dev The number is measured by `setup()` itself (see {Base-setupGasUsed}) rather than by deploying a second
    ///      `FuzzTester` here: this contract's runtime is well past EIP-170 and a `CREATE` inside a Foundry test is
    ///      size-checked, so the second deployment would fail for a reason that has nothing to do with gas.
    function test_setupGas() public view {
        console.log("spokes:", spokeCount());
        console.log("pools:", pools.length);
        console.log("setup() gas:", setupGasUsed);
        assertGt(setupGasUsed, 0, "setup measured itself");
    }

    // forge test --match-test test_sequence -vvv
    /// @notice The Step 7 gate: one call of every primary handler, then every secondary dispatcher selector, in an
    ///         order that makes each of them do real work.
    ///
    /// @dev Every handler is driven through an external self-call and **every** refusal is recorded rather than
    ///      aborting the run, so one execution reports the whole picture; the assertion at the end is that no
    ///      *required* step refused. The `_opt` steps are allowed to refuse for reasons that are part of the design
    ///      — a cooldown, a market a previous selector just closed, a rollout schedule with nothing due, a
    ///      deliberately unknown feed, a rotation into a spoke with no bid ladder yet. This is the same reasoning
    ///      `test/invariant/Phase3Handler.sol` runs on with `fail_on_revert = false`.
    function test_sequence() public {
        setCurrentActor(0);

        // ── The market: both sides of an entry pool, then a rotation out of a spoke ──
        _need(abi.encodeCall(this.ampsRouter_buy_clamped, (uint256(0), uint256(7))), "buy");
        _need(abi.encodeCall(this.ampsRouter_sell_clamped, (uint256(0), uint256(3))), "sell");
        _need(abi.encodeCall(this.ampsRouter_rotate_clamped, (uint256(0), uint256(0), uint256(5))), "rotate");
        _opt(abi.encodeCall(this.ampsRouter_rotate_spokeToSpoke, (uint256(0), uint256(1), uint256(3))), "rotateS2S");

        // ── Bonds: mint, vest, claim both ways ──
        _need(abi.encodeCall(this.ampsBonds_bond_clamped, (uint256(0), uint256(9))), "bond");
        _warp(3 hours);
        _need(abi.encodeCall(this.ampsBonds_claim_clamped, (uint256(0))), "claim");
        _need(abi.encodeCall(this.ampsBonds_bond_clamped, (uint256(1), uint256(4))), "bond2");
        _warp(3 hours);
        _need(abi.encodeCall(this.ampsBonds_claimAll_clamped, ()), "claimAll");

        // ── Upkeep: the two stamps, then the three bountied paths ──
        _need(abi.encodeCall(this.ampsVault_touch_clamped, ()), "touch");
        _need(abi.encodeCall(this.ampsVault_checkpoint_clamped, ()), "checkpoint");
        _need(abi.encodeCall(this.ampsVault_deployBonded_clamped, (uint256(0))), "deployBonded");
        _warp(1 hours);
        _need(abi.encodeCall(this.ampsVault_compound_clamped, (uint256(0))), "compound");
        _warp(1 hours);
        _need(abi.encodeCall(this.ampsVault_rollout_clamped, (uint256(0))), "rollout");

        // ── The ungated floor ──
        _need(abi.encodeCall(this.ampsVault_redeemProRata_clamped, (uint256(1e18), address(uint160(1)))), "redeem");

        // Now that a spoke has bonded collateral under its tick, the canonical rotation should be live.
        _opt(abi.encodeCall(this.ampsRouter_rotate_spokeToSpoke, (uint256(1), uint256(0), uint256(3))), "rotateS2S2");

        // ── The boundary variants ──
        _opt(abi.encodeCall(this.ampsRouter_buy_dust, (uint256(0), uint256(1))), "buyDust");
        _opt(abi.encodeCall(this.ampsBonds_bond_dust, (uint256(2), uint256(1))), "bondDust");
        _opt(abi.encodeCall(this.ampsBonds_bond_full, (uint256(2))), "bondFull");
        _opt(abi.encodeCall(this.ampsVault_redeemProRata_dust, (uint256(1))), "redeemDust");

        // ── The registry first, so the retired-bid withdrawal below has something to withdraw ──
        _need(abi.encodeCall(this.poolRegistry_secondary, (uint8(2), uint256(0), uint256(1))), "setIndexWeights");
        _need(abi.encodeCall(this.poolRegistry_secondary, (uint8(0), uint256(0), uint256(1))), "retire");
        _need(
            abi.encodeCall(this.ampsVault_secondary, (uint8(4), uint256(0), uint256(0), uint256(0), uint256(0))),
            "withdrawRetiredBids"
        );
        _need(abi.encodeCall(this.poolRegistry_secondary, (uint8(1), uint256(0), uint256(300))), "reinstate");

        // ── Every remaining secondary dispatcher selector ──
        // The governed placement first, on the hub's bid side, and only after a warp: `compound`, `deployBonded`,
        // `rollout` and `withdrawRetiredBids` above have all just placed, and `place` is refused with
        // `PlacementCooldown` inside `PLACEMENT_COOLDOWN_SECONDS` of the last placement in the same pool.
        _warp(2 hours);
        _need(
            abi.encodeCall(this.ampsVault_secondary, (uint8(0), uint256(0), uint256(1), uint256(3), uint256(4))),
            "place"
        );
        for (uint8 sel = 1; sel < 4; ++sel) {
            _need(
                abi.encodeCall(this.ampsVault_secondary, (sel, uint256(2), uint256(1), uint256(3), uint256(4))),
                "vaultSecondary"
            );
        }
        for (uint8 sel; sel < 5; ++sel) {
            _need(
                abi.encodeCall(this.ampsBonds_secondary, (sel, uint256(1), uint256(2), uint256(3), uint256(4))),
                "bondsSecondary"
            );
        }
        for (uint8 sel; sel < 8; ++sel) {
            _need(abi.encodeCall(this.oracleGate_secondary, (sel, uint256(1))), "gateSecondary");
        }
        for (uint8 sel; sel < 4; ++sel) {
            _need(abi.encodeCall(this.env_secondary, (sel, uint256(1), uint256(1))), "envSecondary");
        }
        _need(abi.encodeCall(this.feedRegistry_secondary, (uint8(0), uint256(1))), "refresh");
        _need(abi.encodeCall(this.feedRegistry_secondary, (uint8(1), uint256(1))), "refreshMany");
        _opt(abi.encodeCall(this.feedRegistry_secondary, (uint8(2), uint256(1))), "refreshUnknown");
        for (uint8 sel; sel < 3; ++sel) {
            _need(abi.encodeCall(this.amps_secondary, (sel, uint256(1e15), address(uint160(2)))), "ampsSecondary");
        }
        for (uint8 sel; sel < 2; ++sel) {
            _need(abi.encodeCall(this.ampsHook_secondary, (sel, uint256(0), uint256(30))), "hookSecondary");
            _need(abi.encodeCall(this.bountyPot_secondary, (sel, uint256(5e6))), "potSecondary");
        }

        // ── Donations, which nothing in the protocol may come to rest on ──
        _need(abi.encodeCall(this.ampsVault_donateERC20, (uint256(0), uint256(1), uint256(1e6))), "donateERC20");
        _need(abi.encodeCall(this.ampsVault_donateETH, (uint256(0), uint256(1e15))), "donateETH");

        // ── The world is still the world ──
        assertTrue(vault.initialized(), "still initialized");
        assertGt(amps.totalSupply(), 0, "supply survived");
        assertGt(vault.previewNavPerShareX18(), 0, "NAV/share survived");
        console.log("required steps refused:", requiredRefusals);
        assertEq(requiredRefusals, 0, "every required handler did its work");
    }

    /// @notice How many `_need` steps refused. Asserted to be zero at the end of {test_sequence}.
    uint256 internal requiredRefusals;

    /// @dev A step that must do its work. A refusal is logged with its revert data and counted, but the run carries
    ///      on so that one execution reports every problem rather than only the first.
    function _need(bytes memory data, string memory label) internal {
        if (!_run(data, label)) ++requiredRefusals;
    }

    /// @dev A step that is allowed to refuse: the refusal is part of the design, not a defect.
    function _opt(bytes memory data, string memory label) internal {
        _run(data, label);
    }

    function _run(bytes memory data, string memory label) internal returns (bool ok) {
        bytes memory reason;
        (ok, reason) = address(this).call(data);
        if (!ok) {
            console.log("refused:", label);
            console.logBytes(reason);
        }
    }

    /// @dev The clock, through the handler the campaign itself uses, so the test and the fuzzer share one notion of
    ///      "time passed": warp, produce blocks, republish every feed.
    function _warp(uint256 dt) internal {
        env_secondary(0, dt, 0);
    }

    // ── Violation Repros (auto-generated by Step 11) ─────────────────
    // Each test_repro_* function below replays a shrunk fuzzer call
    // sequence that violated a property. Run all with:
    //   forge test --match-contract FoundryTester -vvv

    /// @notice Replays the 2026-09-10 campaign sequence that fired SP-05 ("a bond lowered NAV/share"): a feed walk
    ///         and then a dust bond. The drop was the bond's own checkpoint latching the moved feed, not the
    ///         issuance; the bond handler now checkpoints first, so the replay passes when the property holds.
    function test_repro_sp05_feedWalkThenDustBond() public {
        vm.roll(block.number + 6377);
        vm.warp(block.timestamp + 61_730);
        env_walkFeedToExtreme(
            869_430_121_888_412_902_588_289_888_003_271_723_330_628_663_527_733_088_251_742_348_677_410_313_998,
            810_832_964_950_679_210_041_376_471_510_876_657_106_589_908_917_861_894_419_192_260_269_506_294_476
        );
        ampsBonds_bond_dust(
            254_001_541_755_554_021_369_667_083_088_024_637_657_959_336_400_194_052_825_178_094_937_950_771_460,
            1_809_251_394_333_065_553_493_296_640_760_748_560_207_343_510_400_633_813_116_273_650_125_656_761_034
        );
    }

    /// @notice Replays the sequence that fired SP-20 ("a placement landed outside the divergence band"): a feed
    ///         walk, a buy 4,084 ticks up one spoke, then `deployBonded` on that spoke with no bonded collateral
    ///         idle. Nothing was placed and the gauntlet never ran (`VaultRolloutLib.deployBonded` returns before
    ///         `VaultPlacementLib.place` when there is nothing idle), so the tick the buy left is not a placement's;
    ///         the property now applies only to calls that did work, and measures the guard's own inputs.
    function test_repro_sp20_feedWalkBuyThenDeployBonded() public {
        vm.roll(block.number + 36);
        vm.warp(block.timestamp + 115_587);
        property_ladderGeometryIsContiguous(
            3_618_502_788_666_131_106_986_593_281_838_578_084_404_791_296_222_683_325_853_265_630_265_418_226_773
        );
        env_walkFeedToExtreme(
            115_792_089_237_316_195_423_570_985_008_687_907_853_169_984_665_640_564_039_457_584_007_913_129_639_936,
            69_665_297_146_691_042_010_520_382_514_712_199_082_912_117_164_588_595_552_952_436_856_545_733_504_172
        );
        ampsRouter_buy_clamped(
            19_283_740_927_608_951_501_957_750_522_519_226_923_323_283_660_312_593_593_854_796_748_099_092_592_296,
            54_562_727_793_687_042_279_604_233_754_741_232_733_821_481_583_701
        );
        ampsVault_deployBonded_clamped(6);
    }

    /// @notice Replays the two sequences that fired SP-14 ("a redemption paid more than pro rata"): a sell, then a
    ///         redemption, paying ~2 bp above the fee-netted reference-basis slice. This is the accepted
    ///         reference-vs-pool valuation gap (EXPLORATORY lead, recorded in the campaign report); the property now
    ///         carries 25 bp of slack so growth of the gap, not its existence, is what fires.
    function test_repro_sp14_sellThenRedeem_1() public {
        ampsRouter_sell_clamped(
            14_474_011_154_664_524_427_946_373_126_085_988_481_658_748_083_205_070_504_925_466_750_989_141_205_088,
            14_326_539_605_734_203_569_962_417_505_901_770_330_133_155_836_858_342_636_960_985_284_255_294_258_519
        );
        ampsVault_redeemProRata_clamped(
            330_981_717_096_003_989_485_752_077_995_900_013_871_551_726_216_765_279_864_954_889_266_670_529_651,
            0xd88F38F930b7952f2DB2432Cb002E7abbF3dD869
        );
    }

    function test_repro_sp14_sellThenRedeem_2() public {
        ampsRouter_sell_clamped(
            452_312_848_583_266_388_373_324_160_190_187_140_051_835_877_600_158_453_278_812_437_530_913_162_656,
            14_326_539_605_734_203_569_962_417_505_901_770_330_133_155_836_858_342_636_961_975_247_972_427_812_306
        );
        ampsVault_redeemProRata_clamped(
            4_490_771_965_837_968_876_205_204_908_803_481_404_907_187_478_572_732_044_784_190_435_173_794_617,
            0x00000000000000000000001043561A8829300000
        );
    }

    /// @notice Replays the 2026-09-11 campaign sequence that fired GL-47 ("highWaterTick above
    ///         lastTruncatedTick"): a spoke rotated up and straight back down in one block leaves the running
    ///         maximum above the tick now in force, which is what a high-water mark is. The clause was removed.
    function test_repro_gl47_rotateRoundTripThenHighWater() public {
        ampsRouter_rotateRoundTrip(
            14,
            47_355_019_930_631_105_188_022_191_469_976_317_593_511_876_840_243_825_709_355_880_278_081_723_584_873,
            57_895_161_208_605_476_168_264_858_580_110_248_631_093_136_053_278_453_430_046_326_697_457_885_347_840
        );
        property_highWaterRisesOnly(
            55_413_380_951_247_917_195_055_317_477_328_857_467_034_038_927_085_487_694_683_581_153_772_180_977_808
        );
    }

    /// @notice Replays the 2026-09-11 campaign sequence that fired SP-43 ("a sell/buy round trip left the actor
    ///         with more counter asset"): after a full redemption emptied the pool's asks, the buy-back leg was
    ///         refused and the handler compared a bare sell. The handler now skips a refused second leg.
    function test_repro_sp43_feedWalkRedeemThenSellBuy() public {
        env_walkFeedToExtreme(
            5_342_660,
            15_187_593_602_740_473_516_240_065_818_751_733_558_350_624_602_451_509_833_595_950_784_867_273_636_123
        );
        ampsVault_buyRedeemCycles(
            5_569_937_129_841_895_489_370_602_260_510_239_975_092_649_835_715_347_199_880_389_869_656_886_017_110,
            1_809_251_394_333_065_553_493_296_640_742_723_376_005_171_561_794_123_668_203_038_142_233_695_404_780,
            2_964_004_098_606_611_207_931_525_735_701_675_805_209_758_226_904_284_390_928_054_719_202_193_143_395
        );
        property_poolManagerCoversClaims(141_569_851_180_300_625_603_002_821_782_770_840_281_320_213_828);
        ampsVault_redeemProRata_full();
        ampsRouter_quotedBuy(
            7_237_005_577_332_262_213_973_186_562_955_048_399_593_162_491_400_018_407_406_618_407_423_388_571_427,
            255_063_004_999_995_881
        );
        vm.roll(block.number + 7);
        vm.warp(block.timestamp + 25_200);
        env_walkFeedToExtreme(
            49_998_279,
            12_708_166_519_487_563_353_912_635_768_705_917_907_882_528_293_240_074_630_098_839_271_426_960_034_762
        );
        ampsRouter_sellBuyRoundTrip(
            115_792_089_237_316_195_423_570_985_008_687_907_853_269_984_665_640_564_039_457_584_007_913_079_639_766,
            57_896_044_618_658_097_711_785_492_504_343_953_926_634_992_332_820_282_019_728_792_003_956_564_819_343
        );
    }
}
