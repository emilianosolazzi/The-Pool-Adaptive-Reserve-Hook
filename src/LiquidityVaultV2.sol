// SPDX-License-Identifier: MIT
pragma solidity >=0.8.24 <0.9.0;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {LiquidityAmounts} from "./libraries/LiquidityAmounts.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {IZapRouter} from "./interfaces/IZapRouter.sol";

interface IReserveHook {
    function createReserveOffer(
        PoolKey calldata key,
        Currency sellCurrency,
        uint128 sellAmount,
        uint160 vaultSqrtPriceX96,
        uint64 expiry
    ) external;
    function cancelReserveOffer(PoolKey calldata key) external returns (uint128);
    function claimReserveProceeds(Currency currency) external returns (uint256);
    /// @notice View accessor for the public mapping `proceedsOwed[vault][currency]`.
    function proceedsOwed(address vault, Currency currency) external view returns (uint256);
    /// @notice View accessor for the public mapping `escrowedReserve[vault][sellCurrency]`.
    function escrowedReserve(address vault, Currency currency) external view returns (uint256);
    /// @notice True when the pool has an active reserve offer. Used to gate
    ///         cancel calls so real failures bubble instead of being swallowed.
    function offerActive(PoolKey calldata key) external view returns (bool);
}

/// @notice Minimal interface for the BootstrapRewards bonus program. The vault
///         calls `poke(user)` on every share balance change so that the lazy
///         share-second accrual model never under-credits a depositor who
///         forgot to poke before depositing/withdrawing/transferring.
interface IBootstrapRewardsPoke {
    function poke(address user) external;
}

/// @notice ERC-4626 USDC-entry vault that can zap into active dual-token v4 liquidity.
/// @dev    External swaps go through a narrow zap-router adapter. The vault
///         never accepts arbitrary router calldata.
contract LiquidityVaultV2 is ERC4626, Ownable2Step, ReentrancyGuard, Pausable {
    using Math for uint256;
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint256 public constant MIN_DEPOSIT = 1e6;
    uint256 private constant Q96 = 1 << 96;

    int24 public tickLower = -199020;
    int24 public tickUpper = -198840;

    IPoolManager public immutable poolManager;
    IPositionManager public immutable positionManager;
    address public immutable permit2;
    PoolKey public poolKey;

    uint256 public totalLiquidityDeployed;
    uint256 public assetsDeployed;
    uint256 public totalYieldCollected;
    uint256 public otherTokenYieldCollected;
    uint256 public totalDepositors;
    uint256 public lastYieldUpdate;
    uint256 public positionTokenId;
    bool private _poolKeySet;
    bool public assetIsToken0;

    address public treasury;
    uint256 public performanceFeeBps;
    uint256 public maxTVL;
    uint256 public removeLiquiditySlippageBps = 50;
    uint256 public txDeadlineSeconds = 300;
    address public zapRouter;
    address public reserveHook;
    /// @notice Optional BootstrapRewards bonus program. When set, every share
    ///         balance mutation (mint/burn/transfer) auto-pokes the affected
    ///         users. Defensive try/catch ensures a misbehaving rewards
    ///         contract can never DoS deposits or withdrawals.
    address public bootstrapRewards;

    // ---------------------------------------------------------------
    // NAV pricing rule
    // ---------------------------------------------------------------
    //
    // `totalAssets()` quotes the non-asset side at the pool's live
    // sqrt-price. A single-tx attacker who can move the pool spot far
    // enough to skew NAV inside the same call can mint/redeem shares at
    // a manipulated price. We defend with a deviation guard: every NAV
    // computation compares the live spot against a stored reference and
    // reverts if they disagree by more than `maxNavDeviationBps` of
    // PRICE (token1/token0, i.e. sqrt^2). The reference is bootstrapped
    // on the first deposit/mint/withdraw/redeem after the pool has a
    // slot0, and the owner can re-anchor it explicitly via
    // `refreshNavReference()` after a legitimate price move.
    //
    // We use a min-of-two pricing rule deliberately NOT — a lower NAV
    // benefits depositors at the expense of existing LPs. Symmetric
    // deviation revert is the correct conservative behaviour: under
    // manipulation, NOBODY can deposit or redeem until the price normalises
    // or the owner re-anchors.
    /// @notice Reference sqrt-price the NAV deviation guard checks against.
    ///         0 means "unset" — the next deposit/withdraw will bootstrap it.
    ///
    ///         DEPLOYMENT FLOW: owners SHOULD call `refreshNavReference()`
    ///         immediately after `setPoolKey` and before opening deposits
    ///         (i.e. before `unpause()` if the vault is launched paused).
    ///         Lazy bootstrap is a fallback only — letting an attacker be
    ///         the first depositor at a manipulated spot would anchor the
    ///         reference to that manipulated price. See
    ///         test_nav_lazyBootstrap_anchorsAtFirstDepositPrice.
    uint160 public navReferenceSqrtPriceX96;

    /// @notice Max permitted PRICE deviation between live spot and the NAV
    ///         reference, expressed in basis points. Default 100 bps = 1%.
    uint256 public maxNavDeviationBps = 100;

    /// @notice Hard cap on `maxNavDeviationBps` to keep the guard meaningful.
    ///         500 bps = 5%; values above this are rejected.
    uint256 public constant MAX_NAV_DEVIATION_CAP = 500;

    enum VaultStatus {
        UNCONFIGURED,
        PAUSED,
        IN_RANGE,
        OUT_OF_RANGE
    }

    event LiquidityDeployed(uint256 amount0, uint256 amount1, uint256 liquidity);
    event LiquidityRemoved(uint256 amount0, uint256 amount1, uint256 liquidity);
    event YieldCollected(uint256 amount, uint256 timestamp);
    event OtherTokenYieldCollected(uint256 amount, uint256 timestamp);
    event PerformanceFeePaid(address indexed treasury, uint256 amount);
    event PoolKeySet(bytes32 indexed poolId);
    event Rebalanced(int24 newTickLower, int24 newTickUpper);
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    event PerformanceFeeUpdated(uint256 oldBps, uint256 newBps);
    event MaxTVLUpdated(uint256 oldMax, uint256 newMax);
    event RemoveLiquiditySlippageBpsUpdated(uint256 oldBps, uint256 newBps);
    event TxDeadlineUpdated(uint256 oldSeconds, uint256 newSeconds);
    event ZapRouterUpdated(address indexed oldRouter, address indexed newRouter);
    event ZapExecuted(address indexed tokenIn, address indexed tokenOut, uint256 amountInMax, uint256 amountOut);
    event ZapDeposit(address indexed caller, address indexed receiver, uint256 assets, uint256 swappedAssets, uint256 shares);
    event ZapWithdraw(address indexed caller, address indexed receiver, address indexed owner, uint256 assets, uint256 shares);
    event ReserveHookUpdated(address indexed oldHook, address indexed newHook);
    event ReserveOfferEscrowed(address indexed sellCurrency, uint128 sellAmount, uint160 vaultSqrtPriceX96, uint64 expiry);
    event ReserveOfferReturned(address indexed sellCurrency, uint128 returned);
    event ReserveProceedsCollected(address indexed currency, uint256 amount);
    event BootstrapRewardsUpdated(address indexed oldRewards, address indexed newRewards);
    event BootstrapPokeFailed(address indexed user, bytes reason);
    event NavReferenceRefreshed(uint160 oldRef, uint160 newRef);
    event MaxNavDeviationBpsUpdated(uint256 oldBps, uint256 newBps);
    event NativeRescued(address indexed to, uint256 amount);

    error NAV_PRICE_DEVIATION();
    error NativeNotSupported();

    constructor(
        IERC20 _asset,
        IPoolManager _poolManager,
        IPositionManager _posManager,
        string memory _name,
        string memory _symbol,
        address _permit2,
        address _zapRouter
    ) ERC4626(_asset) ERC20(_name, _symbol) Ownable(msg.sender) {
        poolManager = _poolManager;
        positionManager = _posManager;
        permit2 = _permit2;
        zapRouter = _zapRouter;
        treasury = msg.sender;

        if (_permit2 != address(0)) {
            IERC20(address(_asset)).forceApprove(_permit2, type(uint256).max);
        }
    }

    /// @notice The vault is ERC-20-only. Native ETH is explicitly unsupported;
    ///         plain transfers and fallback calls revert. ETH can still arrive
    ///         via SELFDESTRUCT or coinbase forwarding (these bypass
    ///         receive/fallback); use `rescueNative` to recover such dust.
    receive() external payable {
        revert NativeNotSupported();
    }

    fallback() external payable {
        if (msg.value > 0) revert NativeNotSupported();
    }

    function totalAssets() public view override returns (uint256) {
        uint256 idleAsset = IERC20(asset()).balanceOf(address(this));
        if (!_poolKeySet) return idleAsset;

        uint160 sqrtPriceX96 = _navSqrtPriceX96();
        if (sqrtPriceX96 == 0) return idleAsset;

        uint256 amt0;
        uint256 amt1;
        if (totalLiquidityDeployed > 0 && positionTokenId != 0) {
            uint160 sqrtA = TickMath.getSqrtPriceAtTick(tickLower);
            uint160 sqrtB = TickMath.getSqrtPriceAtTick(tickUpper);
            (amt0, amt1) = LiquidityAmounts.getAmountsForLiquidity(
                sqrtPriceX96, sqrtA, sqrtB, uint128(totalLiquidityDeployed)
            );
        }

        address otherAddr = _otherToken();
        uint256 idleOther = otherAddr.code.length > 0 ? IERC20(otherAddr).balanceOf(address(this)) : 0;

        // Pending reserve-sale proceeds held by the hook on this vault's behalf.
        // These are economically owned by depositors *now*; ignoring them would
        // let new depositors mint shares cheaper than the live NAV.
        // Likewise, escrowed reserve inventory is still vault-owned (the hook
        // is just a custodian until it fills, expires, or is cancelled), and
        // must be counted to keep NAV continuous across the offer lifecycle
        // (post → partial fill → full fill → claim → cancel).
        uint256 pendingAsset;
        uint256 pendingOther;
        uint256 escrowAsset;
        uint256 escrowOther;
        if (reserveHook != address(0)) {
            IReserveHook h = IReserveHook(reserveHook);
            Currency cAsset = Currency.wrap(asset());
            pendingAsset = h.proceedsOwed(address(this), cAsset);
            escrowAsset = h.escrowedReserve(address(this), cAsset);
            if (otherAddr != address(0)) {
                Currency cOther = Currency.wrap(otherAddr);
                pendingOther = h.proceedsOwed(address(this), cOther);
                escrowOther = h.escrowedReserve(address(this), cOther);
            }
        }

        // Idle / pending / escrow other-token gets quoted at a price
        // CLAMPED to [sqrtLower, sqrtUpper]. When the pool is OOR the
        // unclamped spot can over- or under-value held inventory; clamping
        // pins the quote to the range edge, the same price at which the
        // position itself would be valued.
        uint256 quoteSqrt = _clampQuotePrice(sqrtPriceX96);

        if (assetIsToken0) {
            uint256 otherTotal = idleOther + pendingOther + escrowOther;
            uint256 otherInAssetClamped = _quoteToken1ToToken0(otherTotal, quoteSqrt);
            uint256 amt1InAsset = _quoteToken1ToToken0(amt1, uint256(sqrtPriceX96));
            return idleAsset + pendingAsset + escrowAsset + amt0 + amt1InAsset + otherInAssetClamped;
        } else {
            uint256 otherTotal = idleOther + pendingOther + escrowOther;
            uint256 otherInAssetClamped = _quoteToken0ToToken1(otherTotal, quoteSqrt);
            uint256 amt0InAsset = _quoteToken0ToToken1(amt0, uint256(sqrtPriceX96));
            return idleAsset + pendingAsset + escrowAsset + amt1 + amt0InAsset + otherInAssetClamped;
        }
    }

    /// @dev Live spot, deviation-guarded against `navReferenceSqrtPriceX96`.
    ///      Returns 0 if the pool's slot0 is uninitialised. When the
    ///      reference is unset the live spot passes through unchecked
    ///      (bootstrap path); deposit/withdraw entrypoints set the
    ///      reference on first use.
    function _navSqrtPriceX96() internal view returns (uint160) {
        (uint160 spot,,,) = poolManager.getSlot0(poolKey.toId());
        if (spot == 0) return 0;
        uint160 ref = navReferenceSqrtPriceX96;
        if (ref == 0) return spot;
        if (!_priceWithinTolerance(spot, ref, maxNavDeviationBps)) {
            revert NAV_PRICE_DEVIATION();
        }
        return spot;
    }

    /// @dev True when |price(spot) - price(ref)| / price(ref) <= bps / 10000,
    ///      where price = sqrt^2.
    ///
    ///      OVERFLOW SAFETY: We avoid squaring `sqrt` directly (sqrt is up to
    ///      ~2^160, sqrt^2 is up to ~2^320, which would overflow uint256 even
    ///      after a /2^64 shift at the high end of the sqrt range). Instead we
    ///      compute the price ratio (spot/ref)^2 in 1e18 fixed-point via two
    ///      sequential FullMath.mulDiv operations, both of which fit cleanly
    ///      in uint256 across the full TickMath.MIN_SQRT_PRICE..MAX_SQRT_PRICE
    ///      range. See test_nav_deviationMath_doesNotOverflowAtExtremeSqrt.
    function _priceWithinTolerance(uint160 spot, uint160 ref, uint256 bps) internal pure returns (bool) {
        // step1 = spot^2 / ref. spot <= 2^160 so spot^2 <= 2^320; dividing by
        // ref (>= MIN_SQRT_PRICE ~ 2^32) keeps the result <= ~2^288 worst-case,
        // but in the symmetric case where spot ~ ref the result is just spot,
        // which fits in uint256. FullMath uses a 512-bit intermediate so the
        // intermediate product never overflows; only the FINAL value must fit
        // in uint256.
        uint256 step1 = FullMath.mulDiv(uint256(spot), uint256(spot), uint256(ref));
        // ratio = step1 * 1e18 / ref. For spot ~ ref this is ~1e18; FullMath
        // tolerates the 1e18 multiplier without overflow.
        uint256 ratio = FullMath.mulDiv(step1, 1e18, uint256(ref));
        uint256 ONE = 1e18;
        uint256 tol = (ONE * bps) / 10_000;
        return ratio >= ONE ? (ratio - ONE) <= tol : (ONE - ratio) <= tol;
    }

    /// @dev Clamp `sqrt` to the position's range edges. Used only for
    ///      idle/pending/escrow other-token valuation; the position-leg
    ///      math always uses the unclamped (deviation-guarded) spot.
    function _clampQuotePrice(uint160 sqrtP) internal view returns (uint256) {
        uint160 sqrtA = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtB = TickMath.getSqrtPriceAtTick(tickUpper);
        if (sqrtP < sqrtA) return uint256(sqrtA);
        if (sqrtP > sqrtB) return uint256(sqrtB);
        return uint256(sqrtP);
    }

    /// @dev Lazily bootstrap `navReferenceSqrtPriceX96` from the current
    ///      spot if it has never been set, then assert deviation tolerance.
    ///      Called from every entrypoint that mints or burns shares so the
    ///      reference is always live before NAV-dependent math runs.
    function _bootstrapAndCheckNav() internal {
        if (!_poolKeySet) return;
        (uint160 spot,,,) = poolManager.getSlot0(poolKey.toId());
        if (spot == 0) return;
        uint160 ref = navReferenceSqrtPriceX96;
        if (ref == 0) {
            navReferenceSqrtPriceX96 = spot;
            emit NavReferenceRefreshed(0, spot);
            return;
        }
        if (!_priceWithinTolerance(spot, ref, maxNavDeviationBps)) {
            revert NAV_PRICE_DEVIATION();
        }
    }

    function _quoteToken0ToToken1(uint256 amount0, uint256 sqrtPriceX96) internal pure returns (uint256) {
        if (amount0 == 0) return 0;
        uint256 token1Partial = FullMath.mulDiv(amount0, sqrtPriceX96, Q96);
        return FullMath.mulDiv(token1Partial, sqrtPriceX96, Q96);
    }

    function _quoteToken1ToToken0(uint256 amount1, uint256 sqrtPriceX96) internal pure returns (uint256) {
        if (amount1 == 0) return 0;
        uint256 token0Partial = FullMath.mulDiv(amount1, Q96, sqrtPriceX96);
        return FullMath.mulDiv(token0Partial, Q96, sqrtPriceX96);
    }

    function _decimalsOffset() internal pure override returns (uint8) {
        return 6;
    }

    function vaultStatus() public view returns (VaultStatus) {
        if (paused()) return VaultStatus.PAUSED;
        if (!_poolKeySet) return VaultStatus.UNCONFIGURED;
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolKey.toId());
        if (sqrtPriceX96 == 0) return VaultStatus.UNCONFIGURED;
        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(tickUpper);
        if (sqrtPriceX96 >= sqrtLower && sqrtPriceX96 < sqrtUpper) return VaultStatus.IN_RANGE;
        return VaultStatus.OUT_OF_RANGE;
    }

    function maxDeposit(address) public view override returns (uint256) {
        if (paused() || !_poolKeySet) return 0;
        if (maxTVL == 0) return type(uint256).max;
        uint256 current = totalAssets();
        return current >= maxTVL ? 0 : maxTVL - current;
    }

    function maxMint(address receiver) public view override returns (uint256) {
        uint256 maxAssets = maxDeposit(receiver);
        if (maxAssets == type(uint256).max) return type(uint256).max;
        return convertToShares(maxAssets);
    }

    function maxWithdraw(address owner) public view override returns (uint256) {
        if (paused()) return 0;
        return convertToAssets(balanceOf(owner));
    }

    function maxRedeem(address owner) public view override returns (uint256) {
        if (paused()) return 0;
        return balanceOf(owner);
    }

    function deposit(uint256 assets, address receiver) public override nonReentrant whenNotPaused returns (uint256) {
        require(assets >= MIN_DEPOSIT, "MIN_DEPOSIT");
        require(_poolKeySet, "POOL_KEY_NOT_SET");
        _bootstrapAndCheckNav();
        _pullReserveProceedsBoth();
        if (maxTVL > 0) require(totalAssets() + assets <= maxTVL, "TVL_CAP");
        if (balanceOf(receiver) == 0) totalDepositors++;

        uint256 shares = previewDeposit(assets);
        _deposit(msg.sender, receiver, assets, shares);
        _deployBalancedLiquidity(0);
        return shares;
    }

    function mint(uint256 shares, address receiver)
        public
        override
        nonReentrant
        whenNotPaused
        returns (uint256 assets)
    {
        require(_poolKeySet, "POOL_KEY_NOT_SET");
        _bootstrapAndCheckNav();
        _pullReserveProceedsBoth();
        assets = previewMint(shares);
        require(assets >= MIN_DEPOSIT, "MIN_DEPOSIT");
        if (maxTVL > 0) require(totalAssets() + assets <= maxTVL, "TVL_CAP");
        if (balanceOf(receiver) == 0) totalDepositors++;

        _deposit(msg.sender, receiver, assets, shares);
        _deployBalancedLiquidity(0);
    }

    /// @notice Fair-zap deposit: shares are minted from the NAV delta produced
    ///         after the zap-and-LP is realised, not from the gross `assets`
    ///         the caller supplied. This prevents existing depositors from
    ///         eating the new depositor's swap cost / slippage.
    /// @param  minSharesOut user-side guard against unexpectedly low share mint
    ///         (e.g. severe zap slippage). Set to 0 to opt out.
    function depositWithZap(
        uint256 assets,
        address receiver,
        uint256 assetsToSwap,
        uint256 minOtherOut,
        uint256 minLiquidity,
        uint256 minSharesOut,
        uint256 deadline
    ) external nonReentrant whenNotPaused returns (uint256 shares) {
        require(assets >= MIN_DEPOSIT, "MIN_DEPOSIT");
        require(_poolKeySet, "POOL_KEY_NOT_SET");
        require(assetsToSwap <= assets, "SWAP_TOO_LARGE");
        _bootstrapAndCheckNav();
        _pullReserveProceedsBoth();
        if (maxTVL > 0) require(totalAssets() + assets <= maxTVL, "TVL_CAP");

        // Snapshot BEFORE pulling assets so existing-LP NAV is the baseline.
        uint256 totalBefore = totalAssets();
        uint256 supplyBefore = totalSupply();

        IERC20(asset()).safeTransferFrom(msg.sender, address(this), assets);

        if (assetsToSwap > 0) {
            _executeZap(asset(), assetsToSwap, _otherToken(), minOtherOut, deadline);
        }

        uint128 liquidity = _deployBalancedLiquidity(minLiquidity);
        require(liquidity >= minLiquidity, "MIN_LIQUIDITY");

        uint256 totalAfter = totalAssets();
        uint256 netAdded = totalAfter > totalBefore ? totalAfter - totalBefore : 0;
        require(netAdded > 0, "NO_NET_VALUE_ADDED");

        // ERC-4626 virtual-share formula, with `netAdded` standing in for `assets`
        // and the pre-deposit NAV used as the denominator.
        if (supplyBefore == 0) {
            shares = netAdded * (10 ** _decimalsOffset());
        } else {
            shares = netAdded.mulDiv(
                supplyBefore + 10 ** _decimalsOffset(),
                totalBefore + 1,
                Math.Rounding.Floor
            );
        }
        require(shares >= minSharesOut, "MIN_SHARES_OUT");
        require(shares > 0, "ZERO_SHARES");

        if (balanceOf(receiver) == 0) totalDepositors++;
        _mint(receiver, shares);

        emit Deposit(msg.sender, receiver, assets, shares);
        emit ZapDeposit(msg.sender, receiver, assets, assetsToSwap, shares);
    }

    function withdraw(uint256 assets, address receiver, address owner)
        public
        override
        nonReentrant
        whenNotPaused
        returns (uint256 shares)
    {
        _bootstrapAndCheckNav();
        _pullReserveProceedsBoth();
        shares = previewWithdraw(assets);
        _prepareWithdraw(assets);
        require(IERC20(asset()).balanceOf(address(this)) >= assets, "INSUFFICIENT_ASSET_USE_ZAP");
        _withdraw(msg.sender, receiver, owner, assets, shares);
        if (balanceOf(owner) == 0 && totalDepositors > 0) totalDepositors--;
    }

    function redeem(uint256 shares, address receiver, address owner)
        public
        override
        nonReentrant
        whenNotPaused
        returns (uint256 assets)
    {
        _bootstrapAndCheckNav();
        _pullReserveProceedsBoth();
        assets = previewRedeem(shares);
        _prepareWithdraw(assets);
        require(IERC20(asset()).balanceOf(address(this)) >= assets, "INSUFFICIENT_ASSET_USE_ZAP");
        _withdraw(msg.sender, receiver, owner, assets, shares);
        if (balanceOf(owner) == 0 && totalDepositors > 0) totalDepositors--;
    }

    function withdrawWithZap(
        uint256 assets,
        address receiver,
        address owner,
        uint256 otherToSwap,
        uint256 minAssetOut,
        uint256 deadline
    ) external nonReentrant whenNotPaused returns (uint256 shares) {
        _bootstrapAndCheckNav();
        _pullReserveProceedsBoth();
        shares = previewWithdraw(assets);
        _prepareWithdraw(assets);
        _swapOtherForAssetIfNeeded(assets, otherToSwap, minAssetOut, deadline);
        _withdraw(msg.sender, receiver, owner, assets, shares);
        if (balanceOf(owner) == 0 && totalDepositors > 0) totalDepositors--;
        emit ZapWithdraw(msg.sender, receiver, owner, assets, shares);
    }

    function redeemWithZap(
        uint256 shares,
        address receiver,
        address owner,
        uint256 otherToSwap,
        uint256 minAssetOut,
        uint256 deadline
    ) external nonReentrant whenNotPaused returns (uint256 assets) {
        _bootstrapAndCheckNav();
        _pullReserveProceedsBoth();
        assets = previewRedeem(shares);
        _prepareWithdraw(assets);
        _swapOtherForAssetIfNeeded(assets, otherToSwap, minAssetOut, deadline);
        _withdraw(msg.sender, receiver, owner, assets, shares);
        if (balanceOf(owner) == 0 && totalDepositors > 0) totalDepositors--;
        emit ZapWithdraw(msg.sender, receiver, owner, assets, shares);
    }

    function _executeZap(
        address tokenIn,
        uint256 amountInMax,
        address tokenOut,
        uint256 minAmountOut,
        uint256 deadline
    ) internal returns (uint256 amountOut) {
        require(zapRouter != address(0), "ZAP_ROUTER_NOT_SET");
        require(deadline >= block.timestamp, "DEADLINE");
        require(amountInMax <= type(uint160).max, "AMOUNT_TOO_LARGE");

        uint256 outBefore = IERC20(tokenOut).balanceOf(address(this));
        IERC20(tokenIn).forceApprove(zapRouter, 0);
        IERC20(tokenIn).forceApprove(zapRouter, amountInMax);
        IZapRouter(zapRouter).swapExactInput(tokenIn, tokenOut, amountInMax, minAmountOut, address(this), deadline);
        IERC20(tokenIn).forceApprove(zapRouter, 0);

        amountOut = IERC20(tokenOut).balanceOf(address(this)) - outBefore;
        require(amountOut >= minAmountOut, "MIN_ZAP_OUT");
        emit ZapExecuted(tokenIn, tokenOut, amountInMax, amountOut);
    }

    function _deployBalancedLiquidity(uint256 minLiquidity) internal returns (uint128 liquidity) {
        if (!_poolKeySet) return 0;

        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolKey.toId());
        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(tickUpper);
        require(sqrtPriceX96 >= sqrtLower && sqrtPriceX96 < sqrtUpper, "RANGE_NOT_ACTIVE");

        address token0 = Currency.unwrap(poolKey.currency0);
        address token1 = Currency.unwrap(poolKey.currency1);
        uint256 amount0Max = IERC20(token0).balanceOf(address(this));
        uint256 amount1Max = IERC20(token1).balanceOf(address(this));

        liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96, sqrtLower, sqrtUpper, amount0Max, amount1Max
        );
        if (liquidity == 0) {
            require(minLiquidity == 0, "MIN_LIQUIDITY");
            return 0;
        }
        require(liquidity >= minLiquidity, "MIN_LIQUIDITY");

        require(amount0Max <= type(uint128).max && amount1Max <= type(uint128).max, "AMOUNT_TOO_LARGE");
        uint256 balance0Before = IERC20(token0).balanceOf(address(this));
        uint256 balance1Before = IERC20(token1).balanceOf(address(this));

        bytes memory actions;
        bytes[] memory params = new bytes[](2);
        if (positionTokenId == 0) {
            actions = abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR));
            params[0] = abi.encode(
                poolKey,
                tickLower,
                tickUpper,
                liquidity,
                uint128(amount0Max),
                uint128(amount1Max),
                address(this),
                ""
            );
            positionTokenId = positionManager.nextTokenId();
        } else {
            actions = abi.encodePacked(uint8(Actions.INCREASE_LIQUIDITY), uint8(Actions.SETTLE_PAIR));
            params[0] = abi.encode(positionTokenId, liquidity, uint128(amount0Max), uint128(amount1Max), "");
        }
        params[1] = abi.encode(poolKey.currency0, poolKey.currency1);

        _approveForPositionManager(amount0Max, amount1Max);
        positionManager.modifyLiquidities(abi.encode(actions, params), block.timestamp + txDeadlineSeconds);

        uint256 spent0 = balance0Before - IERC20(token0).balanceOf(address(this));
        uint256 spent1 = balance1Before - IERC20(token1).balanceOf(address(this));

        totalLiquidityDeployed += liquidity;
        assetsDeployed += assetIsToken0 ? spent0 : spent1;
        emit LiquidityDeployed(spent0, spent1, liquidity);
    }

    function _prepareWithdraw(uint256 assets) internal {
        _collectYield();
        uint256 currentTotal = totalAssets();
        if (assets > 0 && currentTotal > 0) {
            uint256 proportion = assets.mulDiv(1e18, currentTotal);
            _removeLiquidity(proportion);
        }
    }

    function _swapOtherForAssetIfNeeded(
        uint256 assetsNeeded,
        uint256 maxOtherToSwap,
        uint256 minAssetOut,
        uint256 deadline
    ) internal {
        if (IERC20(asset()).balanceOf(address(this)) >= assetsNeeded) return;
        require(maxOtherToSwap > 0, "OTHER_SWAP_REQUIRED");
        address other = _otherToken();
        uint256 otherBalance = IERC20(other).balanceOf(address(this));
        uint256 amountToSwap = otherBalance < maxOtherToSwap ? otherBalance : maxOtherToSwap;
        require(amountToSwap > 0, "NO_OTHER_TOKEN");
        _executeZap(other, amountToSwap, asset(), minAssetOut, deadline);
        require(IERC20(asset()).balanceOf(address(this)) >= assetsNeeded, "INSUFFICIENT_ASSET_OUT");
    }

    function _approveForPositionManager(uint256 amount0, uint256 amount1) internal {
        if (permit2 != address(0)) {
            IAllowanceTransfer(permit2).approve(
                Currency.unwrap(poolKey.currency0),
                address(positionManager),
                uint160(amount0),
                uint48(block.timestamp + txDeadlineSeconds)
            );
            IAllowanceTransfer(permit2).approve(
                Currency.unwrap(poolKey.currency1),
                address(positionManager),
                uint160(amount1),
                uint48(block.timestamp + txDeadlineSeconds)
            );
        } else {
            IERC20(Currency.unwrap(poolKey.currency0)).forceApprove(address(positionManager), amount0);
            IERC20(Currency.unwrap(poolKey.currency1)).forceApprove(address(positionManager), amount1);
        }
    }

    function _removeLiquidity(uint256 proportion) internal {
        if (totalLiquidityDeployed == 0 || positionTokenId == 0) return;

        uint128 liquidityToRemove = uint128(totalLiquidityDeployed.mulDiv(proportion, 1e18));
        if (liquidityToRemove == 0) return;

        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolKey.toId());
        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(tickUpper);
        (uint256 exp0, uint256 exp1) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtPriceX96, sqrtLower, sqrtUpper, liquidityToRemove
        );
        uint256 amount0Min = exp0 * (10_000 - removeLiquiditySlippageBps) / 10_000;
        uint256 amount1Min = exp1 * (10_000 - removeLiquiditySlippageBps) / 10_000;

        bytes memory actions = abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(positionTokenId, liquidityToRemove, amount0Min, amount1Min, "");
        params[1] = abi.encode(poolKey.currency0, poolKey.currency1, address(this));

        positionManager.modifyLiquidities(abi.encode(actions, params), block.timestamp + txDeadlineSeconds);

        totalLiquidityDeployed -= liquidityToRemove;
        if (totalLiquidityDeployed == 0) positionTokenId = 0;
        assetsDeployed = IERC20(asset()).balanceOf(address(this));
        emit LiquidityRemoved(exp0, exp1, liquidityToRemove);
    }

    function _collectYield() internal {
        if (positionTokenId == 0) return;

        bytes memory actions = abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(positionTokenId, uint128(0), 0, 0, "");
        params[1] = abi.encode(poolKey.currency0, poolKey.currency1, address(this));

        uint256 assetBefore = IERC20(asset()).balanceOf(address(this));
        address other = _otherToken();
        uint256 otherBefore = IERC20(other).balanceOf(address(this));

        positionManager.modifyLiquidities(abi.encode(actions, params), block.timestamp + txDeadlineSeconds);

        uint256 assetGain = IERC20(asset()).balanceOf(address(this)) - assetBefore;
        uint256 otherGain = IERC20(other).balanceOf(address(this)) - otherBefore;
        if (otherGain > 0) {
            otherTokenYieldCollected += otherGain;
            emit OtherTokenYieldCollected(otherGain, block.timestamp);
        }
        if (assetGain > 0) {
            if (performanceFeeBps > 0 && treasury != address(0)) {
                uint256 fee = assetGain * performanceFeeBps / 10_000;
                if (fee > 0) {
                    IERC20(asset()).safeTransfer(treasury, fee);
                    assetGain -= fee;
                    emit PerformanceFeePaid(treasury, fee);
                }
            }
            totalYieldCollected += assetGain;
            emit YieldCollected(assetGain, block.timestamp);
        }
        lastYieldUpdate = block.timestamp;
    }

    function collectYield() external nonReentrant {
        _collectYield();
    }

    function setPoolKey(PoolKey calldata _poolKey) external onlyOwner {
        require(!_poolKeySet, "ALREADY_SET");
        // Reject native-ETH pools. Vault, hook and zap adapter all assume
        // ERC-20 currencies (forceApprove, transferFrom, balanceOf). Native
        // support is a separate, larger feature — fail closed here so a
        // misconfiguration cannot brick the vault silently.
        require(
            Currency.unwrap(_poolKey.currency0) != address(0)
                && Currency.unwrap(_poolKey.currency1) != address(0),
            "NATIVE_NOT_SUPPORTED"
        );
        bool _isToken0 = Currency.unwrap(_poolKey.currency0) == asset();
        require(_isToken0 || Currency.unwrap(_poolKey.currency1) == asset(), "ASSET_NOT_IN_POOL");
        poolKey = _poolKey;
        assetIsToken0 = _isToken0;
        _poolKeySet = true;

        if (permit2 != address(0)) {
            IERC20(Currency.unwrap(_poolKey.currency0)).forceApprove(permit2, type(uint256).max);
            IERC20(Currency.unwrap(_poolKey.currency1)).forceApprove(permit2, type(uint256).max);
        }
        emit PoolKeySet(PoolId.unwrap(_poolKey.toId()));
    }

    function rebalance(int24 newTickLower, int24 newTickUpper, uint256 minLiquidity) external onlyOwner nonReentrant {
        require(_poolKeySet, "POOL_KEY_NOT_SET");
        require(newTickLower < newTickUpper, "INVALID_TICKS");
        _collectYield();
        if (totalLiquidityDeployed > 0 && positionTokenId != 0) {
            _removeLiquidity(1e18);
        }
        positionTokenId = 0;
        tickLower = newTickLower;
        tickUpper = newTickUpper;
        _deployBalancedLiquidity(minLiquidity);
        emit Rebalanced(newTickLower, newTickUpper);
    }

    /// @notice Configure the initial tick band before any liquidity is deployed.
    /// @dev    Cheap pre-launch knob. Reverts after first deposit so that an
    ///         active position cannot be silently moved without going through
    ///         the full {rebalance} (remove → redeploy) flow.
    function setInitialTicks(int24 newTickLower, int24 newTickUpper) external onlyOwner {
        require(_poolKeySet, "POOL_KEY_NOT_SET");
        require(totalLiquidityDeployed == 0 && positionTokenId == 0, "POSITION_LIVE");
        require(newTickLower < newTickUpper, "INVALID_TICKS");
        int24 spacing = poolKey.tickSpacing;
        require(newTickLower % spacing == 0 && newTickUpper % spacing == 0, "TICK_NOT_ALIGNED");
        require(newTickLower >= TickMath.MIN_TICK && newTickUpper <= TickMath.MAX_TICK, "TICK_OUT_OF_BOUNDS");
        tickLower = newTickLower;
        tickUpper = newTickUpper;
        emit Rebalanced(newTickLower, newTickUpper);
    }

    function setZapRouter(address newRouter) external onlyOwner {
        require(newRouter == address(0) || newRouter.code.length > 0, "NOT_CONTRACT");
        emit ZapRouterUpdated(zapRouter, newRouter);
        zapRouter = newRouter;
    }

    /// @notice Bind the reserve-sale hook (must equal poolKey.hooks for offers to fire).
    function setReserveHook(address newHook) external onlyOwner {
        require(newHook == address(0) || newHook.code.length > 0, "NOT_CONTRACT");
        emit ReserveHookUpdated(reserveHook, newHook);
        reserveHook = newHook;
    }

    /// @notice Bind (or unbind) the BootstrapRewards bonus program. Setting
    ///         to address(0) disables auto-poke; non-zero must be a contract.
    function setBootstrapRewards(address newRewards) external onlyOwner {
        require(newRewards == address(0) || newRewards.code.length > 0, "NOT_CONTRACT");
        emit BootstrapRewardsUpdated(bootstrapRewards, newRewards);
        bootstrapRewards = newRewards;
    }

    /// @notice Re-anchor `navReferenceSqrtPriceX96` to the current pool spot.
    ///         Use after a legitimate price move has tripped the deviation
    ///         guard. Owner-only because re-anchoring effectively re-prices
    ///         pending deposits/redemptions; it must not be permissionless.
    function refreshNavReference() external onlyOwner {
        require(_poolKeySet, "POOL_KEY_NOT_SET");
        (uint160 spot,,,) = poolManager.getSlot0(poolKey.toId());
        require(spot != 0, "POOL_NOT_INIT");
        uint160 old = navReferenceSqrtPriceX96;
        navReferenceSqrtPriceX96 = spot;
        emit NavReferenceRefreshed(old, spot);
    }

    /// @notice Update the NAV deviation tolerance. Bps of PRICE deviation
    ///         (token1/token0). Capped at MAX_NAV_DEVIATION_CAP.
    function setMaxNavDeviationBps(uint256 newBps) external onlyOwner {
        require(newBps <= MAX_NAV_DEVIATION_CAP, "BPS_TOO_HIGH");
        emit MaxNavDeviationBpsUpdated(maxNavDeviationBps, newBps);
        maxNavDeviationBps = newBps;
    }

    /// @notice Escrow vault inventory at the hook as a reserve offer.
    /// @param  sellCurrency must be one of the pool currencies.
    /// @param  sellAmount inventory to lock at the hook (vault must hold it).
    /// @param  vaultSqrtPriceX96 vault's chosen sale sqrt-price.
    /// @param  expiry unix seconds; 0 disables expiry.
    function offerReserveToHook(
        Currency sellCurrency,
        uint128 sellAmount,
        uint160 vaultSqrtPriceX96,
        uint64 expiry
    ) external onlyOwner nonReentrant {
        require(_poolKeySet, "POOL_KEY_NOT_SET");
        require(reserveHook != address(0), "HOOK_NOT_SET");
        require(sellAmount > 0, "ZERO_AMOUNT");
        IERC20 tok = IERC20(Currency.unwrap(sellCurrency));
        tok.forceApprove(reserveHook, 0);
        tok.forceApprove(reserveHook, sellAmount);
        IReserveHook(reserveHook).createReserveOffer(poolKey, sellCurrency, sellAmount, vaultSqrtPriceX96, expiry);
        tok.forceApprove(reserveHook, 0);
        emit ReserveOfferEscrowed(Currency.unwrap(sellCurrency), sellAmount, vaultSqrtPriceX96, expiry);
    }

    /// @notice Cancel the active reserve offer; remaining inventory returns to vault.
    function cancelReserveOffer(Currency sellCurrency) external onlyOwner nonReentrant returns (uint128 returned) {
        require(reserveHook != address(0), "HOOK_NOT_SET");
        returned = IReserveHook(reserveHook).cancelReserveOffer(poolKey);
        emit ReserveOfferReturned(Currency.unwrap(sellCurrency), returned);
    }

    /// @notice Pull accumulated proceeds (in `currency`) from the hook back into the vault.
    function collectReserveProceeds(Currency currency) external nonReentrant returns (uint256 amount) {
        require(reserveHook != address(0), "HOOK_NOT_SET");
        amount = IReserveHook(reserveHook).claimReserveProceeds(currency);
        if (amount > 0) emit ReserveProceedsCollected(Currency.unwrap(currency), amount);
    }

    /// @notice Atomic offer rotation: cancel-existing → claim both proceeds →
    ///         repost at the new size and price. One tx replaces three;
    ///         removes the "operator forgot to collectReserveProceeds" footgun.
    /// @param  sellCurrency must be one of the pool currencies.
    /// @param  newSellAmount inventory to lock in the fresh offer.
    /// @param  newSqrtPriceX96 vault's new sale sqrt-price.
    /// @param  expiry unix seconds; 0 disables expiry.
    function rebalanceOffer(
        Currency sellCurrency,
        uint128 newSellAmount,
        uint160 newSqrtPriceX96,
        uint64 expiry
    ) external onlyOwner nonReentrant {
        require(_poolKeySet, "POOL_KEY_NOT_SET");
        require(reserveHook != address(0), "HOOK_NOT_SET");
        require(newSellAmount > 0, "ZERO_AMOUNT");

        IReserveHook h = IReserveHook(reserveHook);

        // 1) Cancel any existing offer behind an explicit `offerActive` view
        //    gate. Previous version used `try/catch` which silently swallowed
        //    real failures (wrong pool key, paused hook, accounting bug)
        //    and would then post on top of broken state. With the gate,
        //    only the "no offer" branch is skipped; real cancel reverts
        //    bubble up and abort the rotation.
        if (h.offerActive(poolKey)) {
            uint128 returned = h.cancelReserveOffer(poolKey);
            if (returned > 0) emit ReserveOfferReturned(Currency.unwrap(sellCurrency), returned);
        }

        // 2) Claim any proceeds the hook is still holding for this vault, in
        //    BOTH currencies. Either or both may be zero.
        Currency c0 = poolKey.currency0;
        Currency c1 = poolKey.currency1;
        uint256 a0 = h.claimReserveProceeds(c0);
        if (a0 > 0) emit ReserveProceedsCollected(Currency.unwrap(c0), a0);
        uint256 a1 = h.claimReserveProceeds(c1);
        if (a1 > 0) emit ReserveProceedsCollected(Currency.unwrap(c1), a1);

        // 3) Post the fresh offer.
        IERC20 tok = IERC20(Currency.unwrap(sellCurrency));
        tok.forceApprove(reserveHook, 0);
        tok.forceApprove(reserveHook, newSellAmount);
        h.createReserveOffer(poolKey, sellCurrency, newSellAmount, newSqrtPriceX96, expiry);
        tok.forceApprove(reserveHook, 0);
        emit ReserveOfferEscrowed(Currency.unwrap(sellCurrency), newSellAmount, newSqrtPriceX96, expiry);
    }

    function setTreasury(address newTreasury) external onlyOwner {
        require(newTreasury != address(0), "ZERO_ADDRESS");
        emit TreasuryUpdated(treasury, newTreasury);
        treasury = newTreasury;
    }

    function setPerformanceFeeBps(uint256 newBps) external onlyOwner {
        require(newBps <= 2000, "FEE_TOO_HIGH");
        emit PerformanceFeeUpdated(performanceFeeBps, newBps);
        performanceFeeBps = newBps;
    }

    function setMaxTVL(uint256 newMax) external onlyOwner {
        emit MaxTVLUpdated(maxTVL, newMax);
        maxTVL = newMax;
    }

    function setRemoveLiquiditySlippageBps(uint256 newBps) external onlyOwner {
        // Hard cap at 1% (100 bps). Withdraw paths must not silently eat more
        // than 1% of NAV due to position-removal slippage; depositors trust this.
        require(newBps <= 100, "SLIPPAGE_TOO_HIGH");
        emit RemoveLiquiditySlippageBpsUpdated(removeLiquiditySlippageBps, newBps);
        removeLiquiditySlippageBps = newBps;
    }

    function setTxDeadlineSeconds(uint256 newSeconds) external onlyOwner {
        require(newSeconds > 0 && newSeconds <= 3_600, "DEADLINE_OUT_OF_RANGE");
        emit TxDeadlineUpdated(txDeadlineSeconds, newSeconds);
        txDeadlineSeconds = newSeconds;
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    /// @notice Owner-only emergency rescue for native ETH that bypassed the
    ///         reverting receive/fallback (e.g. via SELFDESTRUCT or block
    ///         reward forwarding). The vault is ERC-20-only; any ETH balance
    ///         here is unintended dust and is not part of NAV.
    function rescueNative(address payable to, uint256 amount) external onlyOwner nonReentrant {
        require(to != address(0), "ZERO_ADDRESS");
        require(amount <= address(this).balance, "AMOUNT_EXCEEDS_BALANCE");
        (bool ok, ) = to.call{value: amount}("");
        require(ok, "NATIVE_TRANSFER_FAILED");
        emit NativeRescued(to, amount);
    }

    function _otherToken() internal view returns (address) {
        if (!_poolKeySet) return address(0);
        return assetIsToken0 ? Currency.unwrap(poolKey.currency1) : Currency.unwrap(poolKey.currency0);
    }

    /// @notice Pull every claimable reserve-sale proceed from the hook into the
    ///         vault before any share-math runs. This guarantees `totalAssets()`
    ///         reflects already-realised proceeds physically, not just as a
    ///         pending reading. Called from deposit/mint/withdraw/redeem.
    function _pullReserveProceedsBoth() internal {
        if (reserveHook == address(0) || !_poolKeySet) return;
        IReserveHook h = IReserveHook(reserveHook);
        Currency c0 = poolKey.currency0;
        Currency c1 = poolKey.currency1;
        if (h.proceedsOwed(address(this), c0) > 0) {
            uint256 a0 = h.claimReserveProceeds(c0);
            if (a0 > 0) emit ReserveProceedsCollected(Currency.unwrap(c0), a0);
        }
        if (h.proceedsOwed(address(this), c1) > 0) {
            uint256 a1 = h.claimReserveProceeds(c1);
            if (a1 > 0) emit ReserveProceedsCollected(Currency.unwrap(c1), a1);
        }
    }

    /// @notice ERC20 hook override. Auto-pokes the BootstrapRewards bonus
    ///         program for both ends of any share movement (mint, burn, or
    ///         transfer) so depositors never need to remember to poke.
    /// @dev    The poke is wrapped in try/catch and emits BootstrapPokeFailed
    ///         on revert so a misbehaving rewards contract can never block
    ///         vault deposits, withdrawals, or share transfers.
    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        address rewards = bootstrapRewards;
        if (rewards == address(0)) return;
        if (from != address(0)) _pokeBootstrap(rewards, from);
        if (to != address(0)) _pokeBootstrap(rewards, to);
    }

    function _pokeBootstrap(address rewards, address user) private {
        try IBootstrapRewardsPoke(rewards).poke(user) {
            // ok
        } catch (bytes memory reason) {
            emit BootstrapPokeFailed(user, reason);
        }
    }
}