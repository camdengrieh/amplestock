// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title Constants
/// @notice Every hard-coded bound in Amplestocks, in one place. These are the *bands*, not the values: governance
///         moves a parameter inside its band through the timelock, and can never move it outside. Widening a band
///         means new bytecode plus a migration, which is the point.
///
/// @dev Naming convention, enforced by review:
///      - `*_DEFAULT`  the launch value from the confirmed launch-parameter table. Deployment scripts read these;
///                     no contract enforces them after genesis.
///      - `*_MIN` / `*_MAX`  the hard band. The consuming contract `require`s membership on every setter, and the
///                     interface exposes a view getter for each so the dApp and the governance drills can read the
///                     bound rather than restate it.
///      - `*_CAP`      a one-sided hard band (`<= CAP`, no lower bound beyond zero).
///
/// @dev Units: `Bps` is basis points of 10,000 (`BPS`); `X18` is 1e18 fixed point; `Pips` is hundredths of a basis
///      point, the unit Uniswap v4 charges LP fees in (`MAX_LP_FEE == 1_000_000` pips == 100%); seconds are plain
///      `uint32` timestamps; AMPS amounts are 18-decimal wei.
library Constants {
    // -------------------------------------------------------------------------------------------------------------
    // Scales
    // -------------------------------------------------------------------------------------------------------------

    /// @notice Basis-point scale. 10,000 bps == 100%.
    uint256 internal constant BPS = 10_000;

    /// @notice 1e18 fixed-point scale.
    uint256 internal constant WAD = 1e18;

    /// @notice Chainlink answer scale on Robinhood Chain: 8 decimals.
    uint256 internal constant USD_PRICE_SCALE = 1e8;

    /// @notice Uniswap v4's fee unit: hundredths of a basis point. One bp is 100 pips.
    uint24 internal constant PIPS_PER_BPS = 100;

    /// @notice Uniswap v4's maximum LP fee, in pips (100%). Every fee the hook returns is far below this.
    uint24 internal constant MAX_LP_FEE = 1_000_000;

    /// @notice Seconds in an hour, the period the reference rate limit is quoted over.
    uint32 internal constant ONE_HOUR = 3600;

    /// @notice Seconds in a day.
    uint32 internal constant ONE_DAY = 86_400;

    // -------------------------------------------------------------------------------------------------------------
    // Supply and genesis (immutable: `S0` and the split are not governable at all)
    // -------------------------------------------------------------------------------------------------------------

    /// @notice `S0`: the entire genesis supply, minted exactly once. 5,000 AMPS.
    uint256 internal constant S0 = 5000e18;

    /// @notice Team tranche: 5% of `S0` into an OZ `VestingWallet`, 2-month linear, no cliff.
    uint256 internal constant TEAM_SHARES = 250e18;

    /// @notice Protocol-owned-liquidity tranche: 95% of `S0`, held by the vault as ask inventory.
    uint256 internal constant POL_SHARES = 4750e18;

    /// @notice Team vest length: 60 days, linear, no cliff.
    uint32 internal constant TEAM_VEST_SECONDS = 60 * ONE_DAY;

    /// @notice The divide-by-zero guard in `navPerShare = (A + 1) / (T + VIRTUAL_SHARES)`. 1e3 wei of AMPS, i.e.
    ///         1e-15 AMPS: enough to make the denominator non-zero in every reachable state (I22) and far too small
    ///         to matter against a 5,000e18 supply. There is no genesis burn because there is no NAV mint.
    uint256 internal constant VIRTUAL_SHARES = 1e3;

    /// @notice ERC-4626 decimals offset used by `AmpsStaking` (xAMPS), matching `VIRTUAL_SHARES = 10**3`.
    uint8 internal constant STAKING_DECIMALS_OFFSET = 3;

    /// @notice Seed ask placed in each spoke at genesis, in bps of the POL tranche. 1% == 47.5 AMPS per spoke.
    uint16 internal constant SPOKE_SEED_BPS_DEFAULT = 100;

    /// @notice Lower bound of the governed `spokeSeedBps`.
    uint16 internal constant SPOKE_SEED_BPS_MIN = 10;

    /// @notice Upper bound of the governed `spokeSeedBps`. 10% of the POL tranche into one new spoke is already an
    ///         aggressive registration; anything larger should be several proposals.
    uint16 internal constant SPOKE_SEED_BPS_MAX = 1000;

    // -------------------------------------------------------------------------------------------------------------
    // Fees (48 h timelock)
    // -------------------------------------------------------------------------------------------------------------

    /// @notice Launch `sellFeeBps`: 5% on every AMPS-in swap in all 32 pools, less any rotation credit.
    uint16 internal constant SELL_FEE_BPS_DEFAULT = 500;

    /// @notice Hard floor of `sellFeeBps`. 1%.
    uint16 internal constant SELL_FEE_BPS_MIN = 100;

    /// @notice Hard ceiling of `sellFeeBps`. 6%.
    uint16 internal constant SELL_FEE_BPS_MAX = 600;

    /// @notice Launch buy fee in the two entry pools (`AMPS/WETH`, `AMPS/USDG`). 30 bp.
    uint16 internal constant BUY_FEE_BPS_ENTRY_DEFAULT = 30;

    /// @notice Hard floor of an entry pool's buy fee.
    uint16 internal constant BUY_FEE_BPS_ENTRY_MIN = 5;

    /// @notice Hard ceiling of an entry pool's buy fee.
    uint16 internal constant BUY_FEE_BPS_ENTRY_MAX = 100;

    /// @notice Launch buy fee in a spoke. 5 bp.
    uint16 internal constant BUY_FEE_BPS_SPOKE_DEFAULT = 5;

    /// @notice Launch buy fee in a high-volatility spoke (annualised sigma above 60%). 10 bp.
    uint16 internal constant BUY_FEE_BPS_SPOKE_HIGH_VOL_DEFAULT = 10;

    /// @notice Hard floor of a spoke's buy fee.
    uint16 internal constant BUY_FEE_BPS_SPOKE_MIN = 1;

    /// @notice Hard ceiling of a spoke's buy fee.
    uint16 internal constant BUY_FEE_BPS_SPOKE_MAX = 50;

    /// @notice Launch `redeemFeeBps`: the pro-rata floor exit costs 1%, paid to the remaining holders.
    uint16 internal constant REDEEM_FEE_BPS_DEFAULT = 100;

    /// @notice Hard ceiling of `redeemFeeBps`. 5%. There is no floor: governance may set it to zero.
    uint16 internal constant REDEEM_FEE_BPS_MAX = 500;

    /// @notice Launch `burnBps`: 10% of the AMPS-side fees left after the creator and staker slices is burned.
    uint16 internal constant BURN_BPS_DEFAULT = 1000;

    /// @notice Hard ceiling of `burnBps`. 25%.
    uint16 internal constant BURN_BPS_MAX = 2500;

    /// @notice Launch `stakerBps`: 30% of the AMPS-side fees are streamed to xAMPS.
    uint16 internal constant STAKER_BPS_DEFAULT = 3000;

    /// @notice Hard ceiling of `stakerBps`. 50%.
    uint16 internal constant STAKER_BPS_MAX = 5000;

    /// @notice The creator fee at genesis: 100 bp of sell volume, carved out of `sellFeeBps`, never added on top.
    /// @dev The whole schedule is immutable. There is no setter, no band and no governance path that can extend,
    ///      restart or enlarge it; only the current `creator` may reassign the destination address.
    uint16 internal constant CREATOR_FEE_BPS = 100;

    /// @notice The creator fee decays linearly to zero over 30 days from genesis, then is structurally zero.
    uint32 internal constant CREATOR_DECAY_SECONDS = 30 * ONE_DAY;

    // -------------------------------------------------------------------------------------------------------------
    // Staking (48 h timelock)
    // -------------------------------------------------------------------------------------------------------------

    /// @notice Launch `rewardStreamSeconds`: notified rewards vest into xAMPS linearly over 24 h, which is what
    ///         makes a stake/unstake sandwich around `compound()` worthless.
    uint32 internal constant REWARD_STREAM_SECONDS_DEFAULT = 24 * ONE_HOUR;

    /// @notice Hard floor of `rewardStreamSeconds`. 1 h.
    uint32 internal constant REWARD_STREAM_SECONDS_MIN = ONE_HOUR;

    /// @notice Hard ceiling of `rewardStreamSeconds`. 7 d.
    uint32 internal constant REWARD_STREAM_SECONDS_MAX = 7 * ONE_DAY;

    // -------------------------------------------------------------------------------------------------------------
    // Bonds (48 h timelock for parameters, 7 d for the collateral set and the policy pointer)
    // -------------------------------------------------------------------------------------------------------------

    /// @notice Launch base discount `dBase`: 12.5%.
    uint16 internal constant BOND_D_BASE_BPS_DEFAULT = 1250;

    /// @notice Launch discount floor `dMin`: 10%.
    uint16 internal constant BOND_D_MIN_BPS_DEFAULT = 1000;

    /// @notice Launch discount ceiling `dMax`: 15%.
    uint16 internal constant BOND_D_MAX_BPS_DEFAULT = 1500;

    /// @notice Hard floor of every discount parameter. 5%.
    uint16 internal constant DISCOUNT_BPS_MIN = 500;

    /// @notice Hard ceiling of every discount parameter. 25%.
    uint16 internal constant DISCOUNT_BPS_MAX = 2500;

    /// @notice Launch `k_w`: discount added per unit of index deficit, 1e18 fixed point. 0.5 at launch, so a name
    ///         at half its target weight earns +250 bp of discount before clamping.
    uint64 internal constant BOND_K_WEIGHT_X18_DEFAULT = 0.5e18;

    /// @notice Launch `k_c`: discount removed per unit of epoch fill, 1e18 fixed point. 0.25 at launch, so a full
    ///         epoch removes 250 bp before clamping.
    uint64 internal constant BOND_K_FILL_X18_DEFAULT = 0.25e18;

    /// @notice Hard ceiling on either bond coefficient. Beyond 2.0 the clamp to `[dMin, dMax]` binds everywhere and
    ///         the term stops being a control.
    uint64 internal constant BOND_COEFFICIENT_X18_MAX = 2e18;

    /// @notice Launch per-market capacity: 50 bp of `Amps.totalSupply()` per 6-hour epoch.
    uint16 internal constant BOND_CAP_BPS_PER_EPOCH_DEFAULT = 50;

    /// @notice Hard ceiling of `capBpsPerEpoch`. 200 bp of total supply per epoch, per market.
    uint16 internal constant BOND_CAP_BPS_PER_EPOCH_MAX = 200;

    /// @notice Launch global capacity: 200 bp of `Amps.totalSupply()` per rolling day, across all markets.
    uint16 internal constant BOND_DAILY_CAP_BPS_DEFAULT = 200;

    /// @notice Hard ceiling of `dailyCapBps`. 500 bp of total supply per day.
    uint16 internal constant BOND_DAILY_CAP_BPS_MAX = 500;

    /// @notice Launch `epochSeconds`: 6 h.
    uint32 internal constant BOND_EPOCH_SECONDS_DEFAULT = 6 * ONE_HOUR;

    /// @notice Hard floor of `epochSeconds`. 1 h.
    uint32 internal constant BOND_EPOCH_SECONDS_MIN = ONE_HOUR;

    /// @notice Hard ceiling of `epochSeconds`. 7 d.
    uint32 internal constant BOND_EPOCH_SECONDS_MAX = 7 * ONE_DAY;

    /// @notice Launch `vestSeconds`: 12 h linear, no cliff.
    uint32 internal constant BOND_VEST_SECONDS_DEFAULT = 12 * ONE_HOUR;

    /// @notice Hard floor of `vestSeconds`. 1 h.
    uint32 internal constant BOND_VEST_SECONDS_MIN = ONE_HOUR;

    /// @notice Hard ceiling of `vestSeconds`. 7 d.
    uint32 internal constant BOND_VEST_SECONDS_MAX = 7 * ONE_DAY;

    /// @notice Launch `minAccretionBps`: every bond must issue at or above `navPerShare x (1 + 50 bp)`, so a bond
    ///         is accretive even when the market discount has vanished.
    uint16 internal constant MIN_ACCRETION_BPS_DEFAULT = 50;

    /// @notice Hard ceiling of `minAccretionBps`. Above 500 bp the floor binds so hard that no bond ever fills.
    uint16 internal constant MIN_ACCRETION_BPS_MAX = 500;

    /// @notice Launch stale-feed haircut in the Regular session: none.
    uint16 internal constant H_SESSION_REGULAR_BPS_DEFAULT = 0;

    /// @notice Launch stale-feed haircut in Pre/Post: 50 bp.
    uint16 internal constant H_SESSION_PRE_POST_BPS_DEFAULT = 50;

    /// @notice Launch stale-feed haircut Overnight: 150 bp.
    uint16 internal constant H_SESSION_OVERNIGHT_BPS_DEFAULT = 150;

    /// @notice Launch stale-feed haircut when Closed (weekends, holidays): 300 bp. This is the modelled bound on
    ///         weekend gap exposure for the bonded amount.
    uint16 internal constant H_SESSION_CLOSED_BPS_DEFAULT = 300;

    /// @notice Hard ceiling of any `h_session` entry. 10%.
    uint16 internal constant H_SESSION_BPS_MAX = 1000;

    /// @notice Hard ceiling on the number of bond collaterals: `MAX_CONSTITUENTS` plus WETH and USDG.
    uint16 internal constant MAX_COLLATERALS = MAX_CONSTITUENTS + 2;

    // -------------------------------------------------------------------------------------------------------------
    // Reference price and oracle gate (48 h timelock; feed addresses and pointers 7 d)
    // -------------------------------------------------------------------------------------------------------------

    /// @notice Launch `refUpRateBps`: `P_ref` may rise at most 10% per hour. Downward moves are immediate.
    uint16 internal constant REF_UP_RATE_BPS_DEFAULT = 1000;

    /// @notice Hard floor of `refUpRateBps`. 1% per hour.
    uint16 internal constant REF_UP_RATE_BPS_MIN = 100;

    /// @notice Hard ceiling of `refUpRateBps`. 50% per hour.
    uint16 internal constant REF_UP_RATE_BPS_MAX = 5000;

    /// @notice The period `refUpRateBps` is quoted over: one hour. Not governable.
    uint32 internal constant REF_UP_RATE_PERIOD = ONE_HOUR;

    /// @notice Launch `refDivergenceBps`: the `AMPS/USDG` hub and `AMPS/WETH x ETH/USD` must agree within 5%, or
    ///         the reference falls back to NAV and the breaker flags `REF_DIVERGED`.
    uint16 internal constant REF_DIVERGENCE_BPS_DEFAULT = 500;

    /// @notice Hard floor of `refDivergenceBps`. Below 1% ordinary spreads would trip it constantly.
    uint16 internal constant REF_DIVERGENCE_BPS_MIN = 100;

    /// @notice Hard ceiling of `refDivergenceBps`. 20%.
    uint16 internal constant REF_DIVERGENCE_BPS_MAX = 2000;

    /// @notice Launch TWAP window: 30 minutes, matching `TruncatedOracleLib.TWAP_WINDOW`.
    uint32 internal constant TWAP_WINDOW_DEFAULT = 1800;

    /// @notice Hard floor of the TWAP window. 5 minutes.
    uint32 internal constant TWAP_WINDOW_MIN = 300;

    /// @notice Hard ceiling of the TWAP window. 2 hours.
    uint32 internal constant TWAP_WINDOW_MAX = 7200;

    /// @notice Launch per-block truncation cap for the observation ring. Calibrated in Phase 0 from 7 days of
    ///         sampled cadence; this placeholder is the value the Phase 1 gas baselines were taken at.
    int24 internal constant MAX_TICK_MOVE_PER_BLOCK_DEFAULT = 200;

    /// @notice Hard floor of `maxTickMovePerBlock`. A zero cap would freeze the oracle; 10 ticks is 0.1%.
    int24 internal constant MAX_TICK_MOVE_PER_BLOCK_MIN = 10;

    /// @notice Hard ceiling of `maxTickMovePerBlock`. Beyond ~20% per block the truncation stops bounding anything
    ///         useful (I25).
    int24 internal constant MAX_TICK_MOVE_PER_BLOCK_MAX = 2000;

    /// @notice Layer A: no block and no observation for this long trips the watchdog. 1 hour.
    uint32 internal constant GRACE_SECONDS_DEFAULT = ONE_HOUR;

    /// @notice Hard floor of `GRACE`. 5 minutes.
    uint32 internal constant GRACE_SECONDS_MIN = 300;

    /// @notice Hard ceiling of `GRACE`. 24 hours.
    uint32 internal constant GRACE_SECONDS_MAX = ONE_DAY;

    /// @notice Layer A: the expected worst-case inter-block gap on a 100 ms chain. Placeholder pending the Phase 0
    ///         7-day cadence sample.
    uint32 internal constant GAP_SECONDS_DEFAULT = 120;

    /// @notice Hard ceiling of `GAP_SECONDS`. It must stay well inside `GRACE`.
    uint32 internal constant GAP_SECONDS_MAX = 1800;

    /// @notice Layer C freshness multiplier in the Regular session, in hundredths: 1.5 x heartbeat.
    uint16 internal constant FRESHNESS_MULTIPLIER_REGULAR_DEFAULT = 150;

    /// @notice Layer C freshness multiplier in Pre/Post, in hundredths: 3 x heartbeat.
    uint16 internal constant FRESHNESS_MULTIPLIER_PRE_POST_DEFAULT = 300;

    /// @notice Layer C freshness multiplier Overnight, in hundredths: 6 x heartbeat.
    uint16 internal constant FRESHNESS_MULTIPLIER_OVERNIGHT_DEFAULT = 600;

    /// @notice Hard floor of a freshness multiplier: 1.0 x heartbeat.
    uint16 internal constant FRESHNESS_MULTIPLIER_MIN = 100;

    /// @notice Hard ceiling of a freshness multiplier: 24 x heartbeat. The Closed session disables the check
    ///         entirely rather than using a multiplier.
    uint16 internal constant FRESHNESS_MULTIPLIER_MAX = 2400;

    /// @notice Layer C: a single-round move larger than this arms the two-confirmation rule. 10%.
    uint16 internal constant ANSWER_JUMP_BPS = 1000;

    /// @notice Layer C: how long an unconfirmed jump is held before it is adopted without a second agreeing round.
    ///         1 hour. A real 10% move must not be held back for ever by an aggregator that stops publishing.
    uint32 internal constant ANSWER_CONFIRM_SECONDS_DEFAULT = 3600;

    /// @notice Hard floor of the two-confirmation escape window. 5 minutes.
    uint32 internal constant ANSWER_CONFIRM_SECONDS_MIN = 300;

    /// @notice Hard ceiling of the two-confirmation escape window. 24 hours, the RDD heartbeat of every Robinhood
    ///         Chain equity feed: holding a jump longer than one whole heartbeat is indistinguishable from a dead
    ///         feed and is handled by the freshness bound instead.
    uint32 internal constant ANSWER_CONFIRM_SECONDS_MAX = 86_400;

    /// @notice Hard floor of a per-feed heartbeat. 60 s: the fastest publication cadence any Chainlink feed the
    ///         protocol could adopt, and low enough that a future sub-minute feed needs no new bytecode.
    uint32 internal constant FEED_HEARTBEAT_SECONDS_MIN = 60;

    /// @notice Hard ceiling of a per-feed heartbeat. 86,400 s, exactly the RDD heartbeat of every Robinhood Chain
    ///         equity feed.
    uint32 internal constant FEED_HEARTBEAT_SECONDS_MAX = 86_400;

    /// @notice Layer E: the divergence breaker trips above this deviation. 5%.
    uint16 internal constant DIVERGENCE_BPS_DEFAULT = 500;

    /// @notice Hard ceiling of the breaker threshold. 20%.
    uint16 internal constant DIVERGENCE_BPS_MAX = 2000;

    /// @notice Layer E: the deviation must persist this long before `DIVERGED` latches. 60 s.
    uint32 internal constant DIVERGENCE_SUSTAIN_SECONDS_DEFAULT = 60;

    /// @notice Hard ceiling of the breaker's sustain window. 1 hour.
    uint32 internal constant DIVERGENCE_SUSTAIN_SECONDS_MAX = ONE_HOUR;

    /// @notice Layer D: a pending `effectiveAt` within this distance of now freezes the constituent. +/- 30 min.
    uint32 internal constant CORPORATE_ACTION_WINDOW_DEFAULT = 1800;

    /// @notice Hard ceiling of the corporate-action window. 24 hours.
    uint32 internal constant CORPORATE_ACTION_WINDOW_MAX = ONE_DAY;

    /// @notice Gas forwarded to every bounded `staticcall` into a Stock Token (`uiMultiplier`, `oraclePaused`,
    ///         `isBlocked`, `effectiveAt`). A hostile or upgraded issuer implementation cannot grief a swap or a
    ///         placement by burning gas: the call is capped and a failure is read as "unknown", not as a revert.
    uint256 internal constant STOCK_TOKEN_PROBE_GAS = 50_000;

    /// @notice The largest `uiMultiplier()` step the hook treats as a dividend reinvestment rather than a corporate
    ///         action. 2%: above this the constituent is frozen instead of fee-captured.
    uint16 internal constant DIVIDEND_STEP_BPS_MAX = 200;

    /// @notice Share of a detected dividend step converted into an asymmetric capture fee: 0.8 x delta.
    uint16 internal constant DIVIDEND_CAPTURE_NUMERATOR_BPS = 8000;

    /// @notice Half-life of the dividend capture fee. 300 s.
    uint32 internal constant DIVIDEND_CAPTURE_HALF_LIFE = 300;

    // -------------------------------------------------------------------------------------------------------------
    // Hook fee shape (48 h timelock; Phase 3 consumes these, Phase 2 only exposes them)
    // -------------------------------------------------------------------------------------------------------------

    /// @notice Absolute floor on the fee the hook returns, in bps. 3 bp.
    uint16 internal constant F_MIN_BPS = 3;

    /// @notice Cap on the dynamic component when the gate is GREEN. 300 bp.
    uint16 internal constant DYN_CAP_NORMAL_BPS = 300;

    /// @notice Cap on the dynamic component when the gate is DEGRADED, DIVERGED or WATCHDOG. 1,000 bp.
    uint16 internal constant DYN_CAP_DEGRADED_BPS = 1000;

    /// @notice Cap on the dynamic component during band escalation (beyond the inner band, inside the rail).
    uint16 internal constant DYN_CAP_ESCALATION_BPS = 2000;

    /// @notice Floor added to the dynamic component while the gate is not GREEN: a degraded gate raises the fee, it
    ///         never reverts a swap (I15).
    uint16 internal constant FROZEN_FEE_FLOOR_BPS = 100;

    /// @notice Cap on the volatility component `f_vol = k_vol x sigma^2`. 100 bp.
    uint16 internal constant F_VOL_CAP_BPS = 100;

    /// @notice Maximum surge fee, armed after every placement, session open, multiplier step and reference jump
    ///         above 25 bp. 500 bp.
    uint16 internal constant SURGE_MAX_BPS = 500;

    /// @notice Surge half-life. 60 s.
    uint32 internal constant SURGE_HALF_LIFE = 60;

    /// @notice Reference jump that arms the surge. 25 bp.
    uint16 internal constant SURGE_REF_JUMP_BPS = 25;

    /// @notice Session fee add-on in the Regular session (stock legs only).
    uint16 internal constant F_SESSION_REGULAR_BPS = 0;

    /// @notice Session fee add-on in Pre/Post.
    uint16 internal constant F_SESSION_PRE_POST_BPS = 5;

    /// @notice Session fee add-on Overnight.
    uint16 internal constant F_SESSION_OVERNIGHT_BPS = 10;

    /// @notice Session fee add-on when Closed.
    uint16 internal constant F_SESSION_CLOSED_BPS = 25;

    /// @notice Spoke inner band half-width in the Regular session, in ticks.
    int24 internal constant INNER_BAND_REGULAR_TICKS = 200;

    /// @notice Spoke inner band half-width in Pre/Post, in ticks.
    int24 internal constant INNER_BAND_PRE_POST_TICKS = 300;

    /// @notice Spoke inner band half-width Overnight, in ticks.
    int24 internal constant INNER_BAND_OVERNIGHT_TICKS = 500;

    /// @notice Spoke inner band half-width when Closed, in ticks, before the per-closed-hour widening.
    int24 internal constant INNER_BAND_CLOSED_TICKS = 770;

    /// @notice Extra inner-band ticks per hour the market has been closed.
    int24 internal constant INNER_BAND_CLOSED_TICKS_PER_HOUR = 25;

    /// @notice Hard ceiling on the spoke inner band, in ticks. Monotone non-decreasing in closedness (I19).
    int24 internal constant INNER_BAND_MAX_TICKS = 1500;

    /// @notice Spoke outer rail floor, in ticks: the rail is `max(3 x innerBand, 800)`.
    int24 internal constant OUTER_RAIL_MIN_TICKS = 800;

    /// @notice Multiple of the inner band that sets the spoke outer rail.
    int24 internal constant OUTER_RAIL_BAND_MULTIPLE = 3;

    /// @notice Entry-pool outer rail, in ticks: +/-22% per window, so price discovery is never reverted inside it.
    int24 internal constant OUTER_RAIL_ENTRY_TICKS = 2000;

    /// @notice The highest total fee the hook can ever return, in bps: `SELL_FEE_BPS_MAX + DYN_CAP_ESCALATION_BPS`.
    ///         26% is far below `MAX_LP_FEE`, which is what invariant I16 asserts.
    uint16 internal constant TOTAL_FEE_BPS_MAX = SELL_FEE_BPS_MAX + DYN_CAP_ESCALATION_BPS;

    /// @notice The mined hook address must satisfy `address & 0x3FFF == HOOK_FLAGS`:
    ///         `BEFORE_INITIALIZE | AFTER_INITIALIZE | BEFORE_ADD_LIQUIDITY | BEFORE_SWAP | AFTER_SWAP`.
    uint16 internal constant HOOK_FLAGS = 0x38C0;

    /// @notice The mask `HOOK_FLAGS` is compared under: Uniswap v4's whole 14-bit permission field. Named here so
    ///         the mining script, the deployment assertion and the permission test all read the same number.
    /// @dev Equal to `Hooks.ALL_HOOK_MASK`. Restated rather than imported because `04_MineHook.s.sol` and the CI
    ///      re-verification run against a compiled artefact, not against v4-core's source.
    uint160 internal constant HOOK_ADDRESS_MASK = 0x3FFF;

    // -------------------------------------------------------------------------------------------------------------
    // Fee-law coefficients (Phase 3; `docs/phase3-state-model.md` §10 ruling 5)
    // -------------------------------------------------------------------------------------------------------------
    //
    // Ruling 5: `k_vol`, `k_dev`, `F_WALL_BPS` and `lambda` live in the **pointer-upgradeable** `FeePolicy`, with
    // their hard bands here. The values below are what `FeePolicy` ships with — it reads them from this file rather
    // than restating them as literals, exactly like every other governed number — and the `_MIN`/`_MAX` pairs are
    // what a replacement policy may never step outside without new `AmpsHook` bytecode. They are Phase 0
    // placeholders: the cadence and volatility sample recalibrates them, and recalibration is a pointer swap.

    /// @notice `k_vol`: the coefficient on EWMA realised variance in `f_vol = k_vol x sigma^2`, 1e18 fixed point.
    /// @dev Units, stated once: `AmpsHook` writes `FeeInput.varianceX18 = EWMA(d^2) x 1e18` with `d` the raw pool
    ///      tick change of one swap (1 tick ~ 1 bp), lambda 0.98 per swap; `FeePolicy` computes
    ///      `f_vol_bps = K_VOL_X18 x varianceX18 / 1e36`, capped at `F_VOL_CAP_BPS`. At 5e15 that is 1 bp at a
    ///      per-swap sigma of ~14 ticks and the 100 bp cap at ~141 ticks (`5e15 x 141^2 x 1e18 / 1e36` ~ 99 bp),
    ///      which is a violently volatile pool by construction. The field is `uint128` so that the cap is
    ///      reachable (`141^2 x 1e18` ~ 2e22 does not fit 64 bits).
    uint256 internal constant K_VOL_X18 = 5e15;

    /// @notice Hard floor of `k_vol`. Below 1e14 the volatility term is structurally zero at any reachable
    ///         variance, which is what setting the policy's cap to zero is for.
    uint256 internal constant K_VOL_X18_MIN = 1e14;

    /// @notice Hard ceiling of `k_vol`. Above 1e17 the 100 bp cap binds at a ~3-tick sigma and the term stops
    ///         being a control at all.
    uint256 internal constant K_VOL_X18_MAX = 1e17;

    /// @notice `k_dev`: the coefficient on the squared deviation inside the inner band,
    ///         `f_dev = K_DEV_BPS x dev^2 / 1e4` with `dev` in ticks.
    /// @dev 25 puts `f_dev` at exactly 100 bp at the 200-tick Regular band edge, where the quadratic ramp to the
    ///      wall takes over.
    uint16 internal constant K_DEV_BPS = 25;

    /// @notice Hard floor of `k_dev`. Zero would delete the deviation term; 1 is the smallest law that still bites.
    uint16 internal constant K_DEV_BPS_MIN = 1;

    /// @notice Hard ceiling of `k_dev`. At 100 the band edge already costs 400 bp, past `DYN_CAP_NORMAL_BPS`, so
    ///         the clamp rather than the law would be setting the fee everywhere.
    uint16 internal constant K_DEV_BPS_MAX = 100;

    /// @notice `f_wall`: the fee the quadratic ramp reaches at the outer rail, in bps. 1,500.
    /// @dev Between band and rail the law is `f_inner + (F_WALL_BPS - f_inner) x (dev - band)^2 / (rail - band)^2`.
    ///      It is a wall, not a clamp: the fee climbs, the swap is still accepted, and only a deviation-increasing
    ///      swap that *begins* beyond the rail is refused (I15, ruling 2).
    uint16 internal constant F_WALL_BPS = 1500;

    /// @notice Hard floor of `f_wall`. Below `FROZEN_FEE_FLOOR_BPS` the ramp would slope downward into the rail.
    uint16 internal constant F_WALL_BPS_MIN = 100;

    /// @notice Hard ceiling of `f_wall`, equal to `DYN_CAP_ESCALATION_BPS`: the wall may reach the escalation cap
    ///         and never exceed it, so `base + dyn <= TOTAL_FEE_BPS_MAX` holds by construction (I16).
    uint16 internal constant F_WALL_BPS_MAX = DYN_CAP_ESCALATION_BPS;

    /// @notice `lambda`: the EWMA decay on realised variance, 1e18 fixed point. 0.98.
    /// @dev `varianceX18 = (LAMBDA_X18 x varianceX18 + (1e18 - LAMBDA_X18) x d^2 x 1e18) / 1e18` on the raw tick
    ///      delta `d`, saturating at `type(uint64).max`. A ~35-swap memory.
    uint64 internal constant LAMBDA_X18 = 0.98e18;

    /// @notice Hard floor of `lambda`. Below 0.5 the estimator is little more than the last observation squared.
    uint64 internal constant LAMBDA_X18_MIN = 0.5e18;

    /// @notice Hard ceiling of `lambda`. At 1e18 the estimator would never update again.
    uint64 internal constant LAMBDA_X18_MAX = 0.999e18;

    /// @notice How often `afterSwap` may refresh a pool's cached gate, band, rail and fair tick. 60 s.
    /// @dev `beforeSwap` reads nothing outside the hook except the pure fee policy; everything external — the gate,
    ///      the registry, the feeds, the hub TWAP and the `uiMultiplier()` probe — is pulled here, at most once per
    ///      pool per this interval, and a refresh failure is a flag (`gateFlags` bit2) rather than a revert.
    uint32 internal constant GATE_CACHE_SECONDS_DEFAULT = 60;

    /// @notice How stale that cache may be before `beforeSwap` stops trusting it. 900 s.
    /// @dev Past this, the fee is computed from the **most conservative** values for the pool's class — the widest
    ///      band, `DYN_CAP_DEGRADED_BPS`, and `FROZEN_FEE_FLOOR_BPS` on the dynamic part. It still never reverts a
    ///      swap (I15).
    uint32 internal constant GATE_CACHE_MAX_AGE = 900;

    /// @notice The EIP-1153 transient slot holding the same-transaction rotation credit, in AMPS wei.
    /// @dev One slot, hard-coded, in the hook. Transient storage is zero at the start of every transaction by EVM
    ///      rule, which is what makes invariant I26 — no credit ever crosses a transaction boundary — structural
    ///      rather than enforced. Credited in `afterSwap` from the **realised** AMPS delta of a buy; consumed in
    ///      `beforeSwap` by an exact-input sell, blended and rounded up.
    bytes32 internal constant ROTATION_CREDIT_SLOT = keccak256("amplestocks.hook.ROTATION_CREDIT");

    // -------------------------------------------------------------------------------------------------------------
    // Ladder and rollout (48 h timelock; future placements only, never a reshape of existing positions)
    // -------------------------------------------------------------------------------------------------------------

    /// @notice Launch `ladderTilt`: each doubling holds 1.25x the AMPS of the one below it.
    uint64 internal constant LADDER_TILT_X18_DEFAULT = 1.25e18;

    /// @notice Hard floor of `ladderTilt`: a flat ladder.
    uint64 internal constant LADDER_TILT_X18_MIN = 1e18;

    /// @notice Hard ceiling of `ladderTilt`.
    uint64 internal constant LADDER_TILT_X18_MAX = 1.5e18;

    /// @notice Launch `ladderDoublings`: 10 buckets, $1 to $1,024.
    uint8 internal constant LADDER_DOUBLINGS_DEFAULT = 10;

    /// @notice Hard floor of `ladderDoublings`.
    uint8 internal constant LADDER_DOUBLINGS_MIN = 6;

    /// @notice Hard ceiling of `ladderDoublings`, matching `LadderLib.MAX_BUCKETS`.
    uint8 internal constant LADDER_DOUBLINGS_MAX = 14;

    /// @notice Launch `seedHalvings`: the genesis seed sits as 4 bid buckets below $1.
    uint8 internal constant SEED_HALVINGS_DEFAULT = 4;

    /// @notice Launch `bondBidHalvings`: bonded stock is placed as 4 bid buckets below the spoke price.
    uint8 internal constant BOND_BID_HALVINGS_DEFAULT = 4;

    /// @notice Hard floor of either halving count, matching `LadderLib.MIN_BUCKETS`.
    uint8 internal constant HALVINGS_MIN = 2;

    /// @notice Hard ceiling of either halving count.
    uint8 internal constant HALVINGS_MAX = 8;

    /// @notice Launch `rolloutBpsPerDay`: at most 2% of the POL tranche migrates from the entry pools into the
    ///         spokes per day.
    uint16 internal constant ROLLOUT_BPS_PER_DAY_DEFAULT = 200;

    /// @notice Hard ceiling of `rolloutBpsPerDay`. 10% of the POL tranche per day.
    uint16 internal constant ROLLOUT_BPS_PER_DAY_MAX = 1000;

    /// @notice Launch `entryFloorBps`: rollout never takes the entry pools below 30% of the POL tranche.
    uint16 internal constant ENTRY_FLOOR_BPS_DEFAULT = 3000;

    /// @notice Hard ceiling of `entryFloorBps`. Above 80% rollout could never do anything.
    uint16 internal constant ENTRY_FLOOR_BPS_MAX = 8000;

    /// @notice The R1 post-condition: a placement or a compound may not lower `navPerShare` by more than 2 bp.
    ///         Enforced as a revert, not a warning (I11).
    uint16 internal constant PLACEMENT_BLEED_BPS_MAX = 2;

    /// @notice The relaxed R1 bound, applicable only inside `emergencyMigrate`. 50 bp.
    uint16 internal constant MIGRATION_BLEED_BPS_MAX = 50;

    /// @notice Minimum seconds between two placements in the same pool.
    uint32 internal constant PLACEMENT_COOLDOWN_SECONDS = 60;

    /// @notice Maximum `|slot0.tick - tickOf(P_mkt / P_i)|` accepted at the entry *and* exit of any placement.
    int24 internal constant PLACEMENT_DIVERGENCE_TICKS = 800;

    // -------------------------------------------------------------------------------------------------------------
    // The canonical doubling grid (Phase 3; `docs/phase3-state-model.md` §3.2 and §10 rulings 1 and 12)
    // -------------------------------------------------------------------------------------------------------------
    //
    // Every vault position in a pool lies on that pool's grid: cell `m` covers
    // `[gridBaseTick + m*D, gridBaseTick + (m+1)*D)` with `D = LadderLib.doublingTicks(tickSpacing)`. That is what
    // makes placements merge by cell instead of accumulating (one v4 position per range, since the salt is fixed),
    // bounds `redeemProRata`'s work, and lets `LadderPositionValuer` enumerate the vault's positions by `extsload`
    // without any getter on the vault. Invariant I39.

    /// @notice Lowest grid cell index, inclusive. -8 doublings below the anchor: `1/256` of the opening price,
    ///         which is four halvings below the deepest seed bid and leaves room for a bid ladder that has been
    ///         walked all the way down.
    int24 internal constant GRID_MIN_M = -8;

    /// @notice Highest grid cell index, **exclusive**. +16 doublings above the anchor: 65,536x the opening price.
    ///         A pool that runs past it needs a migration to place more asks, which is the documented cost of a
    ///         bounded record count.
    int24 internal constant GRID_MAX_M = 16;

    /// @notice The number of cells in a pool's grid, and therefore the hard ceiling on the vault's
    ///         `PlacementRecord` count per pool. 24.
    uint8 internal constant GRID_CELLS = uint8(uint24(GRID_MAX_M - GRID_MIN_M));

    /// @notice The vault-wide budget of **live** ladder cells (records with non-zero liquidity), summed over every
    ///         pool. 512.
    /// @dev This is what keeps `redeemProRata` executable in one transaction, which is the whole of the redemption
    ///      floor's promise. Redemption removes `floor(L_p x shares / T)` from every live cell and the placement
    ///      suite measures ~46k gas per live cell, so 512 cells is ~23.5M gas: inside Arbitrum's 32M per-transaction
    ///      cap with a quarter in reserve for the idle-asset payouts and the burn. Every path that would open a
    ///      *new* cell checks the budget first: `place` (timelock or registry) reverts with `CellBudgetExceeded`;
    ///      the permissionless bountied paths (`compound`, `rollout`, `deployBonded`) merge into cells that already
    ///      exist and leave the remainder idle rather than revert. At the launch shape (14 cells per pool: ten asks
    ///      plus four bids) the budget admits ~36 pools, so a registry that grows toward `MAX_CONSTITUENTS` must
    ///      either coarsen its ladders or raise this constant through a vault migration, and Phase 0 must confirm
    ///      the chain's `MaxTxGasLimit` before either is decided.
    uint32 internal constant MAX_LIVE_CELLS = 512;

    /// @notice The `salt` every vault position at the PoolManager is opened with: `bytes32(0)`, everywhere, for
    ///         ever (ruling 12).
    /// @dev This is an invariant, not a convenience. A v4 position is keyed by `(owner, lower, upper, salt)`, so a
    ///      second salt namespace would silently break merge-by-cell, the valuer's enumeration and the bounded
    ///      record count all at once. No placement kind may ever open one.
    bytes32 internal constant POSITION_SALT = bytes32(0);

    /// @notice The factor `RolloutPolicy` applies to a spoke with no counter-asset depth yet. 0.5.
    /// @dev A depthless spoke can still receive asks — that is how it gets a market at all — but it is preferred
    ///      half as strongly as one that bonds or buys have already given stock-side depth.
    uint256 internal constant DEPTHLESS_DISCOUNT_X18 = 0.5e18;

    /// @notice Launch `deployThresholdUsd18`: `deployBonded` is a no-op below $100 of idle collateral.
    /// @dev Ruling 15. Without a floor, `deployBonded` is a permissionless bountied call that can be made to fire
    ///      on dust, which is a drain on `BountyPot` rather than a placement. Governed at 48 h inside the band
    ///      below; the call is a **no-op**, never a revert, so an unpaid keeper call costs the caller gas alone.
    uint256 internal constant DEPLOY_THRESHOLD_USD18_DEFAULT = 100e18;

    /// @notice Hard floor of `deployThresholdUsd18`. $10: below this the bounty is worth more than the placement.
    uint256 internal constant DEPLOY_THRESHOLD_USD18_MIN = 10e18;

    /// @notice Hard ceiling of `deployThresholdUsd18`. $10,000: twice the whole launch book, so setting it here
    ///         already means "bonded stock is never deployed", and anything larger is the same statement.
    uint256 internal constant DEPLOY_THRESHOLD_USD18_MAX = 10_000e18;

    // -------------------------------------------------------------------------------------------------------------
    // Registry and index (7 d timelock)
    // -------------------------------------------------------------------------------------------------------------

    /// @notice Hard ceiling on the constituent set. Ids are 1-based, so valid ids are `[1, MAX_CONSTITUENTS]`.
    uint16 internal constant MAX_CONSTITUENTS = 64;

    /// @notice The launch constituent set size (Decision 2). Not a bound: the registry starts here and moves.
    uint16 internal constant LAUNCH_CONSTITUENTS = 30;

    /// @notice The launch pool count: 30 spokes plus `AMPS/WETH` and `AMPS/USDG`.
    uint16 internal constant LAUNCH_POOLS = 32;

    /// @notice Index weight cap for `n` constituents: `max(3000, ceilDiv(10000, n))` bps. This is the floor of the
    ///         cap, i.e. no name is ever capped below 30%.
    uint16 internal constant INDEX_CAP_FLOOR_BPS = 3000;

    /// @notice Index weight floor for `n` constituents: `min(500, 10000 / (2n))` bps. This is the ceiling of the
    ///         floor, i.e. no name is ever floored above 5%.
    uint16 internal constant INDEX_FLOOR_CEILING_BPS = 500;

    /// @notice Minimum days of price history the inclusion rule requires.
    uint32 internal constant MIN_HISTORY_DAYS = 30;

    // -------------------------------------------------------------------------------------------------------------
    // Governance and keeper
    // -------------------------------------------------------------------------------------------------------------

    /// @notice Fast timelock: fees, bands, bond parameters, ladder shape, rollout, staking, keeper. 48 h.
    uint32 internal constant TIMELOCK_FAST_SECONDS = 48 * ONE_HOUR;

    /// @notice Slow timelock: constituent lifecycle, collateral set, index weights, policy pointers. 7 d.
    uint32 internal constant TIMELOCK_SLOW_SECONDS = 7 * ONE_DAY;

    /// @notice Standby-vault registration. 14 d.
    uint32 internal constant TIMELOCK_STANDBY_SECONDS = 14 * ONE_DAY;

    /// @notice The longest a guardian freeze can last before it expires by itself. 7 d. The guardian cannot renew a
    ///         freeze past this without a new action, and can never block `redeemProRata`.
    uint32 internal constant GUARDIAN_FREEZE_MAX_SECONDS = 7 * ONE_DAY;

    /// @notice How stale the vault checkpoint may be before a gated path refuses to use it. 30 minutes. Redemption
    ///         ignores this, as it ignores every other gate.
    uint32 internal constant CHECKPOINT_MAX_AGE = 1800;

    /// @notice Launch keeper tip: $0.05, 18-decimal USD.
    uint256 internal constant KEEPER_TIP_USD18_DEFAULT = 0.05e18;

    /// @notice Launch keeper chip: 2% of the work value.
    uint16 internal constant KEEPER_CHIP_BPS_DEFAULT = 200;

    /// @notice Launch keeper dust guard `chost`: $1 of work value before a paid job is worth calling.
    uint256 internal constant KEEPER_CHOST_USD18_DEFAULT = 1e18;

    /// @notice Multiple of the observed gas cost the bounty may never exceed.
    uint16 internal constant KEEPER_GAS_CAP_MULTIPLE = 3;

    /// @notice Launch `dailyCeilingUsd18`: $25 a day, sized to the $5k launch book. At the launch tip and chip that
    ///         is roughly two hundred paid jobs a day with headroom, and it is governed upward with TVL alongside
    ///         the tip and the dust guard.
    uint256 internal constant DAILY_CEILING_USD18_DEFAULT = 25e18;

    /// @notice Hard ceiling of `tipUsd18`. $5 is a hundred times the launch tip and already far past the point
    ///         where a flat tip is the dominant term for a $5k book.
    uint256 internal constant TIP_USD18_MAX = 5e18;

    /// @notice Hard ceiling of `chipBps`. 10% of realised work value; there is no floor beyond zero.
    uint16 internal constant CHIP_BPS_MAX = 1000;

    /// @notice Hard ceiling of `chostUsd18`. A dust guard above $1,000 of work value would silence every job the
    ///         launch book can generate, which is a migration decision, not a parameter change.
    uint256 internal constant CHOST_USD18_MAX = 1000e18;

    /// @notice Hard floor of `gasCapMultiple`. Zero would mean no job is ever paid whatever the other parameters
    ///         say, which is what a zero `dailyCeilingUsd18` is for.
    uint16 internal constant GAS_CAP_MULTIPLE_MIN = 1;

    /// @notice Hard ceiling of `gasCapMultiple`. Beyond 10x the observed gas cost the cap stops bounding a gas
    ///         spike at all.
    uint16 internal constant GAS_CAP_MULTIPLE_MAX = 10;

    /// @notice Hard ceiling of `dailyCeilingUsd18`. $100k a day is four thousand times the launch ceiling; there is
    ///         no floor, because setting the ceiling to zero is the governance path for pausing paid keeping
    ///         without pausing the jobs themselves.
    uint256 internal constant DAILY_CEILING_USD18_MAX = 100_000e18;
}
