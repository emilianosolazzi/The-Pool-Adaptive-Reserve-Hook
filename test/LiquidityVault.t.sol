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

    // PoolKey with token sorted correctly
    PoolKey public poolKey;

    uint256 constant INITIAL_PRICE_X96 = 79228162514264337593543950336; // 1:1 sqrtPrice

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

        // Build a sortable pool key whose currency0 is the lower address
        address addrA = address(usdc);
        address addrB = address(0x1); // placeholder second token
        (address lo, address hi) = addrA < addrB ? (addrA, addrB) : (addrB, addrA);

        poolKey = PoolKey({
            currency0: Currency.wrap(lo),
            currency1: Currency.wrap(hi),
            fee: 100,
            tickSpacing: 1,
            hooks: toIHooks(address(vault))
        });
    }

    // ─── 1. MIN_DEPOSIT enforced ──────────────────────────────────────────────

    function test_deposit_revertBelowMinDeposit() public {
        vault.setPoolKey(poolKey);

        usdc.mint(alice, 1e6 - 1);
        vm.startPrank(alice);
        usdc.approve(address(vault), type(uint256).max);
        vm.expectRevert("MIN_DEPOSIT");
        vault.deposit(1e6 - 1, alice);
        vm.stopPrank();
    }

    // ─── 2. deposit: pool key must be set ─────────────────────────────────────

    function test_deposit_revertWhenPoolKeyNotSet() public {
        usdc.mint(alice, 10e6);
        vm.startPrank(alice);
        usdc.approve(address(vault), type(uint256).max);
        vm.expectRevert("POOL_KEY_NOT_SET");
        vault.deposit(10e6, alice);
        vm.stopPrank();
    }

    // ─── 3. setPoolKey: only callable once ────────────────────────────────────

    function test_setPoolKey_onlyOnce() public {
        vault.setPoolKey(poolKey);
        vm.expectRevert("ALREADY_SET");
        vault.setPoolKey(poolKey);
    }

    // ─── 4. Depositor count tracks unique depositors ──────────────────────────

    function test_depositorCount_uniquePerAddress() public {
        vault.setPoolKey(poolKey);

        uint256 amt = 10e6;
        usdc.mint(alice, amt * 3);
        usdc.mint(bob,   amt);

        vm.startPrank(alice);
        usdc.approve(address(vault), type(uint256).max);
        vault.deposit(amt, alice);
        assertEq(vault.totalDepositors(), 1);
        vault.deposit(amt, alice); // same depositor again — should NOT increment
        assertEq(vault.totalDepositors(), 1);
        vm.stopPrank();

        vm.startPrank(bob);
        usdc.approve(address(vault), type(uint256).max);
        vault.deposit(amt, bob);
        assertEq(vault.totalDepositors(), 2);
        vm.stopPrank();
    }

    // ─── 5. ERC-4626 share price invariance across deposits ───────────────────

    function test_sharePrice_invarianceAcrossDeposits() public {
        vault.setPoolKey(poolKey);

        uint256 deposit1 = 100e6;
        uint256 deposit2 = 200e6;

        usdc.mint(alice, deposit1);
        usdc.mint(bob,   deposit2);

        vm.startPrank(alice);
        usdc.approve(address(vault), type(uint256).max);
        uint256 shares1 = vault.deposit(deposit1, alice);
        vm.stopPrank();

        // Record share price ratio before second deposit
        uint256 totalAssets1  = vault.totalAssets();
        uint256 totalSupply1  = vault.totalSupply();

        vm.startPrank(bob);
        usdc.approve(address(vault), type(uint256).max);
        uint256 shares2 = vault.deposit(deposit2, bob);
        vm.stopPrank();

        // Shares are proportional to assets at the time of deposit
        // shares1 / shares2 ≈ deposit1 / deposit2  (when second deposit is at same price)
        // This holds because after first deposit, price = totalAssets / totalSupply
        // Second depositor pays that price
        // We verify no dilution: alice's shares represent at least deposit1 of assets
        uint256 aliceAssets = vault.convertToAssets(shares1);
        assertGe(aliceAssets, deposit1 - 1, "alice lost value on second deposit");

        // Silence unused variable warning
        (totalAssets1, totalSupply1, shares2);
    }

    // ─── 6. rescueIdle: owner can recover stray tokens ────────────────────────

    function test_rescueIdle_ownerOnly() public {
        MockERC20 stray = new MockERC20("Stray", "STR", 18);
        uint256 amount = 500e18;
        stray.mint(address(vault), amount);

        // non-owner reverts
        vm.prank(alice);
        vm.expectRevert();
        vault.rescueIdle(address(stray));

        // owner succeeds
        uint256 ownerBefore = stray.balanceOf(owner);
        vault.rescueIdle(address(stray));
        assertEq(stray.balanceOf(owner), ownerBefore + amount);
        assertEq(stray.balanceOf(address(vault)), 0);
    }

    // ─── 7. getVaultStats returns expected structure ───────────────────────────

    function test_getVaultStats_returnsDefaults() public view {
        (
            uint256 tvl,
            uint256 sharePrice,
            uint256 depositors,
            uint256 liqDeployed,
            uint256 yieldColl,
            string memory feeDesc
        ) = vault.getVaultStats();

        assertEq(tvl, 0);
        assertEq(sharePrice, 1e18); // no supply → 1:1
        assertEq(depositors, 0);
        assertEq(liqDeployed, 0);
        assertEq(yieldColl, 0);
        assertTrue(bytes(feeDesc).length > 0);
    }

    // ─── 8. getProjectedAPY: zero when no assets ──────────────────────────────

    function test_getProjectedAPY_zeroWithNoAssets() public view {
        uint256 apy = vault.getProjectedAPY(1e6, 365 days);
        assertEq(apy, 0);
    }

    // ─── helpers ─────────────────────────────────────────────────────────────

    function toIHooks(address addr) internal pure returns (IHooks) {
        return IHooks(addr);
    }
}

