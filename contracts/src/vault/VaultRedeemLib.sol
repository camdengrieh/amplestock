// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IAmps} from "../interfaces/IAmps.sol";
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
///      It imports five things: the PoolManager interface, v4's own maths, `PoolStateLib` (which reads the
///      PoolManager and nothing else), `Constants`, and `IAmps` — the share token itself, for the inventory-burn
///      stream's `burn`, which is the same call the redemption already makes for the redeemer's own shares. There
///      is no `IOracleGate`, no `IFeedRegistry`, no `IPoolRegistry` and no `IMarketReference` import in this file,
///      by construction, and
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
    // The inventory-burn stream (§12.3 ruling U, resolved 2026-09-13)
    // -------------------------------------------------------------------------------------------------------------
    //
    // **What this replaces.** `redeemProRata` used to burn the inventory it released — the ladder AMPS the unwind
    // freed plus `floor(inventory x shares / T)` — in the same transaction, immediately after paying the redeemer.
    // The burn lowers `T`, and `T` is the denominator the *next* redemption divides by, so a holder who split one
    // exit into slices was dividing by a number its own earlier slices had shrunk: 300 AMPS taken in 60 slices
    // returned ~2.9% more than the same 300 taken at once, monotone in the split count (ruling U).
    //
    // **Why "defer it to the next checkpoint" was not the fix.** `checkpoint()` is permissionless and unpaid, by
    // design — the whole protocol depends on anyone being able to refresh NAV. A redeemer could therefore call it
    // between slices and get the identical lift one transaction later.
    //
    // **The stream.** The amount is queued instead, and released linearly over
    // `Constants.REDEEM_BURN_STREAM_SECONDS`. Every path that recomputes NAV settles the accrued portion first
    // (`AmpsVault._checkpoint`), and so does a redemption, so the burn still lands — it simply cannot land inside
    // the sequence that earned it. Two consequences are the point of the design: slices inside one block see
    // `elapsed == 0` and therefore no lift at all, and a slice a day later has already paid the fee on every
    // earlier slice.
    //
    // **What is left is the redemption fee's own superadditivity, and it is not "a few basis points"** (audit
    // disclosure correction wave 5, finding 4). The sentence that used to stand here said the residue was "a few
    // basis points and favours nobody in particular", without qualification, and that is false at the top of the
    // range. Splitting an exit into `k` slices pays the fee `k` times on a base each slice has already shrunk:
    // against a holding `b0` the split surrenders `b0 x (1 - (1 - f)^k)` where the single exit surrenders
    // `k x b0 x f` of the *same* base, and `1 - (1 - f)^k < k f` — so the split is the **dearer** of the two and
    // the gap grows with the fraction of supply being exited. A few basis points for a small exit, +0.78% at a
    // 50% exit, +1.90% at 90%. The direction is the safe one: a split exit is charged more, never less, so this
    // is a reason not to split rather than an advantage to be had from splitting.
    //
    // The three values live at hashed slots beside {LIVE_CELLS_SLOT}, for the same reason: §1.1's numbered layout
    // ends at slot 20, `test/unit/VaultLayout.t.sol` asserts that slots 21 upward stay empty, and state written on
    // the redemption path has to keep that true. They are here rather than in `VaultPlacementLib` because the
    // redemption path must reach them without touching anything gated.
    //
    // **The schedule is one straight line, whatever the settle frequency.** `windowStart` is the opening of the
    // current window and `windowStart + D` is the instant the queue is fully burned; `lastSettle` is where the
    // line was last evaluated. A settlement takes `pending x (now - lastSettle) / (end - lastSettle)` — the
    // remaining amount over the remaining time — so settling hourly for 24 hours burns exactly what settling once
    // at the end burns, and a keeper cannot slow the burn down by calling it often. Queueing more re-opens **one**
    // window for the *combined* amount rather than stacking a second schedule, which is what keeps these three
    // numbers enough to describe the whole state.
    //
    // **The re-opening is amount-weighted, and that is the whole of finding 2** (audit fix wave 5). The window
    // used to restart at `block.timestamp` for the combined amount, so *any* queue — and the only gate on the
    // path is `inventoryReleased != 0`, which a few tens of wei of shares satisfies — pushed the deadline of an
    // arbitrarily large outstanding burn out by a full day, once per block. That turns the linear stream this
    // section is about into an unbounded geometric tail: 36.8% of the queue survives every advertised deadline,
    // `T` stays ~1.6-1.8% above the design figure after a 10% redemption, and every bond quote in that window
    // issues that much more AMPS per dollar of collateral. The opening is therefore the **amount-weighted** one,
    //
    //     newStart = oldStart x P/(P + a) + now x a/(P + a)
    //
    // with `P` the pending amount and `a` the queue: the deadline moves in proportion to what the queue adds, so
    // a dust queue moves it by dust (`<= D x a/P` seconds) and a queue that doubles the outstanding amount moves
    // it half way. `newStart` lies between `oldStart` and `now` by construction, so it can never date the window
    // in the future and can never make an already-overdue queue un-due.

    /// @dev `keccak256("amplestocks.vault.pendingInventoryBurn")` — AMPS wei queued for the stream and not yet
    ///      burned.
    uint256 internal constant PENDING_BURN_SLOT = uint256(keccak256("amplestocks.vault.pendingInventoryBurn"));

    /// @dev `keccak256("amplestocks.vault.burnStreamStart")` — the **amount-weighted** opening of the current
    ///      window. Only a queue moves it; a settlement does not, so
    ///      `burnStreamStart() + REDEEM_BURN_STREAM_SECONDS` is the instant the pending amount is fully burned
    ///      and the dApp can show it as a deadline. A queue moves it in proportion to what it adds: see
    ///      {queueInventoryBurn}.
    uint256 internal constant BURN_STREAM_START_SLOT = uint256(keccak256("amplestocks.vault.burnStreamStart"));

    /// @dev `keccak256("amplestocks.vault.burnStreamLastSettle")` — where the line was last evaluated. Both a
    ///      queue and a settlement move it.
    uint256 internal constant BURN_STREAM_LAST_SETTLE_SLOT =
        uint256(keccak256("amplestocks.vault.burnStreamLastSettle"));

    /// @notice AMPS wei queued by redemptions and not yet burned.
    /// @return amount The pending amount.
    function pendingInventoryBurn() internal view returns (uint256 amount) {
        uint256 slot = PENDING_BURN_SLOT;
        assembly ("memory-safe") {
            amount := sload(slot)
        }
    }

    /// @notice The amount-weighted opening of the current stream window. Zero before the first redemption.
    /// @dev The pending amount is fully burned at `burnStreamStart() + Constants.REDEEM_BURN_STREAM_SECONDS`, and
    ///      a queue moves that deadline in proportion to what it adds ({queueInventoryBurn}).
    /// @return openedAt The window's opening.
    function burnStreamStart() internal view returns (uint256 openedAt) {
        uint256 slot = BURN_STREAM_START_SLOT;
        assembly ("memory-safe") {
            openedAt := sload(slot)
        }
    }

    /// @notice When the stream was last evaluated — by a settlement or by a queue.
    /// @return settledAt The last settlement.
    function burnStreamLastSettle() internal view returns (uint256 settledAt) {
        uint256 slot = BURN_STREAM_LAST_SETTLE_SLOT;
        assembly ("memory-safe") {
            settledAt := sload(slot)
        }
    }

    /// @notice What {settleBurnStream} would burn if it ran right now.
    ///
    /// @dev `due = now >= end ? pending : pending x (now - lastSettle) / (end - lastSettle)`, with
    ///      `end = windowStart + REDEEM_BURN_STREAM_SECONDS`, capped at the vault's idle AMPS balance.
    ///
    /// @dev **Why "remaining over remaining" rather than `pending x elapsed / D`.** The naive form restarts the
    ///      clock on every settlement, which turns a linear stream into a geometric decay: settled hourly it
    ///      retires ~63% of the amount in a day instead of all of it, and the residue never quite reaches zero.
    ///      Taking the remaining amount over the remaining time puts every settlement back on the same straight
    ///      line to `end`, so the burn completes on schedule however often it is settled — and a caller who
    ///      settles more often cannot slow it down, which matters because `checkpoint()` is permissionless.
    ///
    /// @dev The idle cap is what makes the stream safe against the one state it cannot control: the vault's AMPS
    ///      inventory is spendable — `place` commits it to ladders — so the queue can outrun the balance. Capping
    ///      at the balance means the stream burns what it can and keeps owing the rest, which
    ///      {pendingInventoryBurn} still reports and which the next settlement retires as inventory comes back
    ///      (a compound's buyback, a bond, the next rollout). Excluding the queue from `VaultPlacementLib`'s own
    ///      inventory bound would stop the shortfall arising at all; it was measured at 76 B against that
    ///      library's 67 B of EIP-170 headroom and does not fit, so the shortfall is carried here instead.
    /// @param amps The AMPS token.
    /// @return due The amount a settlement would burn.
    function burnStreamDue(address amps) public view returns (uint256 due) {
        (, due) = _burnStreamDue(amps);
    }

    /// @dev {burnStreamDue}'s two halves, which finding 3 is about: what the *schedule* owes at this instant, and
    ///      how much of that the vault's idle AMPS balance can actually pay.
    ///
    /// @dev **Why they have to be told apart** (audit fix wave 5, finding 3). {settleBurnStream} used to stamp
    ///      `lastSettle = now` before it knew whether anything had been burned, so a settlement the idle cap
    ///      truncated — or zeroed, which is the *steady* state, because the POL lives inside ladders and
    ///      `_placeLadder` does not exclude the queue — advanced the clock without retiring its slice. The line
    ///      then re-sloped the same amount over a shorter remaining time, and because `checkpoint()` is
    ///      permissionless and free, one call per block suppressed the burn for the whole window (a single call
    ///      collapsed the next settlement by 360x). The clock now moves only for time the stream was actually
    ///      paid for: see {settleBurnStream}.
    /// @param amps The AMPS token.
    /// @return due What the schedule owes, uncapped.
    /// @return burnable How much of it the idle AMPS balance covers.
    function _burnStreamDue(address amps) private view returns (uint256 due, uint256 burnable) {
        uint256 pending = pendingInventoryBurn();
        if (pending == 0) return (0, 0);

        uint256 end = burnStreamStart() + Constants.REDEEM_BURN_STREAM_SECONDS;
        if (block.timestamp >= end) {
            due = pending;
        } else {
            uint256 lastSettle = burnStreamLastSettle();
            // `lastSettle <= now < end` always: `lastSettle` is only ever written to `block.timestamp`, and the
            // amount-weighted opening {queueInventoryBurn} writes never moves forward past it.
            due = FullMath.mulDiv(pending, block.timestamp - lastSettle, end - lastSettle);
        }

        uint256 idle = IERC20(amps).balanceOf(address(this));
        burnable = due > idle ? idle : due;
    }

    /// @notice Burns the accrued portion of the stream and records the settlement.
    ///
    /// @dev Called first thing by `AmpsVault._checkpoint` — so every compound, bond, placement, genesis step and
    ///      permissionless `checkpoint()` drains it — and first thing by `AmpsVault.redeemProRata`, so a redemption
    ///      is measured against a supply the stream has already been settled into. It is a no-op when nothing is
    ///      pending, which is the state the protocol is in except in the day after a redemption.
    ///
    /// @dev Reads and writes three hashed slots and the AMPS balance, and calls `IAmps.burn`, which the ungated
    ///      path already does for the redeemer's own shares. No gate, no registry, no feed, no price:
    ///      `GuardSymmetry`'s step-4 storage proof is untouched.
    ///
    /// @dev **`burnStreamStart` is not touched here.** The window's deadline is a property of the queue, not of
    ///      who happened to settle it, so a settlement moves only `lastSettle` and the schedule stays the same
    ///      straight line to `burnStreamStart() + REDEEM_BURN_STREAM_SECONDS`.
    ///
    /// @dev **And `lastSettle` moves only when the slice was actually retired** (audit fix wave 5, finding 3).
    ///      `lastSettle` is the point the "remaining amount over the remaining time" line is re-anchored at, so
    ///      advancing it for time the idle cap stopped the stream paying for is what let a free permissionless
    ///      `checkpoint()` per block hold the burn back for a whole window. The stamp is therefore conditioned on
    ///      `burnable == due`: a settlement the cap truncated leaves the clock where it was, so the *next* one
    ///      owes the whole interval since the last settlement that was actually paid, and the queue still
    ///      completes on the same straight line to the same deadline once inventory comes back. The `now >= end`
    ///      branch is unchanged — it burns the whole pending amount as the idle balance permits and carries the
    ///      shortfall, which {pendingInventoryBurn} keeps reporting.
    /// @param amps The AMPS token.
    /// @return burned The amount actually burned, which is zero whenever the vault holds no idle AMPS.
    function settleBurnStream(address amps) public returns (uint256 burned) {
        uint256 pending = pendingInventoryBurn();
        if (pending == 0) return 0;

        (uint256 due, uint256 burnable) = _burnStreamDue(amps);
        if (burnable == due) _setBurnStreamLastSettle(block.timestamp);
        burned = burnable;
        if (burned == 0) return 0;

        // `pending` falls by what was *burned*, never by what was merely due: an amount the idle balance could not
        // cover is still owed, so `pendingInventoryBurn() == queued - drained` holds at every instant
        // (`invariant_r8_pendingBurnIsQueuedMinusDrained`).
        _setPendingInventoryBurn(pending - burned);
        IAmps(amps).burn(address(this), burned);
        emit IAmpsVault.Burn(burned, bytes32("redeemInventory"));
    }

    /// @notice Settles the stream and returns the supply that is left, in one call.
    ///
    /// @dev `AmpsVault.redeemProRata` needs exactly this pair and nothing else — settle, then read `T` — and
    ///      fusing them here rather than making the vault do both keeps two external calls out of a contract that
    ///      has 168 B of EIP-170 headroom. The ordering is the point: `T` must be read *after* the settlement, so
    ///      that a redemption divides by the supply the burn has already left behind and `previewRedeem` (which
    ///      settles the same amount in arithmetic) cannot drift from it.
    /// @param amps The AMPS token.
    /// @return supply `T` after the settlement.
    function settleAndSupply(address amps) public returns (uint256 supply) {
        settleBurnStream(amps);
        return IERC20(amps).totalSupply();
    }

    /// @notice The whole of `AmpsVault.previewRedeem`, in one call.
    ///
    /// @dev **Why the vault does not assemble this itself.** The preview is four steps — settle the stream in
    ///      arithmetic, read `T`, walk the ladder, run the pro-rata — and each one made from `AmpsVault` is an
    ///      external call with its own calldata encoding. Reached from here they are internal jumps inside one
    ///      library, which costs the vault one call instead of four and buys back the EIP-170 headroom revision 8
    ///      spent on the stream.
    ///
    /// @dev **`shares` is clamped to the post-settlement supply.** The mutating path gets that bound for free — a
    ///      redeemer can never hold more than `T`, and the settlement runs before any balance is touched — but a
    ///      view has no such bound, and `previewRedeem(totalSupply())`, which the solvency property GL-22 asks for,
    ///      would otherwise divide by a smaller number than it multiplies by and report a payout larger than the
    ///      vault can free.
    ///
    /// @dev **Nothing is passed as `addedAmps`, and that is what keeps the two paths wei-identical** (audit fix
    ///      wave 5, finding 4). {redemption} nets two things out of the AMPS inventory before the pro-rata: what
    ///      the unwind added, and whatever the burn stream is still owed. A view sees the *pre*-settlement world
    ///      — a balance that still holds the `due` about to be burned, and a pending figure that still counts it —
    ///      so subtracting neither leaves `balance - pending`, which is exactly what the mutating path reaches by
    ///      subtracting both from a balance the settlement has already reduced:
    ///      `(balance - due) - addedAmps - (pending - due) = balance - pending`. The settlement still shows up
    ///      here, in `supply`, where it belongs.
    /// @param ladder The vault's per-pool placement records.
    /// @param pools The vault's own `PoolKey` list.
    /// @param assetIndex The vault's 1-based asset index.
    /// @param assets The vault's registered non-AMPS assets, in registration order.
    /// @param poolManager The Uniswap v4 PoolManager.
    /// @param amps The AMPS token.
    /// @param shares The AMPS wei being previewed.
    /// @param redeemFeeBps The redemption fee, in bps.
    /// @return result The token list, the net amounts, the claim/idle split of each and the inventory released.
    function preview(
        mapping(PoolId => PlacementRecord[]) storage ladder,
        PoolKey[] storage pools,
        mapping(address => uint256) storage assetIndex,
        address[] storage assets,
        address poolManager,
        address amps,
        uint256 shares,
        uint16 redeemFeeBps
    ) public view returns (Redemption memory result) {
        uint256 due = burnStreamDue(amps);
        uint256 supply = IERC20(amps).totalSupply() - due;
        if (shares > supply) shares = supply;

        (uint256[] memory released, uint256 releasedAmps) =
            previewUnwind(ladder, pools, assetIndex, assets.length, poolManager, shares, supply);
        result = redemption(
            assets, poolManager, amps, shares, supply, redeemFeeBps, released, new uint256[](0), releasedAmps, 0
        );
    }

    /// @notice Queues `amount` into the stream, settling whatever had accrued first and restarting the window for
    ///         the combined amount.
    ///
    /// @dev The settle-first ordering is what makes the queue safe to call from anywhere: restarting the window
    ///      with an unsettled balance still in it would push an already-accrued burn back out, and a redeemer who
    ///      redeemed once an hour could keep the stream permanently at zero elapsed.
    ///
    /// @dev A new queue **re-opens one window for the whole pending amount** rather than stacking a second
    ///      schedule beside the first. Three slots cannot describe two schedules, and a per-queue schedule would
    ///      need unbounded state on the one path that must stay bounded. The benefit is that
    ///      `burnStreamStart() + D` is always the instant the whole queue is gone, which is the figure the dApp
    ///      shows and the only one a holder needs.
    ///
    /// @dev **The re-opening is amount-weighted** (audit fix wave 5, finding 2). It used to be
    ///      `burnStreamStart = block.timestamp` for the combined amount, which re-dated an arbitrarily large
    ///      outstanding burn by a full day for the price of a dust redemption — and a dust redemption is cheap:
    ///      the only gate on this path is `inventoryReleased != 0`, which the floor division satisfies at a few
    ///      tens of wei of shares. Repeated once a block that is not a rate limit on the burn, it is a switch that
    ///      turns it off: 36.8% of the queue survives every advertised deadline and `T` stays ~1.6-1.8% above the
    ///      design figure after a 10% redemption, which every bond quote in the window prices off. The new
    ///      opening is
    ///      ```
    ///      newStart = floor(oldStart x P / (P + a)) + floor(now x a / (P + a))
    ///      ```
    ///      — the two openings weighted by the amounts they carry. It is monotone in `a`: `a = 1 wei` against a
    ///      pending `P` moves the deadline by `(now - oldStart) x 1/(P + 1) <= D/P` seconds, and `a = P` moves it
    ///      exactly half way. It lies in `[oldStart, now]`, so the deadline can never be dated into the future
    ///      and an already-overdue queue stays overdue. The two `floor`s can lose one second between them, in the
    ///      protocol-favourable direction (earlier).
    ///
    /// @dev The settle-first ordering above is what makes the weighting honest: `P` is the *post-settlement*
    ///      pending amount, so time the stream has already been paid for does not get re-weighted into the new
    ///      window.
    /// @param amps The AMPS token.
    /// @param amount The AMPS wei to queue.
    /// @return burned What the settlement that preceded the queue burned.
    function queueInventoryBurn(address amps, uint256 amount) public returns (uint256 burned) {
        burned = settleBurnStream(amps);
        if (amount == 0) return burned;

        uint256 pendingBefore = pendingInventoryBurn();
        uint256 combined = pendingBefore + amount;
        _setPendingInventoryBurn(combined);
        _setBurnStreamStart(
            pendingBefore == 0
                ? block.timestamp
                : FullMath.mulDiv(burnStreamStart(), pendingBefore, combined)
                    + FullMath.mulDiv(block.timestamp, amount, combined)
        );
        _setBurnStreamLastSettle(block.timestamp);
    }

    /// @dev Writes the pending amount.
    function _setPendingInventoryBurn(uint256 value) private {
        uint256 slot = PENDING_BURN_SLOT;
        assembly ("memory-safe") {
            sstore(slot, value)
        }
    }

    /// @dev Writes the window's opening.
    function _setBurnStreamStart(uint256 value) private {
        uint256 slot = BURN_STREAM_START_SLOT;
        assembly ("memory-safe") {
            sstore(slot, value)
        }
    }

    /// @dev Writes the last settlement.
    function _setBurnStreamLastSettle(uint256 value) private {
        uint256 slot = BURN_STREAM_LAST_SETTLE_SLOT;
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
    /// @param inventoryReleased AMPS wei released from the vault's own inventory, queued into the burn stream
    ///        rather than burned in the redemption's own transaction (ruling U; {queueInventoryBurn}).
    struct Redemption {
        address[] tokens;
        uint256[] amounts;
        uint256[] fromClaims;
        uint256[] fromIdle;
        uint256 inventoryReleased;
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
            (address token, uint256 moved) = abi.decode(data, (address, uint256));
            _settleAbsorbed(poolManager, token, moved);
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

            // **The absorb is skipped, not attempted, in a frame that cannot afford it** (audit lead wave 5,
            // L-10). This runs at the exit of every entry point, `redeemProRata` included, and `_absorb` is three
            // bounded calls plus an `unlock` — up to ~650k of gas per asset against a probe that costs ~3k. On
            // the redemption path the whole tail after the payout has to fit inside the reserve
            // `Constants.REDEEM_PAYOUT_RESERVE_*` holds back, and sizing that reserve for `MAX_COLLATERALS`
            // *absorbs* would mean holding back tens of millions of gas the redemption then could not use. The
            // absorb is therefore conditioned on the frame: below `Constants.SWEEP_ABSORB_MIN_GAS` the balance
            // simply stays on the vault, where it is still counted in `A` and still paid out by redemption. The
            // probe and the {IAmpsVault-SweepResidue} disclosure below run either way, so a skipped absorb is
            // reported exactly like a refused one.
            if (gasleft() > Constants.SWEEP_ABSORB_MIN_GAS) _absorb(poolManager, token, balance);

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
    /// @dev **The one thing this cannot undo, and what now reports it** (audit lead wave 5, L-5). A token that
    ///      answers `balanceOf` for the probe and for `sync`, accepts the transfer, and then arranges for the
    ///      PoolManager to credit something other than what was moved — refusing `balanceOf` inside `settle`, or
    ///      simply calling `sync(currency)` itself from inside its own `transfer`, which is legal because v4's
    ///      `sync` is not `onlyWhenUnlocked` and re-snapshots the reserves the credit is measured against —
    ///      leaves that transfer sitting in the PoolManager uncredited. The transfer is outside the `unlock`, so
    ///      the `catch` cannot roll it back, and the vault's own balance is then zero, so {sweepClean}'s residue
    ///      probe sees nothing to report. {_settleAbsorbed} therefore compares the credit with the amount moved
    ///      and emits {IAmpsVault-SweepResidue} for the difference: the wei is still that token's own idle dust
    ///      (I12) and no other asset is touched, but it is now a disclosure rather than a silence.
    ///
    ///      The alternative — transferring inside the `unlock` — is what let a hostile token revert the whole
    ///      sweep in the first place, and re-`sync`ing immediately before `settle` (the lead's own suggestion) is
    ///      not available: v4 measures a settlement as `balanceOfSelf() - syncedReserves`, so a `sync` after the
    ///      transfer would make **every** credit zero rather than protecting one.
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
        try IPoolManager(poolManager).unlock(abi.encode(token, amount)) {} catch {}
        assembly ("memory-safe") {
            tstore(slot, 0)
        }
    }

    /// @dev The inside-the-unlock half of {_absorb}: credit whatever the transfer moved and mint the claim.
    ///      `settle` is a bounded low-level call because the PoolManager reads the token's own `balanceOf` inside
    ///      it, so a token that starves it costs its own absorb rather than the caller's frame; `mint` runs only
    ///      on a non-zero credit, so no delta is ever opened that this unlock could not close.
    /// @dev The credit is measured against `moved`, not assumed equal to it: see {_absorb} for the two ways a
    ///      token can make them disagree and why the difference is disclosed here rather than reverted.
    /// @param poolManager The Uniswap v4 PoolManager.
    /// @param token The asset whose transfer is waiting to be settled.
    /// @param moved The amount {_absorb} transferred into the PoolManager.
    function _settleAbsorbed(address poolManager, address token, uint256 moved) private {
        (bool ok, bytes memory returndata) =
            poolManager.call{gas: Constants.STOCK_TOKEN_PROBE_GAS * 4}(abi.encodeCall(IPoolManager.settle, ()));
        uint256 settled;
        if (ok && returndata.length >= 32) {
            assembly ("memory-safe") {
                settled := mload(add(returndata, 0x20))
            }
        }
        if (settled != 0) IPoolManager(poolManager).mint(address(this), Currency.wrap(token).toId(), settled);
        if (settled < moved) emit IAmpsVault.SweepResidue(token, moved - settled);
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
    ///      touches no token at all. A reserve is held back from the first attempt so that the second is always
    ///      affordable, however much gas the first one burns.
    ///
    /// @dev **The reserve is sized per asset** (audit fix, 2026-09-09). It used to be a flat 700,000 whose own
    ///      NatSpec claimed it covered "every asset the protocol can register", and it did not: the claims-only
    ///      unlock does one ERC-6909 `transfer` per asset at ~27.5k cold, so it needs ~900k at 32 assets and about
    ///      27.5k x `Constants.MAX_COLLATERALS` at the registry's ceiling (~1.8M when that ceiling was 66, ~1.0M at
    ///      the measured cap of 36). The fallback therefore ran out of gas in precisely the case it exists for — a hostile
    ///      constituent that burns the first attempt — and the *structurally ungated* redemption reverted, which
    ///      is the one outcome the whole three-fallback design is built to make impossible. The reserve is now
    ///      `REDEEM_PAYOUT_RESERVE_PER_ASSET_GAS x tokens.length + REDEEM_PAYOUT_RESERVE_FIXED_GAS`, and when the
    ///      frame cannot hold that plus a worthwhile attempt the ERC-20 leg is skipped outright rather than
    ///      started and abandoned: an attempt that cannot finish costs the redeemer the whole difference and pays
    ///      nobody, while the fallback pays every asset as a claim.
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
        uint256 reserve =
            Constants.REDEEM_PAYOUT_RESERVE_PER_ASSET_GAS * tokens.length + Constants.REDEEM_PAYOUT_RESERVE_FIXED_GAS;
        bool paid;

        if (gasleft() > reserve + Constants.REDEEM_PAYOUT_ATTEMPT_GAS) {
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
    ///      `released_j` is the position principal the unwind actually freed and is paid in full rather than
    ///      pro-rated, because it *is* the pro-rata slice: it came out of a position by removing
    ///      `floor(L x shares / supply)` of its liquidity.
    ///
    /// @dev **The vault's own AMPS inventory does not take `keepBps`, and the NatSpec used to say it did** (audit
    ///      lead, 2026-09-09). The figure is
    ///      ```
    ///      inventoryReleased = floor(inventory x shares / supply) + releasedAmps
    ///      ```
    ///      with **no** `(BPS - redeemFeeBps)` factor: the whole pro-rata slice is released rather than
    ///      `keepBps` of it. That is deliberate and it is the protocol-favourable direction — the fee on a
    ///      redemption is value the *remaining* holders keep, and inventory AMPS is worth zero in `A` by I5, so
    ///      retiring the larger number lowers `T` and raises NAV per share for them instead of leaving a retained
    ///      slice in a place where it is not counted. `previewRedeem` computes the identical expression, so the
    ///      preview and the payout still agree to the wei; only the sentence describing them was wrong.
    ///
    /// @dev **The figure is queued, not burned** (revision 8, ruling U). The arithmetic above is unchanged; what
    ///      changed is what `AmpsVault.redeemProRata` does with the answer. It calls {queueInventoryBurn} instead
    ///      of `IAmps.burn`, so `T` does not move inside the redeeming transaction and a split exit cannot divide
    ///      by a denominator its own earlier slices shrank. See the stream section above.
    ///
    /// @dev **AMPS the stream is already owed is not inventory** (audit fix wave 5, finding 4). `inventory` is a
    ///      balance, and once a redemption has queued part of that balance for burning the wei is spoken for: it
    ///      belongs to the queue, not to the next redeemer's pro-rata slice. Netting only `addedAmps` meant every
    ///      redemption inside the window re-sliced what earlier ones had already promised — an over-queue of
    ///      `pending x shares / T` each time, so a 50% exit taken in slices queued `I x ln 2` = +38.6% over the
    ///      pro-rata figure, and a cumulative exit past ~63% of supply made `pending` exceed every wei the vault
    ///      held, after which each `checkpoint()` drained the whole idle AMPS inventory. `pendingInventoryBurn()`
    ///      is therefore netted out too, saturating at zero, and the preview reaches the identical number from
    ///      the pre-settlement side (see {preview}).
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
    ///        `previewRedeem` passes zero: it is measuring a balance the unwind has not touched and a settlement
    ///        has not yet drained, so there is nothing to net (see {preview}).
    /// @return result The token list, the net amounts, the claim/idle split of each and the inventory released.
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
        // AMPS an earlier redemption already promised to the stream is not this one's to slice.
        uint256 promised = pendingInventoryBurn();
        if (promised != 0) inventory = inventory > promised ? inventory - promised : 0;
        result.inventoryReleased = FullMath.mulDiv(inventory, shares, supply) + releasedAmps;
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
                // **`record.amount` is deliberately *not* pro-rated here** (audit lead, 2026-09-08; re-measured
                // and re-affirmed as wave 5's lead L-13(b)). Every other removal decrements it, but this one runs
                // on the structurally ungated redemption floor, once per live cell, and the field lives in the
                // record's *second* slot: writing it costs a cold `SLOAD` plus a dirty `SSTORE` per cell. Taking
                // the lead moved the marginal cost of a live cell from **43,032 to 48,531** gas, which is
                // `48,531 x MAX_LIVE_CELLS + fixed = 25,206,709` against the 24,000,000 one-transaction bound
                // `test_e_gasPerLiveCellFitsTheRedemptionBudget` asserts (22,391,221 without it), and 26,234,209
                // against `test_r8_constituentCostAtTheCapFitsTheRedemptionBudget`'s (23,418,721 without it).
                // The disclosure is worth less than
                // the floor's headroom — and the floor may not be gated, rate-limited or split to make it fit —
                // so the field reads as "placed, less what the placement engine removed" and a redemption is the
                // one thing it does not follow. `docs/indexer.md` says so to the consumer.
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

        // §12 ruling F. The whole AMPS claim becomes an idle ERC-20 balance so that {redemption}'s pro-rata slice
        // of the vault's inventory is something the burn stream can actually retire — {settleBurnStream} burns an
        // ERC-20 balance and cannot burn a claim. The slice itself is `floor(inventory x shares / T)`, not the
        // claim, so a dust redemption still queues dust.
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
