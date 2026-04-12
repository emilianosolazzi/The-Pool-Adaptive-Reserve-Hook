// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

import {LiquidityVault} from "../src/LiquidityVault.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockPoolManager} from "./mocks/MockPoolManager.sol";
import {MockPositionManager} from "./mocks/MockPositionManager.sol";

contract LiquidityVaultTest is Test {
    using Math for uint256;

    LiquidityVault public vault;
    MockERC20 public usdc;
    MockPoolManager public mockManager;
    MockPositionManager public mockPosMgr;

    address public owner;
    address public alice = makeAddr("alice");
    address public bob   = makeAddr("bob");

    PoolKey public poolKey;

    function setUp() public {
        owner = address(this);

        usdc        = new MockERC20("USD Coin", "USDC", 6);
        mockManager = new MockPoolManager();
        mockPosMgr  = new MockPositionManager();

        vault = new LiquidityVault(
            usdc,
            IPoolManager(address(mockManager)),
            IPositionManager(address(mockPosMgr)),
            "LP Vault",
            "LPV"
        );

        address addrA = address(usdc);
        address addrB = address(0x1);
        (address lo, address hi) = addrA < addrB ? (addrA, addrB) : (addrB, addrA);

        poolKey = PoolKey({
            currency0: Currency.wrap(lo),
            currency1: Currency.wrap(hi),
            fee: 100,
            tickSpacing: 1,
            hooks: IHooks(address(vault))
        });
    }

    function test_deposit_revertBelowMinDeposit() public {
        vault.setPoolKey(poolKey);

        usdc.mint(alice, 1e6 - 1);
        vm.startPrank(alice);
        usdc.approve(address(vault), type(uint256).max);
        vm.expectRevert("MIN_DEPOSIT");
        vault.deposit(1e6 - 1, alice);
        vm.stopPrank();
    }

    function test_deposit_revertWhenPoolKeyNotSet() public {
        usdc.mint(alice, 10e6);
        vm.startPrank(alice);
        usdc.approve(address(vault), type(uint256).max);
        vm.expectRevert("POOL_KEY_NOT_SET");
        vault.deposit(10e6, alice);
        vm.stopPrank();
    }

    function test_setPoolKey_onlyOnce() public {
        vault.setPoolKey(poolKey);
        vm.expectRevert("ALREADY_SET");
        vault.setPoolKey(poolKey);
    }

    function test_depositorCount_uniquePerAddress() public {
        vault.setPoolKey(poolKey);

        uint256 amt = 10e6;
        usdc.mint(alice, amt * 3);
        usdc.mint(bob,   amt);

        vm.startPrank(alice);
        usdc.approve(address(vault), type(uint256).max);
        vault.deposit(amt, alice);
        assertEq(vault.totalDepositors(), 1);
        vault.deposit(amt, alice);
        assertEq(vault.totalDepositors(), 1);
        vm.stopPrank();

        vm.startPrank(bob);
        usdc.approve(address(vault), type(uint256).max);
        vault.deposit(amt, bob);
        assertEq(vault.totalDepositors(), 2);
        vm.stopPrank();
    }

    function test_sharePrice_invarianceAcrossDeposits() public {
        vault.setPoolKey(poolKey);

        usdc.mint(alice, 100e6);
        usdc.mint(bob,   200e6);

        vm.startPrank(alice);
        usdc.approve(address(vault), type(uint256).max);
        uint256 shares1 = vault.deposit(100e6, alice);
        vm.stopPrank();

        vm.startPrank(bob);
        usdc.approve(address(vault), type(uint256).max);
        vault.deposit(200e6, bob);
        vm.stopPrank();

        assertGe(vault.convertToAssets(shares1), 100e6 - 1);
    }

    function test_rescueIdle_ownerOnly() public {
        MockERC20 stray = new MockERC20("Stray", "STR", 18);
        stray.mint(address(vault), 500e18);

        vm.prank(alice);
        vm.expectRevert();
        vault.rescueIdle(address(stray));

        uint256 before = stray.balanceOf(owner);
        vault.rescueIdle(address(stray));
        assertEq(stray.balanceOf(owner), before + 500e18);
        assertEq(stray.balanceOf(address(vault)), 0);
    }

    function test_getVaultStats_returnsDefaults() public view {
        (uint256 tvl, uint256 sharePrice, uint256 depositors, uint256 liqDeployed, uint256 yieldColl, string memory feeDesc) =
            vault.getVaultStats();

        assertEq(tvl, 0);
        assertEq(sharePrice, 1e18);
        assertEq(depositors, 0);
        assertEq(liqDeployed, 0);
        assertEq(yieldColl, 0);
        assertTrue(bytes(feeDesc).length > 0);
    }

    function test_getProjectedAPY_zeroWithNoAssets() public view {
        assertEq(vault.getProjectedAPY(1e6, 365 days), 0);
    }
}
