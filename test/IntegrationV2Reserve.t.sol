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
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

import {DynamicFeeHookV2} from "../src/DynamicFeeHookV2.sol";
import {FeeDistributor} from "../src/FeeDistributor.sol";
import {HookMiner} from "./utils/HookMiner.sol";

/// @notice End-to-end test of DynamicFeeHookV2 reserve-sale path against a
///         real PoolManager. Verifies the toBeforeSwapDelta sign convention,
///         escrow accounting, and that swappers actually receive `giveAmount`
///         from the hook (not the AMM) on the reserve-fill leg.
contract IntegrationV2ReserveTest is Test, Deployers {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    DynamicFeeHookV2 public hook;
    FeeDistributor public distributor;
    PoolKey public poolKey;
    address public treasury;
    address public vaultEOA = makeAddr("vaultEOA");

    function setUp() public {
        treasury = makeAddr("treasury");

        deployFreshManagerAndRouters();
        (currency0, currency1) = deployMintAndApprove2Currencies();

        distributor = new FeeDistributor(manager, treasury, address(0));

        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );
        (address hookAddr, bytes32 salt) = HookMiner.find(
            address(this),
            flags,
            type(DynamicFeeHookV2).creationCode,
            abi.encode(address(manager), address(distributor), address(this))
        );
        hook = new DynamicFeeHookV2{salt: salt}(manager, address(distributor), address(this));
        require(address(hook) == hookAddr, "hook addr mismatch");
        distributor.setHook(address(hook));

        // Use 100 LP fee + tickSpacing 1 to match hook constants.
        (poolKey,) = initPool(currency0, currency1, IHooks(address(hook)), 100, SQRT_PRICE_1_1);
        distributor.setPoolKey(poolKey);

        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({tickLower: -3000, tickUpper: 3000, liquidityDelta: 10_000e18, salt: 0}),
            ZERO_BYTES
        );

        // Bind vault as reserve-offer manager.
        hook.registerVault(poolKey, vaultEOA);

        // Fund vault with token1 and approve hook.
        MockERC20(Currency.unwrap(currency1)).mint(vaultEOA, 100 ether);
        vm.prank(vaultEOA);
        MockERC20(Currency.unwrap(currency1)).approve(address(hook), type(uint256).max);
    }

    /// @dev Reserve has 0.5e18 token1 at vaultSqrtP = SQRT_PRICE_1_1 (rate 1:1).
    ///      Swapper supplies 1 ether token0. Reserve fills 0.5e18 / 0.5e18,
    ///      remaining 0.5e18 routes through AMM. Sign-convention check:
    ///      swapper must end up with > 0.5e18 token1 (reserve fill + AMM out).
    function test_reserveFill_partialThenAMM() public {
        uint128 sellAmount = 0.5e18;
        // Vault sells currency1 -> sellingCurrency1 = true; fillable on zeroForOne.
        // For exact 1:1 rate use vault sqrtP = SQRT_PRICE_1_1.
        vm.prank(vaultEOA);
        hook.createReserveOffer(poolKey, currency1, sellAmount, SQRT_PRICE_1_1, 0);

        // Pre-balances of test contract (acts as swapper through router).
        uint256 c0Before = MockERC20(Currency.unwrap(currency0)).balanceOf(address(this));
        uint256 c1Before = MockERC20(Currency.unwrap(currency1)).balanceOf(address(this));

        uint256 amountIn = 1 ether;
        swap(poolKey, true, -int256(amountIn), ZERO_BYTES);

        uint256 c0After = MockERC20(Currency.unwrap(currency0)).balanceOf(address(this));
        uint256 c1After = MockERC20(Currency.unwrap(currency1)).balanceOf(address(this));

        // ---- Sign-convention check: swapper paid token0, received token1.
        assertEq(c0Before - c0After, amountIn, "swapper paid exactly amountIn token0");
        // Swapper out > reserve fill alone, since AMM also delivered ~0.5e18 minus LP fee minus hook fee.
        assertGt(c1After - c1Before, sellAmount, "swapper got reserve fill PLUS AMM output");
        // And < amountIn (because AMM has slippage + fees on the 0.5e18 remainder).
        assertLt(c1After - c1Before, amountIn, "AMM remainder loses fees/slippage");

        // ---- Hook-side accounting ----
        // Offer fully consumed.
        DynamicFeeHookV2.ReserveOffer memory o = hook.getOffer(poolKey);
        assertFalse(o.active, "offer cleared after exhaustion");
        assertEq(o.sellRemaining, 0, "sellRemaining drained");

        // Vault escrow drained, proceeds in token0 = 0.5e18 (1:1 rate, full fill of 0.5e18).
        assertEq(hook.escrowedReserve(vaultEOA, currency1), 0, "escrow drained");
        assertEq(hook.proceedsOwed(vaultEOA, currency0), uint256(sellAmount), "proceeds match takeCap at 1:1");

        // Counters.
        assertEq(hook.totalReserveFills(), 1);
        assertEq(hook.totalReserveSold(), uint256(sellAmount));

        // ---- Vault can claim proceeds ----
        vm.prank(vaultEOA);
        uint256 claimed = hook.claimReserveProceeds(currency0);
        assertEq(claimed, uint256(sellAmount), "claim returns proceeds");
        assertEq(hook.proceedsOwed(vaultEOA, currency0), 0, "proceeds zeroed after claim");
        assertEq(MockERC20(Currency.unwrap(currency0)).balanceOf(vaultEOA), uint256(sellAmount));
    }

    /// @dev Reserve has 2e18 token1, swapper sends 1 ether token0.
    ///      maxInput < takeCap -> partial-fill branch. Both AMM fee path and
    ///      reserve fill must coexist, swapper still nets profit.
    function test_reserveFill_partialFillBranch_maxInputUnderCap() public {
        uint128 sellAmount = 2e18;
        vm.prank(vaultEOA);
        hook.createReserveOffer(poolKey, currency1, sellAmount, SQRT_PRICE_1_1, 0);

        uint256 c0Before = MockERC20(Currency.unwrap(currency0)).balanceOf(address(this));
        uint256 c1Before = MockERC20(Currency.unwrap(currency1)).balanceOf(address(this));

        uint256 amountIn = 1 ether;
        swap(poolKey, true, -int256(amountIn), ZERO_BYTES);

        uint256 c0Spent = c0Before - MockERC20(Currency.unwrap(currency0)).balanceOf(address(this));
        uint256 c1Got = MockERC20(Currency.unwrap(currency1)).balanceOf(address(this)) - c1Before;

        // Swapper paid full amountIn (entire input absorbed by reserve at 1:1).
        assertEq(c0Spent, amountIn, "all input consumed");
        // At 1:1 with full reserve absorption, swapper received ~ amountIn token1 (minus 0 AMM fee since AMM did 0 work).
        // Reserve gives gross 1:1 — there is no LP fee on the reserve leg, but the
        // hook charges its afterSwap fee against the unspecified leg. With the
        // full fill the AMM leg = 0 so unspec = 0 and afterSwap fee = 0.
        assertEq(c1Got, amountIn, "exact 1:1 reserve fill, no AMM fee leg");

        // Offer accounting: sellRemaining decreased by amountIn.
        DynamicFeeHookV2.ReserveOffer memory o = hook.getOffer(poolKey);
        assertTrue(o.active, "offer still active, partial fill");
        assertEq(o.sellRemaining, uint128(sellAmount) - uint128(amountIn));
        assertEq(hook.escrowedReserve(vaultEOA, currency1), uint256(sellAmount) - amountIn);
        assertEq(hook.proceedsOwed(vaultEOA, currency0), amountIn);
        assertEq(hook.totalReserveFills(), 1);
        assertEq(hook.totalReserveSold(), amountIn);
    }

    /// @dev Wrong direction: vault sells currency1 but swap is oneForZero.
    ///      Reserve must NOT fire, swap routes 100% through AMM.
    function test_reserveFill_directionMismatch_skipped() public {
        vm.prank(vaultEOA);
        hook.createReserveOffer(poolKey, currency1, 1e18, SQRT_PRICE_1_1, 0);

        uint256 fillsBefore = hook.totalReserveFills();
        swap(poolKey, false, -int256(0.1 ether), ZERO_BYTES); // oneForZero
        assertEq(hook.totalReserveFills(), fillsBefore, "no reserve fill on opposite direction");

        DynamicFeeHookV2.ReserveOffer memory o = hook.getOffer(poolKey);
        assertEq(o.sellRemaining, 1e18, "offer untouched");
        assertTrue(o.active);
    }

    /// @dev Cancel returns full escrowed inventory to vault.
    function test_cancelOffer_returnsEscrow() public {
        vm.prank(vaultEOA);
        hook.createReserveOffer(poolKey, currency1, 1e18, SQRT_PRICE_1_1, 0);

        uint256 vaultBalBefore = MockERC20(Currency.unwrap(currency1)).balanceOf(vaultEOA);
        vm.prank(vaultEOA);
        uint128 returned = hook.cancelReserveOffer(poolKey);

        assertEq(returned, 1e18);
        assertEq(MockERC20(Currency.unwrap(currency1)).balanceOf(vaultEOA) - vaultBalBefore, 1e18);
        assertEq(hook.escrowedReserve(vaultEOA, currency1), 0);

        DynamicFeeHookV2.ReserveOffer memory o = hook.getOffer(poolKey);
        assertFalse(o.active);
    }
}
