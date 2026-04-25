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
            "LPV",
            address(0)  // no Permit2 in test environment
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

    /// First depositor's share of the vault is proportional to their deposit.
    /// With _decimalsOffset() = 6 (inflation-attack mitigation), raw shares are
    /// scaled by 10**6 vs the 1:1 default, so we assert via convertToAssets
    /// which is offset-invariant.
    function test_4626_initialDeposit_sharesMatchAssets() public {
        vault.setPoolKey(poolKey);
        usdc.mint(alice, 100e6);

        vm.startPrank(alice);
        usdc.approve(address(vault), type(uint256).max);
        uint256 shares = vault.deposit(100e6, alice);
        vm.stopPrank();

        assertGt(shares, 0);
        assertEq(vault.convertToAssets(shares), 100e6);
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

        // 100 USDC buys half as many shares now that TVL doubled.
        // Absolute tolerance widened from 2 to 1e6 to accommodate the larger
        // raw share counts under _decimalsOffset() = 6 (relative error stays
        // at ~1e-8, i.e. still essentially exact).
        assertLt(sharesAfter, sharesBefore);
        assertApproxEqAbs(sharesAfter, sharesBefore / 2, 1e6);
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
    // ── Additional coverage ──────────────────────────────────────────────────

    /// ERC-4626 redeem() path: burn shares → receive assets (alternative to withdraw).
    function test_4626_redeem_alternativePath() public {
        vault.setPoolKey(poolKey);
        usdc.mint(alice, 100e6);

        vm.startPrank(alice);
        usdc.approve(address(vault), type(uint256).max);
        uint256 shares = vault.deposit(100e6, alice);

        uint256 assetsOut = vault.redeem(shares, alice, alice);
        vm.stopPrank();

        assertApproxEqAbs(assetsOut, 100e6, 1);
        assertEq(vault.balanceOf(alice), 0);
    }

    /// rebalance() reverts when newTickLower >= newTickUpper.
    function test_4626_rebalance_invalidTicks_reverts() public {
        vault.setPoolKey(poolKey);
        vm.expectRevert("INVALID_TICKS");
        vault.rebalance(-100000, -100000); // equal → invalid

        vm.expectRevert("INVALID_TICKS");
        vault.rebalance(-69082, -230270);  // reversed → invalid
    }

    /// rebalance() reverts when the pool key has not been set yet.
    function test_4626_rebalance_poolKeyNotSet_reverts() public {
        // vault from setUp has no pool key yet
        vm.expectRevert("POOL_KEY_NOT_SET");
        vault.rebalance(-300000, -100000);
    }

    /// getVaultStats() reflects live TVL, share price, and yield after state changes.
    function test_4626_getVaultStats_updatesAfterYield() public {
        vault.setPoolKey(poolKey);
        usdc.mint(alice, 100e6);

        vm.startPrank(alice);
        usdc.approve(address(vault), type(uint256).max);
        vault.deposit(100e6, alice);
        vm.stopPrank();

        // Pre-yield baseline
        (uint256 tvl0, uint256 sp0, uint256 dep0,,uint256 yield0,) = vault.getVaultStats();
        assertEq(tvl0, 100e6);
        assertEq(dep0, 1);
        assertEq(yield0, 0);
        assertGe(sp0, 1e18); // share price ≥ 1 USDC (18-dec representation)

        // Inject yield
        uint256 yieldAmt = 20e6;
        usdc.mint(address(mockPosMgr), yieldAmt);
        mockPosMgr.queueYield(address(vault), address(usdc), yieldAmt);
        vault.collectYield();

        (uint256 tvl1, uint256 sp1,,,uint256 yield1,) = vault.getVaultStats();
        assertEq(tvl1, 120e6);
        assertGt(sp1, sp0);     // share price appreciated
        assertEq(yield1, yieldAmt);
    }

    /// collectYield() is a no-op (no revert) when no position has been opened yet.
    function test_4626_collectYield_noopBeforeDeposit() public {
        vault.setPoolKey(poolKey);
        // positionTokenId == 0 → _collectYield returns immediately
        vault.collectYield(); // must not revert
        assertEq(vault.totalYieldCollected(), 0);
    }

    /// For any deposit size, withdrawing the full balance returns essentially the same amount.
    function testFuzz_depositWithdraw_noLeakage(uint256 assets) public {
        assets = bound(assets, 1e6, 1e12); // 1 USDC to 1M USDC
        vault.setPoolKey(poolKey);
        usdc.mint(alice, assets);

        vm.startPrank(alice);
        usdc.approve(address(vault), type(uint256).max);
        vault.deposit(assets, alice);

        uint256 maxOut = vault.maxWithdraw(alice);
        vault.withdraw(maxOut, alice, alice);
        vm.stopPrank();

        // Alice should recover her full deposit within 1 wei of rounding
        assertApproxEqAbs(usdc.balanceOf(alice), assets, 1);
    }

    // ── New feature tests ────────────────────────────────────────────────────

    /// rescueIdle() must revert when called on the vault's own asset token.
    function test_rescueIdle_assetToken_reverts() public {
        vm.expectRevert("CANNOT_RESCUE_ASSET");
        vault.rescueIdle(address(usdc));
    }

    /// pause() blocks deposit; unpause() re-enables it.
    function test_pause_blocksDeposit_unpaused() public {
        vault.setPoolKey(poolKey);
        vault.pause();

        usdc.mint(alice, 10e6);
        vm.startPrank(alice);
        usdc.approve(address(vault), type(uint256).max);
        vm.expectRevert();
        vault.deposit(10e6, alice);
        vm.stopPrank();

        vault.unpause();

        vm.startPrank(alice);
        vault.deposit(10e6, alice); // must succeed after unpause
        vm.stopPrank();
        assertGt(vault.balanceOf(alice), 0);
    }

    /// pause() blocks withdraw.
    function test_pause_blocksWithdraw() public {
        vault.setPoolKey(poolKey);
        usdc.mint(alice, 10e6);

        vm.startPrank(alice);
        usdc.approve(address(vault), type(uint256).max);
        vault.deposit(10e6, alice);
        vm.stopPrank();

        vault.pause();

        uint256 aliceMax = vault.maxWithdraw(alice);
        vm.prank(alice);
        vm.expectRevert();
        vault.withdraw(aliceMax, alice, alice);
    }

    /// setPerformanceFeeBps validates max 20%; collectYield() routes the fee to treasury.
    function test_performanceFee_sentToTreasury() public {
        vault.setPoolKey(poolKey);
        address myTreasury = makeAddr("myTreasury");
        vault.setTreasury(myTreasury);
        vault.setPerformanceFeeBps(1000); // 10%

        usdc.mint(alice, 100e6);
        vm.startPrank(alice);
        usdc.approve(address(vault), type(uint256).max);
        vault.deposit(100e6, alice);
        vm.stopPrank();

        uint256 yield = 20e6;
        usdc.mint(address(mockPosMgr), yield);
        mockPosMgr.queueYield(address(vault), address(usdc), yield);
        vault.collectYield();

        uint256 expectedFee = yield * 1000 / 10_000; // 2e6
        assertEq(usdc.balanceOf(myTreasury), expectedFee);
        assertEq(vault.totalYieldCollected(), yield - expectedFee); // 18e6 net to depositors
        assertEq(vault.totalAssets(), 100e6 + (yield - expectedFee));
    }

    /// setPerformanceFeeBps reverts above 2000 (20%).
    function test_performanceFeeBps_maxValidation() public {
        vm.expectRevert("FEE_TOO_HIGH");
        vault.setPerformanceFeeBps(2001);

        vault.setPerformanceFeeBps(2000); // exactly 20% — must succeed
        assertEq(vault.performanceFeeBps(), 2000);
    }

    /// Deposits that would push TVL over maxTVL are rejected.
    function test_maxTVL_enforced() public {
        vault.setPoolKey(poolKey);
        vault.setMaxTVL(50e6); // 50 USDC cap

        usdc.mint(alice, 100e6);
        vm.startPrank(alice);
        usdc.approve(address(vault), type(uint256).max);
        vault.deposit(40e6, alice);    // 40 USDC — fits
        vm.expectRevert("TVL_CAP");
        vault.deposit(20e6, alice);    // would push to 60 USDC — rejected
        vm.stopPrank();
    }

    /// setTreasury is owner-only and updates the treasury address.
    function test_setTreasury_ownerOnly() public {
        address newTreasury = makeAddr("newTreasury");

        vm.prank(alice);
        vm.expectRevert();
        vault.setTreasury(newTreasury);

        vault.setTreasury(newTreasury);
        assertEq(vault.treasury(), newTreasury);
    }

    /// Treasury is initialized to the deployer (owner) at construction.
    function test_treasury_initializedToDeployer() public view {
        assertEq(vault.treasury(), owner);
    }

    /// setPoolKey must revert when the vault asset is not one of the pool's currencies.
    function test_setPoolKey_assetNotInPool_reverts() public {
        PoolKey memory badKey = PoolKey({
            currency0: Currency.wrap(address(1)),
            currency1: Currency.wrap(address(2)),
            fee: 100,
            tickSpacing: 1,
            hooks: IHooks(address(vault))
        });
        vm.expectRevert("ASSET_NOT_IN_POOL");
        vault.setPoolKey(badKey);
    }

    /// totalDepositors decrements when a depositor fully exits via redeem().
    function test_totalDepositors_decrements_onFullWithdraw() public {
        vault.setPoolKey(poolKey);
        usdc.mint(alice, 10e6);
        vm.startPrank(alice);
        usdc.approve(address(vault), type(uint256).max);
        vault.deposit(10e6, alice);
        vm.stopPrank();

        assertEq(vault.totalDepositors(), 1);

        uint256 allShares = vault.balanceOf(alice);
        vm.prank(alice);
        vault.redeem(allShares, alice, alice);

        assertEq(vault.balanceOf(alice), 0);
        assertEq(vault.totalDepositors(), 0);
    }

    /// maxDeposit returns 0 when the vault is paused.
    function test_maxDeposit_returnsZeroWhenPaused() public {
        vault.setPoolKey(poolKey);
        vault.pause();
        assertEq(vault.maxDeposit(alice), 0);
    }

    /// maxDeposit respects maxTVL: returns remaining headroom only.
    function test_maxDeposit_respectsMaxTVL() public {
        vault.setPoolKey(poolKey);
        vault.setMaxTVL(50e6);

        usdc.mint(alice, 100e6);
        vm.startPrank(alice);
        usdc.approve(address(vault), type(uint256).max);
        vault.deposit(30e6, alice);
        vm.stopPrank();

        assertEq(vault.maxDeposit(alice), 20e6); // 50 - 30 = 20
    }

    /// maxWithdraw returns 0 when the vault is paused.
    function test_maxWithdraw_returnsZeroWhenPaused() public {
        vault.setPoolKey(poolKey);
        usdc.mint(alice, 10e6);
        vm.startPrank(alice);
        usdc.approve(address(vault), type(uint256).max);
        vault.deposit(10e6, alice);
        vm.stopPrank();

        vault.pause();
        assertEq(vault.maxWithdraw(alice), 0);
    }

    // ── Audit regressions ───────────────────────────────────────────────────

    /// H-2: rescueIdle MUST refuse the pool's non-asset currency once the pool
    /// is configured. Pre-fix the owner could silently sweep token balances
    /// that legitimately belong to depositors (e.g. WETH released from an
    /// in-range withdrawal of a USDC/WETH position).
    function test_h2_rescueIdle_blocksNonAssetPoolCurrency() public {
        // Configure a pool where currency1 is a real ERC20 (so otherAddr.code.length > 0).
        MockERC20 weth = new MockERC20("Wrapped Ether", "WETH", 18);
        address addrA = address(usdc);
        address addrB = address(weth);
        (address lo, address hi) = addrA < addrB ? (addrA, addrB) : (addrB, addrA);
        PoolKey memory pk = PoolKey({
            currency0: Currency.wrap(lo),
            currency1: Currency.wrap(hi),
            fee: 100,
            tickSpacing: 1,
            hooks: IHooks(address(vault))
        });
        vault.setPoolKey(pk);

        // Simulate non-asset currency accumulating in the vault.
        weth.mint(address(vault), 1 ether);

        vm.expectRevert("POOL_CURRENCY");
        vault.rescueIdle(address(weth));

        // The other pool currency (asset itself) is still blocked by CANNOT_RESCUE_ASSET.
        vm.expectRevert("CANNOT_RESCUE_ASSET");
        vault.rescueIdle(address(usdc));

        // Unrelated stray tokens are still recoverable.
        MockERC20 stray = new MockERC20("Stray", "STR", 18);
        stray.mint(address(vault), 7e18);
        vault.rescueIdle(address(stray));
        assertEq(stray.balanceOf(owner), 7e18);
    }

    /// M-1: Idle non-asset balance must contribute to totalAssets() so
    /// remaining depositors don't lose value when the price moves into the
    /// vault's range. Pre-fix totalAssets ignored the non-asset side entirely.
    function test_m1_totalAssets_includesIdleNonAssetCurrency() public {
        // Force WETH to sort lower than USDC by trying CREATE2 salts until
        // the deployed address is lower than usdc's.
        MockERC20 weth;
        for (uint256 salt = 0; salt < 256; salt++) {
            try new MockERC20{salt: bytes32(salt)}("Wrapped Ether", "WETH", 18) returns (MockERC20 deployed) {
                if (address(deployed) < address(usdc)) {
                    weth = deployed;
                    break;
                }
            } catch {
                // collision; try next salt
            }
        }
        if (address(weth) == address(0)) {
            vm.skip(true);
            return;
        }

        PoolKey memory pk = PoolKey({
            currency0: Currency.wrap(address(weth)),
            currency1: Currency.wrap(address(usdc)),
            fee: 100,
            tickSpacing: 1,
            hooks: IHooks(address(vault))
        });
        vault.setPoolKey(pk);

        // Seed vault with 100 USDC of "asset idle" + 1 WETH of "other idle".
        usdc.mint(address(vault), 100e6);
        weth.mint(address(vault), 1e18);

        // Configure mock pool price: 1 WETH = 2000 USDC.
        // sqrtPriceX96 = sqrt(token1_per_token0_raw) * 2**96.
        // raw ratio = 2000e6 / 1e18 = 2e-9; sqrt ≈ 4.4721e-5; * 2**96 ≈ 3.5432e+24.
        uint160 sqrtPriceX96 = 3543191142285914207004270;
        mockManager.setSlot0(sqrtPriceX96, 0);

        // Expected NAV ≈ idleAsset + idleOther_in_asset_units = 100e6 + ~2_000e6.
        uint256 nav = vault.totalAssets();
        assertGt(nav, 100e6 + 1_900e6, "non-asset leg must be priced in");
        assertLt(nav, 100e6 + 2_100e6 + 1, "no double counting");
    }

    /// M-1: With no pool key set, totalAssets falls back to idle asset only.
    function test_m1_totalAssets_idleOnly_whenPoolKeyUnset() public view {
        assertEq(vault.totalAssets(), 0);
    }

    // ── Audit hardening (Low / Info) ────────────────────────────────────────

    /// Info: setTreasury must reject address(0).
    function test_setTreasury_zeroAddress_reverts() public {
        vm.expectRevert("ZERO_ADDRESS");
        vault.setTreasury(address(0));
    }

    /// L-2: removeLiquiditySlippageBps is owner-adjustable and capped at 1000 BPS.
    function test_setRemoveLiquiditySlippageBps_ownerAndCap() public {
        assertEq(vault.removeLiquiditySlippageBps(), 50);

        vault.setRemoveLiquiditySlippageBps(150);
        assertEq(vault.removeLiquiditySlippageBps(), 150);

        vm.expectRevert("SLIPPAGE_TOO_HIGH");
        vault.setRemoveLiquiditySlippageBps(1_001);

        vm.prank(alice);
        vm.expectRevert();
        vault.setRemoveLiquiditySlippageBps(100);
    }

    /// L-3: txDeadlineSeconds is owner-adjustable, must be in (0, 3600].
    function test_setTxDeadlineSeconds_ownerAndCap() public {
        assertEq(vault.txDeadlineSeconds(), 60);

        vault.setTxDeadlineSeconds(300);
        assertEq(vault.txDeadlineSeconds(), 300);

        vm.expectRevert("DEADLINE_OUT_OF_RANGE");
        vault.setTxDeadlineSeconds(0);

        vm.expectRevert("DEADLINE_OUT_OF_RANGE");
        vault.setTxDeadlineSeconds(3_601);

        vm.prank(alice);
        vm.expectRevert();
        vault.setTxDeadlineSeconds(120);
    }

    /// L-1: If another minter slips in between the vault's nextTokenId()
    /// snapshot and its own modifyLiquidities call, the post-call invariant
    /// (`nextTokenId == expectedTokenId + 1`) must fail and revert the deposit.
    function test_l1_tokenIdRace_revertsDeposit() public {
        vault.setPoolKey(poolKey);
        // Simulate a concurrent mint racing the vault's first deposit.
        mockPosMgr.queueRace(1);

        usdc.mint(alice, 10e6);
        vm.startPrank(alice);
        usdc.approve(address(vault), type(uint256).max);
        vm.expectRevert("TOKEN_ID_RACE");
        vault.deposit(10e6, alice);
        vm.stopPrank();
    }
}
