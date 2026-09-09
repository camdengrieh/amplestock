// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IAmpsGenesis} from "../interfaces/IAmpsGenesis.sol";
import {IAmpsVault} from "../interfaces/IAmpsVault.sol";
import {IFeedRegistry} from "../interfaces/IFeedRegistry.sol";
import {AuctionParameters, IContinuousClearingAuction} from "../interfaces/external/IContinuousClearingAuction.sol";
import {IContinuousClearingAuctionFactory} from "../interfaces/external/IContinuousClearingAuctionFactory.sol";
import {Constants} from "../types/Constants.sol";
import {NotContract, NotTimelock, ZeroAddress} from "../types/Errors.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

/// @title AmpsGenesis
/// @notice The genesis adapter: it owns both Continuous Clearing Auctions from the outside, and it is the only
///         auction-side caller of `AmpsVault.genesisPlace`.
///
/// @dev **Immutable, ownerless, one-shot.** Six immutables, one governed call ({createAuctions}) and one
///      permissionless call ({settle}), each behind its own latch. There is no admin, no upgrade path, no rescue
///      function and no way to change where the money goes: `fundsRecipient` and `tokensRecipient` are this
///      contract, and this contract can only ever forward to the vault it was constructed against.
///
/// @dev **Why the protocol does not use the stock Liquidity Launcher LBP strategy.** That strategy initialises a
///      Uniswap v4 pool itself out of `lbpInitializationParams()`. `AmpsHook.beforeInitialize` and
///      `beforeAddLiquidity` require `sender == vault`, so no third party can open or seed an Amplestocks pool —
///      by design, because the ladder is the protocol's own inventory and `PoolRegistry` owns the grid origin.
///      Amplestocks therefore consumes the auction's *result* rather than its handoff: {settle} reads the clearing
///      price, hands the proceeds to the vault, and `05_Registry` opens all 32 pools at `P0` afterwards.
///
/// @dev **The two things this contract validates that a proposal cannot be trusted with.** The floor price is
///      computed here from the currency's decimals and the ETH/USD price, never taken from the proposal, because
///      a mis-scaled floor is a total loss for bidders. And `auctionStepsData` is totalled here: a schedule that
///      does not issue exactly 100% of the tranche over exactly the auction's block window is rejected, because
///      an under-issuing schedule strands the tranche inside the auction and an over-issuing one is not
///      representable.
///
/// @dev **What is trusted.** The factory address (a Phase 0 `eth_getCode` check), the auction bytecode it deploys,
///      and the protocol fee its controller charges — which is measured rather than predicted: {settle} reads the
///      balances that actually arrived. A hostile factory could return an address that never pays out, which is
///      why {createAuctions} is `onlyTimelock` and the factory is fixed at construction.
contract AmpsGenesis is IAmpsGenesis {
    using SafeERC20 for IERC20;

    // -------------------------------------------------------------------------------------------------------------
    // Constants
    // -------------------------------------------------------------------------------------------------------------

    /// @dev `2^96`. The auction quotes every price as currency raw units per token raw unit, shifted left 96 bits.
    uint256 private constant Q96 = 0x1000000000000000000000000;

    /// @dev The auction's issuance schedule is denominated in milli-bips of the tranche: `1e7` is 100%.
    uint256 private constant MPS = 1e7;

    /// @dev How many bytes one packed issuance step occupies.
    uint256 private constant STEP_BYTES = 8;

    /// @dev The gas ceiling on the one optional read this contract makes of the vault's feed registry. Bounded for
    ///      the same reason `AmpsVault._gateRead` is: a pointer this contract does not own must not be able to
    ///      turn an optional cross-check into an out-of-gas.
    uint256 private constant FEED_READ_GAS = 200_000;

    // -------------------------------------------------------------------------------------------------------------
    // Immutables
    // -------------------------------------------------------------------------------------------------------------

    /// @dev The vault this adapter settles into.
    address private immutable _VAULT;
    /// @dev The AMPS token: the auctions' `token`.
    address private immutable _AMPS;
    /// @dev The `ContinuousClearingAuctionFactory`.
    address private immutable _FACTORY;
    /// @dev WETH9, which the native proceeds are wrapped into.
    address private immutable _WETH9;
    /// @dev USDG, the USDG leg's currency.
    address private immutable _USDG;
    /// @dev The governance timelock: the only caller of {createAuctions}.
    address private immutable _TIMELOCK;
    /// @dev `10 ** usdg.decimals()`, read once at construction so the floor and `P0` never assume six.
    uint256 private immutable _USDG_UNIT;

    // -------------------------------------------------------------------------------------------------------------
    // Storage
    // -------------------------------------------------------------------------------------------------------------

    /// @dev The USDG-denominated auction, or zero when that leg was disabled.
    address private _usdgAuction;
    /// @dev The native-ETH auction, or zero when that leg was disabled.
    address private _ethAuction;
    /// @dev The earliest start block across the legs created.
    uint64 private _startBlock;
    /// @dev The latest end block across the legs created.
    uint64 private _endBlock;
    /// @dev Whether {settle} has run.
    bool private _settledLatch;
    /// @dev Whether {settle} ran and nothing graduated.
    bool private _abortedLatch;

    /// @dev The ETH/USD price this adapter uses: the proposal's at creation, refreshed at settlement when the
    ///      vault's feed registry can be read.
    uint256 private _ethUsdX18;
    /// @dev The USDG leg's Q96 floor.
    uint256 private _floorUsdgQ96;
    /// @dev The ETH leg's Q96 floor.
    uint256 private _floorEthQ96;
    /// @dev The launch reference handed to the vault.
    uint256 private _p0X18;
    /// @dev USDG raw units swept, net of the protocol fee.
    uint256 private _raisedUsdg;
    /// @dev WETH wei swept, net of the protocol fee, after wrapping.
    uint256 private _raisedWeth;
    /// @dev AMPS wei returned to the vault.
    uint256 private _unsoldAmps;

    // -------------------------------------------------------------------------------------------------------------
    // Construction
    // -------------------------------------------------------------------------------------------------------------

    /// @param vault_ `AmpsVault`.
    /// @param amps_ The AMPS token.
    /// @param factory_ The `ContinuousClearingAuctionFactory`.
    /// @param weth9_ WETH9.
    /// @param usdg_ USDG.
    /// @param timelock_ The governance timelock.
    constructor(address vault_, address amps_, address factory_, address weth9_, address usdg_, address timelock_) {
        if (
            vault_ == address(0) || amps_ == address(0) || factory_ == address(0) || weth9_ == address(0)
                || usdg_ == address(0) || timelock_ == address(0)
        ) revert ZeroAddress();

        _VAULT = vault_;
        _AMPS = amps_;
        _FACTORY = factory_;
        _WETH9 = weth9_;
        _USDG = usdg_;
        _TIMELOCK = timelock_;
        _USDG_UNIT = 10 ** IERC20Metadata(usdg_).decimals();
    }

    /// @notice Accepts native value from the ETH auction (its currency sweep) and from WETH9 only.
    /// @dev Everything else reverts: a donation this contract could not account for would either be swept into
    ///      the raise silently or strand {settle}'s sweep-clean assertion.
    receive() external payable {
        if (msg.sender != _ethAuction && msg.sender != _WETH9) revert UnexpectedNative(msg.sender);
    }

    // -------------------------------------------------------------------------------------------------------------
    // Mutative — creation
    // -------------------------------------------------------------------------------------------------------------

    /// @inheritdoc IAmpsGenesis
    function createAuctions(AuctionSpec calldata usdgSpec, AuctionSpec calldata ethSpec, uint256 ethUsdX18_) external {
        if (msg.sender != _TIMELOCK) revert NotTimelock(msg.sender);
        if (_usdgAuction != address(0) || _ethAuction != address(0)) revert AuctionsAlreadyCreated();

        // Each leg is either its whole constant or disabled. A "half tranche" is not a launch parameter: the
        // split is `Constants`, and the part that is not auctioned comes back to the vault as unsold.
        bool usdgOn = usdgSpec.shares != 0;
        bool ethOn = ethSpec.shares != 0;
        if (
            (!usdgOn && !ethOn) || (usdgOn && usdgSpec.shares != Constants.AUCTION_USDG_SHARES)
                || (ethOn && ethSpec.shares != Constants.AUCTION_ETH_SHARES)
        ) revert InvalidTranche(usdgSpec.shares, ethSpec.shares);

        // **`>=`, and the surplus goes home** (audit fix, 2026-09-08). This address is derivable from the
        // deployment long before genesis and holds a known balance in a known window, so `held != AUCTION_SHARES`
        // meant one wei sent between `genesisMint` and this call stranded half of `S0` in an ownerless adapter
        // with no other exit and halved NAV/share for good. The tranche is still exact — the legs below are funded
        // from it to the wei — and anything above it is a donation, which goes back to the vault as inventory,
        // where every other stray balance in this protocol goes.
        uint256 held = IERC20(_AMPS).balanceOf(address(this));
        if (held < Constants.AUCTION_SHARES) revert TrancheNotFunded(held, Constants.AUCTION_SHARES);
        uint256 surplus = held - Constants.AUCTION_SHARES;
        if (surplus != 0) {
            IERC20(_AMPS).safeTransfer(_VAULT, surplus);
            emit TrancheSurplusSwept(surplus);
        }

        if (ethUsdX18_ == 0) revert EthUsdMismatch(0, 0);
        _requireEthUsdAgrees(ethUsdX18_);
        _ethUsdX18 = ethUsdX18_;

        // $1.00 per AMPS in each currency, computed here rather than taken from the proposal.
        uint256 floorUsdg = FullMath.mulDiv(_USDG_UNIT, Q96, Constants.WAD);
        uint256 floorEth = FullMath.mulDiv(Q96, Constants.WAD, ethUsdX18_);
        _floorUsdgQ96 = floorUsdg;
        _floorEthQ96 = floorEth;

        uint64 start = type(uint64).max;
        uint64 end;
        address usdgAuctionAddress;
        address ethAuctionAddress;

        if (usdgOn) {
            usdgAuctionAddress = _createLeg(_USDG, floorUsdg, usdgSpec);
            _usdgAuction = usdgAuctionAddress;
            start = usdgSpec.startBlock;
            end = usdgSpec.endBlock;
        }
        if (ethOn) {
            ethAuctionAddress = _createLeg(address(0), floorEth, ethSpec);
            _ethAuction = ethAuctionAddress;
            if (ethSpec.startBlock < start) start = ethSpec.startBlock;
            if (ethSpec.endBlock > end) end = ethSpec.endBlock;
        }

        _startBlock = start;
        _endBlock = end;

        emit AuctionsCreated(usdgAuctionAddress, ethAuctionAddress, floorUsdg, floorEth, start, end);
    }

    // -------------------------------------------------------------------------------------------------------------
    // Mutative — settlement
    // -------------------------------------------------------------------------------------------------------------

    /// @inheritdoc IAmpsGenesis
    function settle() external {
        if (_settledLatch) revert AlreadySettled();
        address usdgAuctionAddress = _usdgAuction;
        address ethAuctionAddress = _ethAuction;
        if (usdgAuctionAddress == address(0) && ethAuctionAddress == address(0)) revert AuctionsNotCreated();

        // Effects before interactions, and the latch is the reentrancy guard as well: nothing below can re-enter
        // a second settlement, however hostile the factory's auction bytecode turns out to be.
        _settledLatch = true;

        bool usdgGraduated = _harvest(usdgAuctionAddress);
        bool ethGraduated = _harvest(ethAuctionAddress);

        // The ETH leg pays out in native value. Wrap it before anything else looks at a balance, so that from
        // here on the adapter holds only ERC-20s and the sweep-clean assertion has one fewer case.
        uint256 nativeBalance = address(this).balance;
        if (nativeBalance != 0) IWeth9(_WETH9).deposit{value: nativeBalance}();

        uint256 usdgRaised = IERC20(_USDG).balanceOf(address(this));
        uint256 wethRaised = IERC20(_WETH9).balanceOf(address(this));
        uint256 unsold = IERC20(_AMPS).balanceOf(address(this));
        _raisedUsdg = usdgRaised;
        _raisedWeth = wethRaised;
        _unsoldAmps = unsold;

        if (!usdgGraduated && !ethGraduated) {
            // No launch. Bidders refund themselves through the auctions; the whole tranche goes back to the vault
            // as inventory and the timelock runs the fallback `genesisPlace` with the founders' seed. Anything
            // else that happens to be here (a donation) goes with it rather than stranding the assertion below.
            _abortedLatch = true;
            _forward(usdgRaised, wethRaised, unsold);
            emit Settled(0, usdgRaised, wethRaised, unsold, false, false);
            _requireSweptClean();
            return;
        }

        uint256 p0 = _launchPrice(usdgGraduated, ethGraduated);
        _p0X18 = p0;

        if (IAmpsVault(_VAULT).initialized()) {
            // **The vault was already opened by someone else** — the only way that can happen is the timelock
            // running the founders'-seed `genesisPlace` while these auctions were still live, which is a
            // governance mistake rather than a state this contract can produce. `genesisPlace` would revert on
            // its latch, and because `sweepCurrency` is one-shot and `fundsRecipient`-only, a reverting `settle()`
            // would strand the whole raise inside the auctions for ever. So everything is forwarded to the vault
            // as plain balances instead: the vault's own `sweepClean` folds the currency into backing at its next
            // entry point and the AMPS stays as inventory, which is where `genesisPlace` would have put them
            // anyway. Only the `P_ref` seeding is lost, and that is already gone by construction.
            _forward(usdgRaised, wethRaised, unsold);
        } else {
            _place(p0, usdgRaised, wethRaised, unsold);
        }

        emit Settled(p0, usdgRaised, wethRaised, unsold, usdgGraduated, ethGraduated);
        _requireSweptClean();
    }

    // -------------------------------------------------------------------------------------------------------------
    // Views
    // -------------------------------------------------------------------------------------------------------------

    /// @inheritdoc IAmpsGenesis
    function vault() external view returns (address vaultAddress) {
        return _VAULT;
    }

    /// @inheritdoc IAmpsGenesis
    function amps() external view returns (address ampsAddress) {
        return _AMPS;
    }

    /// @inheritdoc IAmpsGenesis
    function factory() external view returns (address factoryAddress) {
        return _FACTORY;
    }

    /// @inheritdoc IAmpsGenesis
    function weth9() external view returns (address weth9Address) {
        return _WETH9;
    }

    /// @inheritdoc IAmpsGenesis
    function usdg() external view returns (address usdgAddress) {
        return _USDG;
    }

    /// @inheritdoc IAmpsGenesis
    function timelock() external view returns (address timelockAddress) {
        return _TIMELOCK;
    }

    /// @inheritdoc IAmpsGenesis
    function usdgAuction() external view returns (address auction) {
        return _usdgAuction;
    }

    /// @inheritdoc IAmpsGenesis
    function ethAuction() external view returns (address auction) {
        return _ethAuction;
    }

    /// @inheritdoc IAmpsGenesis
    function phase() external view returns (Phase current) {
        if (_abortedLatch) return Phase.Aborted;
        if (_settledLatch) return Phase.Settled;
        if (_usdgAuction == address(0) && _ethAuction == address(0)) return Phase.Created;
        if (block.number < _startBlock) return Phase.Created;
        if (block.number < _endBlock) return Phase.Bidding;
        return Phase.Ended;
    }

    /// @inheritdoc IAmpsGenesis
    function settled() external view returns (bool done) {
        return _settledLatch;
    }

    /// @inheritdoc IAmpsGenesis
    function p0X18() external view returns (uint256 price) {
        return _p0X18;
    }

    /// @inheritdoc IAmpsGenesis
    function raisedUsdg() external view returns (uint256 amount) {
        return _raisedUsdg;
    }

    /// @inheritdoc IAmpsGenesis
    function raisedWeth() external view returns (uint256 amount) {
        return _raisedWeth;
    }

    /// @inheritdoc IAmpsGenesis
    function raisedUsd18() external view returns (uint256 value) {
        uint256 usdgUsd18 = FullMath.mulDiv(_raisedUsdg, Constants.WAD, _USDG_UNIT);
        uint256 wethUsd18 = FullMath.mulDiv(_raisedWeth, _ethUsdX18, Constants.WAD);
        return usdgUsd18 + wethUsd18;
    }

    /// @inheritdoc IAmpsGenesis
    function unsoldAmps() external view returns (uint256 amount) {
        return _unsoldAmps;
    }

    /// @inheritdoc IAmpsGenesis
    function ethUsdX18() external view returns (uint256 price) {
        return _ethUsdX18;
    }

    /// @inheritdoc IAmpsGenesis
    function floorUsdgQ96() external view returns (uint256 priceQ96) {
        return _floorUsdgQ96;
    }

    /// @inheritdoc IAmpsGenesis
    function floorEthQ96() external view returns (uint256 priceQ96) {
        return _floorEthQ96;
    }

    /// @inheritdoc IAmpsGenesis
    function packStep(uint24 mps, uint40 blockDelta) public pure returns (bytes8 word) {
        return bytes8((uint64(mps) << 40) | uint64(blockDelta));
    }

    /// @inheritdoc IAmpsGenesis
    function stepsTotals(bytes calldata stepsData) public pure returns (uint256 totalMps, uint256 totalBlocks) {
        uint256 length = stepsData.length;
        if (length == 0 || length % STEP_BYTES != 0) return (0, 0);
        for (uint256 offset; offset < length; offset += STEP_BYTES) {
            uint64 word = uint64(bytes8(stepsData[offset:offset + STEP_BYTES]));
            uint256 mps = uint256(word >> 40);
            uint256 blocks = uint256(uint40(word));
            totalMps += mps * blocks;
            totalBlocks += blocks;
        }
    }

    // -------------------------------------------------------------------------------------------------------------
    // Internals
    // -------------------------------------------------------------------------------------------------------------

    /// @dev Builds, deploys and funds one auction leg.
    /// @param currency The leg's currency: USDG, or `address(0)` for native ETH.
    /// @param floorQ96 The Q96 floor computed for that currency.
    /// @param spec The proposal's schedule and graduation parameters.
    /// @return auction The deployed auction.
    function _createLeg(address currency, uint256 floorQ96, AuctionSpec calldata spec)
        private
        returns (address auction)
    {
        if (spec.startBlock < block.number || spec.endBlock <= spec.startBlock || spec.claimBlock < spec.endBlock) {
            revert InvalidSchedule(spec.startBlock, spec.endBlock, spec.claimBlock);
        }

        (uint256 totalMps, uint256 totalBlocks) = stepsTotals(spec.auctionStepsData);
        if (totalMps != MPS || totalBlocks != uint256(spec.endBlock - spec.startBlock)) {
            revert InvalidSteps(totalMps, totalBlocks);
        }

        bytes memory configData = abi.encode(
            AuctionParameters({
                currency: currency,
                tokensRecipient: address(this),
                fundsRecipient: address(this),
                startBlock: spec.startBlock,
                endBlock: spec.endBlock,
                claimBlock: spec.claimBlock,
                tickSpacing: spec.tickSpacing,
                validationHook: spec.validationHook,
                floorPrice: floorQ96,
                requiredCurrencyRaised: spec.requiredCurrencyRaised,
                auctionStepsData: spec.auctionStepsData
            })
        );

        // The factory may take the tranche itself (a `transferFrom` inside the deployment) or expect it to be
        // pushed afterwards. Approving first covers the pulling shape; the allowance is cleared immediately, and
        // whatever is still missing is pushed below. Both shapes end with the auction holding exactly `shares`.
        IERC20(_AMPS).forceApprove(_FACTORY, spec.shares);
        auction = _deploy(spec.shares, configData, spec.salt);
        IERC20(_AMPS).forceApprove(_FACTORY, 0);

        if (auction == address(0)) revert ZeroAddress();
        if (auction.code.length == 0) revert NotContract(auction);

        uint256 held = IERC20(_AMPS).balanceOf(auction);
        if (held < spec.shares) IERC20(_AMPS).safeTransfer(auction, spec.shares - held);

        // Some CCA revisions record the funding lazily and emit `TokensReceived` from a nudge rather than from the
        // transfer. The nudge is optional by construction: a factory that already recorded the tranche has no such
        // function and the call fails harmlessly, and the balance assertion below is what actually decides.
        (bool ok,) = auction.call(abi.encodeWithSignature("onTokensReceived()"));
        ok;

        // `>=` for the reason {createAuctions} gives: the leg's CREATE2 address is derivable from the proposal's
        // own salt, so a pre-donation of one wei must not be able to force the whole launch to be re-proposed. A
        // leg holding more than its tranche sells only what its schedule issues and returns the rest through
        // `sweepUnsoldTokens` at settlement, which is the same path the unsold part of the tranche takes.
        held = IERC20(_AMPS).balanceOf(auction);
        if (held < spec.shares) revert AuctionNotFunded(auction, held, spec.shares);
    }

    /// @dev Deploys one auction through the factory, trying the v2 name before the pre-v2 one.
    /// @param amount The tranche.
    /// @param configData The ABI-encoded `AuctionParameters`.
    /// @param salt The CREATE2 salt.
    /// @return auction The address the factory returned.
    function _deploy(uint256 amount, bytes memory configData, bytes32 salt) private returns (address auction) {
        (bool ok, bytes memory returndata) =
            _FACTORY.call(abi.encodeCall(IContinuousClearingAuctionFactory.create, (_AMPS, amount, configData, salt)));
        if (!ok || returndata.length < 32) {
            (ok, returndata) = _FACTORY.call(
                abi.encodeCall(
                    IContinuousClearingAuctionFactory.initializeDistribution, (_AMPS, amount, configData, salt)
                )
            );
            if (!ok) {
                // Surface the factory's own revert rather than a generic one: a launch that fails here fails on
                // a parameter, and the operator needs to see which.
                assembly ("memory-safe") {
                    revert(add(returndata, 0x20), mload(returndata))
                }
            }
        }
        auction = abi.decode(returndata, (address));
    }

    /// @dev Checkpoints one leg, reads its graduation and sweeps everything it owes this contract.
    /// @param auction The leg, or zero when it was never created.
    /// @return graduated Whether the leg reached its `requiredCurrencyRaised`.
    function _harvest(address auction) private returns (bool graduated) {
        if (auction == address(0)) return false;
        IContinuousClearingAuction leg = IContinuousClearingAuction(auction);

        uint64 endBlock = leg.endBlock();
        if (block.number < endBlock) revert AuctionNotEnded(auction, endBlock);

        // `isGraduated` and `clearingPrice` both read the latest checkpoint, which is only written when a bid
        // arrives. Forcing one here is what makes the end block itself checkpointed and the price final.
        leg.checkpoint();
        graduated = leg.isGraduated();

        // A non-graduated leg raised nothing to sweep — upstream turns that into a no-op rather than a revert, but
        // this contract never relies on it. The token sweep runs either way: it is what returns the tranche.
        if (graduated) leg.sweepCurrency();
        leg.sweepUnsoldTokens();
    }

    /// @dev `P0`, in 18-decimal USD per AMPS, with the cross-check when both legs graduated.
    /// @param usdgGraduated Whether the USDG leg graduated.
    /// @param ethGraduated Whether the ETH leg graduated.
    /// @return p0 The launch reference.
    function _launchPrice(bool usdgGraduated, bool ethGraduated) private returns (uint256 p0) {
        // Refresh the ETH/USD price from the vault's feed registry when it can be read. The value recorded at
        // creation is up to the whole bidding window old, and the ETH leg's clearing price is quoted in ETH.
        // The refresh is taken only when the registry calls the answer **fresh** (audit fix, 2026-09-08). `P0` is
        // the protocol's launch reference and, on an ETH-only graduation, the ETH/USD answer *is* `P0` up to the
        // clearing price — so adopting a stale one would set the reference of the whole system off a price nobody
        // vouches for. An unusable answer falls back to the price recorded at `createAuctions`, which was itself
        // cross-checked against the registry then, and says so; it does not revert, because a `settle()` that
        // reverts strands the raise inside one-shot auction sweeps for ever.
        (uint256 ethUsd, bool fresh) = _feedEthUsdX18();
        if (ethUsd == 0 || !fresh) {
            emit EthUsdNotRefreshed(ethUsd, _ethUsdX18);
            ethUsd = _ethUsdX18;
        } else {
            _ethUsdX18 = ethUsd;
        }

        uint256 usdgPrice;
        uint256 ethPrice;

        if (usdgGraduated) {
            uint256 clearingQ96 = IContinuousClearingAuction(_usdgAuction).clearingPrice();
            if (clearingQ96 == 0) revert ZeroClearingPrice(_usdgAuction);
            // `clearingQ96 / 2^96` is USDG raw units per AMPS wei. One AMPS is `1e18` wei and one USDG is
            // `_USDG_UNIT` raw units, and USDG is the unit `P_ref` is quoted in, so the conversion to
            // 18-decimal USD per AMPS is one `mulDiv` with `1e36` over `2^96 x _USDG_UNIT`.
            usdgPrice = FullMath.mulDiv(clearingQ96, Constants.WAD * Constants.WAD, Q96 * _USDG_UNIT);
        }
        if (ethGraduated) {
            uint256 clearingQ96 = IContinuousClearingAuction(_ethAuction).clearingPrice();
            if (clearingQ96 == 0) revert ZeroClearingPrice(_ethAuction);
            // Both legs of this ratio are 18-decimal, so `clearingQ96 / 2^96` is ETH per AMPS outright.
            ethPrice = FullMath.mulDiv(clearingQ96, ethUsd, Q96);
        }

        if (usdgGraduated && ethGraduated) {
            uint16 toleranceBps = IAmpsVault(_VAULT).refDivergenceBps();
            uint256 gap = usdgPrice > ethPrice ? usdgPrice - ethPrice : ethPrice - usdgPrice;
            if (FullMath.mulDiv(gap, Constants.BPS, usdgPrice) > toleranceBps) {
                emit ClearingPricesDiverged(usdgPrice, ethPrice, toleranceBps);
            }
        }

        // The USDG leg wins whenever it graduated: it is the only one denominated in the unit `P_ref` is quoted
        // in, so it needs no oracle to become a price.
        p0 = usdgGraduated ? usdgPrice : ethPrice;
    }

    /// @dev Sends everything this contract holds to the vault as plain balances. The escape hatch for the two
    ///      states in which `genesisPlace` cannot be called: no graduation, and a vault someone else already
    ///      opened. Nothing is ever left here to strand a one-shot sweep.
    /// @param usdgRaised USDG raw units to forward.
    /// @param wethRaised WETH wei to forward.
    /// @param unsold AMPS wei to forward.
    function _forward(uint256 usdgRaised, uint256 wethRaised, uint256 unsold) private {
        if (unsold != 0) IERC20(_AMPS).safeTransfer(_VAULT, unsold);
        if (usdgRaised != 0) IERC20(_USDG).safeTransfer(_VAULT, usdgRaised);
        if (wethRaised != 0) IERC20(_WETH9).safeTransfer(_VAULT, wethRaised);
    }

    /// @dev Approves the vault for exactly what it is about to pull and calls `genesisPlace`.
    /// @param p0 The launch reference.
    /// @param usdgRaised USDG raw units to hand over.
    /// @param wethRaised WETH wei to hand over.
    /// @param unsold AMPS wei to hand back.
    function _place(uint256 p0, uint256 usdgRaised, uint256 wethRaised, uint256 unsold) private {
        uint256 count;
        if (usdgRaised != 0) ++count;
        if (wethRaised != 0) ++count;

        address[] memory tokens = new address[](count);
        uint256[] memory amounts = new uint256[](count);
        uint256 i;
        if (usdgRaised != 0) {
            tokens[i] = _USDG;
            amounts[i] = usdgRaised;
            IERC20(_USDG).forceApprove(_VAULT, usdgRaised);
            ++i;
        }
        if (wethRaised != 0) {
            tokens[i] = _WETH9;
            amounts[i] = wethRaised;
            IERC20(_WETH9).forceApprove(_VAULT, wethRaised);
        }
        if (unsold != 0) IERC20(_AMPS).forceApprove(_VAULT, unsold);

        IAmpsVault(_VAULT)
            .genesisPlace(
                IAmpsVault.GenesisPlaceParams({p0X18: p0, tokens: tokens, amounts: amounts, unsoldAmps: unsold})
            );
    }

    /// @dev I12's shape, for this contract: nothing is left behind. Every balance was either handed to the vault
    ///      or pulled by it, so a residue means an accounting error rather than a donation — the donation cases
    ///      are folded into the raise and into the aborted branch's forwarding above.
    function _requireSweptClean() private view {
        uint256 balance = address(this).balance;
        if (balance != 0) revert NotSweptClean(address(0), balance);
        balance = IERC20(_AMPS).balanceOf(address(this));
        if (balance != 0) revert NotSweptClean(_AMPS, balance);
        balance = IERC20(_USDG).balanceOf(address(this));
        if (balance != 0) revert NotSweptClean(_USDG, balance);
        balance = IERC20(_WETH9).balanceOf(address(this));
        if (balance != 0) revert NotSweptClean(_WETH9, balance);
    }

    /// @dev Refuses an ETH/USD price the vault's own feed registry disagrees with by more than the vault's
    ///      `refDivergenceBps`. Skipped entirely when no feed registry is wired or WETH has no feed: the
    ///      cross-check is a guard against a fat-fingered proposal, not a dependency.
    /// @param supplied The proposal's price.
    function _requireEthUsdAgrees(uint256 supplied) private view {
        // An answer the registry does not call fresh is no answer for this purpose: the cross-check exists to
        // catch a fat-fingered proposal, and comparing against a price the registry itself will not stand behind
        // can only turn a correct proposal into a revert. Skipping is what "cannot be read" has always done here.
        (uint256 feedPrice, bool fresh) = _feedEthUsdX18();
        if (feedPrice == 0 || !fresh) return;
        uint256 gap = supplied > feedPrice ? supplied - feedPrice : feedPrice - supplied;
        if (FullMath.mulDiv(gap, Constants.BPS, feedPrice) > IAmpsVault(_VAULT).refDivergenceBps()) {
            revert EthUsdMismatch(supplied, feedPrice);
        }
    }

    /// @dev WETH's 18-decimal USD price from the vault's feed registry, or zero when it cannot be read.
    /// @dev A bounded, hand-decoded `staticcall` rather than a typed `try`, for the reason `AmpsVault._gateRead`
    ///      gives: a `try` fails open only for a target that *reverts*, not for one that is codeless, answers
    ///      short or burns the gas it is given, and this read must never be able to stop a launch.
    /// @dev The freshness word is read and returned rather than discarded: `latestAnswerUsd18` reports an answer
    ///      it does not consider actionable — aged past its session-scaled bound, or held behind an unconfirmed
    ///      jump — and both callers here have to know, because one of them sets `P0`.
    /// @return price18 The price, or zero.
    /// @return fresh Whether the registry considers it actionable. False whenever `price18` is zero.
    function _feedEthUsdX18() private view returns (uint256 price18, bool fresh) {
        address feeds = IAmpsVault(_VAULT).feedRegistry();
        if (feeds == address(0) || feeds.code.length == 0) return (0, false);
        (bool ok, bytes memory returndata) =
            feeds.staticcall{gas: FEED_READ_GAS}(abi.encodeCall(IFeedRegistry.latestAnswerUsd18, (_WETH9)));
        if (!ok || returndata.length < 96) return (0, false);
        uint256 freshWord;
        assembly ("memory-safe") {
            price18 := mload(add(returndata, 0x20))
            freshWord := mload(add(returndata, 0x60))
        }
        fresh = price18 != 0 && freshWord != 0;
    }
}

/// @title IWeth9
/// @notice The one WETH9 entry point this adapter uses. Declared here rather than in `src/interfaces/` for the
///         same reason `AmpsRouter` declares its own: nothing else in the protocol wraps native value.
interface IWeth9 {
    /// @notice Wraps the ether sent with the call.
    function deposit() external payable;
}
