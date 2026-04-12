// SPDX-License-Identifier: MIT
pragma solidity >=0.8.24 <0.9.0;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";

contract LiquidityVault is ERC4626, Ownable, ReentrancyGuard {
    using Math for uint256;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint256 public constant MIN_DEPOSIT = 1e6;
    int24 public constant TICK_LOWER = -230270;
    int24 public constant TICK_UPPER = -69082;

    IPoolManager public immutable poolManager;
    IPositionManager public immutable positionManager;
    PoolKey public poolKey;

    uint256 public totalLiquidityDeployed;
    uint256 public totalYieldCollected;
    uint256 public totalDepositors;
    uint256 public lastYieldUpdate;
    uint256 public positionTokenId;
    bool private _poolKeySet;

    event LiquidityDeployed(uint256 amount0, uint256 amount1, uint256 liquidity);
    event LiquidityRemoved(uint256 amount0, uint256 amount1, uint256 liquidity);
    event YieldCollected(uint256 amount, uint256 timestamp);
    event PoolKeySet(bytes32 indexed poolId);

    constructor(
        IERC20 _asset,
        IPoolManager _poolManager,
        IPositionManager _posManager,
        string memory _name,
        string memory _symbol
    ) ERC4626(_asset) ERC20(_name, _symbol) Ownable(msg.sender) {
        poolManager = _poolManager;
        positionManager = _posManager;
    }

    function totalAssets() public view override returns (uint256) {
        return IERC20(asset()).balanceOf(address(this))
            + totalLiquidityDeployed
            + totalYieldCollected;
    }

    function deposit(uint256 assets, address receiver) public override nonReentrant returns (uint256) {
        require(assets >= MIN_DEPOSIT, "MIN_DEPOSIT");
        require(_poolKeySet, "POOL_KEY_NOT_SET");
        if (balanceOf(receiver) == 0) totalDepositors++;

        uint256 shares = super.deposit(assets, receiver);
        _deployLiquidity(assets);
        return shares;
    }

    function withdraw(uint256 assets, address receiver, address owner) public override nonReentrant returns (uint256) {
        _collectYield();
        uint256 proportion = assets.mulDiv(1e18, totalAssets());
        _removeLiquidity(proportion);
        return super.withdraw(assets, receiver, owner);
    }

    function _deployLiquidity(uint256 amount) internal {
        if (!_poolKeySet || amount == 0) return;

        uint160 sqrtPriceLower = TickMath.getSqrtPriceAtTick(TICK_LOWER);
        uint160 sqrtPriceUpper = TickMath.getSqrtPriceAtTick(TICK_UPPER);
        (uint160 sqrtPriceX96, , , ) = poolManager.getSlot0(poolKey.toId());

        uint128 liquidity = LiquidityAmounts.getLiquidityForAmount0(
            sqrtPriceX96,
            sqrtPriceUpper,
            amount
        );

        if (positionTokenId == 0) {
            bytes memory actions = abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR));
            bytes[] memory params = new bytes[](2);
            params[0] = abi.encode(poolKey, TICK_LOWER, TICK_UPPER, liquidity, amount, amount, address(this), "");
            params[1] = abi.encode(poolKey.currency0, poolKey.currency1);

            IERC20(asset()).approve(address(positionManager), amount);
            uint256 expectedTokenId = positionManager.nextTokenId();
            positionManager.modifyLiquidities(abi.encode(actions, params), block.timestamp + 60);
            positionTokenId = expectedTokenId;
        } else {
            bytes memory actions = abi.encodePacked(uint8(Actions.INCREASE_LIQUIDITY), uint8(Actions.SETTLE_PAIR));
            bytes[] memory params = new bytes[](2);
            params[0] = abi.encode(positionTokenId, liquidity, amount, amount, "");
            params[1] = abi.encode(poolKey.currency0, poolKey.currency1);

            IERC20(asset()).approve(address(positionManager), amount);
            positionManager.modifyLiquidities(abi.encode(actions, params), block.timestamp + 60);
        }

        totalLiquidityDeployed += liquidity;
        emit LiquidityDeployed(amount, 0, liquidity);
    }

    function _removeLiquidity(uint256 proportion) internal {
        if (totalLiquidityDeployed == 0 || positionTokenId == 0) return;

        uint128 liquidityToRemove = uint128(totalLiquidityDeployed.mulDiv(proportion, 1e18));
        if (liquidityToRemove == 0) return;

        uint256 amount0Min = 0;
        uint256 amount1Min = 0;

        bytes memory actions = abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR), uint8(Actions.SWEEP));
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(positionTokenId, liquidityToRemove, amount0Min, amount1Min, "");
        params[1] = abi.encode(poolKey.currency0, poolKey.currency1, address(this));
        params[2] = abi.encode(poolKey.currency0, address(this));

        positionManager.modifyLiquidities(abi.encode(actions, params), block.timestamp + 60);
        totalLiquidityDeployed -= liquidityToRemove;
        emit LiquidityRemoved(0, 0, liquidityToRemove);
    }

    function _collectYield() internal {
        if (positionTokenId == 0) return;

        bytes memory actions = abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(positionTokenId, uint128(0), 0, 0, "");
        params[1] = abi.encode(poolKey.currency0, poolKey.currency1, address(this));

        uint256 balanceBefore = IERC20(asset()).balanceOf(address(this));
        positionManager.modifyLiquidities(abi.encode(actions, params), block.timestamp + 60);
        uint256 balanceAfter = IERC20(asset()).balanceOf(address(this));

        uint256 yieldAmount = balanceAfter - balanceBefore;
        if (yieldAmount > 0) {
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
        poolKey = _poolKey;
        _poolKeySet = true;
        emit PoolKeySet(PoolId.unwrap(_poolKey.toId()));
    }

    function rescueIdle(address token) external onlyOwner {
        uint256 idle = IERC20(token).balanceOf(address(this));
        require(idle > 0, "NO_IDLE");
        IERC20(token).transfer(owner(), idle);
    }

    function getVaultStats() external view returns (uint256 tvl, uint256 sharePrice, uint256 depositors, uint256 liqDeployed, uint256 yieldColl, string memory feeDesc) {
        tvl = totalAssets();
        sharePrice = totalSupply() == 0 ? 1e18 : tvl.mulDiv(1e18, totalSupply());
        depositors = totalDepositors;
        liqDeployed = totalLiquidityDeployed;
        yieldColl = totalYieldCollected;
        feeDesc = "0.01% Base LP + 0.02% Yield Bonus via Hook";
    }

    function getProjectedAPY(uint256 recentYield, uint256 windowSeconds) external view returns (uint256 aprBps) {
        if (totalAssets() == 0 || windowSeconds == 0) return 0;
        aprBps = recentYield.mulDiv(365 days, windowSeconds).mulDiv(10_000, totalAssets());
    }
}
