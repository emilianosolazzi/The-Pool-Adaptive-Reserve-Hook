// SPDX-License-Identifier: MIT
pragma solidity >=0.8.24 <0.9.0;

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

    // ── ERC-4626 Performance Tests ───────────────────────────────────────────

    /// First depositor receives exactly 1 share per asset (no virtual offset inflation).
    function test_4626_initialDeposit_oneToOne() public {
        vault.setPoolKey(poolKey);
        usdc.mint(alice, 100e6);

        vm.startPrank(alice);
        usdc.approve(address(vault), type(uint256).max);
        uint256 shares = vault.deposit(100e6, alice);
        vm.stopPrank();

        assertEq(shares, 100e6);
        assertEq(vault.totalAssets(), 100e6);
    }

    /// After yield is collected, share price (assets per share) rises above 1:1.
    function test_4626_sharePrice_appreciates_afterYield() public {
        vault.setPoolKey(poolKey);
        usdc.mint(alice, 100e6);

        vm.startPrank(alice);
        usdc.approve(address(vault), type(uint256).max);
        uint256 shares = vault.deposit(100e6, alice);
        vm.stopPrank();

        // Simulate 10 USDC yield arriving via the position manager
        uint256 yield = 10e6;
        usdc.mint(address(mockPosMgr), yield);
        mockPosMgr.queueYield(address(vault), address(usdc), yield);
        vault.collectYield();

        // totalAssets grew; each share is worth more than 1 USDC
        assertEq(vault.totalAssets(), 110e6);
        assertEq(vault.totalYieldCollected(), yield);
        assertGt(vault.convertToAssets(shares), 100e6);
    }

    /// An early depositor captures yield accrued before a late depositor arrives.
    function test_4626_earlyDepositor_advantaged_overLate() public {
        vault.setPoolKey(poolKey);
        usdc.mint(alice, 100e6);

        vm.startPrank(alice);
        usdc.approve(address(vault), type(uint256).max);
        uint256 aliceShares = vault.deposit(100e6, alice);
        vm.stopPrank();

        // 20 USDC yield accrues before Bob arrives
        uint256 yield = 20e6;
        usdc.mint(address(mockPosMgr), yield);
        mockPosMgr.queueYield(address(vault), address(usdc), yield);
        vault.collectYield();

        // Bob deposits the same amount but now gets fewer shares
        usdc.mint(bob, 100e6);
        vm.startPrank(bob);
        usdc.approve(address(vault), type(uint256).max);
        uint256 bobShares = vault.deposit(100e6, bob);
        vm.stopPrank();

        assertLt(bobShares, aliceShares); // diluted entry

        // Alice withdraws all her principal + yield
        uint256 aliceMax = vault.maxWithdraw(alice);
        vm.prank(alice);
        vault.withdraw(aliceMax, alice, alice);

        assertGt(aliceMax, 100e6); // Alice profitable
    }

    /// Two equal depositors split yield proportionally (each gets half).
    function test_4626_proportional_twoDepositors_splitYield() public {
        vault.setPoolKey(poolKey);
        uint256 amt = 100e6;

        usdc.mint(alice, amt);
        vm.startPrank(alice);
        usdc.approve(address(vault), type(uint256).max);
        uint256 aliceShares = vault.deposit(amt, alice);
        vm.stopPrank();

        usdc.mint(bob, amt);
        vm.startPrank(bob);
        usdc.approve(address(vault), type(uint256).max);
        uint256 bobShares = vault.deposit(amt, bob);
        vm.stopPrank();

        assertEq(aliceShares, bobShares); // equal deposits → equal shares

        // Inject 20 USDC yield (split equally)
        uint256 yield = 20e6;
        usdc.mint(address(mockPosMgr), yield);
        mockPosMgr.queueYield(address(vault), address(usdc), yield);
        vault.collectYield();

        uint256 aliceMax = vault.maxWithdraw(alice);
        vm.prank(alice);
        vault.withdraw(aliceMax, alice, alice);

        uint256 bobMax = vault.maxWithdraw(bob);
        vm.prank(bob);
        vault.withdraw(bobMax, bob, bob);

        // Each gets ≈ 110 USDC (100 principal + 10 yield), within 2 wei rounding
        assertApproxEqAbs(aliceMax, amt + yield / 2, 2);
        assertApproxEqAbs(bobMax,   amt + yield / 2, 2);
    }

    /// After yield accrues, the same USDC amount buys fewer shares (share price rose).
    function test_4626_convertToShares_decreases_afterYield() public {
        vault.setPoolKey(poolKey);
        usdc.mint(alice, 100e6);

        vm.startPrank(alice);
        usdc.approve(address(vault), type(uint256).max);
        vault.deposit(100e6, alice);
        vm.stopPrank();

        uint256 sharesBefore = vault.convertToShares(100e6);

        // Double the vault assets via yield
        uint256 yield = 100e6;
        usdc.mint(address(mockPosMgr), yield);
        mockPosMgr.queueYield(address(vault), address(usdc), yield);
        vault.collectYield();

        uint256 sharesAfter = vault.convertToShares(100e6);

        // 100 USDC buys half as many shares now that TVL doubled
        assertLt(sharesAfter, sharesBefore);
        assertApproxEqAbs(sharesAfter, sharesBefore / 2, 2);
    }

    /// getProjectedAPY returns correct basis-points for a known yield/tvl/window.
    function test_4626_projectedAPY_math() public {
        vault.setPoolKey(poolKey);
        usdc.mint(alice, 1000e6);

        vm.startPrank(alice);
        usdc.approve(address(vault), type(uint256).max);
        vault.deposit(1000e6, alice);
        vm.stopPrank();

        // 10 USDC over 30 days on 1000 USDC TVL ≈ 12.17% APY = 1216 BPS
        uint256 aprBps = vault.getProjectedAPY(10e6, 30 days);
        assertGe(aprBps, 1210);
        assertLe(aprBps, 1225);
    }

    /// rebalance() updates tick boundaries and reseeds the position.
    function test_4626_rebalance_updatesTickRange() public {
        vault.setPoolKey(poolKey);
        usdc.mint(alice, 10e6);

        vm.startPrank(alice);
        usdc.approve(address(vault), type(uint256).max);
        vault.deposit(10e6, alice);
        vm.stopPrank();

        int24 newLower = -300000;
        int24 newUpper = -100000;
        vault.rebalance(newLower, newUpper);

        assertEq(vault.tickLower(), newLower);
        assertEq(vault.tickUpper(), newUpper);
        assertGt(vault.positionTokenId(), 0); // new position seeded
    }

    /// rebalance() must not change the vault's NAV (no value leaked to mock).
    function test_4626_rebalance_preservesNAV() public {
        vault.setPoolKey(poolKey);
        usdc.mint(alice, 100e6);

        vm.startPrank(alice);
        usdc.approve(address(vault), type(uint256).max);
        vault.deposit(100e6, alice);
        vm.stopPrank();

        uint256 navBefore = vault.totalAssets();
        vault.rebalance(-300000, -100000);
        uint256 navAfter = vault.totalAssets();

        assertEq(navAfter, navBefore);
    }

    /// Non-owner cannot call rebalance().
    function test_4626_rebalance_onlyOwner() public {
        vault.setPoolKey(poolKey);
        vm.prank(alice);
        vm.expectRevert();
        vault.rebalance(-300000, -100000);
    }

    /// Ownable2Step: transferOwnership alone must not change the active owner;
    /// acceptOwnership() by the pending owner completes the handoff.
    function test_4626_ownable2step_requiresAccept() public {
        address newOwner = makeAddr("newOwner");

        vault.transferOwnership(newOwner);

        assertEq(vault.owner(),        owner);    // still old owner
        assertEq(vault.pendingOwner(), newOwner); // queued

        vm.prank(newOwner);
        vault.acceptOwnership();

        assertEq(vault.owner(), newOwner); // handoff complete
    }
}
