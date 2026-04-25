// SPDX-License-Identifier: MIT
pragma solidity >=0.8.24 <0.9.0;

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

    function test_split_20_80_precision() public {
        uint256 amount = 100e6;
        uint256 expectedTreasury = (amount * 20) / 100;

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
        FeeDistributor fresh = new FeeDistributor(IPoolManager(address(mockManager)), treasury, hookAddr);
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

    function test_distribute_revertOnNonPoolCurrency() public {
        MockERC20 stray = new MockERC20("Stray", "STRAY", 18);
        stray.mint(address(distributor), 1000);

        vm.prank(hookAddr);
        vm.expectRevert(abi.encodeWithSelector(FeeDistributor.InvalidDistributionCurrency.selector, address(stray)));
        distributor.distribute(Currency.wrap(address(stray)), 1000);
    }

    function test_setHook_ownerOnly() public {
        address newHook = makeAddr("newHook");

        vm.prank(makeAddr("rando"));
        vm.expectRevert();
        distributor.setHook(newHook);

        distributor.setHook(newHook);
        assertEq(distributor.hook(), newHook);
    }

    function test_setHook_zeroAddress_reverts() public {
        vm.expectRevert("ZERO_ADDRESS");
        distributor.setHook(address(0));
    }

    function test_setTreasury_ownerOnly() public {
        address newTreasury = makeAddr("newTreasury");

        vm.prank(makeAddr("rando"));
        vm.expectRevert();
        distributor.setTreasury(newTreasury);

        distributor.setTreasury(newTreasury);
        assertEq(distributor.treasury(), newTreasury);
    }

    function test_setTreasury_zeroAddress_reverts() public {
        vm.expectRevert("ZERO_ADDRESS");
        distributor.setTreasury(address(0));
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
        assertEq(distributor.totalToTreasury(), ((amount * 20) / 100) * rounds);
    }

    // ── Additional coverage ──────────────────────────────────────────────────

    /// After setTreasury(), subsequent distributions send fees to the new address, not the old one.
    function test_setTreasury_routesFeeToUpdatedAddress() public {
        address newTreasury = makeAddr("newTreasury");
        distributor.setTreasury(newTreasury);

        Currency feeCur = poolKey.currency0;
        address tokenAddr = Currency.unwrap(feeCur);
        uint256 amount = 100e6;
        MockERC20(tokenAddr).mint(address(distributor), amount);

        vm.prank(hookAddr);
        distributor.distribute(feeCur, amount);

        uint256 expectedTreasury = (amount * 20) / 100;
        assertEq(MockERC20(tokenAddr).balanceOf(newTreasury), expectedTreasury);
        assertEq(MockERC20(tokenAddr).balanceOf(treasury), 0); // old treasury gets nothing
    }

    /// Ownable2Step: transferOwnership alone does not change the active owner.
    function test_distributor_ownable2step_requiresAccept() public {
        address newOwner = makeAddr("newOwner");
        distributor.transferOwnership(newOwner);

        assertEq(distributor.owner(), address(this));
        assertEq(distributor.pendingOwner(), newOwner);

        vm.prank(newOwner);
        distributor.acceptOwnership();
        assertEq(distributor.owner(), newOwner);
    }

    /// For any amount, treasury + LP portion must always equal the input total.
    function testFuzz_split_treasuryPlusLP_equalsTotal(uint256 amount) public {
        amount = bound(amount, 1, type(uint64).max);

        Currency feeCur = poolKey.currency0;
        MockERC20(Currency.unwrap(feeCur)).mint(address(distributor), amount);

        uint256 treasuryBefore = MockERC20(Currency.unwrap(feeCur)).balanceOf(treasury);
        uint256 lpsBefore = distributor.totalToLPs();

        vm.prank(hookAddr);
        distributor.distribute(feeCur, amount);

        uint256 treasuryGot = MockERC20(Currency.unwrap(feeCur)).balanceOf(treasury) - treasuryBefore;
        uint256 lpsGot = distributor.totalToLPs() - lpsBefore;

        assertEq(treasuryGot + lpsGot, amount);
    }

    // ── Audit hardening (Info) ──────────────────────────────────────────────

    /// Owner can adjust treasuryShare; cap is MAX_TREASURY_SHARE (50).
    function test_setTreasuryShare_ownerAndCap() public {
        assertEq(distributor.treasuryShare(), 20);

        distributor.setTreasuryShare(35);
        assertEq(distributor.treasuryShare(), 35);

        // LP share is the complement.
        assertEq(distributor.lpShare(), 65);

        // Cap.
        vm.expectRevert("SHARE_TOO_HIGH");
        distributor.setTreasuryShare(51);

        // Non-owner.
        vm.prank(makeAddr("rando"));
        vm.expectRevert();
        distributor.setTreasuryShare(10);
    }

    /// After setTreasuryShare, distributions split using the new ratio.
    function test_setTreasuryShare_appliesToNextDistribution() public {
        distributor.setTreasuryShare(40); // 40 / 60

        Currency feeCur = poolKey.currency0;
        address tokenAddr = Currency.unwrap(feeCur);
        uint256 amount = 100e6;
        MockERC20(tokenAddr).mint(address(distributor), amount);

        uint256 treasuryBefore = MockERC20(tokenAddr).balanceOf(treasury);
        vm.prank(hookAddr);
        distributor.distribute(feeCur, amount);

        assertEq(MockERC20(tokenAddr).balanceOf(treasury) - treasuryBefore, (amount * 40) / 100);
        assertEq(distributor.totalToLPs(), amount - (amount * 40) / 100);
    }
}
