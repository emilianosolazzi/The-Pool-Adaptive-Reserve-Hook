// SPDX-License-Identifier: MIT
pragma solidity >=0.8.24 <0.9.0;

import {Test} from "forge-std/Test.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {DynamicFeeHookV2} from "../src/DynamicFeeHookV2.sol";

import {MockERC20} from "./mocks/MockERC20.sol";
import {MockPoolManager} from "./mocks/MockPoolManager.sol";
import {MockFeeDistributor} from "./mocks/MockFeeDistributor.sol";
import {HookMiner} from "./utils/HookMiner.sol";

contract DynamicFeeHookV2ReserveTest is Test {
    using PoolIdLibrary for PoolKey;

    DynamicFeeHookV2 public hook;
    MockPoolManager public mockManager;
    MockFeeDistributor public mockDistributor;
    MockERC20 public token0;
    MockERC20 public token1;
    PoolKey public poolKey;

    address public vaultEOA = makeAddr("vaultEOA");

    function setUp() public {
        mockManager = new MockPoolManager();
        mockDistributor = new MockFeeDistributor();

        MockERC20 tA = new MockERC20("Token A", "TKA", 18);
        MockERC20 tB = new MockERC20("Token B", "TKB", 6);
        (token0, token1) = address(tA) < address(tB) ? (tA, tB) : (tB, tA);

        uint160 flags = Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
            | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;
        (address hookAddr, bytes32 salt) = HookMiner.find(
            address(this),
            flags,
            type(DynamicFeeHookV2).creationCode,
            abi.encode(address(mockManager), address(mockDistributor), address(this))
        );
        hook = new DynamicFeeHookV2{salt: salt}(
            IPoolManager(address(mockManager)), address(mockDistributor), address(this)
        );
        assertEq(address(hook), hookAddr);

        poolKey = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 100,
            tickSpacing: 1,
            hooks: hook
        });
    }

    function _pid() internal view returns (PoolId) {
        return poolKey.toId();
    }

    function test_registerVault_onlyOwnerOnce() public {
        hook.registerVault(poolKey, vaultEOA);
        assertEq(hook.registeredVault(_pid()), vaultEOA);

        vm.expectRevert(DynamicFeeHookV2.VaultAlreadyRegistered.selector);
        hook.registerVault(poolKey, address(0xBEEF));

        vm.prank(address(0xCAFE));
        vm.expectRevert();
        hook.registerVault(poolKey, address(0xBEEF));
    }

    function test_createReserveOffer_unregisteredReverts() public {
        vm.prank(vaultEOA);
        vm.expectRevert(DynamicFeeHookV2.NotRegisteredVault.selector);
        hook.createReserveOffer(
            poolKey, Currency.wrap(address(token1)), uint128(1e6), uint160(1 << 96), 0
        );
    }

    function test_createReserveOffer_pullsEscrow_andSetsState() public {
        hook.registerVault(poolKey, vaultEOA);
        token1.mint(vaultEOA, 1_000e6);

        vm.startPrank(vaultEOA);
        token1.approve(address(hook), type(uint256).max);
        hook.createReserveOffer(
            poolKey,
            Currency.wrap(address(token1)),
            uint128(500e6),
            uint160(2 ** 96),
            uint64(block.timestamp + 1 days)
        );
        vm.stopPrank();

        DynamicFeeHookV2.ReserveOffer memory o = hook.getOffer(poolKey);
        assertEq(uint256(o.sellRemaining), 500e6);
        assertTrue(o.active);
        assertEq(token1.balanceOf(address(hook)), 500e6);
        assertEq(token1.balanceOf(vaultEOA), 500e6);

        vm.startPrank(vaultEOA);
        vm.expectRevert(DynamicFeeHookV2.OfferAlreadyActive.selector);
        hook.createReserveOffer(
            poolKey, Currency.wrap(address(token1)), uint128(1e6), uint160(2 ** 96), 0
        );
        vm.stopPrank();
    }

    function test_cancelReserveOffer_returnsEscrow() public {
        hook.registerVault(poolKey, vaultEOA);
        token1.mint(vaultEOA, 500e6);

        vm.startPrank(vaultEOA);
        token1.approve(address(hook), type(uint256).max);
        hook.createReserveOffer(
            poolKey, Currency.wrap(address(token1)), uint128(500e6), uint160(2 ** 96), 0
        );
        uint128 returned = hook.cancelReserveOffer(poolKey);
        vm.stopPrank();

        assertEq(uint256(returned), 500e6);
        assertEq(token1.balanceOf(vaultEOA), 500e6);
        assertEq(token1.balanceOf(address(hook)), 0);
        DynamicFeeHookV2.ReserveOffer memory o = hook.getOffer(poolKey);
        assertFalse(o.active);
    }

    function test_createReserveOffer_revertsForCurrencyNotInPool() public {
        hook.registerVault(poolKey, vaultEOA);
        MockERC20 stranger = new MockERC20("X", "X", 18);
        stranger.mint(vaultEOA, 1e18);

        vm.startPrank(vaultEOA);
        stranger.approve(address(hook), type(uint256).max);
        vm.expectRevert(DynamicFeeHookV2.UnknownPool.selector);
        hook.createReserveOffer(
            poolKey, Currency.wrap(address(stranger)), uint128(1e18), uint160(2 ** 96), 0
        );
        vm.stopPrank();
    }

    function test_claimReserveProceeds_zeroWhenNoneOwed() public {
        uint256 amount = hook.claimReserveProceeds(Currency.wrap(address(token0)));
        assertEq(amount, 0);
    }

    function test_createReserveOffer_revertsBelowMinSqrtPrice() public {
        hook.registerVault(poolKey, vaultEOA);
        token1.mint(vaultEOA, 1e6);
        vm.startPrank(vaultEOA);
        token1.approve(address(hook), type(uint256).max);
        // TickMath.MIN_SQRT_PRICE = 4295128739; one less must revert.
        vm.expectRevert(DynamicFeeHookV2.InvalidOffer.selector);
        hook.createReserveOffer(
            poolKey, Currency.wrap(address(token1)), uint128(1e6), uint160(4295128738), 0
        );
        vm.stopPrank();
    }

    function test_createReserveOffer_revertsAtOrAboveMaxSqrtPrice() public {
        hook.registerVault(poolKey, vaultEOA);
        token1.mint(vaultEOA, 1e6);
        vm.startPrank(vaultEOA);
        token1.approve(address(hook), type(uint256).max);
        // TickMath.MAX_SQRT_PRICE; equal must also revert (gate is `>=`).
        vm.expectRevert(DynamicFeeHookV2.InvalidOffer.selector);
        hook.createReserveOffer(
            poolKey,
            Currency.wrap(address(token1)),
            uint128(1e6),
            uint160(1461446703485210103287273052203988822378723970342),
            0
        );
        vm.stopPrank();
    }
}
