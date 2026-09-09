// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IAmpsVault} from "../interfaces/IAmpsVault.sol";
import {PoolStateLib} from "../lib/PoolStateLib.sol";
import {Constants} from "../types/Constants.sol";
import {PlacementRecord} from "../types/Types.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IExtsload} from "@uniswap/v4-core/src/interfaces/IExtsload.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

/// @title VaultRedeemLib
/// @notice The redemption floor's arithmetic and its position removal, and nothing else.
///         `docs/phase3-state-model.md` §3.10 and §10 ruling 6.
///
/// @dev **Why this library exists.** `AmpsVault` is at the EIP-170 ceiling, and the Phase 3 placement path needs
///      the room. Ruling 6 puts the pro-rata *position removal* here rather than in `VaultPlacementLib` for a
///      second, larger reason: `redeemProRata` is the one structurally ungated path in the protocol (Phase 2
///      §7), and the I14 bytecode/`vm.accesses` proof has to follow the link. A library that the redemption path
///      reaches must therefore contain **no** reference to the oracle gate, the feed registry, the pool registry,
///      the guardian, the standby vault, a freeze timestamp, a pause flag or any price — and this one does not.
///      It imports four things: the PoolManager interface, v4's own maths, `PoolStateLib` (which reads the
///      PoolManager and nothing else) and `Constants`. There is no `IOracleGate`, no `IFeedRegistry`, no
///      `IPoolRegistry` and no `IMarketReference` import in this file, by construction, and
///      `test/unit/GuardSymmetry.t.sol` asserts the storage-level consequence: no slot holding one of those
///      pointers is read during a redemption, in the vault **or** in any library it delegate-calls.
///
/// @dev **Where the pool list comes from, and why not the registry.** The removal needs a `PoolKey` per pool, and
///      reading one from `PoolRegistry` would put a registry `SLOAD` on the ungated path. The vault therefore
///      keeps its own append-only `PoolKey[]`, written by `initializePool` — the same call that already registers
///      the counter asset for exactly this reason (Phase 2 §7: "`redeemProRata` never has to consult the
///      registry"). It lives at a hashed slot rather than at the end of the sequential layout so that section
///      1.1's "the layout ends at slot 20" stays literally true.
///
/// @dev **Bounded work** (ruling 7). Every vault position lies on the pool's canonical doubling grid, so a pool
///      holds at most `Constants.GRID_CELLS` records and the loop is `pools x GRID_CELLS` in the worst case. The
///      floor is never gated, rate-limited or split into instalments to make it fit; the bound is a property of
///      the grid, and `test/unit/VaultRedeem.t.sol` measures the worst reachable redemption.
///
/// @dev **Uncollected fees are not the redeemer's.** v4 collects a position's whole accrued fee balance whenever
///      its liquidity is modified, not a pro-rata slice of it, so a one-wei redemption that touched every
///      position would otherwise sweep 100% of the outstanding fees. This library therefore splits every
///      `modifyLiquidity` result into `principal = callerDelta - feesAccrued` and the fees: the redeemer is paid
///      out of the principal only, and the fees are minted into the vault's ERC-6909 claims, where they are part
///      of `A` and belong to every holder. {redemption} therefore nets *everything* the unwind added out of the
///      pro-rata base, which is also what keeps `previewRedeem` — a `view`, so it cannot know what fees a removal
///      will realise — equal to the payout to the wei.
library VaultRedeemLib {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using SafeERC20 for IERC20;

    // -------------------------------------------------------------------------------------------------------------
    // Transient slots and unlock actions — the vault's, declared once, here
    // -------------------------------------------------------------------------------------------------------------
    //
    // `AmpsVault`, `VaultPlacementLib` and this library are one contract at run time: the libraries are reached by
    // `DELEGATECALL`, so they share the vault's storage *and* its transient storage. The discriminator constants
    // therefore have exactly one home, and it is the ungated library, so that neither of the other two can be the
    // reason the redemption path pulls in a definition.

    /// @dev `keccak256("amplestocks.vault.REENTRANCY_LOCK")`.
    uint256 internal constant REENTRANCY_LOCK = 0x3abe6f13db6cb23388862b0e36259666a9a7cd452a11ef9de4aed253478c843c;

    /// @dev `keccak256("amplestocks.vault.UNLOCK_ACTION")`: the discriminator `unlockCallback` dispatches on.
    uint256 internal constant UNLOCK_ACTION = 0x291441d399a16c9ae9ccf88b6ae5184884515a8004caafbe978b06287b215855;

    /// @dev `keccak256("amplestocks.vault.NAV_BEFORE")`. **Reserved, and written by nothing.** It was the channel
    ///      NatSpec claimed carried NAV/share into the migration's relaxed bleed bound, but nothing ever read it
    ///      and `AmpsVault.emergencyMigrate` now measures both sides of that bound live in one frame (audit fix,
    ///      2026-09-08). The number stays declared so the slot is accounted for — `test/unit/VaultPlacement.t.sol`
    ///      asserts it does not collide with the staging buffer — and so a future transient value cannot be
    ///      derived onto it by accident.
    uint256 internal constant NAV_BEFORE = 0x6f2a9a8b4cb99f4e46ead1f9b636e99fbe475b6e810215ed22b447ae90ae3975;

    /// @dev Pull an ERC-20 from a payer straight into the PoolManager and mint the claim.
    uint256 internal constant ACTION_SETTLE = 1;

    /// @dev Burn claims and `take` the ERC-20 out to a redeemer.
    uint256 internal constant ACTION_PAYOUT = 2;

    /// @dev Move the vault's own idle ERC-20 balances into ERC-6909 claims (I12).
    uint256 internal constant ACTION_ABSORB = 3;

    /// @dev Add a ladder into one pool (§3.9).
    uint256 internal constant ACTION_PLACE = 4;

    /// @dev `modifyLiquidity(0)` over a pool's records to realise `feesAccrued` (§3.9).
    uint256 internal constant ACTION_COMPOUND = 5;

    /// @dev Withdraw the high-water-crossed cells, burn the AMPS, re-place the counter below the tick (§3.9).
    uint256 internal constant ACTION_BURNBACK = 6;

    /// @dev Remove `floor(L x shares / supply)` from every record in every pool (§3.9, §3.10).
    uint256 internal constant ACTION_UNWIND = 7;

    /// @dev Remove named cells from one pool and hold the proceeds (rollout source, `withdrawRetiredBids`).
    uint256 internal constant ACTION_HARVEST = 8;

    /// @dev The redemption floor's unblockable payout: hand every claim part to the redeemer as an ERC-6909
    ///      `transfer` and touch no token contract at all. {payout} falls back to it when the ERC-20 attempt
    ///      fails for any reason whatever, so that a hostile constituent can degrade a redemption into claims but
    ///      can never stop it (Phase 2 §7, ruling AD).
    uint256 internal constant ACTION_PAYOUT_CLAIMS = 9;

    // -------------------------------------------------------------------------------------------------------------
    // The live-cell budget (§12 ruling E)
    // -------------------------------------------------------------------------------------------------------------

    /// @dev `keccak256("amplestocks.vault.liveCells")` — a vault-wide `uint32` count of ladder cells with non-zero
    ///      liquidity, summed over every pool.
    ///
    ///      **Why it exists.** {unwind} removes `floor(L x shares / T)` from every live cell, and the placement
    ///      suite measures ~46k gas a cell, so the count is what bounds the gas of the one path that must never
    ///      be gated, rate-limited or split into instalments. `Constants.MAX_LIVE_CELLS` (512, ~23.5M gas) is
    ///      checked wherever a *new* cell would open: `place` reverts `CellBudgetExceeded`, and the permissionless
    ///      bountied paths merge into cells that already exist and leave the remainder idle.
    ///
    ///      **Why a hashed slot.** Section 1.1's numbered layout ends at slot 20 and `test/unit/VaultLayout.t.sol`
    ///      asserts that slots 21 upward and slot 15's high 96 bits stay empty; a counter written on the
    ///      redemption path has to live somewhere that keeps both true. It is here rather than in
    ///      `VaultPlacementLib` because all four libraries maintain it and the redemption path is the one that
    ///      must reach it without touching anything gated.
    uint256 internal constant LIVE_CELLS_SLOT = uint256(keccak256("amplestocks.vault.liveCells"));

    /// @notice The vault's live ladder cells, across every pool.
    /// @return count The count.
    function liveCellCount() internal view returns (uint32 count) {
        uint256 slot = LIVE_CELLS_SLOT;
        uint256 value;
        assembly ("memory-safe") {
            value := sload(slot)
        }
        return uint32(value);
    }

    /// @notice Records `opened` newly live cells.
    /// @param opened How many cells went from empty to holding liquidity.
    function addLiveCells(uint32 opened) internal {
        if (opened == 0) return;
        _setLiveCells(liveCellCount() + opened);
    }

    /// @notice Records `closed` cells that went empty. Saturating at zero: a miscount must never make a
    ///         redemption revert.
    /// @param closed How many cells went from holding liquidity to empty.
    function subLiveCells(uint32 closed) internal {
        if (closed == 0) return;
        uint32 live = liveCellCount();
        _setLiveCells(closed >= live ? 0 : live - closed);
    }

    /// @dev Writes the count.
    function _setLiveCells(uint32 value) private {
        uint256 slot = LIVE_CELLS_SLOT;
        assembly ("memory-safe") {
            sstore(slot, value)
        }
    }

    // -------------------------------------------------------------------------------------------------------------
    // Types
    // -------------------------------------------------------------------------------------------------------------

    /// @notice The result of {redemption}: what `previewRedeem` shows and what `redeemProRata` pays, computed once
    ///         by one function so that the preview can never drift from the payout.
    /// @param tokens The non-AMPS assets paid, in registration order.
    /// @param amounts The net amount of each, after `redeemFeeBps`.
    /// @param fromClaims The part of each payout taken out of the vault's ERC-6909 claims.
    /// @param fromIdle The part of each payout taken out of an idle ERC-20 balance.
    /// @param inventoryBurned AMPS wei released from the vault's own inventory and burned.
    struct Redemption {
        address[] tokens;
        uint256[] amounts;
        uint256[] fromClaims;
        uint256[] fromIdle;
        uint256 inventoryBurned;
    }

    // -------------------------------------------------------------------------------------------------------------
    // Custody: the unlock actions that move an asset, and the `sweepClean` invariant
    // -------------------------------------------------------------------------------------------------------------

    /// @notice The four unlock actions that are about *custody* rather than about the ladder: `ACTION_SETTLE`,
    ///         `ACTION_PAYOUT`, `ACTION_ABSORB` and `ACTION_UNWIND`.
    /// @dev Called only by `AmpsVault.unlockCallback`, which has already checked that the caller is the
    ///      PoolManager and that the transient discriminator is one the vault set immediately before unlocking.
    ///      They live here rather than in the vault because the vault has no EIP-170 headroom left, and here
    ///      rather than in `VaultPlacementLib` because `ACTION_PAYOUT` and `ACTION_UNWIND` are on the ungated
    ///      redemption path and must not reach a library that knows what a gate is.
    /// @param ladder The vault's placement records.
    /// @param pools The vault's own `PoolKey` list.
    /// @param assetIndex The vault's 1-based asset index.
    /// @param assetCount The width of the released array.
    /// @param poolManager The Uniswap v4 PoolManager.
    /// @param action The action.
    /// @param data The action's ABI-encoded payload.
    /// @return result The action's ABI-encoded answer.
    function unlockAction(
        mapping(PoolId => PlacementRecord[]) storage ladder,
        PoolKey[] storage pools,
        mapping(address => uint256) storage assetIndex,
        uint256 assetCount,
        address poolManager,
        uint256 action,
        bytes calldata data
    ) public returns (bytes memory result) {
        if (action == ACTION_SETTLE) {
            (address token, address from, uint256 amount) = abi.decode(data, (address, address, uint256));
            return abi.encode(settleFrom(poolManager, token, from, amount));
        }
        if (action == ACTION_PAYOUT || action == ACTION_PAYOUT_CLAIMS) {
            (address[] memory tokens, uint256[] memory fromClaims, address to) =
                abi.decode(data, (address[], uint256[], address));
            _payOut(poolManager, tokens, fromClaims, to, action == ACTION_PAYOUT);
            return "";
        }
        if (action == ACTION_ABSORB) {
            address token = abi.decode(data, (address));
            _settleAbsorbed(poolManager, token);
            return "";
        }
        if (action == ACTION_UNWIND) {
            (address amps, uint256 shares, uint256 supply) = abi.decode(data, (address, uint256, uint256));
            (uint256[] memory released, uint256[] memory added, uint256 releasedAmps, uint256 addedAmps) =
                unwind(ladder, pools, assetIndex, assetCount, poolManager, amps, shares, supply);
            return abi.encode(released, added, releasedAmps, addedAmps);
        }
        revert IAmpsVault.UnknownUnlockAction();
    }

    /// @notice `sync -> transferFrom -> settle -> mint`: the asset goes straight from the payer into the
    ///         PoolManager and comes back as an ERC-6909 claim owned by the vault, so the vault's own ERC-20
    ///         balance is untouched and `sweepClean` (I12) holds at function exit.
    /// @param poolManager The Uniswap v4 PoolManager.
    /// @param token The asset to settle.
    /// @param from The payer. `address(this)` when absorbing an idle balance the vault already holds.
    /// @param amount The raw amount to move.
    /// @return settled The amount the PoolManager actually credited.
    function settleFrom(address poolManager, address token, address from, uint256 amount)
        public
        returns (uint256 settled)
    {
        IPoolManager pm = IPoolManager(poolManager);
        Currency currency = Currency.wrap(token);

        pm.sync(currency);
        if (from == address(this)) {
            IERC20(token).safeTransfer(address(pm), amount);
        } else {
            IERC20(token).safeTransferFrom(from, address(pm), amount);
        }
        settled = pm.settle();
        if (settled != 0) pm.mint(address(this), currency.toId(), settled);
    }

    /// @notice I12. Any ERC-20 balance the vault is left holding — a donation, a rounding remainder — is absorbed
    ///         into ERC-6909 claims, where it becomes backing for every holder.
    ///
    /// @dev **Nothing in here can revert on a hostile token, and that is the whole point.** `sweepClean` runs at
    ///      the exit of *every* entry point, `redeemProRata` included, and §7 says the redemption floor cannot be
    ///      gated. An implementation that read `balanceOf` unguarded, absorbed with `safeTransfer` and then
    ///      reverted `SweepDirty` on the residue handed anybody a one-transaction kill switch for the whole
    ///      contract: donate one wei of a Stock Token, have the issuer pause it or denylist the vault, and every
    ///      selector reverts forever. Four changes close that:
    ///
    ///        1. **Balances are probed, not read.** A bounded `staticcall` whose answer is hand-decoded; a token
    ///           whose `balanceOf` reverts, runs away with the gas or answers short is simply skipped.
    ///        2. **The absorb is per token and best effort** ({_absorb}): a token that refuses the transfer into
    ///           the PoolManager costs that token its absorb, not the transaction.
    ///        3. **Every call into the token is gas-bounded and each token gets its own `unlock`.** A `transfer`
    ///           that burns whatever it is handed used to leave the skip branch a sixty-fourth of the frame, and
    ///           a `transfer` that re-entered the PoolManager from inside the vault's *own* unlock could open a
    ///           delta nobody closes and take the whole `unlock` down with `CurrencyNotSettled`. Both are gone:
    ///           see {_absorb} for the ordering that removes the second and the caps that remove the first.
    ///        4. **Residue is disclosed, not enforced.** Whatever is still on the vault at the end is reported
    ///           with `IAmpsVault.SweepResidue`. It stays part of the vault's holdings — it is counted in `A` and
    ///           paid out by redemption — so a donation is still backing rather than a leak, exactly as before;
    ///           only the revert is gone.
    ///
    /// @param assets The vault's registered non-AMPS assets.
    /// @param poolManager The Uniswap v4 PoolManager.
    function sweepClean(address[] storage assets, address poolManager) public {
        uint256 length = assets.length;
        for (uint256 i; i < length; ++i) {
            address token = assets[i];
            (bool readable, uint256 balance) = _probeBalance(token);
            if (!readable || balance == 0) continue;

            _absorb(poolManager, token, balance);

            (readable, balance) = _probeBalance(token);
            if (readable && balance != 0) emit IAmpsVault.SweepResidue(token, balance);
        }
    }

    /// @dev One token's best-effort absorb: `sync -> transfer` **outside** an unlock, then `settle -> mint` inside
    ///      one the token cannot poison, abandoned at the first step that fails.
    ///
    /// @dev **Why the transfer happens before the `unlock` and not inside it.** v4's `sync` is not
    ///      `onlyWhenUnlocked`, and neither is an ERC-20 `transfer`. A Stock Token is a beacon proxy whose
    ///      `transfer` must be assumed hostile, and the one thing a hostile `transfer` can do from inside the
    ///      vault's own `unlock` is call the PoolManager — `mint`, `take`, a swap — and leave a delta of *its
    ///      own* open. v4 counts non-zero deltas globally, so the vault's `unlock` then reverts with
    ///      `CurrencyNotSettled` however clean the vault's own books are, and before this that revert took the
    ///      entry point with it. Moved out here the same call-back hits `ManagerLocked` and it is the *token's*
    ///      transfer that fails, which costs that token its absorb and nothing else.
    ///
    /// @dev **Every leg is gas-bounded.** `sync` reads the token's `balanceOf` inside the PoolManager and the
    ///      `transfer` is the token's own code, so an unbounded call to either leaves the skip branch a
    ///      sixty-fourth of the caller's frame — a griefing kill switch by exhaustion rather than by reverting.
    ///      Four probe budgets is orders of magnitude more than an honest ERC-20 needs for either.
    ///
    /// @dev **The `unlock` itself is `try`/`catch`ed**, so even a residual failure inside it — a `settle` the
    ///      token starves, a `mint` the PoolManager refuses — skips this token's absorb instead of reverting the
    ///      entry point. One token, one `unlock`: a token that fails cannot take another token's absorb with it.
    ///
    /// @dev **The one thing this cannot undo.** A token that answers `balanceOf` for the probe and for `sync`,
    ///      accepts the transfer, and *then* refuses `balanceOf` inside `settle` leaves that transfer sitting in
    ///      the PoolManager uncredited: the transfer is outside the `unlock`, so the `catch` cannot roll it back.
    ///      The amount is that token's own idle dust (I12), no other asset is touched, and the alternative —
    ///      transferring inside the `unlock` — is what let a hostile token revert the whole sweep in the first
    ///      place. It is a disclosure, not a hole: the balance leaves the vault either way.
    /// @param poolManager The Uniswap v4 PoolManager.
    /// @param token The asset to absorb.
    /// @param amount The idle balance {sweepClean} measured.
    function _absorb(address poolManager, address token, uint256 amount) private {
        if (amount == 0) return;

        (bool synced,) = poolManager.call{gas: Constants.STOCK_TOKEN_PROBE_GAS * 4}(
            abi.encodeCall(IPoolManager.sync, (Currency.wrap(token)))
        );
        if (!synced) return;
        if (!_tryTransfer(token, poolManager, amount)) return;

        uint256 slot = UNLOCK_ACTION;
        uint256 absorb = ACTION_ABSORB;
        assembly ("memory-safe") {
            tstore(slot, absorb)
        }
        try IPoolManager(poolManager).unlock(abi.encode(token)) {} catch {}
        assembly ("memory-safe") {
            tstore(slot, 0)
        }
    }

    /// @dev The inside-the-unlock half of {_absorb}: credit whatever the transfer moved and mint the claim.
    ///      `settle` is a bounded low-level call because the PoolManager reads the token's own `balanceOf` inside
    ///      it, so a token that starves it costs its own absorb rather than the caller's frame; `mint` runs only
    ///      on a non-zero credit, so no delta is ever opened that this unlock could not close.
    /// @param poolManager The Uniswap v4 PoolManager.
    /// @param token The asset whose transfer is waiting to be settled.
    function _settleAbsorbed(address poolManager, address token) private {
        (bool ok, bytes memory returndata) =
            poolManager.call{gas: Constants.STOCK_TOKEN_PROBE_GAS * 4}(abi.encodeCall(IPoolManager.settle, ()));
        if (!ok || returndata.length < 32) return;
        uint256 settled;
        assembly ("memory-safe") {
            settled := mload(add(returndata, 0x20))
        }
        if (settled != 0) IPoolManager(poolManager).mint(address(this), Currency.wrap(token).toId(), settled);
    }

    // -------------------------------------------------------------------------------------------------------------
    // The payout (§7, ruling AD)
    // -------------------------------------------------------------------------------------------------------------

    /// @notice Pays one redemption out: ERC-20 where the token allows it, an ERC-6909 claim where it does not,
    ///         and value for every asset either way.
    ///
    /// @dev **Three nested fallbacks, because the floor may not be stoppable by anybody.** Per asset, `take`
    ///      moves a real ERC-20 to the redeemer and a token that is paused, that denylists the vault or the
    ///      redeemer, or that simply burns the gas it is handed makes it fail; the claim is then transferred
    ///      instead, which is a balance move inside the PoolManager that no token contract can observe or refuse.
    ///      That is the per-asset fallback, and it lives inside the unlock ({_payOut}).
    ///
    ///      The second fallback is this function's own. A hostile `transfer` reached through `take` runs while the
    ///      PoolManager is unlocked and can open a delta of *its own* — `mint`, `take`, a swap — which makes the
    ///      vault's `unlock` revert with `CurrencyNotSettled` at the end, after every per-asset `catch` has
    ///      already been passed. One constituent could therefore revert the whole payout. The ERC-20 attempt is
    ///      therefore itself a `try`, and its failure runs a second `unlock` that transfers every claim part and
    ///      touches no token at all. `Constants.REDEEM_PAYOUT_RESERVE_GAS` is held back from the first attempt so
    ///      that the second is always affordable, however much gas the first one burns.
    ///
    ///      The third is the idle leg, which is paid **after** the unlock: an idle ERC-20 balance is dust by I12
    ///      (every deposit path settles straight into the PoolManager), it cannot be handed over as a claim
    ///      because it is not one, and moving it inside the unlock would put a hostile `transfer` back on the one
    ///      call path this function exists to protect. Each leg is a bounded best-effort call; an idle wei a
    ///      token refuses to move is **not paid** and stays on the vault as backing for every holder.
    ///
    /// @dev The result: the redeemer receives value for every asset, as tokens or as claims, and no third party
    ///      can turn "degraded" into "reverted".
    /// @param poolManager The Uniswap v4 PoolManager.
    /// @param tokens The assets being paid, in registration order.
    /// @param fromClaims The part of each payout that comes out of the vault's ERC-6909 claims.
    /// @param fromIdle The part that comes out of an idle ERC-20 balance.
    /// @param to The redeemer.
    function payout(
        address poolManager,
        address[] memory tokens,
        uint256[] memory fromClaims,
        uint256[] memory fromIdle,
        address to
    ) public {
        uint256 slot = UNLOCK_ACTION;
        bytes memory data = abi.encode(tokens, fromClaims, to);
        uint256 reserve = Constants.REDEEM_PAYOUT_RESERVE_GAS;
        bool paid;

        if (gasleft() > reserve) {
            uint256 action = ACTION_PAYOUT;
            assembly ("memory-safe") {
                tstore(slot, action)
            }
            try IPoolManager(poolManager).unlock{gas: gasleft() - reserve}(data) {
                paid = true;
            } catch {}
        }

        if (!paid) {
            uint256 action = ACTION_PAYOUT_CLAIMS;
            assembly ("memory-safe") {
                tstore(slot, action)
            }
            // Deliberately not `try`ed: this unlock moves ERC-6909 balances the vault is known to hold and calls
            // no token, so a failure here is a bug in this library rather than something a third party can cause.
            IPoolManager(poolManager).unlock(data);
        }

        assembly ("memory-safe") {
            tstore(slot, 0)
        }

        uint256 length = tokens.length;
        for (uint256 i; i < length; ++i) {
            uint256 idlePart = fromIdle[i];
            if (idlePart == 0) continue;
            // The claims are already paid; what is left is dust, and running out of gas over it would revert a
            // redemption that has otherwise succeeded. An unpaid idle part stays on the vault as backing.
            if (gasleft() < Constants.STOCK_TOKEN_PROBE_GAS * 8) return;
            _tryTransfer(tokens[i], to, idlePart);
        }
    }

    /// @dev Burns the claim slice and `take`s it out as ERC-20, or hands the claim itself over when it cannot.
    ///
    /// @dev **One paused constituent must not stop every redemption.** `take` moves a real ERC-20 to the redeemer,
    ///      so a Stock Token that is paused, or that denylists either the vault or the redeemer, reverts it — and
    ///      because the payout walks every registered asset in one unlock, that revert used to take the other
    ///      thirty-one assets and every other holder's redemption with it. The `take` is therefore attempted and,
    ///      when it fails, the claim itself is handed over instead: `pm.transfer` is an ERC-6909 balance move
    ///      inside the PoolManager that touches no token contract, so nothing about the token can block it. The
    ///      redeemer holds a claim on exactly the same amount and can `take` it whenever the issuer relents.
    ///
    /// @dev **The `take` is gas-bounded**, because it calls the token's `transfer`: a token that burns everything
    ///      it is handed would otherwise leave the `catch` branch a sixty-fourth of the frame and starve the
    ///      assets after it, which is a way of stopping the floor by exhaustion rather than by reverting.
    ///
    /// @dev **The burn lives in the success branch, and must.** `take` opens a negative delta for the vault that
    ///      burning the claim settles; both orders are legal inside one unlock, but the claim may only be burned
    ///      when the `take` that consumed it actually happened. In the fallback the claim is transferred, not
    ///      burned, so the vault's ledger balances either way.
    /// @param poolManager The Uniswap v4 PoolManager.
    /// @param tokens The assets being paid.
    /// @param fromClaims The claim part of each payout.
    /// @param to The redeemer.
    /// @param withErc20 Whether to attempt the ERC-20 `take` at all. False on {ACTION_PAYOUT_CLAIMS}, the
    ///        unblockable second attempt, which must not call a token under any circumstances.
    function _payOut(
        address poolManager,
        address[] memory tokens,
        uint256[] memory fromClaims,
        address to,
        bool withErc20
    ) private {
        IPoolManager pm = IPoolManager(poolManager);
        for (uint256 i; i < tokens.length; ++i) {
            uint256 claimPart = fromClaims[i];
            if (claimPart == 0) continue;

            Currency currency = Currency.wrap(tokens[i]);
            uint256 id = currency.toId();
            bool moved;
            if (withErc20) {
                try pm.take{gas: Constants.STOCK_TOKEN_PROBE_GAS * 4}(currency, to, claimPart) {
                    pm.burn(address(this), id, claimPart);
                    moved = true;
                } catch {}
            }
            if (!moved) pm.transfer(to, id, claimPart);
        }
    }

    /// @dev The vault's own balance of `token`, or `(false, 0)` when the token cannot be asked. A bounded
    ///      `staticcall` with a hand-decoded answer: a `balanceOf` that reverts, that consumes everything it is
    ///      given, or that returns fewer than 32 bytes is "unreadable", never a revert of the caller.
    /// @param token The asset.
    /// @return readable Whether the answer can be believed.
    /// @return balance The answer, or zero.
    function _probeBalance(address token) private view returns (bool readable, uint256 balance) {
        (bool ok, bytes memory returndata) =
            token.staticcall{gas: Constants.STOCK_TOKEN_PROBE_GAS}(abi.encodeCall(IERC20.balanceOf, (address(this))));
        if (!ok || returndata.length < 32) return (false, 0);
        uint256 word;
        assembly ("memory-safe") {
            word := mload(add(returndata, 0x20))
        }
        return (true, word);
    }

    /// @dev One ERC-20 `transfer` that reports failure instead of causing it. SafeERC20's acceptance rule, by
    ///      hand: the call must succeed against a contract, and it must return either nothing at all or a single
    ///      non-zero word. A short or non-canonical answer is a failure rather than a `Panic` in the vault's frame.
    /// @dev **Bounded.** Every caller here is a best-effort leg whose failure is a skip, and an unbounded call to
    ///      a token that burns whatever it is handed leaves that skip branch a sixty-fourth of the frame — which
    ///      is a way of stopping the redemption floor by exhaustion rather than by reverting. Four probe budgets
    ///      is orders of magnitude more than an honest ERC-20 `transfer` costs.
    /// @param token The asset.
    /// @param to The recipient.
    /// @param amount The amount.
    /// @return moved Whether the tokens moved.
    function _tryTransfer(address token, address to, uint256 amount) private returns (bool moved) {
        (bool ok, bytes memory returndata) =
            token.call{gas: Constants.STOCK_TOKEN_PROBE_GAS * 4}(abi.encodeCall(IERC20.transfer, (to, amount)));
        if (!ok) return false;
        if (returndata.length == 0) return token.code.length != 0;
        if (returndata.length < 32) return false;
        uint256 word;
        assembly ("memory-safe") {
            word := mload(add(returndata, 0x20))
        }
        return word != 0;
    }

    // -------------------------------------------------------------------------------------------------------------
    // The pro-rata arithmetic (I23)
    // -------------------------------------------------------------------------------------------------------------

    /// @notice The whole of I23 in one place.
    ///
    /// @dev Per registered asset `j`, with `b_j` the vault's holding of `j` *before* any position was unwound:
    ///      ```
    ///      gross_j = floor(b_j x shares / supply) + released_j
    ///      net_j   = floor(gross_j x (BPS - redeemFeeBps) / BPS)
    ///      ```
    ///      and the same shape for the vault's own AMPS inventory, which is burned rather than paid out so that
    ///      `T` falls by more than `shares`. `released_j` is the position principal the unwind actually freed and
    ///      is paid in full rather than pro-rated, because it *is* the pro-rata slice: it came out of a position
    ///      by removing `floor(L x shares / supply)` of its liquidity.
    ///
    /// @dev Reads balances only: no oracle, no gate, no registry, no price.
    ///
    /// @param assets The vault's registered non-AMPS assets, in registration order.
    /// @param poolManager The Uniswap v4 PoolManager, where the vault's claims live.
    /// @param amps The AMPS token.
    /// @param shares The AMPS wei being redeemed.
    /// @param supply `T`, read before the burn.
    /// @param redeemFeeBps The redemption fee, in bps.
    /// @param released Position principal freed per asset, parallel to `assets`; may be empty for "none".
    /// @param added Everything the unwind added per asset — principal **plus** the fees the removal realised —
    ///        parallel to `assets`. Empty when the unwind has not run (`previewRedeem`), in which case the
    ///        balances are already the pre-unwind ones and nothing is netted.
    /// @param releasedAmps Position principal freed on the AMPS side.
    /// @param addedAmps Everything the unwind added to the vault's AMPS holdings, principal plus realised fees.
    /// @return result The token list, the net amounts, the claim/idle split of each and the inventory burn.
    function redemption(
        address[] storage assets,
        address poolManager,
        address amps,
        uint256 shares,
        uint256 supply,
        uint16 redeemFeeBps,
        uint256[] memory released,
        uint256[] memory added,
        uint256 releasedAmps,
        uint256 addedAmps
    ) public view returns (Redemption memory result) {
        uint256 length = assets.length;
        result.tokens = new address[](length);
        result.amounts = new uint256[](length);
        result.fromClaims = new uint256[](length);
        result.fromIdle = new uint256[](length);
        if (supply == 0) return result;

        uint256 keepBps = Constants.BPS - redeemFeeBps;
        bool hasReleased = released.length == length;
        bool hasAdded = added.length == length;

        for (uint256 i; i < length; ++i) {
            result.tokens[i] = assets[i];
            (result.amounts[i], result.fromClaims[i], result.fromIdle[i]) = _payout(
                assets[i], poolManager, shares, supply, keepBps, hasReleased ? released[i] : 0, hasAdded ? added[i] : 0
            );
        }

        uint256 inventory = IERC20(amps).balanceOf(address(this))
            + IPoolManager(poolManager).balanceOf(address(this), Currency.wrap(amps).toId());
        if (addedAmps != 0) inventory = inventory > addedAmps ? inventory - addedAmps : 0;
        result.inventoryBurned = FullMath.mulDiv(inventory, shares, supply) + releasedAmps;
    }

    /// @dev One asset's slice of a redemption.
    ///
    ///      Everything the unwind added — position principal *and* the fees the removal realised — is netted out
    ///      of the pro-rata base, and the principal is then added back in full: it is already the redeemer's
    ///      `floor(L x shares / T)` slice, not a basis to take a second slice of. The fees stay with the protocol,
    ///      and because they never enter the base, `previewRedeem` (which cannot know them) sees the same number.
    /// @param token The asset.
    /// @param poolManager The Uniswap v4 PoolManager.
    /// @param shares The AMPS wei being redeemed.
    /// @param supply `T`.
    /// @param keepBps `BPS - redeemFeeBps`.
    /// @param released The position principal this asset freed.
    /// @param added The principal plus the realised fees; zero when the unwind has not run.
    /// @dev The idle leg is a {_probeBalance} rather than a plain `balanceOf`, for the same reason
    ///      {sweepClean} probes: a constituent whose `balanceOf` reverts would otherwise revert `previewRedeem`
    ///      and `redeemProRata` for every asset and every holder. An unreadable balance is read as zero, so the
    ///      claim side — which lives in the PoolManager and cannot be interfered with — is still paid in full.
    /// @return net The payout, after the fee.
    /// @return fromClaim The part taken out of ERC-6909 claims.
    /// @return fromIdle The part taken out of an idle ERC-20 balance.
    function _payout(
        address token,
        address poolManager,
        uint256 shares,
        uint256 supply,
        uint256 keepBps,
        uint256 released,
        uint256 added
    ) private view returns (uint256 net, uint256 fromClaim, uint256 fromIdle) {
        uint256 claimBalance = IPoolManager(poolManager).balanceOf(address(this), Currency.wrap(token).toId());
        (, uint256 idleBalance) = _probeBalance(token);
        uint256 balance = claimBalance + idleBalance;
        if (added != 0) balance = balance > added ? balance - added : 0;

        net = FullMath.mulDiv(FullMath.mulDiv(balance, shares, supply) + released, keepBps, Constants.BPS);
        if (net == 0) return (0, 0, 0);
        fromClaim = net > claimBalance ? claimBalance : net;
        fromIdle = net - fromClaim;
    }

    // -------------------------------------------------------------------------------------------------------------
    // The position removal (§3.10)
    // -------------------------------------------------------------------------------------------------------------

    /// @notice Removes exactly `floor(L x shares / supply)` from every {PlacementRecord} in every pool the vault
    ///         has opened, inside the caller's `unlock`.
    ///
    /// @dev The released **principal** is split by currency: AMPS (`currency0` everywhere) is `take`n out as ERC-20
    ///      so the vault can burn it, and the counter asset is `mint`ed as an ERC-6909 claim so the payout can pay
    ///      it without a second `settle`. Accrued fees realised by the removal are minted as claims on both sides
    ///      and stay with the protocol.
    ///
    /// @dev `shares == supply` removes everything, which is what {AmpsVault-emergencyMigrate} uses to bring the
    ///      ladder home before the claims move to the standby: liquidity that stayed in v4 positions owned by a
    ///      denylisted vault would be unreachable by the standby.
    ///
    /// @param ladder The vault's per-pool placement records (slot 18).
    /// @param pools The vault's own `PoolKey` list, written by `initializePool`.
    /// @param assetIndex The vault's 1-based asset index (slot 17), for attributing each pool's counter.
    /// @param assetCount The length of the vault's asset list, i.e. the width of the returned array.
    /// @param poolManager The Uniswap v4 PoolManager.
    /// @param amps The AMPS token, whose ERC-6909 claim is swept to an ERC-20 balance so the caller can burn it.
    /// @param shares The AMPS wei being redeemed.
    /// @param supply `T`, read before the burn.
    /// @return releasedCounter Counter principal freed per asset, parallel to the vault's asset list.
    /// @return addedCounter Principal **plus** realised fees per asset: everything the unwind added.
    /// @return releasedAmps AMPS principal freed, now an idle ERC-20 balance on the vault.
    /// @return addedAmps Principal plus realised fees on the AMPS side.
    function unwind(
        mapping(PoolId => PlacementRecord[]) storage ladder,
        PoolKey[] storage pools,
        mapping(address => uint256) storage assetIndex,
        uint256 assetCount,
        address poolManager,
        address amps,
        uint256 shares,
        uint256 supply
    )
        public
        returns (
            uint256[] memory releasedCounter,
            uint256[] memory addedCounter,
            uint256 releasedAmps,
            uint256 addedAmps
        )
    {
        releasedCounter = new uint256[](assetCount);
        addedCounter = new uint256[](assetCount);
        if (supply == 0 || shares == 0) return (releasedCounter, addedCounter, 0, 0);

        IPoolManager pm = IPoolManager(poolManager);
        uint256 poolCount = pools.length;
        uint32 closed;

        for (uint256 p; p < poolCount; ++p) {
            PoolKey memory key = pools[p];
            PlacementRecord[] storage records = ladder[key.toId()];
            uint256 n = records.length;
            if (n == 0) continue;

            int256 principal0;
            int256 principal1;
            int256 fees0;
            int256 fees1;

            for (uint256 i; i < n; ++i) {
                PlacementRecord storage record = records[i];
                uint128 live = record.liquidity;
                if (live == 0) continue;
                uint128 removed = uint128(FullMath.mulDiv(live, shares, supply));
                if (removed == 0) continue;

                (BalanceDelta callerDelta, BalanceDelta feesAccrued) = pm.modifyLiquidity(
                    key,
                    ModifyLiquidityParams({
                        tickLower: record.lowerTick,
                        tickUpper: record.upperTick,
                        liquidityDelta: -int256(uint256(removed)),
                        salt: Constants.POSITION_SALT
                    }),
                    ""
                );

                record.liquidity = live - removed;
                // **`record.amount` is deliberately *not* pro-rated here** (audit lead, 2026-09-08). Every other
                // removal decrements it, but this one runs on the structurally ungated redemption floor, once per
                // live cell, and the field lives in the record's *second* slot: writing it costs a cold `SLOAD`
                // plus a dirty `SSTORE` per cell, which measured +2.5M gas at the 512-cell budget and pushed
                // `redeemProRata` past the one-transaction bound `test_e_gasPerLiveCellFitsTheRedemptionBudget`
                // asserts. The disclosure is worth less than the floor's headroom, so the field reads as "placed,
                // less what the placement engine removed" and a redemption is the one thing it does not follow.
                if (live == removed) ++closed;
                principal0 += int256(callerDelta.amount0()) - int256(feesAccrued.amount0());
                principal1 += int256(callerDelta.amount1()) - int256(feesAccrued.amount1());
                fees0 += int256(feesAccrued.amount0());
                fees1 += int256(feesAccrued.amount1());
            }

            if (principal0 > 0) {
                // AMPS out as ERC-20: the caller burns it (redemption) or hands it on (migration).
                pm.take(key.currency0, address(this), uint256(principal0));
                releasedAmps += uint256(principal0);
                addedAmps += uint256(principal0);
            }
            if (fees0 > 0) {
                pm.mint(address(this), key.currency0.toId(), uint256(fees0));
                addedAmps += uint256(fees0);
            }

            uint256 counterOut = principal1 > 0 ? uint256(principal1) : 0;
            uint256 counterFees = fees1 > 0 ? uint256(fees1) : 0;
            if (counterOut + counterFees != 0) {
                pm.mint(address(this), key.currency1.toId(), counterOut + counterFees);
                uint256 index = assetIndex[Currency.unwrap(key.currency1)];
                if (index != 0 && index <= assetCount) {
                    releasedCounter[index - 1] += counterOut;
                    addedCounter[index - 1] += counterOut + counterFees;
                }
            }
        }

        subLiveCells(closed);

        // §12 ruling F. The whole AMPS claim becomes an idle ERC-20 balance so {redemption}'s pro-rata slice of
        // the vault's inventory can actually be burned; the slice itself is `floor(inventory x shares / T)`, not
        // the claim, so a dust redemption still burns dust.
        uint256 ampsClaim = pm.balanceOf(address(this), Currency.wrap(amps).toId());
        if (ampsClaim != 0) {
            pm.burn(address(this), Currency.wrap(amps).toId(), ampsClaim);
            pm.take(Currency.wrap(amps), address(this), ampsClaim);
        }
    }

    /// @notice What {unwind} would free, without moving anything.
    ///
    /// @dev Mirrors v4's own decomposition exactly — it branches on `slot0.tick` against the range, not on the
    ///      sqrt price, and every amount rounds **down** — so `previewRedeem` and `redeemProRata` agree to the wei.
    ///      `test/unit/VaultRedeem.t.sol` asserts that equality against a live pool rather than trusting it.
    ///
    /// @param ladder The vault's per-pool placement records.
    /// @param pools The vault's own `PoolKey` list.
    /// @param assetIndex The vault's 1-based asset index.
    /// @param assetCount The width of the returned array.
    /// @param poolManager The Uniswap v4 PoolManager.
    /// @param shares The AMPS wei being redeemed.
    /// @param supply `T`.
    /// @return releasedCounter Counter principal that would be freed, per asset.
    /// @return releasedAmps AMPS principal that would be freed.
    function previewUnwind(
        mapping(PoolId => PlacementRecord[]) storage ladder,
        PoolKey[] storage pools,
        mapping(address => uint256) storage assetIndex,
        uint256 assetCount,
        address poolManager,
        uint256 shares,
        uint256 supply
    ) public view returns (uint256[] memory releasedCounter, uint256 releasedAmps) {
        releasedCounter = new uint256[](assetCount);
        if (supply == 0 || shares == 0) return (releasedCounter, 0);

        uint256 poolCount = pools.length;
        for (uint256 p; p < poolCount; ++p) {
            PoolKey memory key = pools[p];
            PoolId poolId = key.toId();
            PlacementRecord[] storage records = ladder[poolId];
            uint256 n = records.length;
            if (n == 0) continue;

            (uint160 sqrtPriceX96, int24 tick) = PoolStateLib.sqrtPriceAndTick(IExtsload(poolManager), poolId);
            if (sqrtPriceX96 == 0) continue;

            uint256 out0;
            uint256 out1;
            for (uint256 i; i < n; ++i) {
                PlacementRecord memory record = records[i];
                if (record.liquidity == 0) continue;
                uint128 removed = uint128(FullMath.mulDiv(record.liquidity, shares, supply));
                if (removed == 0) continue;

                uint160 sqrtLower = TickMath.getSqrtPriceAtTick(record.lowerTick);
                uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(record.upperTick);
                if (tick < record.lowerTick) {
                    out0 += SqrtPriceMath.getAmount0Delta(sqrtLower, sqrtUpper, removed, false);
                } else if (tick < record.upperTick) {
                    out0 += SqrtPriceMath.getAmount0Delta(sqrtPriceX96, sqrtUpper, removed, false);
                    out1 += SqrtPriceMath.getAmount1Delta(sqrtLower, sqrtPriceX96, removed, false);
                } else {
                    out1 += SqrtPriceMath.getAmount1Delta(sqrtLower, sqrtUpper, removed, false);
                }
            }

            releasedAmps += out0;
            if (out1 != 0) {
                uint256 index = assetIndex[Currency.unwrap(key.currency1)];
                if (index != 0 && index <= assetCount) releasedCounter[index - 1] += out1;
            }
        }
    }
}
