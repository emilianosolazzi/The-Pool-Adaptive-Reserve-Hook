// SPDX-License-Identifier: MIT
pragma solidity >=0.8.24 <0.9.0;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {DynamicFeeHook} from "../src/DynamicFeeHook.sol";
import {FeeDistributor} from "../src/FeeDistributor.sol";
import {HookMiner} from "./utils/HookMiner.sol";

contract IntegrationTest is Test, Deployers {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    DynamicFeeHook public hook;
    FeeDistributor public distributor;
    PoolKey public poolKey;
    address public treasury;

    uint256 constant HOOK_FEE_BPS = 30;
    uint256 constant BPS_DENOM = 10_000;
    uint256 constant MAX_FEE_BPS = 50;  // 0.5% of amountIn — matches hook.maxFeeBps default
    uint256 constant TREASURY_SHARE = 20;

    function setUp() public {
        treasury = makeAddr("treasury");

        // Deploy real PoolManager + all Uniswap v4-core test routers.
        deployFreshManagerAndRouters();

        // Mint test tokens, approve them for every standard router.
        (currency0, currency1) = deployMintAndApprove2Currencies();

        // Deploy FeeDistributor first with a placeholder hook — resolved below.
        distributor = new FeeDistributor(manager, treasury, address(0));

        // Mine the hook address satisfying the required permission-flag bits.
        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );
        (address hookAddr, bytes32 salt) = HookMiner.find(
            address(this),
            flags,
            type(DynamicFeeHook).creationCode,
            abi.encode(address(manager), address(distributor))
        );

        hook = new DynamicFeeHook{salt: salt}(manager, address(distributor));
        require(address(hook) == hookAddr, "hook addr mismatch");

        // Resolve the circular dependency: now tell the distributor about the hook.
        distributor.setHook(address(hook));

        // Initialize pool at 1:1 price with the hook attached.
        (poolKey,) = initPool(currency0, currency1, IHooks(address(hook)), 3000, SQRT_PRICE_1_1);

        // Register pool key so distribute() can donate to LPs.
        distributor.setPoolKey(poolKey);

        // Seed deep liquidity so swaps don't fail on price limits.
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({tickLower: -3000, tickUpper: 3000, liquidityDelta: 10_000e18, salt: 0}),
            ZERO_BYTES
        );
    }

    // ── Full-cycle test: swap triggers the complete fee pipeline ──────────────

    function test_fullCycle_swapFeeSplitDonate() public {
        uint256 amountIn = 1 ether;
        uint256 expectedFee = (amountIn * HOOK_FEE_BPS) / BPS_DENOM;
        uint256 expectedTreasury = (expectedFee * TREASURY_SHARE) / 100;
        uint256 expectedLP = expectedFee - expectedTreasury;

        uint256 treasuryBefore = MockERC20(Currency.unwrap(currency1)).balanceOf(treasury);

        // Exact-input zeroForOne: caller spends token0, receives token1.
        // Fee is on the output token (currency1).
        swap(poolKey, true, -int256(amountIn), ZERO_BYTES);

        uint256 treasuryGained = MockERC20(Currency.unwrap(currency1)).balanceOf(treasury) - treasuryBefore;

        assertEq(hook.totalSwaps(), 1);
        assertEq(hook.totalFeesRouted(), expectedFee);
        assertEq(treasuryGained, expectedTreasury);
        assertEq(distributor.totalDistributed(), expectedFee);
        assertEq(distributor.totalToTreasury(), expectedTreasury);
        assertEq(distributor.totalToLPs(), expectedLP);
        assertEq(distributor.distributionCount(), 1);
    }

    // ── Fee cap at MAX_FEE_BPS = 50 BPS of amountIn ─────────────────────────

    function test_feeCap_largeSwap() public {
        uint256 amountIn = 100 ether;
        uint256 uncappedFee = (amountIn * HOOK_FEE_BPS) / BPS_DENOM; // 30 BPS of 100 ETH
        uint256 cappedFee   = (amountIn * MAX_FEE_BPS)  / BPS_DENOM; // 50 BPS of 100 ETH
        // 30 BPS < 50 BPS cap → fee is NOT capped; cap only triggers when base > MAX_FEE_BPS.
        // Lower the cap for this test so the cap triggers.
        hook.setMaxFeeBps(20); // 20 BPS cap < 30 BPS base
        uint256 expectedFee = (amountIn * 20) / BPS_DENOM;
        assertTrue(uncappedFee > expectedFee, "precondition: base fee exceeds 20bps cap");

        uint256 treasuryBefore = MockERC20(Currency.unwrap(currency1)).balanceOf(treasury);

        swap(poolKey, true, -int256(amountIn), ZERO_BYTES);

        uint256 expectedTreasury = (expectedFee * TREASURY_SHARE) / 100;

        assertEq(hook.totalFeesRouted(), expectedFee);
        assertEq(
            MockERC20(Currency.unwrap(currency1)).balanceOf(treasury) - treasuryBefore,
            expectedTreasury
        );
    }

    // ── Multiple swaps accumulate stats correctly ─────────────────────────────

    function test_multipleSwaps_accumulateFees() public {
        uint256 amountIn = 1 ether;
        uint256 feePerSwap = (amountIn * HOOK_FEE_BPS) / BPS_DENOM;
        uint256 n = 5;

        uint256 treasuryBefore = MockERC20(Currency.unwrap(currency1)).balanceOf(treasury);

        for (uint256 i; i < n; i++) {
            swap(poolKey, true, -int256(amountIn), ZERO_BYTES);
        }

        uint256 totalExpectedFee = feePerSwap * n;
        uint256 totalExpectedTreasury = (totalExpectedFee * TREASURY_SHARE) / 100;

        assertEq(hook.totalSwaps(), n);
        assertEq(hook.totalFeesRouted(), totalExpectedFee);
        assertEq(distributor.distributionCount(), n);
        assertEq(distributor.totalDistributed(), totalExpectedFee);
        assertEq(
            MockERC20(Currency.unwrap(currency1)).balanceOf(treasury) - treasuryBefore,
            totalExpectedTreasury
        );
    }

    // ── Bidirectional swaps: fees collected in both currency directions ────────

    function test_bidirectional_swapsSucceed() public {
        uint256 amountIn = 1 ether;
        uint256 fee0 = (amountIn * HOOK_FEE_BPS) / BPS_DENOM;

        // zeroForOne: fee on currency1
        uint256 t1Before = MockERC20(Currency.unwrap(currency1)).balanceOf(treasury);
        swap(poolKey, true, -int256(amountIn), ZERO_BYTES);
        uint256 t1Gained = MockERC20(Currency.unwrap(currency1)).balanceOf(treasury) - t1Before;
        assertEq(t1Gained, (fee0 * TREASURY_SHARE) / 100);

        // oneForZero: fee on currency0
        uint256 t0Before = MockERC20(Currency.unwrap(currency0)).balanceOf(treasury);
        swap(poolKey, false, -int256(amountIn), ZERO_BYTES);
        uint256 t0Gained = MockERC20(Currency.unwrap(currency0)).balanceOf(treasury) - t0Before;
        assertEq(t0Gained, (fee0 * TREASURY_SHARE) / 100);

        assertEq(hook.totalSwaps(), 2);
        assertEq(distributor.distributionCount(), 2);
    }

    // ── LP donation increases pool's fee growth globals ───────────────────────

    function test_lpDonation_increasesFeeGrowthGlobals() public {
        PoolId id = poolKey.toId();
        (, uint256 feeGrowth1Before) = manager.getFeeGrowthGlobals(id);

        // zeroForOne → hook fee is on currency1 → feeGrowthGlobal1 must rise.
        swap(poolKey, true, -int256(1 ether), ZERO_BYTES);

        (, uint256 feeGrowth1After) = manager.getFeeGrowthGlobals(id);

        assertGt(feeGrowth1After, feeGrowth1Before, "fee growth did not increase");
    }

    // ── Hook address carries the correct permission bits ──────────────────────

    function test_hookAddress_hasCorrectFlags() public view {
        uint160 addr = uint160(address(hook));
        assertTrue(addr & Hooks.BEFORE_SWAP_FLAG != 0, "missing BEFORE_SWAP");
        assertTrue(addr & Hooks.AFTER_SWAP_FLAG != 0, "missing AFTER_SWAP");
        assertTrue(addr & Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG != 0, "missing AFTER_SWAP_RETURNS_DELTA");
        assertTrue(addr & Hooks.BEFORE_INITIALIZE_FLAG == 0, "unexpected BEFORE_INITIALIZE");
        assertTrue(addr & Hooks.AFTER_DONATE_FLAG == 0, "unexpected AFTER_DONATE");
    }

    // ── Swap with zero fee (tiny amount below 30 bps resolution) ─────────────

    function test_zeroFee_swapSucceeds() public {
        // amountIn = 3 → fee = (3 * 30) / 10000 = 0 (integer truncation)
        swap(poolKey, true, -int256(3), ZERO_BYTES);

        assertEq(hook.totalSwaps(), 1);
        assertEq(hook.totalFeesRouted(), 0);
        assertEq(distributor.distributionCount(), 0);
    }

    // ── distributor.setHook() access control guard ────────────────────────────

    function test_distribute_onlyHookCanCall() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert("ONLY_HOOK");
        distributor.distribute(currency1, 1e18);
    }
}
