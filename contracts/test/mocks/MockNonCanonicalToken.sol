// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title MockNonCanonicalToken
/// @notice A token-shaped contract that answers every `bool` with the word `2`.
///
/// @dev **Why this cannot be a flag on `MockStockToken`.** Solidity cannot *return* a non-canonical bool: the
///      compiler emits a clean 0 or 1 for every `bool` return, and `isBlocked` there is a public mapping getter
///      besides. The only way to model a token that answers `abi.encode(uint256(2))` — which real ERC-20s on
///      mainnet do, and which the ABI spec leaves undefined — is to write the returndata by hand, so this mock
///      dispatches in a `fallback` and returns raw words.
///
/// @dev **What it is for.** `abi.decode(returndata, (bool))` reverts with a `Panic` on any word that is not 0 or 1,
///      and that `Panic` happens in the *caller's* frame, where no `try`/`catch` can reach it. A Stock Token
///      shaped like this therefore used to brick `AmpsVault.emergencyMigrate` outright, through both halves of
///      `VaultNavLib.migrationPredicate`: the `isBlocked` read and the self-transfer probe. Both now hand-decode
///      the word and treat any non-zero answer as `true`, which is what this mock exists to prove.
///
/// @dev Balances are real, so the predicate's "move 1 wei if you hold at least 1 wei" probe is exercised for what
///      it is rather than short-circuited by an empty balance.
contract MockNonCanonicalToken {
    /// @notice The word every boolean-returning function answers with. 2 by default: true, but not canonically so.
    uint256 public boolAnswer = 2;

    /// @notice Raw balances, so `balanceOf` is a real number and the probe transfers a real wei.
    mapping(address account => uint256 amount) public rawBalance;

    /// @notice 18, like every Stock Token.
    uint8 public constant decimals = 18;

    /// @notice Sets the word returned for `isBlocked` and `transfer`. Zero means "false" and is canonical.
    /// @param value The word.
    function setBoolAnswer(uint256 value) external {
        boolAnswer = value;
    }

    /// @notice Credits `to` with `amount`, so the vault can hold a balance of this thing.
    /// @param to The account.
    /// @param amount The amount.
    function mint(address to, uint256 amount) external {
        rawBalance[to] += amount;
    }

    /// @dev Dispatches by selector and writes the answer word by hand.
    ///
    ///      - `balanceOf(address)`  -> the real balance, canonically encoded.
    ///      - `isBlocked(address)`  -> {boolAnswer}.
    ///      - `transfer(address,uint256)` -> moves the tokens, then answers {boolAnswer}.
    ///      - anything else -> zero, which keeps `decimals()`-style probes harmless.
    fallback(bytes calldata data) external returns (bytes memory) {
        bytes4 selector = bytes4(data);

        if (selector == bytes4(keccak256("balanceOf(address)"))) {
            address account = abi.decode(data[4:], (address));
            return abi.encode(rawBalance[account]);
        }

        if (selector == bytes4(keccak256("transfer(address,uint256)"))) {
            (address to, uint256 amount) = abi.decode(data[4:], (address, uint256));
            require(rawBalance[msg.sender] >= amount, "balance");
            unchecked {
                rawBalance[msg.sender] -= amount;
            }
            rawBalance[to] += amount;
            return abi.encode(boolAnswer);
        }

        if (selector == bytes4(keccak256("isBlocked(address)"))) {
            return abi.encode(boolAnswer);
        }

        return abi.encode(uint256(0));
    }
}
