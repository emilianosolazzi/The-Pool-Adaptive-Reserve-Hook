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
        // 1e18 * 25 / 10000 = 2.5e15; cap is 50 BPS of amountIn = 5e15 → base fee wins
        uint256 amountIn = 1e18;
        (uint256 feeAmount,,,, ) = hook.getSwapFeeInfo(amountIn);
        assertEq(feeAmount, (amountIn * 25) / 10_000);
    }

    function test_feeCalculation_cappedAtMax() public view {
        // HOOK_FEE_BPS=25, maxFeeBps=50 → cap = 50 BPS, base = 25 BPS → base always wins
        // The cap only triggers when the base (or volatility-scaled) fee exceeds maxFeeBps.
        // Verify via an explicit lower cap set in the next test.
        uint256 amountIn = 1e22;
        (uint256 feeAmount,,,, ) = hook.getSwapFeeInfo(amountIn);
        // 25 BPS of 1e22 = 2.5e19, cap = 50 BPS of 1e22 = 5e19 → base wins
        assertEq(feeAmount, (amountIn * 25) / 10_000);
    }

    function test_beforeSwap_noFeeForMismatchedKey() public {
        PoolKey memory wrongKey = poolKey;
        wrongKey.hooks = DynamicFeeHook(payable(address(0xdead)));

        SwapParams memory params = SwapParams({zeroForOne: true, amountSpecified: -1e18, sqrtPriceLimitX96: 0});
        vm.prank(address(mockManager));
        (bytes4 sel, , ) = hook.beforeSwap(address(this), wrongKey, params, "");

        assertEq(sel, DynamicFeeHook.beforeSwap.selector);
        assertEq(hook.totalSwaps(), 0);
    }

    function test_afterSwap_routesFeeToDistributor() public {
        uint256 amountIn = 1e18;
        uint256 expectedFee = (amountIn * 25) / 10_000;

        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: -int256(amountIn),
            sqrtPriceLimitX96: 0
        });

        token1.mint(address(mockManager), expectedFee);
        vm.prank(address(mockManager));
        hook.beforeSwap(address(this), poolKey, params, "");
        assertEq(hook.totalSwaps(), 1);

        vm.prank(address(mockManager));
        hook.afterSwap(address(this), poolKey, params, toBalanceDelta(0, 0), "");

        assertEq(mockDistributor.callCount(), 1);
        assertEq(mockDistributor.lastAmount(), expectedFee);
        assertEq(hook.totalFeesRouted(), expectedFee);
    }

    function test_transientStorage_clearedAfterAfterSwap() public {
        uint256 amountIn = 1e18;
        uint256 fee = (amountIn * 25) / 10_000;
        BalanceDelta delta = toBalanceDelta(0, 0);

        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: -int256(amountIn),
            sqrtPriceLimitX96: 0
        });

        token1.mint(address(mockManager), fee);
        vm.prank(address(mockManager));
        hook.beforeSwap(address(this), poolKey, params, "");
        vm.prank(address(mockManager));
        hook.afterSwap(address(this), poolKey, params, delta, "");

        uint256 countBefore = mockDistributor.callCount();
        vm.prank(address(mockManager));
        hook.afterSwap(address(this), poolKey, params, delta, "");
        assertEq(mockDistributor.callCount(), countBefore);
    }

    function test_stats_accumulateAcrossSwaps() public {
        uint256 amountIn = 1e18;
        uint256 feePerSwap = (amountIn * 25) / 10_000;
        uint256 swaps = 3;

        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: -int256(amountIn),
            sqrtPriceLimitX96: 0
        });

        token1.mint(address(mockManager), feePerSwap * swaps);

        for (uint256 i = 0; i < swaps; i++) {
            vm.prank(address(mockManager));
            hook.beforeSwap(address(this), poolKey, params, "");
            vm.prank(address(mockManager));
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
        uint256 newCapBps = 20; // 20 BPS < 25 BPS base fee
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

    /// setMaxFeeBps reverts above the 1000 BPS (10%) protocol ceiling.
    function test_setMaxFeeBps_revertOnOverflow() public {
        vm.expectRevert("BPS_TOO_HIGH");
        hook.setMaxFeeBps(1_001);
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

    /// setFeeDistributor reverts on address(0).
    function test_setFeeDistributor_zeroAddress_reverts() public {
        vm.expectRevert("ZERO_ADDRESS");
        hook.setFeeDistributor(address(0));
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

    /// getVolatilityInfo returns correct constants and zero state before any swap.
    function test_getVolatilityInfo_defaults() public view {
        (uint256 thresholdBps, uint256 multiplierPct, uint160 refPrice, uint256 refBlock) =
            hook.getVolatilityInfo();
        assertEq(thresholdBps,  100); // 1% inter-swap price move triggers multiplier
        assertEq(multiplierPct, 150); // 1.5x fee in volatile regime
        assertEq(refPrice,        0); // no swaps have occurred yet
        assertEq(refBlock,        0); // no swaps have occurred yet
    }

    // ── Audit regressions ───────────────────────────────────────────────────

    /// M-2: hook callbacks must reject callers other than the PoolManager.
    function test_m2_beforeSwap_revertsWhenNotPoolManager() public {
        SwapParams memory p = SwapParams({zeroForOne: true, amountSpecified: -1e18, sqrtPriceLimitX96: 0});
        vm.expectRevert(); // BaseHook.NotPoolManager
        hook.beforeSwap(address(this), poolKey, p, "");
    }

    function test_m2_afterSwap_revertsWhenNotPoolManager() public {
        SwapParams memory p = SwapParams({zeroForOne: true, amountSpecified: -1e18, sqrtPriceLimitX96: 0});
        vm.expectRevert(); // BaseHook.NotPoolManager
        hook.afterSwap(address(this), poolKey, p, toBalanceDelta(0, 0), "");
    }

    /// H-1: For exact-output swaps the fee must be charged in the UNSPECIFIED
    /// (input) currency, because afterSwapReturnDelta is applied to the
    /// unspecified side. Pre-fix this picked the OUTPUT currency, taking value
    /// from the pool while billing the user on the input — net loss to LPs.
    function test_h1_exactOutput_zeroForOne_takesFeeOnInputCurrency() public {
        uint256 amountOut = 1e18;
        uint256 expectedFee = (amountOut * 25) / 10_000;

        // exact-output: amountSpecified > 0; specified = currency1 (output),
        // unspecified = currency0 (input). Hook MUST take the fee in token0.
        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: int256(amountOut),
            sqrtPriceLimitX96: 0
        });

        // Fund the pool manager with the INPUT currency, not the output.
        // If the hook (incorrectly) tried to take from currency1, the
        // mockManager.take call would revert for missing balance.
        token0.mint(address(mockManager), expectedFee);

        vm.prank(address(mockManager));
        hook.beforeSwap(address(this), poolKey, params, "");
        vm.prank(address(mockManager));
        hook.afterSwap(address(this), poolKey, params, toBalanceDelta(0, 0), "");

        // Distributor was paid in the unspecified (input) currency.
        assertEq(mockDistributor.callCount(), 1, "fee not routed");
        assertEq(mockDistributor.lastAmount(), expectedFee, "wrong fee amount");
        assertEq(
            Currency.unwrap(mockDistributor.lastCurrency()),
            address(token0),
            "fee must be charged in unspecified (input) currency"
        );
    }

    /// H-1: Symmetric exact-output check for the oneForZero direction.
    function test_h1_exactOutput_oneForZero_takesFeeOnInputCurrency() public {
        uint256 amountOut = 1e18;
        uint256 expectedFee = (amountOut * 25) / 10_000;

        // oneForZero exact-output: input = currency1, output = currency0,
        // unspecified = currency1.
        SwapParams memory params = SwapParams({
            zeroForOne: false,
            amountSpecified: int256(amountOut),
            sqrtPriceLimitX96: 0
        });

        token1.mint(address(mockManager), expectedFee);

        vm.prank(address(mockManager));
        hook.beforeSwap(address(this), poolKey, params, "");
        vm.prank(address(mockManager));
        hook.afterSwap(address(this), poolKey, params, toBalanceDelta(0, 0), "");

        assertEq(
            Currency.unwrap(mockDistributor.lastCurrency()),
            address(token1),
            "fee must be charged in unspecified (input) currency"
        );
    }

    /// Sanity: exact-input direction selection is unchanged after the H-1 fix.
    function test_h1_exactInput_oneForZero_takesFeeOnOutputCurrency() public {
        uint256 amountIn = 1e18;
        uint256 expectedFee = (amountIn * 25) / 10_000;

        // oneForZero exact-input: input = currency1, output = currency0,
        // unspecified = currency0 (output).
        SwapParams memory params = SwapParams({
            zeroForOne: false,
            amountSpecified: -int256(amountIn),
            sqrtPriceLimitX96: 0
        });

        token0.mint(address(mockManager), expectedFee);

        vm.prank(address(mockManager));
        hook.beforeSwap(address(this), poolKey, params, "");
        vm.prank(address(mockManager));
        hook.afterSwap(address(this), poolKey, params, toBalanceDelta(0, 0), "");

        assertEq(
            Currency.unwrap(mockDistributor.lastCurrency()),
            address(token0),
            "fee currency must be unspecified (output) for exact-input"
        );
    }
}
