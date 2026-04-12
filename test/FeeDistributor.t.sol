// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {FeeDistributor} from "../src/FeeDistributor.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockPoolManager} from "./mocks/MockPoolManager.sol";

contract FeeDistributorTest is Test {
    FeeDistributor public distributor;
    MockPoolManager public mockManager;
    MockERC20 public token0;
    MockERC20 public token1;
    MockERC20 public feeToken;

    address public treasury = makeAddr("treasury");
    address public hookAddr = makeAddr("hook");

    PoolKey public poolKey;

    function setUp() public {
        mockManager = new MockPoolManager();

        MockERC20 tA = new MockERC20("USD Coin", "USDC", 6);
        MockERC20 tB = new MockERC20("Wrapped ETH", "WETH", 18);
        (token0, token1) = address(tA) < address(tB) ? (tA, tB) : (tB, tA);

        distributor = new FeeDistributor(IPoolManager(address(mockManager)), treasury, hookAddr);

        poolKey = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 100,
            tickSpacing: 1,
            hooks: IHooks(address(distributor))
        });

        distributor.setPoolKey(poolKey);
        feeToken = token0;
    }

    function test_distribute_revertIfNotHook() public {
        vm.expectRevert("ONLY_HOOK");
        distributor.distribute(Currency.wrap(address(feeToken)), 1000);
    }

    function test_split_33_67_precision() public {
        uint256 amount = 100e6;
        uint256 expectedTreasury = (amount * 33) / 100;

        Currency feeCurrency = poolKey.currency0;
        address tokenAddr = Currency.unwrap(feeCurrency);
        MockERC20(tokenAddr).mint(address(distributor), amount);

        vm.prank(hookAddr);
        distributor.distribute(feeCurrency, amount);

        assertEq(MockERC20(tokenAddr).balanceOf(treasury), expectedTreasury);
        assertEq(distributor.totalToTreasury(), expectedTreasury);
        assertEq(distributor.totalToLPs(), amount - expectedTreasury);
        assertEq(distributor.totalDistributed(), amount);
        assertEq(distributor.distributionCount(), 1);
    }

    function test_setPoolKey_onlyOnce() public {
        vm.expectRevert("ALREADY_SET");
        distributor.setPoolKey(poolKey);
    }

    function test_distribute_revertIfPoolKeyNotSet() public {
        FeeDistributor fresh = new FeeDistributor(
            IPoolManager(address(mockManager)),
            treasury,
            hookAddr
        );
        MockERC20(Currency.unwrap(poolKey.currency0)).mint(address(fresh), 100);

        vm.prank(hookAddr);
        vm.expectRevert("POOL_KEY_NOT_SET");
        fresh.distribute(poolKey.currency0, 100);
    }

    function test_distribute_revertOnZeroAmount() public {
        vm.prank(hookAddr);
        vm.expectRevert("ZERO_AMOUNT");
        distributor.distribute(poolKey.currency0, 0);
    }

    function test_setHook_ownerOnly() public {
        address newHook = makeAddr("newHook");

        vm.prank(makeAddr("rando"));
        vm.expectRevert();
        distributor.setHook(newHook);

        distributor.setHook(newHook);
        assertEq(distributor.hook(), newHook);
    }

    function test_setTreasury_ownerOnly() public {
        address newTreasury = makeAddr("newTreasury");

        vm.prank(makeAddr("rando"));
        vm.expectRevert();
        distributor.setTreasury(newTreasury);

        distributor.setTreasury(newTreasury);
        assertEq(distributor.treasury(), newTreasury);
    }

    function test_stats_accumulateAcrossDistributions() public {
        Currency feeCurrency = poolKey.currency0;
        address tokenAddr = Currency.unwrap(feeCurrency);
        uint256 amount = 300e6;
        uint256 rounds = 3;

        MockERC20(tokenAddr).mint(address(distributor), amount * rounds);

        vm.startPrank(hookAddr);
        for (uint256 i = 0; i < rounds; i++) {
            distributor.distribute(feeCurrency, amount);
        }
        vm.stopPrank();

        assertEq(distributor.distributionCount(), rounds);
        assertEq(distributor.totalDistributed(), amount * rounds);
        assertEq(distributor.totalToTreasury(), ((amount * 33) / 100) * rounds);
    }
}
