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
        _maybeReenter(REENTRANCY_BEFORE);
        bool ok = super.transfer(to, value);
        _maybeReenter(REENTRANCY_AFTER);
        return ok;
    }

    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        _maybeReenter(REENTRANCY_BEFORE);
        bool ok = super.transferFrom(from, to, value);
        _maybeReenter(REENTRANCY_AFTER);
        return ok;
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
