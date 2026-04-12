// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

import {FeeDistributor} from "../src/FeeDistributor.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {MockERC20} from "./mocks/MockERC20.sol";
import {MockPoolManager} from "./mocks/MockPoolManager.sol";

contract FeeDistributorTest is Test {
    FeeDistributor public distributor;
    MockPoolManager public mockManager;
    MockERC20 public token0; // the lower-address token (currency0)
    MockERC20 public token1; // the higher-address token (currency1)
    MockERC20 public feeToken; // whichever is currency0 after sorting

    address public treasury = makeAddr("treasury");
    address public hookAddr = makeAddr("hook");
    address public owner;

    PoolKey public poolKey;

    function setUp() public {
        owner = address(this);
        mockManager = new MockPoolManager();

        MockERC20 tA = new MockERC20("USD Coin", "USDC", 6);
        MockERC20 tB = new MockERC20("Wrapped ETH", "WETH", 18);

        // Sort so currency0 < currency1
        if (address(tA) < address(tB)) {
            token0 = tA;
            token1 = tB;
        } else {
            token0 = tB;
            token1 = tA;
        }

        distributor = new FeeDistributor(IPoolManager(address(mockManager)), treasury, hookAddr);

        poolKey = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 100,
            tickSpacing: 1,
            hooks: toIHooks(address(distributor))
        });

        distributor.setPoolKey(poolKey);
        feeToken = token0; // we'll distribute via currency0 in tests
    }

    // ─── 1. Only hook can call distribute ────────────────────────────────────

    function test_distribute_revertIfNotHook() public {
        vm.expectRevert("ONLY_HOOK");
        distributor.distribute(Currency.wrap(address(feeToken)), 1000);
    }

    // ─── 2. Exact 33/67 split precision ──────────────────────────────────────

    function test_split_33_67_precision() public {
        uint256 amount = 100e6; // 100 USDC
        uint256 expectedTreasury = (amount * 33) / 100; // 33 USDC
        uint256 expectedLP = amount - expectedTreasury;    // 67 USDC

        // Fund distributor and MockPoolManager
        Currency feeCurrency = poolKey.currency0; // use currency0 (the token)
        address tokenAddr = Currency.unwrap(feeCurrency);
        MockERC20(tokenAddr).mint(address(distributor), amount);

        vm.prank(hookAddr);
        distributor.distribute(feeCurrency, amount);

        assertEq(MockERC20(tokenAddr).balanceOf(treasury), expectedTreasury);
        assertEq(distributor.totalToTreasury(), expectedTreasury);
        assertEq(distributor.totalToLPs(), expectedLP);
        assertEq(distributor.totalDistributed(), amount);
        assertEq(distributor.distributionCount(), 1);
    }

    // ─── 3. setPoolKey: only callable once ───────────────────────────────────

    function test_setPoolKey_onlyOnce() public {
        vm.expectRevert("ALREADY_SET");
        distributor.setPoolKey(poolKey);
    }

    // ─── 4. distribute: reverts when pool key not set ─────────────────────────

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

    // ─── 5. distribute: reverts on zero amount ────────────────────────────────

    function test_distribute_revertOnZeroAmount() public {
        Currency feeCurrency = poolKey.currency0;
        vm.prank(hookAddr);
        vm.expectRevert("ZERO_AMOUNT");
        distributor.distribute(feeCurrency, 0);
    }

    // ─── 6. Ownership: setHook and setTreasury are owner-only ─────────────────

    function test_setHook_ownerOnly() public {
        address newHook = makeAddr("newHook");

        vm.prank(makeAddr("rando"));
        vm.expectRevert();  // OZ Ownable revert
        distributor.setHook(newHook);

        // Owner can change
        distributor.setHook(newHook);
        assertEq(distributor.hook(), newHook);
    }

    function test_setTreasury_ownerOnly() public {
        address newTreasury = makeAddr("newTreasury");

        vm.prank(makeAddr("rando"));
        vm.expectRevert();  // OZ Ownable revert
        distributor.setTreasury(newTreasury);

        distributor.setTreasury(newTreasury);
        assertEq(distributor.treasury(), newTreasury);
    }

    // ─── 7. Stats accumulate over multiple distributions ─────────────────────

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

    // ─── helpers ─────────────────────────────────────────────────────────────

    function toIHooks(address addr) internal pure returns (IHooks) {
        return IHooks(addr);
    }
}

