// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title MockHostileCollateral
/// @notice An 18-decimal ERC-20 whose three misbehaviours are exactly the ones `AmpsBonds._issue`'s dust forward
///         has to survive: a `balanceOf` that reverts for one account, a `transfer` that burns every wei of gas it
///         is handed, and a `transfer` that answers with a non-canonical `bool`.
///
/// @dev **Why not a flag on `MockStockToken`.** Two of the three cannot be expressed in Solidity at all. A
///      compiler-emitted `bool` return is always a clean 0 or 1, so answering the word `2` — which real ERC-20s on
///      mainnet do, and which the ABI spec leaves undefined — means writing the returndata by hand; and a
///      `balanceOf` that reverts only for the *bond shell* (never for the vault, which must still settle the
///      deposit through it) needs a per-account switch rather than a global one.
///
/// @dev **What each one breaks if it is not handled.** The dust forward runs inside `bond()`, after the mint and
///      the effects, on a token governance registered but does not control:
///        - a typed `IERC20(collateral).balanceOf(address(this))` makes a reverting balance a revert of `bond()`,
///          i.e. a permanent denial of service on that market;
///        - an uncapped `collateral.call(transfer)` lets the token consume the whole remaining gas of the
///          transaction, which is the same denial of service with a different receipt;
///        - `abi.decode(returned, (bool))` `Panic`s in the shell's frame on the word `2`, which no `try` can catch.
///      All three are probes now, and this mock is what proves it.
contract MockHostileCollateral {
    /// @notice ERC-20 metadata.
    string public name = "Hostile Collateral";

    /// @notice ERC-20 metadata.
    string public symbol = "HOST";

    /// @notice 18, like every Stock Token.
    uint8 public constant decimals = 18;

    /// @notice Total minted supply.
    uint256 public totalSupply;

    /// @notice ERC-20 allowances.
    mapping(address owner => mapping(address spender => uint256 amount)) public allowance;

    /// @notice The one account whose {balanceOf} reverts, or `address(0)` for none.
    /// @dev Per-account on purpose: the vault reads its *own* balance twice inside `depositBonded`, so a global
    ///      switch would stop the bond before the dust forward it is meant to exercise ever runs.
    address public balanceProbeVictim;

    /// @notice When true, {transfer} burns storage gas until whatever it was given runs out.
    bool public transferBurnsGas;

    /// @notice The word {transfer} answers with. 1 is a canonical `true`; 2 is the non-canonical case; 0 is a
    ///         plain `false`.
    uint256 public transferAnswer = 1;

    /// @notice Gas sink for {transferBurnsGas}.
    uint256 public sink;

    mapping(address account => uint256 amount) internal _balance;

    /// @notice Thrown by {balanceOf} for {balanceProbeVictim}.
    error BalanceUnavailable();

    /// @notice Mirrors the ERC-20 event, so a test can assert the dust really moved.
    event Transfer(address indexed from, address indexed to, uint256 value);

    /// @notice Mirrors the ERC-20 event.
    event Approval(address indexed owner, address indexed spender, uint256 value);

    /* -------------------------------------------- switches -------------------------------------------- */

    /// @notice Makes {balanceOf} revert for one account and nobody else.
    /// @param account The victim, or `address(0)` to clear.
    function setBalanceProbeVictim(address account) external {
        balanceProbeVictim = account;
    }

    /// @notice Makes {transfer} burn every wei of gas it is given.
    /// @param value Whether to burn.
    function setTransferBurnsGas(bool value) external {
        transferBurnsGas = value;
    }

    /// @notice Sets the raw word {transfer} answers with.
    /// @param value The word.
    function setTransferAnswer(uint256 value) external {
        transferAnswer = value;
    }

    /// @notice Credits `to`, so a bonder can be funded and dust can be donated.
    /// @param to The account.
    /// @param amount The amount.
    function mint(address to, uint256 amount) external {
        _balance[to] += amount;
        totalSupply += amount;
        emit Transfer(address(0), to, amount);
    }

    /* --------------------------------------------- ERC-20 --------------------------------------------- */

    /// @notice The account's balance, or a revert for {balanceProbeVictim}.
    /// @param account The account.
    /// @return amount The balance.
    function balanceOf(address account) external view returns (uint256 amount) {
        if (account == balanceProbeVictim) revert BalanceUnavailable();
        return _balance[account];
    }

    /// @notice ERC-20 approve.
    /// @param spender The spender.
    /// @param amount The allowance.
    /// @return ok Always true.
    function approve(address spender, uint256 amount) external returns (bool ok) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    /// @notice ERC-20 transferFrom, always canonical: the deposit leg must work for the dust leg to be reached.
    /// @param from The payer.
    /// @param to The recipient.
    /// @param amount The amount.
    /// @return ok Always true.
    function transferFrom(address from, address to, uint256 amount) external returns (bool ok) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        _move(from, to, amount);
        return true;
    }

    /// @notice ERC-20 transfer, with both misbehaviours available.
    /// @dev The answer is written by hand because the compiler cannot emit a non-canonical `bool`. The tokens
    ///      move first either way: a token that lies about its answer has still moved the balance, and the shell's
    ///      accounting must not depend on the lie.
    /// @param to The recipient.
    /// @param amount The amount.
    function transfer(address to, uint256 amount) external returns (bool) {
        _move(msg.sender, to, amount);
        if (transferBurnsGas) {
            for (uint256 i = 1; i < 1_000_000; ++i) {
                sink = i;
            }
        }
        uint256 answer = transferAnswer;
        assembly ("memory-safe") {
            mstore(0x00, answer)
            return(0x00, 0x20)
        }
    }

    /// @dev The balance move both transfer entry points share.
    function _move(address from, address to, uint256 amount) internal {
        uint256 balance = _balance[from];
        require(balance >= amount, "balance");
        unchecked {
            _balance[from] = balance - amount;
        }
        _balance[to] += amount;
        emit Transfer(from, to, amount);
    }
}
