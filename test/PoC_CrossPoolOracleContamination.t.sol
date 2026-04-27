// SPDX-License-Identifier: MIT
pragma solidity >=0.8.24 <0.9.0;

// PoC for Finding 1 (auditor-supplied). Adapted only for the new
// getVolatilityInfo(PoolKey) signature introduced by the per-pool keying fix.
// Regression test: a tiny side-pool swap must not poison the canonical pool's
// volatility reference. This would fail against the pre-fix global oracle slot.

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

contract PoC_CrossPoolOracleContamination is Test {
    DynamicFeeHook hook;
    MockPoolManager mgr;
    MockFeeDistributor dist;

    MockERC20 t0;
    MockERC20 t1;
    PoolKey canonical;

    MockERC20 sideToken;
    PoolKey sidePool;

    uint256 constant BASE_BPS = 25;
    uint256 constant DENOM = 10_000;

    function setUp() public {
        mgr = new MockPoolManager();
        dist = new MockFeeDistributor();

        MockERC20 a = new MockERC20("A", "A", 18);
        MockERC20 b = new MockERC20("B", "B", 18);
        (t0, t1) = address(a) < address(b) ? (a, b) : (b, a);
        sideToken = new MockERC20("X", "X", 18);

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

        canonical = PoolKey({
            currency0: Currency.wrap(address(t0)),
            currency1: Currency.wrap(address(t1)),
            fee: 100,
            tickSpacing: 1,
            hooks: hook
        });

        (MockERC20 s0, MockERC20 s1) = address(t0) < address(sideToken)
            ? (t0, sideToken)
            : (sideToken, t0);
        sidePool = PoolKey({
            currency0: Currency.wrap(address(s0)),
            currency1: Currency.wrap(address(s1)),
            fee: 3000,
            tickSpacing: 60,
            hooks: hook
        });
    }

    /// Regression: after a tiny side-pool swap, the canonical pool's volatility
    /// reference remains its own warmed-up price, not the side-pool extreme.
    function test_attack_crossPoolDoesNotPoisonReference() public {
        uint160 canonicalPrice = uint160(1 << 96);
        mgr.setSlot0(canonicalPrice, 0);

        // Warm up canonical pool reference.
        SwapParams memory warm =
            SwapParams({zeroForOne: true, amountSpecified: -int256(uint256(1e18)), sqrtPriceLimitX96: 0});
        MockERC20(Currency.unwrap(canonical.currency1)).mint(address(mgr), 1e18);
        vm.prank(address(mgr));
        hook.beforeSwap(address(this), canonical, warm, "");
        vm.prank(address(mgr));
        hook.afterSwap(address(this), canonical, warm, toBalanceDelta(0, int128(int256(1e15))), "");
        vm.roll(block.number + 1);

        // Attacker: side pool with extreme slot0.
        uint160 extremePrice = uint160(1 << 96) * 4;
        mgr.setSlot0(extremePrice, 0);

        SwapParams memory tinySideSwap =
            SwapParams({zeroForOne: true, amountSpecified: -int256(uint256(1)), sqrtPriceLimitX96: 0});
        vm.prank(address(mgr));
        hook.beforeSwap(address(this), sidePool, tinySideSwap, "");
        vm.prank(address(mgr));
        hook.afterSwap(address(this), sidePool, tinySideSwap, toBalanceDelta(0, 0), "");

        // Read CANONICAL pool's reference. With per-pool keying, this must stay
        // at the canonical price and must not equal the attacker's side price.
        (,, uint160 canonRef,) = hook.getVolatilityInfo(canonical);
        assertEq(canonRef, canonicalPrice, "canonical reference changed");
        assertNotEq(canonRef, extremePrice, "canonical reference poisoned by side pool");
    }
}
