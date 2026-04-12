// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

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

        // Two tokens — ensure token0 < token1 by address
        MockERC20 tA = new MockERC20("Token A", "TKA", 18);
        MockERC20 tB = new MockERC20("Token B", "TKB", 18);
        if (address(tA) < address(tB)) {
            token0 = tA;
            token1 = tB;
        } else {
            token0 = tB;
            token1 = tA;
        }

        // Mine a salt for DynamicFeeHook that gives an address with BEFORE_SWAP | AFTER_SWAP flags
        uint160 flags = Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG;
        (address hookAddr, bytes32 salt) = HookMiner.find(
            address(this),
            flags,
            type(DynamicFeeHook).creationCode,
            abi.encode(address(mockManager), address(mockDistributor))
        );

        hook = new DynamicFeeHook{salt: salt}(IPoolManager(address(mockManager)), address(mockDistributor));
        assertEq(address(hook), hookAddr, "hook address mismatch");

        poolKey = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: FEE,
            tickSpacing: TICK_SPACING,
            hooks: hook
        });
    }

    // ─── 1. Pure fee math — small swap (below cap) ────────────────────────────

    function test_feeCalculation_smallSwap() public view {
        // 1e18 → fee = 1e18 * 30 / 10000 = 3e15 < 0.02 ether cap
        uint256 amountIn = 1e18;
        uint256 expected = (amountIn * 30) / 10_000;
        (uint256 feeAmount,,,, ) = _swapFeeInfo(amountIn);
        assertEq(feeAmount, expected);
    }

    // ─── 2. Fee cap at MAX_FEE_PER_SWAP ──────────────────────────────────────

    function test_feeCalculation_cappedAtMax() public view {
        // 1e22 → uncapped fee = 1e22 * 30 / 10000 = 3e19 >> 0.02 ether
        uint256 amountIn = 1e22;
        uint256 uncapped = (amountIn * 30) / 10_000;

        (uint256 feeAmount,,,, ) = _swapFeeInfo(amountIn);
        if (uncapped > 0.02 ether) {
            assertEq(feeAmount, 0.02 ether);
        } else {
            assertEq(feeAmount, uncapped);
        }
    }

    // ─── 3. beforeSwap: no fee when key.hooks != hook ────────────────────────

    function test_beforeSwap_noFeeForMismatchedKey() public {
        PoolKey memory wrongKey = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: FEE,
            tickSpacing: TICK_SPACING,
            hooks: hook  // correct hooks address
        });
        // Swap 0→1 with exact input
        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: -1e18,
            sqrtPriceLimitX96: 0
        });

        // Override key.hooks to something else so the early-return path triggers
        wrongKey.hooks = DynamicFeeHook(payable(address(0xdead)));

        (bytes4 sel, , ) = hook.beforeSwap(address(this), wrongKey, params, "");
        assertEq(sel, DynamicFeeHook.beforeSwap.selector);
        // totalSwaps must NOT increment (early return)
        assertEq(hook.totalSwaps(), 0);
    }

    // ─── 4. beforeSwap → afterSwap: fee routed to distributor ────────────────

    function test_afterSwap_routesFeeToDistributor() public {
        // 1e18 → fee = 3e15 (well below 0.02 ether cap)
        uint256 amountIn = 1e18;
        uint256 expectedFee = (amountIn * 30) / 10_000;

        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: -int256(amountIn),
            sqrtPriceLimitX96: 0
        });

        // Pre-fund MockPoolManager with token1 so take() can succeed
        token1.mint(address(mockManager), expectedFee);

        // Call beforeSwap to load transient storage
        hook.beforeSwap(address(this), poolKey, params, "");
        assertEq(hook.totalSwaps(), 1);

        // Call afterSwap — hook will do take → transfer → distribute
        BalanceDelta delta = toBalanceDelta(0, 0);
        hook.afterSwap(address(this), poolKey, params, delta, "");

        assertEq(mockDistributor.callCount(), 1);
        assertEq(mockDistributor.lastAmount(), expectedFee);
        assertEq(hook.totalFeesRouted(), expectedFee);
    }

    // ─── 5. Transient storage cleared after afterSwap ────────────────────────

    function test_transientStorage_clearedAfterAfterSwap() public {
        uint256 amountIn = 1e18;
        uint256 fee = (amountIn * 30) / 10_000;

        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: -int256(amountIn),
            sqrtPriceLimitX96: 0
        });

        token1.mint(address(mockManager), fee);
        hook.beforeSwap(address(this), poolKey, params, "");

        BalanceDelta delta = toBalanceDelta(0, 0);
        hook.afterSwap(address(this), poolKey, params, delta, "");

        // A second afterSwap in the same tx should see fee=0 (transient cleared)
        // and therefore NOT call distributor again
        uint256 beforeCount = mockDistributor.callCount();
        hook.afterSwap(address(this), poolKey, params, delta, "");
        assertEq(mockDistributor.callCount(), beforeCount, "distributor called with stale transient data");
    }

    // ─── 6. Stats accumulate over multiple swaps ──────────────────────────────

    function test_stats_accumulateAcrossSwaps() public {
        // 1e18 → fee = 3e15 per swap (below cap)
        uint256 amountIn = 1e18;
        uint256 feePerSwap = (amountIn * 30) / 10_000;
        uint256 swaps = 3;

        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: -int256(amountIn),
            sqrtPriceLimitX96: 0
        });
        BalanceDelta delta = toBalanceDelta(0, 0);

        token1.mint(address(mockManager), feePerSwap * swaps);

        for (uint256 i = 0; i < swaps; i++) {
            hook.beforeSwap(address(this), poolKey, params, "");
            hook.afterSwap(address(this), poolKey, params, delta, "");
        }

        assertEq(hook.totalSwaps(), swaps);
        assertEq(hook.totalFeesRouted(), feePerSwap * swaps);
        assertEq(mockDistributor.callCount(), swaps);
    }

    // ─── helpers ─────────────────────────────────────────────────────────────

    function _swapFeeInfo(uint256 amountIn)
        internal
        view
        returns (
            uint256 feeAmount,
            uint256 feeBps,
            uint256 treasuryBps,
            uint256 lpBonusBps,
            string memory description
        )
    {
        return hook.getSwapFeeInfo(amountIn);
    }
}
