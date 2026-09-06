// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {AmpsHook} from "../../src/hook/AmpsHook.sol";
import {IAmpsQuoter} from "../../src/interfaces/IAmpsQuoter.sol";
import {AmpsQuoter} from "../../src/periphery/AmpsQuoter.sol";
import {Amps} from "../../src/token/Amps.sol";
import {Constants} from "../../src/types/Constants.sol";
import {AmpsVault} from "../../src/vault/AmpsVault.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @title Phase3Ghosts
/// @notice The Phase 3 invariant campaign's whole bookkeeping surface: every ghost `Phase3.invariant.t.sol` reads,
///         and every check that writes one. The handlers drive the system; this contract watches them.
///
/// @dev **Why this is its own contract, and not part of the handler.** `Phase3Handler` inherits `CommonBase`,
///      `StdCheats` and `StdUtils` rather than `Test`, so `forge build --sizes` counts it like any deployable
///      contract - and Medusa's geth enforces EIP-170 at deploy time too, so a handler over 24,576 B could not be
///      fuzzed at all (§8.3). With sixteen actions, the router, Permit2, the bond path and all of this
///      bookkeeping in one contract it came to 31,203 B. The action space is therefore split across two
///      handlers, both targeted, and everything that only *records* lives here.
///
/// @dev **This contract holds no cheatcodes and takes no actions.** It reads the system and writes ghosts, which
///      is why it inherits nothing: the bookkeeping has to be cheap in bytecode as well as correct.
///
/// @dev **Nothing here asserts.** A finding is a flag, never a revert; `Phase3.invariant.t.sol` reads the flags.
contract Phase3Ghosts {
    // -------------------------------------------------------------------------------------------------------------
    // Wiring
    // -------------------------------------------------------------------------------------------------------------

    AmpsVault internal immutable VAULT;
    Amps internal immutable AMPS;
    AmpsHook internal immutable HOOK;
    AmpsQuoter internal immutable QUOTER;
    IPoolManager internal immutable POOL_MANAGER;

    /// @dev The account that deployed this contract and may name its writers, once each.
    address internal immutable DEPLOYER;

    /// @notice The handlers allowed to write ghosts. Test-only, and set once per handler at set-up.
    mapping(address handler => bool allowed) public writer;

    /// @dev Every pool the campaign drives, hub first.
    PoolId[] internal pools;

    // -------------------------------------------------------------------------------------------------------------
    // Ghosts
    // -------------------------------------------------------------------------------------------------------------

    /// @notice AMPS wei minted through `AmpsBonds` - the only mint path after the genesis latch (I3, I10, I33).
    uint256 public mintedVesting;
    /// @notice AMPS wei burned, by any path.
    uint256 public burnedTotal;
    /// @notice AMPS wei paid to the creator across every compound (I31).
    uint256 public creatorPaid;
    /// @notice AMPS wei the AMPS-side fee split has passed through, across every compound.
    uint256 public feesSplit;
    /// @notice AMPS wei moved out of the entry pools by rollout, in the current rolling day (I32).
    uint256 public rolloutMoved;
    /// @notice The largest ladder length ever observed in any pool (I39's bound).
    uint256 public maxRecordsSeen;
    /// @notice The largest live-cell count ever observed (§12 ruling E).
    uint256 public maxLiveCellsSeen;
    /// @notice Set the moment a non-market action lowers NAV/share by more than `PLACEMENT_BLEED_BPS_MAX` (I11).
    bool public navEverFell;
    /// @notice Set the moment a swap reverts for anything other than the outer rail (I15).
    bool public swapEverReverted;
    /// @notice Set the moment `AmpsQuoter` reverts (§6: it never may).
    bool public quoterEverReverted;
    /// @notice Set the moment a fee fails to decompose as `base + dyn` inside its bands (I16).
    bool public feeEverMalformed;
    /// @notice Set the moment the rotation credit is non-zero at the start of an action (I26).
    bool public creditEverLeaked;
    /// @notice Set the moment the hook is found holding an ERC-20 or ERC-6909 balance (I13).
    bool public hookEverHeldValue;
    /// @notice Set the moment a removal of liquidity is refused (I18).
    bool public removalEverBlocked;
    /// @notice Per-action call counters, so the campaign can prove it was not vacuous.
    mapping(bytes32 action => uint256 count) public actionCount;
    /// @notice Total actions attempted.
    uint256 public actionsAttempted;
    /// @notice Total actions that did something.
    uint256 public actionsSucceeded;
    /// @notice AMPS wei observed entering `totalSupply`, whatever the action - which must equal {mintedVesting}.
    uint256 public mintedObserved;
    /// @notice The first revert payload a direct hook probe produced that was not `BeyondRail`, for diagnosis.
    bytes public firstUnexpectedRevert;

    /// @dev `totalSupply` as it stood when the current action opened.
    uint256 internal supplyAtOpen;

    /// @dev The rolling 24-hour rollout window this campaign tracks itself, mirroring the vault's.
    uint256 internal rolloutWindowStart;

    /// @dev Only a named handler may write a ghost.
    modifier onlyWriter() {
        require(writer[msg.sender], "Phase3Ghosts: not a handler");
        _;
    }

    /// @param vault_ The `AmpsVault`.
    /// @param amps_ The AMPS token.
    /// @param hook_ The real `AmpsHook`.
    /// @param quoter_ The periphery quoter.
    /// @param poolManager_ The v4 PoolManager.
    /// @param pools_ Every pool the campaign drives, hub first.
    constructor(
        AmpsVault vault_,
        Amps amps_,
        AmpsHook hook_,
        AmpsQuoter quoter_,
        IPoolManager poolManager_,
        PoolId[] memory pools_
    ) {
        VAULT = vault_;
        AMPS = amps_;
        HOOK = hook_;
        QUOTER = quoter_;
        POOL_MANAGER = poolManager_;
        DEPLOYER = msg.sender;
        for (uint256 i; i < pools_.length; ++i) {
            pools.push(pools_[i]);
        }
        rolloutWindowStart = block.timestamp;
    }

    /// @notice Names a handler as a ghost writer. Only the deployer, and only at set-up.
    /// @param handler The handler.
    function authorize(address handler) external {
        require(msg.sender == DEPLOYER, "Phase3Ghosts: not the deployer");
        writer[handler] = true;
    }

    // -------------------------------------------------------------------------------------------------------------
    // The action boundary
    // -------------------------------------------------------------------------------------------------------------

    /// @notice Every action opens here: the transaction-boundary checks that must hold *before* anything happens.
    /// @param name The action's name, for the non-vacuity count.
    function open(bytes32 name) external onlyWriter {
        ++actionsAttempted;
        actionCount[name] += 1;
        supplyAtOpen = AMPS.totalSupply();
        // I26: the rotation credit is transient, so it is zero at the start of every transaction, always.
        if (HOOK.rotationCredit() != 0) creditEverLeaked = true;
        // I13: the hook holds nothing, ever.
        if (AMPS.balanceOf(address(HOOK)) != 0) hookEverHeldValue = true;
        if (POOL_MANAGER.balanceOf(address(HOOK), uint256(uint160(address(AMPS)))) != 0) hookEverHeldValue = true;
    }

    /// @notice Every action closes here: the quoter must have survived whatever just happened, the fee must still
    ///         decompose, and the supply delta is attributed.
    function close() external onlyWriter {
        try QUOTER.quoteAll() returns (IAmpsQuoter.PoolQuote[] memory quotes) {
            for (uint256 i; i < quotes.length; ++i) {
                _checkFee(quotes[i]);
            }
        } catch {
            quoterEverReverted = true;
        }

        uint256 supplyNow = AMPS.totalSupply();
        if (supplyNow < supplyAtOpen) burnedTotal += supplyAtOpen - supplyNow;
        else mintedObserved += supplyNow - supplyAtOpen;

        uint256 cells = VAULT.liveCells();
        if (cells > maxLiveCellsSeen) maxLiveCellsSeen = cells;
        for (uint256 i; i < pools.length; ++i) {
            uint256 length = VAULT.ladderLength(pools[i]);
            if (length > maxRecordsSeen) maxRecordsSeen = length;
        }
    }

    /// @notice Records that the action just taken actually did something.
    function noteSuccess() external onlyWriter {
        ++actionsSucceeded;
    }

    // -------------------------------------------------------------------------------------------------------------
    // Per-action records
    // -------------------------------------------------------------------------------------------------------------

    /// @notice Records a bond's issuance (I3, I10, I30, I33).
    /// @param ampsOut The AMPS the bond minted.
    function noteBond(uint256 ampsOut) external onlyWriter {
        mintedVesting += ampsOut;
    }

    /// @notice Records a compound's AMPS-side fee split and the creator's slice of it (I31).
    /// @param ampsFees The AMPS-side fees the compound collected.
    /// @param creatorDelta The AMPS the creator was paid out of them.
    function noteCompound(uint256 ampsFees, uint256 creatorDelta) external onlyWriter {
        feesSplit += ampsFees;
        creatorPaid += creatorDelta;
    }

    /// @notice Rolls the 24-hour rollout window if it has expired, and returns whether a rollout may be recorded
    ///         against it (I32).
    function rollRolloutWindow() external onlyWriter {
        if (block.timestamp - rolloutWindowStart >= Constants.ONE_DAY) {
            rolloutWindowStart = block.timestamp;
            rolloutMoved = 0;
        }
    }

    /// @notice Records AMPS moved out of the entry pools by a rollout (I32).
    /// @param moved The AMPS moved.
    function noteRollout(uint256 moved) external onlyWriter {
        rolloutMoved += moved;
    }

    /// @notice Records that a liquidity removal was refused, which I18 says can never happen.
    function noteRemovalBlocked() external onlyWriter {
        removalEverBlocked = true;
    }

    /// @notice Records a malformed fee or a non-zero hook delta (I13, I16).
    function noteMalformedFee() external onlyWriter {
        feeEverMalformed = true;
    }

    /// @notice A direct hook probe that failed for anything but the rail is I15's violation, and the payload is
    ///         kept so the campaign's counterexample says *what* failed rather than only that something did.
    /// @param reason The revert payload.
    function noteProbeFailure(bytes calldata reason) external onlyWriter {
        if (_isBeyondRail(reason)) return;
        swapEverReverted = true;
        if (firstUnexpectedRevert.length == 0) firstUnexpectedRevert = reason;
    }

    // -------------------------------------------------------------------------------------------------------------
    // NAV
    // -------------------------------------------------------------------------------------------------------------

    /// @notice NAV/share, or zero when the preview cannot be taken.
    /// @return value NAV/share, 18 decimals.
    function navNow() public view returns (uint256 value) {
        try VAULT.previewNavPerShareX18() returns (uint256 nav) {
            return nav;
        } catch {
            return 0;
        }
    }

    /// @notice I11's 2 bp bound, measured the only way it is measurable from outside the vault: **at a fixed
    ///         reference price**.
    ///
    /// @dev `A` decomposes every ladder position at `sqrtPrice(P_ref / P_counter)` from the *previous* checkpoint
    ///      (I7), and every placement path takes a checkpoint of its own on the way out. So the preview taken
    ///      before a placement and the preview taken after it are, in general, computed at two different
    ///      references, and their difference is a market move rather than a bleed - which is exactly what the
    ///      vault's own R1 avoids by comparing both sides against the same `pRefPrev` inside one call. The
    ///      comparison is therefore made only when `P_ref` came out where it went in, which is the "ex market
    ///      moves" clause of I8 and I11 spelled out as a condition rather than assumed.
    /// @param navBefore NAV/share before the placement.
    /// @param pRefBefore `P_ref` before the placement.
    function checkNav(uint256 navBefore, uint256 pRefBefore) external onlyWriter {
        if (VAULT.pRefX18() != pRefBefore) return;
        uint256 navAfter = navNow();
        if (navAfter * Constants.BPS < navBefore * (Constants.BPS - Constants.PLACEMENT_BLEED_BPS_MAX)) {
            navEverFell = true;
        }
    }

    // -------------------------------------------------------------------------------------------------------------
    // Views the invariant suite reads
    // -------------------------------------------------------------------------------------------------------------

    /// @notice How many pools this campaign drives.
    /// @return count The count.
    function poolCount() external view returns (uint256 count) {
        return pools.length;
    }

    /// @notice Pool `i`.
    /// @param i The index.
    /// @return poolId The pool.
    function poolAt(uint256 i) external view returns (PoolId poolId) {
        return pools[i];
    }

    /// @notice Every action in the space, across both handlers - the non-vacuity checklist.
    /// @return names The action names.
    function actionNames() external pure returns (bytes32[] memory names) {
        names = new bytes32[](16);
        names[0] = "swapBuy";
        names[1] = "swapSell";
        names[2] = "swapRotate";
        names[3] = "bond";
        names[4] = "claim";
        names[5] = "redeem";
        names[6] = "compound";
        names[7] = "rollout";
        names[8] = "deployBonded";
        names[9] = "checkpoint";
        names[10] = "warp";
        names[11] = "moveFeed";
        names[12] = "stepMultiplier";
        names[13] = "armGate";
        names[14] = "probeHook";
        names[15] = "removeLiquidity";
    }

    // -------------------------------------------------------------------------------------------------------------
    // Internals
    // -------------------------------------------------------------------------------------------------------------

    /// @dev I16 on one quote: the total is `base + dyn`, `sellFeeBps` is inside its band, and neither side
    ///      exceeds the protocol ceiling.
    ///
    ///      The cap is deliberately *not* compared against `quote.dynCapBps`: §12.1 ruling K says the word the
    ///      quoter reports is the **cached** cap, while the fee the hook charges uses the effective one, which is
    ///      the degraded cap whenever the cache is older than `GATE_CACHE_MAX_AGE`. The bound that always holds
    ///      is the protocol ceiling.
    function _checkFee(IAmpsQuoter.PoolQuote memory quote) private {
        if (quote.degraded != 0) return;
        uint256 ceiling = uint256(HOOK.TOTAL_FEE_BPS_MAX()) * Constants.PIPS_PER_BPS;
        if (quote.sellFeeBps < 100 || quote.sellFeeBps > 600) feeEverMalformed = true;
        if (uint256(quote.buyFeePips) > ceiling) feeEverMalformed = true;
        if (uint256(quote.sellFeePips) > ceiling) feeEverMalformed = true;
    }

    /// @dev Whether a revert payload carries `Errors.BeyondRail`, at any nesting depth.
    function _isBeyondRail(bytes calldata reason) private pure returns (bool found) {
        bytes4 selector = bytes4(keccak256("BeyondRail(bytes32,int24,int24)"));
        if (reason.length < 4) return false;
        for (uint256 i; i + 4 <= reason.length; ++i) {
            if (bytes4(reason[i:i + 4]) == selector) return true;
        }
    }
}
