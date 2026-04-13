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

contract LiquidityVault is ERC4626, Ownable2Step, ReentrancyGuard, Pausable {
    using Math for uint256;
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint256 public constant MIN_DEPOSIT = 1e6;

    int24 public tickLower = -230270;
    int24 public tickUpper = -69082;

    IPoolManager public immutable poolManager;
    IPositionManager public immutable positionManager;
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
        string memory _symbol
    ) ERC4626(_asset) ERC20(_name, _symbol) Ownable(msg.sender) {
        poolManager = _poolManager;
        positionManager = _posManager;
        treasury = msg.sender;
    }

    function totalAssets() public view override returns (uint256) {
        return IERC20(asset()).balanceOf(address(this))
            + assetsDeployed;
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

        uint128 liquidity;
        if (assetIsToken0) {
            uint160 sqrtPriceUpper = TickMath.getSqrtPriceAtTick(tickUpper);
            liquidity = LiquidityAmounts.getLiquidityForAmount0(sqrtPriceX96, sqrtPriceUpper, amount);
        } else {
            uint160 sqrtPriceLower = TickMath.getSqrtPriceAtTick(tickLower);
            liquidity = LiquidityAmounts.getLiquidityForAmount1(sqrtPriceLower, sqrtPriceX96, amount);
        }

        if (positionTokenId == 0) {
            bytes memory actions = abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR));
            bytes[] memory params = new bytes[](2);
            params[0] = abi.encode(poolKey, tickLower, tickUpper, liquidity, amount, amount, address(this), "");
            params[1] = abi.encode(poolKey.currency0, poolKey.currency1);

            IERC20(asset()).approve(address(positionManager), amount);
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

            IERC20(asset()).approve(address(positionManager), amount);
            uint256 balBefore = IERC20(asset()).balanceOf(address(this));
            positionManager.modifyLiquidities(abi.encode(actions, params), block.timestamp + 60);
            uint256 spent = balBefore - IERC20(asset()).balanceOf(address(this));
            assetsDeployed += spent;
        }

        totalLiquidityDeployed += liquidity;
        emit LiquidityDeployed(amount, 0, liquidity);
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
        sharePrice = totalSupply() == 0 ? 1e18 : tvl.mulDiv(1e18, totalSupply());
        depositors = totalDepositors;
        liqDeployed = assetsDeployed;
        yieldColl = totalYieldCollected;
        feeDesc = "0.30% Hook Fee (20% Treasury / 80% LP Bonus) + Base Pool Fee";
    }

    function getProjectedAPY(uint256 recentYield, uint256 windowSeconds) external view returns (uint256 aprBps) {
        if (totalAssets() == 0 || windowSeconds == 0) return 0;
        aprBps = recentYield.mulDiv(365 days, windowSeconds).mulDiv(10_000, totalAssets());
    }
}
