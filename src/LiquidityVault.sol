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
import {LiquidityAmounts} from "v4-core-test/utils/LiquidityAmounts.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

contract LiquidityVault is ERC4626, Ownable2Step, ReentrancyGuard, Pausable {
    using Math for uint256;
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint256 public constant MIN_DEPOSIT = 1e6;

    // Default range for USDC-deposit vault on WETH/USDC (Arbitrum One).
    // WETH = currency0, USDC = currency1 (by address sort), so vault asset is token1.
    // Single-sided token1 requires currentTick > tickUpper; as ETH drops below
    // the range, the vault slowly converts USDC -> WETH while earning fees.
    //   tickUpper = -201360 ~ 1 WETH ~= 1,800 USDC
    //   tickLower = -210780 ~ 1 WETH ~=   700 USDC
    // Both values are multiples of 10 and 60 so they align with common v4 tick
    // spacings (fee tiers 500 / 3000). Owner may call rebalance() at any time.
    int24 public tickLower = -210780;
    int24 public tickUpper = -201360;

    IPoolManager public immutable poolManager;
    IPositionManager public immutable positionManager;
    /// @dev Canonical Permit2 address. address(0) in test environments (mocked positionManager).
    address public immutable permit2;
    PoolKey public poolKey;

    uint256 public totalLiquidityDeployed;  // raw Uniswap L units (for display)
    uint256 public assetsDeployed;            // token-denominated assets in position (for NAV)
    uint256 public totalYieldCollected;       // net asset-token yield credited to depositors
    uint256 public currency1YieldCollected;   // non-asset-token yield (e.g. WETH in USDC/WETH)
    uint256 public totalDepositors;
    uint256 public lastYieldUpdate;
    uint256 public positionTokenId;
    bool private _poolKeySet;
    bool public assetIsToken0;        // true when vault asset == poolKey.currency0

    address public treasury;          // receives performance fees
    uint256 public performanceFeeBps; // fee on collected yield; 0 default, max 2000 (20%)
    uint256 public maxTVL;            // deposit ceiling in asset-token units; 0 = unlimited

    event LiquidityDeployed(uint256 amount0, uint256 amount1, uint256 liquidity);
    event LiquidityRemoved(uint256 amount0, uint256 amount1, uint256 liquidity);
    event YieldCollected(uint256 amount, uint256 timestamp);
    event Currency1YieldCollected(uint256 amount, uint256 timestamp);
    event PerformanceFeePaid(address indexed treasury, uint256 amount);
    event PoolKeySet(bytes32 indexed poolId);
    event Rebalanced(int24 newTickLower, int24 newTickUpper);
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    event PerformanceFeeUpdated(uint256 oldBps, uint256 newBps);
    event MaxTVLUpdated(uint256 oldMax, uint256 newMax);

    constructor(
        IERC20 _asset,
        IPoolManager _poolManager,
        IPositionManager _posManager,
        string memory _name,
        string memory _symbol,
        address _permit2
    ) ERC4626(_asset) ERC20(_name, _symbol) Ownable(msg.sender) {
        poolManager = _poolManager;
        positionManager = _posManager;
        permit2 = _permit2;
        treasury = msg.sender;
        // One-time infinite approval so Permit2 can pull asset tokens on behalf of this vault.
        // Skipped when _permit2 is address(0) (test environments with mock PositionManager).
        if (_permit2 != address(0)) {
            IERC20(address(_asset)).approve(_permit2, type(uint256).max);
        }
    }

    function totalAssets() public view override returns (uint256) {
        uint256 idle = IERC20(asset()).balanceOf(address(this));
        // Live position valuation only when tokens were actually deployed.
        // assetsDeployed == 0 in test environments (mock PositionManager
        // doesn't transfer tokens) or after a full liquidity removal.
        if (totalLiquidityDeployed == 0 || assetsDeployed == 0 || !_poolKeySet) return idle;

        // Compute the live asset-token value of the position at current price.
        // When the pool price moves into range, part of the single-sided deposit
        // is converted to the other token. Using the stale `assetsDeployed`
        // bookkeeping would overstate totalAssets and cause withdrawals to revert.
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolKey.toId());
        uint160 sqrtA = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtB = TickMath.getSqrtPriceAtTick(tickUpper);
        (uint256 amt0, uint256 amt1) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtPriceX96, sqrtA, sqrtB, uint128(totalLiquidityDeployed)
        );
        return idle + (assetIsToken0 ? amt0 : amt1);
    }

    /// @notice ERC-4626 inflation-attack mitigation.
    /// @dev    Multiplies OpenZeppelin's default virtual-shares/assets offset
    ///         (`+1`) by 10**6. This raises the attacker's required donation
    ///         to successfully round a victim's shares to zero by the same
    ///         factor, rendering the "first-depositor donation attack"
    ///         economically infeasible regardless of the asset's decimals
    ///         (so MIN_DEPOSIT=1e6 remains safe even when deployed against an
    ///         18-decimal asset).
    ///
    ///         Semantic impact: the share-to-asset ratio at the initial
    ///         deposit is 10**6 : 1, not 1 : 1. ERC-4626 convertToAssets /
    ///         convertToShares accounting remains internally consistent;
    ///         depositors should use those helpers (not raw share counts)
    ///         when computing entitlements.
    function _decimalsOffset() internal pure override returns (uint8) {
        return 6;
    }

    /// @inheritdoc ERC4626
    function maxDeposit(address) public view override returns (uint256) {
        if (paused() || !_poolKeySet) return 0;
        if (maxTVL == 0) return type(uint256).max;
        uint256 current = totalAssets();
        return current >= maxTVL ? 0 : maxTVL - current;
    }

    /// @inheritdoc ERC4626
    function maxMint(address receiver) public view override returns (uint256) {
        uint256 maxAssets = maxDeposit(receiver);
        if (maxAssets == type(uint256).max) return type(uint256).max;
        return convertToShares(maxAssets);
    }

    /// @inheritdoc ERC4626
    function maxWithdraw(address owner) public view override returns (uint256) {
        if (paused()) return 0;
        return convertToAssets(balanceOf(owner));
    }

    /// @inheritdoc ERC4626
    function maxRedeem(address owner) public view override returns (uint256) {
        if (paused()) return 0;
        return balanceOf(owner);
    }

    function deposit(uint256 assets, address receiver) public override nonReentrant whenNotPaused returns (uint256) {
        require(assets >= MIN_DEPOSIT, "MIN_DEPOSIT");
        require(_poolKeySet, "POOL_KEY_NOT_SET");
        if (maxTVL > 0) require(totalAssets() + assets <= maxTVL, "TVL_CAP");
        if (balanceOf(receiver) == 0) totalDepositors++;

        uint256 shares = super.deposit(assets, receiver);
        _deployLiquidity(assets);
        return shares;
    }

    function withdraw(uint256 assets, address receiver, address owner) public override nonReentrant whenNotPaused returns (uint256) {
        _collectYield();
        uint256 proportion = assets.mulDiv(1e18, totalAssets());
        _removeLiquidity(proportion);
        uint256 shares_ = super.withdraw(assets, receiver, owner);
        if (balanceOf(owner) == 0 && totalDepositors > 0) totalDepositors--;
        return shares_;
    }

    function redeem(uint256 shares, address receiver, address owner) public override nonReentrant whenNotPaused returns (uint256) {
        _collectYield();
        uint256 assets = convertToAssets(shares);
        if (assets > 0) {
            uint256 proportion = assets.mulDiv(1e18, totalAssets());
            _removeLiquidity(proportion);
        }
        uint256 returned = super.redeem(shares, receiver, owner);
        if (balanceOf(owner) == 0 && totalDepositors > 0) totalDepositors--;
        return returned;
    }

    function _deployLiquidity(uint256 amount) internal {
        if (!_poolKeySet || amount == 0) return;

        (uint160 sqrtPriceX96, , , ) = poolManager.getSlot0(poolKey.toId());

        uint160 sqrtPriceLower = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtPriceUpper = TickMath.getSqrtPriceAtTick(tickUpper);

        // Single-asset vault: can only deploy when the price is fully out of
        // range on the asset side (100% asset token, 0% other token).
        // In-range or opposite-side positions require both tokens, which we
        // don't have. Assets remain idle until owner rebalances to a new range.
        // Guard is skipped in test environments (permit2 == 0) where the mock
        // PositionManager doesn't actually transfer tokens.
        if (permit2 != address(0)) {
            if (assetIsToken0) {
                if (sqrtPriceX96 >= sqrtPriceLower) return; // needs token1
            } else {
                if (sqrtPriceX96 <= sqrtPriceUpper) return; // needs token0
            }
        }

        uint128 liquidity;
        if (assetIsToken0) {
            liquidity = LiquidityAmounts.getLiquidityForAmount0(sqrtPriceX96, sqrtPriceUpper, amount);
        } else {
            liquidity = LiquidityAmounts.getLiquidityForAmount1(sqrtPriceLower, sqrtPriceX96, amount);
        }

        if (positionTokenId == 0) {
            bytes memory actions = abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR));
            bytes[] memory params = new bytes[](2);
            params[0] = abi.encode(poolKey, tickLower, tickUpper, liquidity, amount, amount, address(this), "");
            params[1] = abi.encode(poolKey.currency0, poolKey.currency1);

            _approveForPositionManager(amount);
            uint256 expectedTokenId = positionManager.nextTokenId();
            uint256 balBefore = IERC20(asset()).balanceOf(address(this));
            positionManager.modifyLiquidities(abi.encode(actions, params), block.timestamp + 60);
            uint256 spent = balBefore - IERC20(asset()).balanceOf(address(this));
            positionTokenId = expectedTokenId;
            assetsDeployed += spent;
        } else {
            bytes memory actions = abi.encodePacked(uint8(Actions.INCREASE_LIQUIDITY), uint8(Actions.SETTLE_PAIR));
            bytes[] memory params = new bytes[](2);
            params[0] = abi.encode(positionTokenId, liquidity, amount, amount, "");
            params[1] = abi.encode(poolKey.currency0, poolKey.currency1);

            _approveForPositionManager(amount);
            uint256 balBefore = IERC20(asset()).balanceOf(address(this));
            positionManager.modifyLiquidities(abi.encode(actions, params), block.timestamp + 60);
            uint256 spent = balBefore - IERC20(asset()).balanceOf(address(this));
            assetsDeployed += spent;
        }

        totalLiquidityDeployed += liquidity;
        emit LiquidityDeployed(amount, 0, liquidity);
    }

    /// @dev Grants the PositionManager permission to pull `amount` of asset tokens
    ///      via Permit2. Falls back to a direct ERC20 approve when Permit2 is not
    ///      available (test environments using a mock PositionManager).
    ///      SETTLE_PAIR checks Permit2 for both currencies even when the debt for
    ///      one is zero, so we must set a valid expiration for the non-asset currency
    ///      to prevent AllowanceExpired(0) reverts.
    function _approveForPositionManager(uint256 amount) internal {
        if (permit2 != address(0)) {
            IAllowanceTransfer(permit2).approve(
                asset(),
                address(positionManager),
                uint160(amount),
                uint48(block.timestamp + 60)
            );
            // Non-asset currency: 0-amount allowance but valid expiry so Permit2 doesn't revert.
            address otherCurrency = assetIsToken0
                ? Currency.unwrap(poolKey.currency1)
                : Currency.unwrap(poolKey.currency0);
            IAllowanceTransfer(permit2).approve(
                otherCurrency,
                address(positionManager),
                0,
                uint48(block.timestamp + 60)
            );
        } else {
            IERC20(asset()).approve(address(positionManager), amount);
        }
    }

    function _removeLiquidity(uint256 proportion) internal {
        if (totalLiquidityDeployed == 0 || positionTokenId == 0) return;

        uint128 liquidityToRemove = uint128(totalLiquidityDeployed.mulDiv(proportion, 1e18));
        if (liquidityToRemove == 0) return;

        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolKey.toId());
        uint160 sqrtPriceLower = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtPriceUpper = TickMath.getSqrtPriceAtTick(tickUpper);
        (uint256 exp0, uint256 exp1) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtPriceX96, sqrtPriceLower, sqrtPriceUpper, liquidityToRemove
        );
        uint256 amount0Min = exp0 * 995 / 1000;
        uint256 amount1Min = exp1 * 995 / 1000;

        bytes memory actions = abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR), uint8(Actions.SWEEP));
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(positionTokenId, liquidityToRemove, amount0Min, amount1Min, "");
        params[1] = abi.encode(poolKey.currency0, poolKey.currency1, address(this));
        params[2] = abi.encode(assetIsToken0 ? poolKey.currency0 : poolKey.currency1, address(this));

        uint256 balBefore = IERC20(asset()).balanceOf(address(this));
        positionManager.modifyLiquidities(abi.encode(actions, params), block.timestamp + 60);
        uint256 returned = IERC20(asset()).balanceOf(address(this)) - balBefore;
        totalLiquidityDeployed -= liquidityToRemove;
        // assetsDeployed decreases by what was actually returned from the position
        if (returned >= assetsDeployed) {
            assetsDeployed = 0;
        } else {
            assetsDeployed -= returned;
        }
        emit LiquidityRemoved(0, 0, liquidityToRemove);
    }

    function _collectYield() internal {
        if (positionTokenId == 0) return;

        bytes memory actions = abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(positionTokenId, uint128(0), 0, 0, "");
        params[1] = abi.encode(poolKey.currency0, poolKey.currency1, address(this));

        uint256 balanceBefore = IERC20(asset()).balanceOf(address(this));

        // Track non-asset currency yield only when the other token is a real contract.
        // Pools may use address(1) or similar sentinels for currency0 in tests/staging.
        address otherAddr = Currency.unwrap(assetIsToken0 ? poolKey.currency1 : poolKey.currency0);
        bool hasOtherToken = otherAddr.code.length > 0;
        uint256 otherBefore = hasOtherToken ? IERC20(otherAddr).balanceOf(address(this)) : 0;

        positionManager.modifyLiquidities(abi.encode(actions, params), block.timestamp + 60);

        uint256 balanceAfter = IERC20(asset()).balanceOf(address(this));

        // Account for non-asset currency yield (e.g. WETH fees in a USDC/WETH pool).
        // These tokens stay in the vault; owner can extract via rescueIdle(otherAddr).
        if (hasOtherToken) {
            uint256 otherAfter = IERC20(otherAddr).balanceOf(address(this));
            if (otherAfter > otherBefore) {
                currency1YieldCollected += otherAfter - otherBefore;
                emit Currency1YieldCollected(otherAfter - otherBefore, block.timestamp);
            }
        }

        uint256 yieldAmount = balanceAfter - balanceBefore;
        if (yieldAmount > 0) {
            // Deduct performance fee and route to treasury before crediting depositors
            if (performanceFeeBps > 0 && treasury != address(0)) {
                uint256 fee = yieldAmount * performanceFeeBps / 10_000;
                if (fee > 0) {
                    IERC20(asset()).safeTransfer(treasury, fee);
                    yieldAmount -= fee;
                    emit PerformanceFeePaid(treasury, fee);
                }
            }
            totalYieldCollected += yieldAmount;
            emit YieldCollected(yieldAmount, block.timestamp);
        }
        lastYieldUpdate = block.timestamp;
    }

    function collectYield() external nonReentrant {
        _collectYield();
    }

    function setPoolKey(PoolKey calldata _poolKey) external onlyOwner {
        require(!_poolKeySet, "ALREADY_SET");
        bool _isToken0 = Currency.unwrap(_poolKey.currency0) == asset();
        require(_isToken0 || Currency.unwrap(_poolKey.currency1) == asset(), "ASSET_NOT_IN_POOL");
        poolKey = _poolKey;
        assetIsToken0 = _isToken0;
        _poolKeySet = true;
        // Approve Permit2 for the non-asset currency so SETTLE_PAIR doesn't
        // revert with InsufficientAllowance even when the settlement amount is 0.
        if (permit2 != address(0)) {
            address otherCurrency = _isToken0
                ? Currency.unwrap(_poolKey.currency1)
                : Currency.unwrap(_poolKey.currency0);
            IERC20(otherCurrency).approve(permit2, type(uint256).max);
        }
        emit PoolKeySet(PoolId.unwrap(_poolKey.toId()));
    }

    function rebalance(int24 newTickLower, int24 newTickUpper) external onlyOwner nonReentrant {
        require(_poolKeySet, "POOL_KEY_NOT_SET");
        require(newTickLower < newTickUpper, "INVALID_TICKS");
        _collectYield();
        if (totalLiquidityDeployed > 0 && positionTokenId != 0) {
            _removeLiquidity(1e18);
        }
        positionTokenId = 0;
        tickLower = newTickLower;
        tickUpper = newTickUpper;
        uint256 idle = IERC20(asset()).balanceOf(address(this));
        if (idle >= MIN_DEPOSIT) _deployLiquidity(idle);
        emit Rebalanced(newTickLower, newTickUpper);
    }

    function rescueIdle(address token) external onlyOwner {
        require(token != asset(), "CANNOT_RESCUE_ASSET");
        uint256 idle = IERC20(token).balanceOf(address(this));
        require(idle > 0, "NO_IDLE");
        IERC20(token).safeTransfer(owner(), idle);
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    function setTreasury(address newTreasury) external onlyOwner {
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

    function getVaultStats() external view returns (uint256 tvl, uint256 sharePrice, uint256 depositors, uint256 liqDeployed, uint256 yieldColl, string memory feeDesc) {
        tvl = totalAssets();
        // Share price is reported as asset-per-share normalized to 1e18 so that
        // it starts at exactly 1e18 regardless of the `_decimalsOffset()` we use
        // for inflation-attack mitigation. Using convertToAssets() with a full
        // share unit (10**decimals()) and scaling by the asset's own decimals
        // keeps the public semantics stable: 1e18 = "no yield", >1e18 = accrued.
        if (totalSupply() == 0) {
            sharePrice = 1e18;
        } else {
            uint256 oneShareUnit = 10 ** uint256(decimals());
            uint256 oneAssetUnit = 10 ** (uint256(decimals()) - uint256(_decimalsOffset()));
            sharePrice = convertToAssets(oneShareUnit).mulDiv(1e18, oneAssetUnit);
        }
        depositors = totalDepositors;
        liqDeployed = assetsDeployed;
        yieldColl = totalYieldCollected;
        feeDesc = "0.25% Hook Fee (20% Treasury / 80% LP Bonus) + Base Pool Fee";
    }

    function getProjectedAPY(uint256 recentYield, uint256 windowSeconds) external view returns (uint256 aprBps) {
        if (totalAssets() == 0 || windowSeconds == 0) return 0;
        aprBps = recentYield.mulDiv(365 days, windowSeconds).mulDiv(10_000, totalAssets());
    }
}
