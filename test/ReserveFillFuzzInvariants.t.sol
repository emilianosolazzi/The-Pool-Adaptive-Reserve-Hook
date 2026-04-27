// SPDX-License-Identifier: MIT
pragma solidity >=0.8.24 <0.9.0;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {CommonBase} from "forge-std/Base.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {DynamicFeeHookV2} from "../src/DynamicFeeHookV2.sol";
import {FeeDistributor} from "../src/FeeDistributor.sol";
import {HookMiner} from "./utils/HookMiner.sol";

/// @notice Stateful handler driving random sequences of post / cancel / swap /
///         claim against a single pool + single registered vault. Tracks
///         per-currency cumulative ghost variables so the invariant suite can
///         assert exact conservation across thousands of randomly-ordered
///         actions, including paths that the deterministic suite cannot
///         enumerate (rapid post-cancel churn, partial fills interleaved with
///         opposite-direction AMM-only swaps, etc.).
contract ReserveFillHandler is CommonBase, StdUtils {
    using PoolIdLibrary for PoolKey;

    DynamicFeeHookV2 public immutable hook;
    PoolKey public poolKey;
    PoolSwapTest public immutable swapRouter;
    Currency public immutable currency0;
    Currency public immutable currency1;
    address public immutable vault;

    bool public offerActive;
    bool public sellingC1;

    mapping(Currency => uint256) public ghostEscrowedIn;
    mapping(Currency => uint256) public ghostReturned;
    mapping(Currency => uint256) public ghostSold;
    mapping(Currency => uint256) public ghostProceedsAccrued;
    mapping(Currency => uint256) public ghostClaimed;

    uint256 public callsPostOffer;
    uint256 public callsCancel;
    uint256 public callsSwap;
    uint256 public callsClaim;
    uint256 public swapsThatFilled;

    // Mirrors Deployers' SQRT_PRICE_1_1.
    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    constructor(
        DynamicFeeHookV2 _hook,
        PoolKey memory _key,
        PoolSwapTest _swap,
        address _vault
    ) {
        hook = _hook;
        poolKey = _key;
        swapRouter = _swap;
        currency0 = _key.currency0;
        currency1 = _key.currency1;
        vault = _vault;
    }

    function _syncOffer() internal {
        if (!offerActive) return;
        DynamicFeeHookV2.ReserveOffer memory o = hook.getOffer(poolKey);
        if (!o.active) offerActive = false;
    }

    // -----------------------------------------------------------------
    // Actions exposed to the fuzzer
    // -----------------------------------------------------------------

    function postOffer(bool sellC1_, uint128 amount) external {
        callsPostOffer++;
        if (offerActive) return;
        amount = uint128(bound(uint256(amount), 1e15, 2 ether));
        Currency sellC = sellC1_ ? currency1 : currency0;
        vm.prank(vault);
        try hook.createReserveOffer(poolKey, sellC, amount, SQRT_PRICE_1_1, 0) {
            ghostEscrowedIn[sellC] += amount;
            offerActive = true;
            sellingC1 = sellC1_;
        } catch {}
    }

    function cancelOffer() external {
        callsCancel++;
        if (!offerActive) return;
        Currency sellC = sellingC1 ? currency1 : currency0;
        vm.prank(vault);
        try hook.cancelReserveOffer(poolKey) returns (uint128 returned) {
            ghostReturned[sellC] += returned;
            offerActive = false;
        } catch {}
    }

    function swap(bool zeroForOne, uint256 amountIn) external {
        callsSwap++;
        amountIn = bound(amountIn, 1e14, 0.5 ether);

        // A reserve fill is possible iff offer is active AND swap direction
        // matches the offer side (sellingC1 ↔ zeroForOne).
        bool relevant = offerActive && (sellingC1 == zeroForOne);
        Currency sellC = sellingC1 ? currency1 : currency0;
        Currency buyC = sellingC1 ? currency0 : currency1;

        uint128 remBefore = relevant ? hook.getOffer(poolKey).sellRemaining : 0;
        uint256 procBefore = relevant ? hook.proceedsOwed(vault, buyC) : 0;

        SwapParams memory p = SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -int256(amountIn),
            sqrtPriceLimitX96: zeroForOne
                ? TickMath.MIN_SQRT_PRICE + 1
                : TickMath.MAX_SQRT_PRICE - 1
        });
        PoolSwapTest.TestSettings memory s = PoolSwapTest.TestSettings({
            takeClaims: false,
            settleUsingBurn: false
        });

        try swapRouter.swap(poolKey, p, s, "") {
            if (relevant) {
                uint128 remAfter = hook.getOffer(poolKey).sellRemaining;
                if (remBefore > remAfter) {
                    uint256 sold = uint256(remBefore - remAfter);
                    ghostSold[sellC] += sold;
                    uint256 procAfter = hook.proceedsOwed(vault, buyC);
                    ghostProceedsAccrued[buyC] += procAfter - procBefore;
                    swapsThatFilled++;
                }
            }
            _syncOffer();
        } catch {}
    }

    function claimC0() external {
        callsClaim++;
        vm.prank(vault);
        try hook.claimReserveProceeds(currency0) returns (uint256 amount) {
            ghostClaimed[currency0] += amount;
        } catch {}
    }

    function claimC1() external {
        callsClaim++;
        vm.prank(vault);
        try hook.claimReserveProceeds(currency1) returns (uint256 amount) {
            ghostClaimed[currency1] += amount;
        } catch {}
    }
}

/// @notice Handler-driven stateful fuzz invariants for `_tryFillReserve`.
///         Asserts the conservation properties spelled out in the V2 hook's
///         design notes hold under thousands of random action sequences:
///
///           1. Hook ERC20 balance ≥ live escrow + outstanding proceeds.
///           2. Per-currency escrow conservation:
///                ghostEscrowedIn[c] = ghostReturned[c] + ghostSold[c]
///                                   + escrow[c]
///           3. Per-currency proceeds conservation:
///                ghostProceedsAccrued[c] = ghostClaimed[c] + proceeds[c]
///           4. Cumulative reserve sold across both currencies matches the
///              hook's own `totalReserveSold` counter.
///           5. Offer-active flag implies on-chain offer is active with
///              non-zero sellRemaining.
contract ReserveFillFuzzInvariantsTest is StdInvariant, Test, Deployers {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;

    DynamicFeeHookV2 public hook;
    FeeDistributor public distributor;
    PoolKey public fuzzPoolKey;
    address public treasury = makeAddr("treasury");
    address public vault = makeAddr("vault");
    ReserveFillHandler public handler;

    function setUp() public {
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

        (fuzzPoolKey,) = initPool(currency0, currency1, IHooks(address(hook)), 100, SQRT_PRICE_1_1);
        distributor.setPoolKey(fuzzPoolKey);

        // Deep liquidity so AMM-tail swaps don't run into price limits.
        modifyLiquidityRouter.modifyLiquidity(
            fuzzPoolKey,
            ModifyLiquidityParams({tickLower: -3000, tickUpper: 3000, liquidityDelta: 10_000e18, salt: 0}),
            ZERO_BYTES
        );

        hook.registerVault(fuzzPoolKey, vault);

        // Fund the vault generously and pre-approve the hook for both sides.
        MockERC20(Currency.unwrap(currency0)).mint(vault, 1_000 ether);
        MockERC20(Currency.unwrap(currency1)).mint(vault, 1_000 ether);
        vm.startPrank(vault);
        MockERC20(Currency.unwrap(currency0)).approve(address(hook), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(hook), type(uint256).max);
        vm.stopPrank();

        // Deploy the handler and equip it as the swapper.
        handler = new ReserveFillHandler(hook, fuzzPoolKey, swapRouter, vault);
        MockERC20(Currency.unwrap(currency0)).mint(address(handler), 1_000 ether);
        MockERC20(Currency.unwrap(currency1)).mint(address(handler), 1_000 ether);
        vm.startPrank(address(handler));
        MockERC20(Currency.unwrap(currency0)).approve(address(swapRouter), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();

        // Restrict invariant fuzzing to handler entrypoints; auto-generated
        // calls into Deployers state would corrupt setUp invariants.
        targetContract(address(handler));
        bytes4[] memory sels = new bytes4[](5);
        sels[0] = ReserveFillHandler.postOffer.selector;
        sels[1] = ReserveFillHandler.cancelOffer.selector;
        sels[2] = ReserveFillHandler.swap.selector;
        sels[3] = ReserveFillHandler.claimC0.selector;
        sels[4] = ReserveFillHandler.claimC1.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: sels}));
    }

    // -----------------------------------------------------------------
    // Invariants
    // -----------------------------------------------------------------

    /// 1. Hook ERC20 balance dominates accounting per currency.
    function invariant_hookBalanceDominates() public view {
        uint256 esc0 = hook.escrowedReserve(vault, currency0);
        uint256 esc1 = hook.escrowedReserve(vault, currency1);
        uint256 prc0 = hook.proceedsOwed(vault, currency0);
        uint256 prc1 = hook.proceedsOwed(vault, currency1);
        uint256 bal0 = MockERC20(Currency.unwrap(currency0)).balanceOf(address(hook));
        uint256 bal1 = MockERC20(Currency.unwrap(currency1)).balanceOf(address(hook));

        assertGe(bal0, esc0 + prc0, "hook c0 balance < escrow0 + proceeds0");
        assertGe(bal1, esc1 + prc1, "hook c1 balance < escrow1 + proceeds1");
    }

    /// 2. Per-currency escrow conservation.
    function invariant_escrowConservation() public view {
        uint256 esc0 = hook.escrowedReserve(vault, currency0);
        uint256 esc1 = hook.escrowedReserve(vault, currency1);

        assertEq(
            handler.ghostEscrowedIn(currency0),
            handler.ghostReturned(currency0) + handler.ghostSold(currency0) + esc0,
            "escrow conservation c0"
        );
        assertEq(
            handler.ghostEscrowedIn(currency1),
            handler.ghostReturned(currency1) + handler.ghostSold(currency1) + esc1,
            "escrow conservation c1"
        );
    }

    /// 3. Per-currency proceeds conservation.
    function invariant_proceedsConservation() public view {
        uint256 prc0 = hook.proceedsOwed(vault, currency0);
        uint256 prc1 = hook.proceedsOwed(vault, currency1);

        assertEq(
            handler.ghostProceedsAccrued(currency0),
            handler.ghostClaimed(currency0) + prc0,
            "proceeds conservation c0"
        );
        assertEq(
            handler.ghostProceedsAccrued(currency1),
            handler.ghostClaimed(currency1) + prc1,
            "proceeds conservation c1"
        );
    }

    /// 4. Hook's own totalReserveSold counter must match the per-currency sum.
    function invariant_totalReserveSoldMatchesGhost() public view {
        assertEq(
            hook.totalReserveSold(),
            handler.ghostSold(currency0) + handler.ghostSold(currency1),
            "totalReserveSold == sum of ghost sold per currency"
        );
    }

    /// 5. If handler thinks an offer is live, the on-chain offer must agree
    ///    and have positive sellRemaining.
    function invariant_offerActiveImpliesEscrowed() public view {
        if (!handler.offerActive()) return;
        DynamicFeeHookV2.ReserveOffer memory o = hook.getOffer(fuzzPoolKey);
        assertTrue(o.active, "offer.active disagrees with handler");
        assertGt(o.sellRemaining, 0, "offerActive but sellRemaining == 0");
    }
}
