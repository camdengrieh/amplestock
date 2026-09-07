// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Constants} from "../../src/types/Constants.sol";
import {Phase3Fixture} from "../integration/Phase3Fixture.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {console} from "forge-std/console.sol";

/// @title ArrakisFlashDepositTest
/// @notice The plan's named attack **Arrakis G-UNI flash-loan deposit manipulation, against `bond()`**. The
///         original exploit moved a Uniswap pool with a flash loan, deposited into a vault that priced the
///         deposit off `slot0`, and unwound - minting shares against a price that existed for one transaction.
///
///         `AmpsBonds` cannot be moved that way. Its quote reads the vault's **NAV checkpoint** and the
///         collateral's **Chainlink answer**; the only pool-derived input is `m`, the spoke's *truncated
///         30-minute TWAP*, which one transaction cannot move by more than `maxTickMovePerBlock`; and whatever
///         the policy answers is capped at `q_floor`, a pure NAV quantity re-checked by the shell itself.
contract ArrakisFlashDepositTest is Phase3Fixture {
    address internal constant ATTACKER = address(0xA77ACC);

    function setUp() public {
        deployPhase3World();
        placeGenesisLadders();
        fundPot(100_000e6);
        deepenSpokes(400e18);
        warpBy(Constants.PLACEMENT_COOLDOWN_SECONDS + 1);
        settleTwap();
    }

    /// @notice Move the pool and bond in the **same transaction**: the AMPS issued is identical to the honest
    ///         quote, to the wei.
    function test_aSameTransactionPoolMoveBuysNoExtraAmps() public {
        uint256 snapshot = vm.snapshotState();
        uint256 honest = this.honestBondEntry();
        vm.revertToState(snapshot);
        (uint256 gamed, int24 moved) = this.flashMoveThenBondEntry();

        console.log("honest bond AMPS", honest, "after a same-tx pool move", gamed);
        assertGt(moved, 0, "the pool really was moved inside the transaction");
        assertEq(gamed, honest, "and the bond priced identically: no pool price enters the quote");
    }

    /// @notice And NAV/share is never lowered by it, which is the invariant the original exploit broke.
    function test_theFlashManipulationNeverDilutes() public {
        uint256 navBefore = vault.previewNavPerShareX18();
        this.flashMoveThenBondEntry();
        assertGe(vault.previewNavPerShareX18(), navBefore, "I27: a bond never lowers NAV/share");
    }

    /// @notice The one pool-derived input the quote does use - the spoke's truncated TWAP - is Lipschitz in block
    ///         count (I25), so a single transaction cannot move it more than one block's allowance however much
    ///         capital it brings.
    function test_theTruncatedTwapCannotBeMovedInOneTransaction() public {
        PoolId spoke = spokePools[0];
        int24 before = hook.lastTruncatedTick(spoke);
        int24 cap = hook.maxTickMovePerBlock(spoke);

        this.flashMoveThenBondEntry();

        int24 moved = hook.lastTruncatedTick(spoke) - before;
        if (moved < 0) moved = -moved;
        assertLe(moved, cap, "one block, one allowance (I25)");
    }

    /// @notice One transaction: buy the spoke up hard, bond, and sell back out.
    /// @return ampsOut The AMPS the bond issued.
    /// @return moved Ticks the pool moved before the bond.
    function flashMoveThenBondEntry() external returns (uint256 ampsOut, int24 moved) {
        require(msg.sender == address(this), "self-call only");
        PoolId spoke = spokePools[0];
        int24 before = tickOf(spoke);
        // As large a single move as the rail will accept - the flash loan's whole point.
        buyAmps(spoke, ATTACKER, 0.004e18);
        moved = tickOf(spoke) - before;

        (ampsOut,) = _bondCapacity(ATTACKER);

        approveStack(address(amps), ATTACKER);
        if (amps.balanceOf(ATTACKER) != 0) sellAmps(spoke, ATTACKER, amps.balanceOf(ATTACKER) / 2);
    }

    /// @notice The control: the same bond, with the pool untouched.
    /// @return ampsOut The AMPS the bond issued.
    function honestBondEntry() external returns (uint256 ampsOut) {
        require(msg.sender == address(this), "self-call only");
        (ampsOut,) = _bondCapacity(ATTACKER);
    }

    /// @dev A capacity-sized bond on spoke 0, with `minAmpsOut` set the way a real bonder sets it.
    function _bondCapacity(address who) private returns (uint256 issued, uint256 collateral) {
        uint16 marketId = marketIds[0];
        uint256 capacity = bonds.capacityRemaining(marketId);
        (uint256 probeOut,,,,,) = bonds.quote(marketId, 1e18);
        collateral = capacity * 1e18 / probeOut;
        stocks[0].mint(who, collateral);
        vm.startPrank(who);
        stocks[0].approve(address(vault), type(uint256).max);
        (issued,) = bonds.bond(marketId, collateral, capacity * 9 / 10, who);
        vm.stopPrank();
    }
}
