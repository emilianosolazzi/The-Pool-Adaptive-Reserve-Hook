// SPDX-License-Identifier: MIT
pragma solidity >=0.8.24 <0.9.0;

import {Test} from "forge-std/Test.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {LiquidityVaultV2} from "../src/LiquidityVaultV2.sol";
import {IZapRouter} from "../src/interfaces/IZapRouter.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockPoolManager} from "./mocks/MockPoolManager.sol";
import {MockPositionManager} from "./mocks/MockPositionManager.sol";

contract MockZapRouter is IZapRouter {
    uint256 public amountOut;

    function setAmountOut(uint256 newAmountOut) external {
        amountOut = newAmountOut;
    }

    function swapExactInput(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        address recipient,
        uint256 deadline
    ) external returns (uint256) {
        require(deadline >= block.timestamp, "DEADLINE");
        require(amountOut >= minAmountOut, "MOCK_MIN_OUT");
        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        IERC20(tokenOut).transfer(recipient, amountOut);
        return amountOut;
    }
}

contract LiquidityVaultV2Test is Test {
    LiquidityVaultV2 public vault;
    MockERC20 public usdc;
    MockERC20 public weth;
    MockPoolManager public mockManager;
    MockPositionManager public mockPosMgr;
    MockZapRouter public zapRouter;

    address public alice = makeAddr("alice");
    PoolKey public poolKey;

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        mockManager = new MockPoolManager();
        mockPosMgr = new MockPositionManager();
        zapRouter = new MockZapRouter();

        vault = new LiquidityVaultV2(
            usdc,
            IPoolManager(address(mockManager)),
            IPositionManager(address(mockPosMgr)),
            "LP Vault V2",
            "LPV2",
            address(0),
            address(zapRouter)
        );

        address lo = address(weth) < address(usdc) ? address(weth) : address(usdc);
        address hi = address(weth) < address(usdc) ? address(usdc) : address(weth);
        poolKey = PoolKey({
            currency0: Currency.wrap(lo),
            currency1: Currency.wrap(hi),
            fee: 500,
            tickSpacing: 60,
            hooks: IHooks(address(vault))
        });

        mockManager.setSlot0(TickMath.getSqrtPriceAtTick(-198900), -198900);
        vault.setPoolKey(poolKey);
    }

    function test_depositWithZap_buysOtherTokenAndMintsActiveLiquidity() public {
        usdc.mint(alice, 100e6);
        weth.mint(address(zapRouter), 1 ether);
        zapRouter.setAmountOut(1 ether);

        vm.startPrank(alice);
        usdc.approve(address(vault), type(uint256).max);
        uint256 shares = vault.depositWithZap(100e6, alice, 50e6, 1 ether, 1, block.timestamp + 1);
        vm.stopPrank();

        assertGt(shares, 0);
        assertEq(vault.totalDepositors(), 1);
        assertGt(vault.totalLiquidityDeployed(), 0);
        assertEq(mockPosMgr.callCount(), 1);
        assertEq(usdc.balanceOf(address(zapRouter)), 50e6);
    }

    function test_depositWithZap_revertsWhenRouterOutputBelowMinimum() public {
        usdc.mint(alice, 100e6);
        weth.mint(address(zapRouter), 1 ether);
        zapRouter.setAmountOut(0.5 ether);

        vm.startPrank(alice);
        usdc.approve(address(vault), type(uint256).max);
        vm.expectRevert("MOCK_MIN_OUT");
        vault.depositWithZap(100e6, alice, 50e6, 1 ether, 1, block.timestamp + 1);
        vm.stopPrank();
    }

    function test_depositWithZap_revertsWhenRouterNotSet() public {
        vault.setZapRouter(address(0));
        usdc.mint(alice, 100e6);

        vm.startPrank(alice);
        usdc.approve(address(vault), type(uint256).max);
        vm.expectRevert("ZAP_ROUTER_NOT_SET");
        vault.depositWithZap(100e6, alice, 50e6, 1, 1, block.timestamp + 1);
        vm.stopPrank();
    }
}