// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

/// @title MockStockToken
/// @notice Test stand-in for a Robinhood Stock Token: an 18-decimal ERC-20 with an ERC-8056-style display
///         multiplier, a beacon-level denylist, a pause switch and (test-only) reentrancy modes.
/// @dev    Fidelity notes, all of which the design depends on:
///         - `uiMultiplier()` is a *display* number. Raw balances never change when it changes: a split or a
///           dividend reinvestment is value-neutral on-chain, so nothing here touches `_balances`.
///         - `newUIMultiplier()`/`effectiveAt()` describe a scheduled change; `oraclePaused()` is the freeze gate.
///           A silent `effectiveAt` flip is representable by setting the schedule without ever announcing it.
///         - `blockAccounts(address[])` keeps the observed beacon selector `0x6abf7081`; transfers touching a
///           blocked account revert, which is what the denylist drill and `emergencyMigrate` are tested against.
///         - The reentrancy modes let a test make `transfer`/`transferFrom` call back into an attacker contract
///           before or after balances move, which is the shape of every "reentrant Stock Token" test case.
contract MockStockToken is ERC20, Ownable, Pausable {
    /// @dev Reentrancy phases for {setReentrancy}.
    uint8 internal constant REENTRANCY_NONE = 0;
    uint8 internal constant REENTRANCY_BEFORE = 1;
    uint8 internal constant REENTRANCY_AFTER = 2;

    /// @notice Current display multiplier, 1e18 == 1.0.
    uint256 public uiMultiplier = 1e18;

    /// @notice Scheduled next display multiplier (0 when nothing is scheduled).
    uint256 public newUIMultiplier;

    /// @notice Timestamp at which {newUIMultiplier} becomes {uiMultiplier} (0 when nothing is scheduled).
    uint256 public effectiveAt;

    /// @notice Issuer-side freeze flag; management actions must stand still while it is true.
    bool public oraclePaused;

    /// @notice Denylist membership, mirroring the beacon-level `isBlocked(address)` view.
    mapping(address account => bool blocked) public isBlocked;

    /// @notice TEST ONLY. While true, {balanceOf} reverts for everybody.
    /// @dev The third shape a hostile constituent takes, alongside the pause and the denylist: a token whose view
    ///      is unavailable rather than unfavourable. It is what an issuer-side beacon looks like from the outside
    ///      once it has been switched off, and it is the case a `balanceOf` on a redemption path must survive —
    ///      `sweepClean` and the pro-rata payout probe balances precisely because of it.
    bool public balanceOfReverts;

    /// @notice TEST ONLY. Gas the token burns inside every {transfer}/{transferFrom} before doing anything else.
    /// @dev The griefing shape every bounded call on the redemption path exists for. An unbounded `transfer` into
    ///      a token that spends whatever it is handed leaves the caller's "this failed, skip it" branch a
    ///      sixty-fourth of the frame (EIP-150), so the *skip* runs out of gas instead of the token — which stops
    ///      the one path §7 says nothing may stop, without ever reverting. Zero disarms it.
    uint256 public transferGasBurn;

    /// @notice TEST ONLY. A call the token makes from inside {transfer}/{transferFrom}, ignoring failure.
    /// @dev The second half of the same shape: a Stock Token is a beacon proxy, so its `transfer` may call
    ///      anything — including the PoolManager, from inside the vault's own `unlock`, where opening a delta of
    ///      its own makes the vault's `unlock` revert with `CurrencyNotSettled` however clean the vault's books
    ///      are. Unlike {reentrancyTarget} the result is **discarded**, because the interesting case is the one
    ///      where the side effect lands and the token's own transfer still succeeds.
    address public transferHookTarget;

    /// @notice Calldata for {transferHookTarget}.
    bytes public transferHookData;

    /// @notice Reentrancy phase: 0 none, 1 before balances move, 2 after balances move.
    uint8 public reentrancyMode;

    /// @notice Contract called back while a reentrancy mode is armed.
    address public reentrancyTarget;

    /// @notice Calldata used for the callback.
    bytes public reentrancyData;

    /// @dev True while a callback is executing, so an attacker re-entering `transfer` does not recurse forever.
    bool private _inCallback;

    event UIMultiplierUpdated(uint256 previousMultiplier, uint256 newMultiplier);
    event UIMultiplierScheduled(uint256 newMultiplier, uint256 effectiveAt);
    event OraclePausedSet(bool paused);
    event AccountsBlocked(address[] accounts);
    event AccountsUnblocked(address[] accounts);

    error AccountBlocked(address account);

    /// @notice Thrown by {balanceOf} while {balanceOfReverts} is armed.
    error BalanceUnavailable();

    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) Ownable(msg.sender) {}

    /* --------------------------------------------------------------------- */
    /*                              display multiplier                        */
    /* --------------------------------------------------------------------- */

    /// @notice Applies a multiplier immediately, as a dividend reinvestment does (an unannounced +0.1-1% step).
    function setUIMultiplier(uint256 multiplier) external onlyOwner {
        emit UIMultiplierUpdated(uiMultiplier, multiplier);
        uiMultiplier = multiplier;
    }

    /// @notice Schedules a multiplier change, as a stock split does. Set `at == 0` to clear the schedule.
    function scheduleUIMultiplier(uint256 multiplier, uint256 at) external onlyOwner {
        newUIMultiplier = multiplier;
        effectiveAt = at;
        emit UIMultiplierScheduled(multiplier, at);
    }

    /// @notice Promotes the scheduled multiplier, leaving raw balances untouched.
    function applyScheduledUIMultiplier() external onlyOwner {
        emit UIMultiplierUpdated(uiMultiplier, newUIMultiplier);
        uiMultiplier = newUIMultiplier;
        newUIMultiplier = 0;
        effectiveAt = 0;
    }

    /// @notice Sets the issuer freeze flag read by the vault's gate.
    function setOraclePaused(bool paused_) external onlyOwner {
        oraclePaused = paused_;
        emit OraclePausedSet(paused_);
    }

    /* --------------------------------------------------------------------- */
    /*                                  denylist                              */
    /* --------------------------------------------------------------------- */

    /// @notice Adds accounts to the denylist. Selector must stay `0x6abf7081`.
    function blockAccounts(address[] calldata accounts) external onlyOwner {
        for (uint256 i = 0; i < accounts.length; ++i) {
            isBlocked[accounts[i]] = true;
        }
        emit AccountsBlocked(accounts);
    }

    /// @notice Removes accounts from the denylist.
    function unblockAccounts(address[] calldata accounts) external onlyOwner {
        for (uint256 i = 0; i < accounts.length; ++i) {
            isBlocked[accounts[i]] = false;
        }
        emit AccountsUnblocked(accounts);
    }

    /* --------------------------------------------------------------------- */
    /*                                pause / mint                            */
    /* --------------------------------------------------------------------- */

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice TEST ONLY. Arms or disarms the reverting {balanceOf}.
    /// @param value Whether `balanceOf` should revert.
    function setBalanceOfReverts(bool value) external {
        balanceOfReverts = value;
    }

    /// @notice TEST ONLY. Makes every transfer burn `gas` before moving anything. Zero disarms.
    /// @param gas The gas to burn per transfer.
    function setTransferGasBurn(uint256 gas) external {
        transferGasBurn = gas;
    }

    /// @notice TEST ONLY. Arms a best-effort call the token makes from inside every transfer.
    /// @param target The callee; `address(0)` disarms.
    /// @param data The calldata.
    function setTransferHook(address target, bytes calldata data) external {
        transferHookTarget = target;
        transferHookData = data;
    }

    /// @inheritdoc ERC20
    /// @dev Reverts wholesale while {balanceOfReverts} is armed; otherwise the plain ERC-20 answer.
    function balanceOf(address account) public view override returns (uint256) {
        if (balanceOfReverts) revert BalanceUnavailable();
        return super.balanceOf(account);
    }

    /// @notice Open mint: tests fund accounts freely.
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /// @notice Open burn, mirroring the issuer's burn power.
    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }

    /* --------------------------------------------------------------------- */
    /*                              reentrancy modes                          */
    /* --------------------------------------------------------------------- */

    /// @notice Arms a callback into `target` with `data` from `transfer`/`transferFrom`.
    /// @param mode 0 disarms, 1 calls back before balances move, 2 calls back after balances move.
    function setReentrancy(uint8 mode, address target, bytes calldata data) external {
        reentrancyMode = mode;
        reentrancyTarget = target;
        reentrancyData = data;
    }

    function transfer(address to, uint256 value) public override returns (bool) {
        _burnGas();
        _maybeCallOut();
        _maybeReenter(REENTRANCY_BEFORE);
        bool ok = super.transfer(to, value);
        _maybeReenter(REENTRANCY_AFTER);
        return ok;
    }

    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        _burnGas();
        _maybeCallOut();
        _maybeReenter(REENTRANCY_BEFORE);
        bool ok = super.transferFrom(from, to, value);
        _maybeReenter(REENTRANCY_AFTER);
        return ok;
    }

    /// @dev Spends {transferGasBurn}, or everything it has when that is more than it was given: a caller that
    ///      capped the call sees the cap consumed, a caller that did not sees its whole frame consumed.
    function _burnGas() private view {
        uint256 budget = transferGasBurn;
        if (budget == 0) return;
        uint256 floor_ = gasleft() > budget ? gasleft() - budget : 0;
        while (gasleft() > floor_ + 200) {}
    }

    /// @dev The best-effort call out. Failure is deliberately ignored so the token's own transfer still succeeds.
    function _maybeCallOut() private {
        address target = transferHookTarget;
        if (target == address(0) || _inCallback) return;
        _inCallback = true;
        (bool ok,) = target.call(transferHookData);
        ok;
        _inCallback = false;
    }

    /// @dev Bubbles the callee's revert so a reentrancy guard's error reaches the test unchanged.
    function _maybeReenter(uint8 phase) private {
        if (reentrancyMode != phase || reentrancyTarget == address(0) || _inCallback) return;
        _inCallback = true;
        (bool ok, bytes memory ret) = reentrancyTarget.call(reentrancyData);
        _inCallback = false;
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 0x20), mload(ret))
            }
        }
    }

    /// @dev Pause and denylist gate every balance movement, mint and burn included.
    function _update(address from, address to, uint256 value) internal override whenNotPaused {
        if (isBlocked[from]) revert AccountBlocked(from);
        if (isBlocked[to]) revert AccountBlocked(to);
        super._update(from, to, value);
    }
}
