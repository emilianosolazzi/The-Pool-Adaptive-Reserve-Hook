// SPDX-License-Identifier: MIT
pragma solidity >=0.8.24 <0.9.0;

import {Test} from "forge-std/Test.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";

import {DynamicFeeHook} from "../src/DynamicFeeHook.sol";

import {MockERC20} from "./mocks/MockERC20.sol";
import {MockPoolManager} from "./mocks/MockPoolManager.sol";
import {MockFeeDistributor} from "./mocks/MockFeeDistributor.sol";
import {HookMiner} from "./utils/HookMiner.sol";

contract DynamicFeeHookTest is Test {
    DynamicFeeHook public hook;
    MockPoolManager public mockManager;
    MockFeeDistributor public mockDistributor;
    MockERC20 public token0;
    MockERC20 public token1;
    PoolKey public poolKey;

    uint24 constant FEE = 100;
    int24 constant TICK_SPACING = 1;

    function setUp() public {
        mockManager    = new MockPoolManager();
        mockDistributor = new MockFeeDistributor();

        MockERC20 tA = new MockERC20("Token A", "TKA", 18);
        MockERC20 tB = new MockERC20("Token B", "TKB", 18);
        (token0, token1) = address(tA) < address(tB) ? (tA, tB) : (tB, tA);

        uint160 flags = Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;
        (address hookAddr, bytes32 salt) = HookMiner.find(
            address(this),
            flags,
            type(DynamicFeeHook).creationCode,
            abi.encode(address(mockManager), address(mockDistributor))
        );

        hook = new DynamicFeeHook{salt: salt}(IPoolManager(address(mockManager)), address(mockDistributor));
        assertEq(address(hook), hookAddr);

        poolKey = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: FEE,
            tickSpacing: TICK_SPACING,
            hooks: hook
        });
    }

    function test_feeCalculation_smallSwap() public view {
        // 1e18 * 30 / 10000 = 3e15; cap is 50 BPS of amountIn = 5e15 → base fee wins
        uint256 amountIn = 1e18;
        (uint256 feeAmount,,,, ) = hook.getSwapFeeInfo(amountIn);
        assertEq(feeAmount, (amountIn * 30) / 10_000);
    }

    function test_feeCalculation_cappedAtMax() public view {
        // HOOK_FEE_BPS=30, maxFeeBps=50 → cap = 50 BPS, base = 30 BPS → base always wins
        // Make amountIn huge so even 30 BPS > 50 BPS of a smaller reference — not possible
        // Actually 30 < 50 so the fee is always the 30 BPS leg unless maxFeeBps < 30.
        // Verify via an explicit lower cap set in the next test.
        uint256 amountIn = 1e22;
        (uint256 feeAmount,,,, ) = hook.getSwapFeeInfo(amountIn);
        // 30 BPS of 1e22 = 3e19, cap = 50 BPS of 1e22 = 5e19 → base wins
        assertEq(feeAmount, (amountIn * 30) / 10_000);
    }

    function test_beforeSwap_noFeeForMismatchedKey() public {
        PoolKey memory wrongKey = poolKey;
        wrongKey.hooks = DynamicFeeHook(payable(address(0xdead)));

        SwapParams memory params = SwapParams({zeroForOne: true, amountSpecified: -1e18, sqrtPriceLimitX96: 0});
        (bytes4 sel, , ) = hook.beforeSwap(address(this), wrongKey, params, "");

        assertEq(sel, DynamicFeeHook.beforeSwap.selector);
        assertEq(hook.totalSwaps(), 0);
    }

    function test_afterSwap_routesFeeToDistributor() public {
        uint256 amountIn = 1e18;
        uint256 expectedFee = (amountIn * 30) / 10_000;

        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: -int256(amountIn),
            sqrtPriceLimitX96: 0
        });

        token1.mint(address(mockManager), expectedFee);
        hook.beforeSwap(address(this), poolKey, params, "");
        assertEq(hook.totalSwaps(), 1);

        hook.afterSwap(address(this), poolKey, params, toBalanceDelta(0, 0), "");

        assertEq(mockDistributor.callCount(), 1);
        assertEq(mockDistributor.lastAmount(), expectedFee);
        assertEq(hook.totalFeesRouted(), expectedFee);
    }

    function test_transientStorage_clearedAfterAfterSwap() public {
        uint256 amountIn = 1e18;
        uint256 fee = (amountIn * 30) / 10_000;
        BalanceDelta delta = toBalanceDelta(0, 0);

        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: -int256(amountIn),
            sqrtPriceLimitX96: 0
        });

        token1.mint(address(mockManager), fee);
        hook.beforeSwap(address(this), poolKey, params, "");
        hook.afterSwap(address(this), poolKey, params, delta, "");

        uint256 countBefore = mockDistributor.callCount();
        hook.afterSwap(address(this), poolKey, params, delta, "");
        assertEq(mockDistributor.callCount(), countBefore);
    }

    function test_stats_accumulateAcrossSwaps() public {
        uint256 amountIn = 1e18;
        uint256 feePerSwap = (amountIn * 30) / 10_000;
        uint256 swaps = 3;

        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: -int256(amountIn),
            sqrtPriceLimitX96: 0
        });

        token1.mint(address(mockManager), feePerSwap * swaps);

        for (uint256 i = 0; i < swaps; i++) {
            hook.beforeSwap(address(this), poolKey, params, "");
            hook.afterSwap(address(this), poolKey, params, toBalanceDelta(0, 0), "");
        }

        assertEq(hook.totalSwaps(), swaps);
        assertEq(hook.totalFeesRouted(), feePerSwap * swaps);
        assertEq(mockDistributor.callCount(), swaps);
    }

    // ── Setter & access-control tests ───────────────────────────────────────

    /// Owner can lower the fee cap; getSwapFeeInfo and beforeSwap respect the new value.
    function test_setMaxFeeBps_updatesAndEnforces() public {
        // Lower the cap below HOOK_FEE_BPS so the cap triggers
        uint256 newCapBps = 20; // 20 BPS < 30 BPS base fee
        hook.setMaxFeeBps(newCapBps);
        assertEq(hook.maxFeeBps(), newCapBps);

        uint256 amountIn = 1e18;
        (uint256 fee,,,,) = hook.getSwapFeeInfo(amountIn);
        assertEq(fee, (amountIn * newCapBps) / 10_000);
    }

    /// Non-owner cannot adjust the fee cap.
    function test_setMaxFeeBps_onlyOwner() public {
        vm.prank(makeAddr("rando"));
        vm.expectRevert();
        hook.setMaxFeeBps(10);
    }

    /// setMaxFeeBps reverts if caller passes more than 10 000 BPS.
    function test_setMaxFeeBps_revertOnOverflow() public {
        vm.expectRevert("BPS_TOO_HIGH");
        hook.setMaxFeeBps(10_001);
    }

    /// Owner can point the hook at a new distributor.
    function test_setFeeDistributor_updatesAddress() public {
        address newDist = makeAddr("newDist");
        hook.setFeeDistributor(newDist);
        assertEq(address(hook.feeDistributor()), newDist);
    }

    /// Non-owner cannot replace the distributor.
    function test_setFeeDistributor_onlyOwner() public {
        vm.prank(makeAddr("rando"));
        vm.expectRevert();
        hook.setFeeDistributor(makeAddr("newDist"));
    }

    /// Ownable2Step: transferOwnership alone does not change the active owner;
    /// acceptOwnership() by the pending owner completes the handoff.
    function test_hook_ownable2step_requiresAccept() public {
        address newOwner = makeAddr("newOwner");
        hook.transferOwnership(newOwner);

        assertEq(hook.owner(),        address(this)); // unchanged
        assertEq(hook.pendingOwner(), newOwner);      // queued

        vm.prank(newOwner);
        hook.acceptOwnership();
        assertEq(hook.owner(), newOwner);
    }

    // ── Fuzz tests ───────────────────────────────────────────────────────────

    /// Fee must never exceed maxFeeBps fraction of amountIn for any amountIn.
    function testFuzz_feeCalculation_capAlwaysRespected(uint256 amountIn) public view {
        amountIn = bound(amountIn, 0, type(uint256).max / 10_000);
        (uint256 fee,,,,) = hook.getSwapFeeInfo(amountIn);
        uint256 cap = (amountIn * hook.maxFeeBps()) / 10_000;
        assertLe(fee, cap == 0 ? 0 : cap + 1); // allow 1 wei rounding
    }
}
