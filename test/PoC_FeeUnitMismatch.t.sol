// SPDX-License-Identifier: MIT
pragma solidity >=0.8.24 <0.9.0;

// PoC regressions for Finding 2. The pre-fix hook computed fees from
// amountSpecified units, then took them from the unspecified currency. On
// cross-decimal pools that could turn 1e18 WETH wei into an impossible raw-USDC
// fee. The fixed hook sizes fees from the actual unspecified BalanceDelta leg.

import {Test} from "forge-std/Test.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

import {DynamicFeeHook} from "../src/DynamicFeeHook.sol";

import {MockERC20} from "./mocks/MockERC20.sol";
import {MockPoolManager} from "./mocks/MockPoolManager.sol";
import {MockFeeDistributor} from "./mocks/MockFeeDistributor.sol";
import {HookMiner} from "./utils/HookMiner.sol";

contract PoC_FeeUnitMismatch is Test {
    DynamicFeeHook hook;
    MockPoolManager mgr;
    MockFeeDistributor dist;

    uint256 constant BPS = 25;
    uint256 constant DENOM = 10_000;

    function setUp() public {
        mgr = new MockPoolManager();
        dist = new MockFeeDistributor();

        uint160 flags =
            Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;

        (address hookAddr, bytes32 salt) = HookMiner.find(
            address(this),
            flags,
            type(DynamicFeeHook).creationCode,
            abi.encode(address(mgr), address(dist), address(this))
        );
        hook = new DynamicFeeHook{salt: salt}(IPoolManager(address(mgr)), address(dist), address(this));
        assertEq(address(hook), hookAddr);
    }

    /// Baseline regression: same-decimal pair routes fee equal to the
    /// unspecified-leg output amount * 25/10000. We pass a simplified 1:1
    /// BalanceDelta so this remains a green control on the fixed code.
    function test_sameDecimal_swapSucceeds() public {
        MockERC20 a = new MockERC20("A18", "A18", 18);
        MockERC20 b = new MockERC20("B18", "B18", 18);
        (MockERC20 t0, MockERC20 t1) = address(a) < address(b) ? (a, b) : (b, a);

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(t0)),
            currency1: Currency.wrap(address(t1)),
            fee: 100,
            tickSpacing: 1,
            hooks: hook
        });

        uint256 amountIn = 1e18;
        uint256 fee = (amountIn * BPS) / DENOM; // 2.5e15
        t1.mint(address(mgr), fee);

        SwapParams memory p =
            SwapParams({zeroForOne: true, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: 0});

        vm.prank(address(mgr));
        hook.beforeSwap(address(this), key, p, "");
        vm.prank(address(mgr));
        hook.afterSwap(address(this), key, p, toBalanceDelta(-int128(uint128(amountIn)), int128(uint128(amountIn))), "");

        assertEq(hook.totalFeesRouted(), fee, "same-decimal pair routes fee from output delta");
    }

    /// Regression: cross-decimal exact-input swaps route fees in the output
    /// token's native units and do not revert from impossible raw-unit fees.
    function test_crossDecimal_swapDoesNotDoS() public {
        MockERC20 weth = new MockERC20("WETH", "WETH", 18);
        MockERC20 usdc = new MockERC20("USDC", "USDC", 6);
        (MockERC20 t0, MockERC20 t1) = address(weth) < address(usdc) ? (weth, usdc) : (usdc, weth);

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(t0)),
            currency1: Currency.wrap(address(t1)),
            fee: 100,
            tickSpacing: 1,
            hooks: hook
        });

        uint256 amountIn = 1e18;
        bool t1IsSixDec = address(t1) == address(usdc);

        SwapParams memory p =
            SwapParams({zeroForOne: true, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: 0});

        if (t1IsSixDec) {
            uint256 outputAmount = 5_000e6;
            uint256 expectedFee = (outputAmount * BPS) / DENOM;
            t1.mint(address(mgr), expectedFee);

            vm.prank(address(mgr));
            hook.beforeSwap(address(this), key, p, "");
            vm.prank(address(mgr));
            hook.afterSwap(address(this), key, p, toBalanceDelta(-int128(uint128(amountIn)), int128(uint128(outputAmount))), "");

            assertEq(hook.totalFeesRouted(), expectedFee, "USDC output fee uses USDC units");
            return;
        }

        uint256 outputAmount = 5_000e6;
        uint256 expectedFee = (outputAmount * BPS) / DENOM;
        t0.mint(address(mgr), expectedFee);

        SwapParams memory pFlip =
            SwapParams({zeroForOne: false, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: 0});
        vm.prank(address(mgr));
        hook.beforeSwap(address(this), key, pFlip, "");
        vm.prank(address(mgr));
        hook.afterSwap(address(this), key, pFlip, toBalanceDelta(int128(uint128(outputAmount)), -int128(uint128(amountIn))), "");

        assertEq(hook.totalFeesRouted(), expectedFee, "USDC output fee uses USDC units");
    }
}
