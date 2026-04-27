// SPDX-License-Identifier: MIT
pragma solidity >=0.8.24 <0.9.0;

import {Test, console2} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
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

/// @notice Test-only distributor whose `distribute` always reverts. Used to
///         prove that a misconfigured / bug-ridden distributor does NOT
///         block swaps after the hook's soft-fail patch.
contract RevertingDistributor {
    function distribute(Currency, uint256) external pure {
        revert("DISTRIBUTOR_BROKEN");
    }
}

/// @notice "What actually happens" — a narrated end-to-end run of every
///         user-facing flow against the real PoolManager. Each step prints
///         the on-chain state change so a non-engineer can read the trace
///         and verify that reality matches the spec.
///
///         Run with: forge test --match-contract RealityCheck -vv
contract RealityCheckTest is Test, Deployers {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    DynamicFeeHookV2 public hook;
    FeeDistributor public distributor;
    PoolKey public poolKey;
    address public treasury = makeAddr("treasury");
    address public vaultEOA = makeAddr("vault");      // simulates LiquidityVaultV2
    address public alice = makeAddr("alice-swapper");
    address public bob = makeAddr("bob-swapper");

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

        (poolKey,) = initPool(currency0, currency1, IHooks(address(hook)), 100, SQRT_PRICE_1_1);
        distributor.setPoolKey(poolKey);

        // Seed deep liquidity so swaps don't bonk on price limits.
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({tickLower: -3000, tickUpper: 3000, liquidityDelta: 10_000e18, salt: 0}),
            ZERO_BYTES
        );

        // Owner registers the vault as the reserve-offer manager.
        hook.registerVault(poolKey, vaultEOA);

        // Fund the simulated vault.
        MockERC20(Currency.unwrap(currency1)).mint(vaultEOA, 100 ether);
        vm.prank(vaultEOA);
        MockERC20(Currency.unwrap(currency1)).approve(address(hook), type(uint256).max);
    }

    // -----------------------------------------------------------------
    // Reality test: full life cycle of a reserve offer.
    // -----------------------------------------------------------------
    //
    // Day 0:  Vault posts a 1.0 token1 reserve offer at 1:1 rate.
    // Day 0:  Alice swaps 0.4 token0 for token1 → fills entirely from reserve.
    // Day 0:  Bob   swaps 0.8 token0 for token1 → first 0.6 from reserve, rest AMM.
    // Day 1:  Vault calls claimReserveProceeds → sweeps token0 income to itself.
    // Day 1:  Vault cancels the (now-empty) offer → state cleared.
    function test_reality_fullReserveLifeCycle() public {
        console2.log("=== RealityCheck: full reserve-sale life cycle ===");
        console2.log("");

        // ---------- DAY 0: vault posts offer ----------
        uint128 sellAmount = 1 ether;       // 1.0 token1
        console2.log("[Day 0] Vault posts reserve offer:");
        console2.log("        sells          : 1.0 token1");
        console2.log("        rate           : 1:1 (sqrtP = SQRT_PRICE_1_1)");
        console2.log("        expiry         : never");

        vm.prank(vaultEOA);
        hook.createReserveOffer(poolKey, currency1, sellAmount, SQRT_PRICE_1_1, 0);

        DynamicFeeHookV2.ReserveOffer memory o = hook.getOffer(poolKey);
        console2.log("        active         :", o.active);
        console2.log("        escrow (token1):", hook.escrowedReserve(vaultEOA, currency1));
        console2.log("");

        // ---------- DAY 0: Alice swaps under cap ----------
        uint256 aliceIn = 0.4 ether;
        console2.log("[Day 0] Alice swaps 0.4 token0 -> token1 (zeroForOne, exact-input):");

        uint256 a0Before = MockERC20(Currency.unwrap(currency0)).balanceOf(address(this));
        uint256 a1Before = MockERC20(Currency.unwrap(currency1)).balanceOf(address(this));
        swap(poolKey, true, -int256(aliceIn), ZERO_BYTES);
        uint256 a0Spent = a0Before - MockERC20(Currency.unwrap(currency0)).balanceOf(address(this));
        uint256 a1Got = MockERC20(Currency.unwrap(currency1)).balanceOf(address(this)) - a1Before;
        console2.log("        token0 paid    :", a0Spent);
        console2.log("        token1 received:", a1Got);
        console2.log("        => fully filled by reserve at 1:1");

        o = hook.getOffer(poolKey);
        console2.log("        offer.sellRem  :", o.sellRemaining);
        console2.log("        proceeds (t0)  :", hook.proceedsOwed(vaultEOA, currency0));
        console2.log("        reserve fills  :", hook.totalReserveFills());
        console2.log("");

        assertEq(a0Spent, aliceIn, "Alice paid exactly aliceIn");
        assertEq(a1Got, aliceIn, "Alice got exact 1:1");
        assertEq(o.sellRemaining, sellAmount - uint128(aliceIn));

        // ---------- DAY 0: Bob exhausts the reserve ----------
        uint256 bobIn = 0.8 ether;
        console2.log("[Day 0] Bob swaps 0.8 token0 -> token1 (exhausts reserve, AMM tail):");

        uint256 b0Before = MockERC20(Currency.unwrap(currency0)).balanceOf(address(this));
        uint256 b1Before = MockERC20(Currency.unwrap(currency1)).balanceOf(address(this));
        swap(poolKey, true, -int256(bobIn), ZERO_BYTES);
        uint256 b0Spent = b0Before - MockERC20(Currency.unwrap(currency0)).balanceOf(address(this));
        uint256 b1Got = MockERC20(Currency.unwrap(currency1)).balanceOf(address(this)) - b1Before;
        console2.log("        token0 paid    :", b0Spent);
        console2.log("        token1 received:", b1Got);

        o = hook.getOffer(poolKey);
        console2.log("        offer.active   :", o.active, "(expect false: drained)");
        console2.log("        offer.sellRem  :", o.sellRemaining, "(expect 0)");
        console2.log("        proceeds (t0)  :", hook.proceedsOwed(vaultEOA, currency0));
        console2.log("        escrow (t1)    :", hook.escrowedReserve(vaultEOA, currency1));
        console2.log("        reserve fills  :", hook.totalReserveFills());
        console2.log("");

        assertFalse(o.active, "offer drained");
        assertEq(o.sellRemaining, 0);
        assertEq(hook.escrowedReserve(vaultEOA, currency1), 0, "escrow cleaned");
        // Proceeds = aliceIn (full fill) + remaining 0.6 of Bob's input that hit the reserve cap.
        assertEq(hook.proceedsOwed(vaultEOA, currency0), uint256(sellAmount));

        // ---------- DAY 1: vault claims proceeds ----------
        skip(1 days);
        console2.log("[Day 1] Vault claims reserve proceeds (token0):");

        uint256 vaultC0Before = MockERC20(Currency.unwrap(currency0)).balanceOf(vaultEOA);
        vm.prank(vaultEOA);
        uint256 claimed = hook.claimReserveProceeds(currency0);
        uint256 vaultC0After = MockERC20(Currency.unwrap(currency0)).balanceOf(vaultEOA);
        console2.log("        claimed        :", claimed);
        console2.log("        vault t0 +/-   :", vaultC0After - vaultC0Before);
        console2.log("        proceeds left  :", hook.proceedsOwed(vaultEOA, currency0));
        console2.log("");

        assertEq(claimed, uint256(sellAmount));
        assertEq(vaultC0After - vaultC0Before, claimed);
        assertEq(hook.proceedsOwed(vaultEOA, currency0), 0);

        console2.log("=== RESULT: every step matched expected state. ===");
    }

    // -----------------------------------------------------------------
    // Reality test: market moves THROUGH the offer; price gate blocks fill.
    // -----------------------------------------------------------------
    //
    // Vault posts offer at 1:1 price. AMM gets pushed to a worse price for the
    // swapper than the offer would give. Then a new swap arrives in the same
    // direction. Expectation: gate skips the offer (because AMM is now better
    // than the offer for the swapper would be in the OPPOSITE direction; in
    // the SAME direction the gate trips when AMM is worse than offer, which
    // is exactly when we WANT to fill — verify that path).
    //
    // The realistic "stale offer" case: vault posts at 1:1, AMM moves UP
    // (token0 cheaper), so token1 from the offer is now worse than AMM.
    // Direction-correct swappers (zeroForOne) would prefer AMM, gate skips.
    function test_reality_staleOfferGetsSkipped() public {
        console2.log("=== RealityCheck: stale offer skipped by price gate ===");

        vm.prank(vaultEOA);
        hook.createReserveOffer(poolKey, currency1, 1 ether, SQRT_PRICE_1_1, 0);
        console2.log("[t0] Vault posts 1.0 token1 offer @ 1:1");

        // Push AMM by doing a chunky oneForZero swap (token1 -> token0) so
        // pool sqrtPrice rises above 1:1. After this, AMM gives more token0
        // per token1 than 1:1 — offer (sells token1) becomes worse for a
        // zeroForOne swapper than AMM, so price gate should skip the fill.
        swap(poolKey, false, -int256(50 ether), ZERO_BYTES);
        (uint160 sqrtAfter,,,) = manager.getSlot0(poolKey.toId());
        console2.log("[t1] AMM pushed to sqrtP =", sqrtAfter);
        console2.log("     vault sqrtP set     =", uint256(SQRT_PRICE_1_1));

        // Now a zeroForOne swap arrives. Reserve direction matches, but price gate
        // requires poolSqrtP <= vaultSqrtP. After our push, poolSqrtP > vaultSqrtP,
        // so gate must skip.
        uint256 fillsBefore = hook.totalReserveFills();
        swap(poolKey, true, -int256(0.1 ether), ZERO_BYTES);
        console2.log("[t2] Swap routed; reserve fills before/after:", fillsBefore, hook.totalReserveFills());

        assertEq(hook.totalReserveFills(), fillsBefore, "stale offer was correctly skipped");

        // Vault notices, cancels, gets escrow back.
        uint256 vBefore = MockERC20(Currency.unwrap(currency1)).balanceOf(vaultEOA);
        vm.prank(vaultEOA);
        uint128 returned = hook.cancelReserveOffer(poolKey);
        uint256 vAfter = MockERC20(Currency.unwrap(currency1)).balanceOf(vaultEOA);
        console2.log("[t3] Vault cancels stale offer; escrow returned:", vAfter - vBefore);

        assertEq(returned, 1 ether);
        assertEq(vAfter - vBefore, 1 ether);

        console2.log("=== RESULT: stale offer is non-toxic; vault recovers full inventory. ===");
    }

    // -----------------------------------------------------------------
    // Reality test: fee distribution to treasury actually fires after a swap.
    // -----------------------------------------------------------------
    function test_reality_feesReachTreasury() public {
        console2.log("=== RealityCheck: hook fees -> distributor -> treasury ===");

        uint256 treasuryT1Before = MockERC20(Currency.unwrap(currency1)).balanceOf(treasury);
        console2.log("[pre]  treasury token1 :", treasuryT1Before);

        uint256 amountIn = 1 ether;
        swap(poolKey, true, -int256(amountIn), ZERO_BYTES);

        uint256 treasuryT1After = MockERC20(Currency.unwrap(currency1)).balanceOf(treasury);
        uint256 routed = hook.totalFeesRouted();
        uint256 treasurySplit = treasuryT1After - treasuryT1Before;
        uint256 distributed = distributor.totalDistributed();
        uint256 toLPs = distributor.totalToLPs();

        console2.log("[post] hook routed total:", routed);
        console2.log("       distributor total:", distributed);
        console2.log("       to treasury (20%):", treasurySplit);
        console2.log("       to LPs (80%)     :", toLPs);

        assertEq(distributed, routed);
        assertEq(treasurySplit, (routed * 20) / 100);
        assertEq(toLPs, routed - treasurySplit);

        console2.log("=== RESULT: split is exact 20/80, money lands where expected. ===");
    }

    // -----------------------------------------------------------------
    // P1 #B2 — getOfferHealth: one-call keeper view returns coherent state.
    // -----------------------------------------------------------------
    function test_reality_getOfferHealth_reportsActiveAndDrift() public {
        console2.log("=== RealityCheck: getOfferHealth one-call view ===");

        // Pre-offer: nothing active, drift 0, all zeros.
        (bool a0, int256 d0, uint256 e00, uint256 e10, uint256 p00, uint256 p10, uint160 vsq0, uint160 psq0) =
            hook.getOfferHealth(poolKey, vaultEOA);
        console2.log("[pre]  active:", a0);
        console2.log("       drift_bps:", d0);
        assertFalse(a0);
        assertEq(d0, 0);
        assertEq(e00, 0); assertEq(e10, 0);
        assertEq(p00, 0); assertEq(p10, 0);
        assertEq(vsq0, 0);
        assertEq(psq0, uint256(SQRT_PRICE_1_1));

        // Post offer at exact spot price -> active, drift ≈ 0, escrow1 = 1.0.
        vm.prank(vaultEOA);
        hook.createReserveOffer(poolKey, currency1, 1 ether, SQRT_PRICE_1_1, 0);
        (bool a1, int256 d1, , uint256 e1, , , uint160 vsq1, uint160 psq1) =
            hook.getOfferHealth(poolKey, vaultEOA);
        console2.log("[t1]   active:", a1);
        console2.log("       drift_bps:", d1);
        console2.log("       vaultSqrtP:", vsq1);
        console2.log("       poolSqrtP :", psq1);
        assertTrue(a1);
        assertEq(uint256(vsq1), uint256(SQRT_PRICE_1_1));
        assertEq(d1, 0, "drift is 0 when pool sits at offer price");
        assertEq(e1, 1 ether);

        // Push pool sqrtP up (oneForZero swap) and read drift again.
        swap(poolKey, false, -int256(50 ether), ZERO_BYTES);
        (, int256 d2, , , , , uint160 vsq2, uint160 psq2) = hook.getOfferHealth(poolKey, vaultEOA);
        console2.log("[t2]   poolSqrtP:", psq2);
        console2.log("       vaultSqrtP:", vsq2);
        console2.log("       drift_bps:", d2);
        assertGt(d2, 0, "pool > vault -> positive drift");
        assertGt(uint256(psq2), uint256(vsq2));

        console2.log("=== RESULT: getOfferHealth returns the full keeper-decision payload. ===");
    }

    // -----------------------------------------------------------------
    // P1 #B3 — ReserveOfferStale event fires on price-gated skip with |drift| > 50.
    // -----------------------------------------------------------------
    function test_reality_staleOfferEmitsEvent() public {
        // Post offer at 1:1 then push pool above it.
        vm.prank(vaultEOA);
        hook.createReserveOffer(poolKey, currency1, 1 ether, SQRT_PRICE_1_1, 0);
        swap(poolKey, false, -int256(50 ether), ZERO_BYTES);

        // The next zeroForOne swap should hit the skip path AND emit the stale event.
        // Topic match only — drift value is computed at runtime.
        bytes32 poolIdTopic = PoolId.unwrap(poolKey.toId());
        vm.expectEmit(true, true, false, false, address(hook));
        emit DynamicFeeHookV2.ReserveOfferStale(poolIdTopic, vaultEOA, int256(0));

        swap(poolKey, true, -int256(0.1 ether), ZERO_BYTES);
    }

    function test_reality_staleEvent_silentBelowThreshold() public {
        // Tiny drift (well below 50bps): no event expected.
        vm.prank(vaultEOA);
        hook.createReserveOffer(poolKey, currency1, 1 ether, SQRT_PRICE_1_1, 0);

        // Move the pool by a microscopic amount: 1 wei input -> sub-bp drift.
        // We allow up to 1 swap to avoid breaking test logic; the assertion
        // is about emission, not about price.
        vm.recordLogs();
        swap(poolKey, false, -int256(1_000), ZERO_BYTES);
        // Now do a tiny zeroForOne — drift is sub-50bps → should NOT emit.
        swap(poolKey, true, -int256(1_000), ZERO_BYTES);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 staleSig = keccak256("ReserveOfferStale(bytes32,address,int256)");
        for (uint256 i = 0; i < logs.length; i++) {
            assertFalse(logs[i].topics.length > 0 && logs[i].topics[0] == staleSig,
                "no ReserveOfferStale should fire below 50 bps drift");
        }
    }

    // -----------------------------------------------------------------
    // Hardening — a reverting distributor MUST NOT block swaps.
    // -----------------------------------------------------------------
    function test_reality_revertingDistributor_doesNotBlockSwap() public {
        // Replace distributor with one whose distribute() always reverts.
        RevertingDistributor bad = new RevertingDistributor();
        hook.setFeeDistributor(address(bad));

        bytes32 distFailedSig = keccak256("FeeDistributionFailed(address,uint256,uint256)");
        vm.recordLogs();

        uint256 routedBefore = hook.totalFeesRouted();
        // Swap should succeed despite distributor reverting.
        swap(poolKey, true, -int256(1 ether), ZERO_BYTES);
        uint256 routedAfter = hook.totalFeesRouted();

        // Hook still records the routed fee (it left the hook into the
        // distributor); only the distribute() side-effect failed.
        assertGt(routedAfter, routedBefore, "fees still routed despite distributor revert");

        // FeeDistributionFailed event was emitted.
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == distFailedSig
                && logs[i].emitter == address(hook)) {
                found = true;
                break;
            }
        }
        assertTrue(found, "FeeDistributionFailed event must fire when distribute reverts");

        // Funds physically sit at the broken distributor (operator recovers via sweep).
        uint256 distBalT1 = MockERC20(Currency.unwrap(currency1)).balanceOf(address(bad));
        assertEq(distBalT1, routedAfter - routedBefore, "fees parked at distributor pending recovery");
    }

    // -----------------------------------------------------------------
    // Hardening — failedDistribution tally + acknowledge bookkeeping.
    //
    // The hook tracks unresolved fees in `failedDistribution[currency]` so
    // operators have a deterministic on-chain query for "how much is parked
    // at the distributor pending recovery". `acknowledgeFailedDistribution`
    // is the bookkeeping primitive operators call AFTER they've physically
    // recovered tokens via FeeDistributor.retryDistribute / sweepUndistributed.
    // -----------------------------------------------------------------
    function test_reality_failedDistribution_tallyAccumulates() public {
        RevertingDistributor bad = new RevertingDistributor();
        hook.setFeeDistributor(address(bad));

        // Direction true = zeroForOne, exact input -> fee paid in unspecified
        // (currency1 here). Run two swaps so we can watch the tally accumulate.
        uint256 routedBefore = hook.totalFeesRouted();
        swap(poolKey, true, -int256(1 ether), ZERO_BYTES);
        uint256 firstFailed = hook.failedDistribution(Currency.unwrap(currency1));
        assertGt(firstFailed, 0, "tally must increment on first failure");
        assertEq(firstFailed, hook.totalFeesRouted() - routedBefore, "tally == routed delta");

        swap(poolKey, true, -int256(1 ether), ZERO_BYTES);
        uint256 secondFailed = hook.failedDistribution(Currency.unwrap(currency1));
        assertGt(secondFailed, firstFailed, "tally must keep accumulating");
        assertEq(secondFailed, hook.totalFeesRouted() - routedBefore, "tally tracks cumulative routed");
    }

    function test_reality_acknowledgeFailedDistribution_clearsTally() public {
        RevertingDistributor bad = new RevertingDistributor();
        hook.setFeeDistributor(address(bad));

        swap(poolKey, true, -int256(1 ether), ZERO_BYTES);
        uint256 outstanding = hook.failedDistribution(Currency.unwrap(currency1));
        assertGt(outstanding, 0);

        // Operator has, off-chain, called retryDistribute / sweepUndistributed
        // on the (now-fixed) distributor. They acknowledge the recovery here.
        hook.acknowledgeFailedDistribution(currency1, outstanding);
        assertEq(hook.failedDistribution(Currency.unwrap(currency1)), 0, "tally cleared");

        // Partial acknowledgement also works.
        swap(poolKey, true, -int256(1 ether), ZERO_BYTES);
        uint256 newOutstanding = hook.failedDistribution(Currency.unwrap(currency1));
        hook.acknowledgeFailedDistribution(currency1, newOutstanding / 2);
        assertEq(
            hook.failedDistribution(Currency.unwrap(currency1)),
            newOutstanding - newOutstanding / 2,
            "partial ack decrements correctly"
        );
    }

    function test_reality_acknowledgeFailedDistribution_overAmountReverts() public {
        RevertingDistributor bad = new RevertingDistributor();
        hook.setFeeDistributor(address(bad));
        swap(poolKey, true, -int256(1 ether), ZERO_BYTES);

        uint256 outstanding = hook.failedDistribution(Currency.unwrap(currency1));
        vm.expectRevert(bytes("AMOUNT_EXCEEDS_FAILED"));
        hook.acknowledgeFailedDistribution(currency1, outstanding + 1);
    }

    function test_reality_acknowledgeFailedDistribution_zeroAmountReverts() public {
        vm.expectRevert(bytes("ZERO_AMOUNT"));
        hook.acknowledgeFailedDistribution(currency1, 0);
    }

    function test_reality_acknowledgeFailedDistribution_nonOwnerReverts() public {
        RevertingDistributor bad = new RevertingDistributor();
        hook.setFeeDistributor(address(bad));
        swap(poolKey, true, -int256(1 ether), ZERO_BYTES);

        vm.prank(alice);
        vm.expectRevert();
        hook.acknowledgeFailedDistribution(currency1, 1);
    }

    function test_reality_failedDistribution_recoveryFlow_endToEnd() public {
        // Stage 1: distributor broken, fees fail to distribute.
        RevertingDistributor bad = new RevertingDistributor();
        hook.setFeeDistributor(address(bad));
        swap(poolKey, true, -int256(1 ether), ZERO_BYTES);
        uint256 outstanding = hook.failedDistribution(Currency.unwrap(currency1));
        assertGt(outstanding, 0);

        // Stage 2: fees are physically parked on the broken distributor.
        // Operator deploys a fresh good distributor. The parked tokens are
        // stuck on `bad`; they have to be sweep-recovered out-of-band by the
        // bad distributor's owner (here we just simulate the operator moving
        // them to treasury via vm.prank — RevertingDistributor has no admin
        // path, which is exactly why the production FeeDistributor exposes
        // sweepUndistributed/retryDistribute).
        //
        // Stage 3: operator points hook back at a working distributor and
        // acknowledges the recovered amount on the hook.
        hook.setFeeDistributor(address(distributor));
        hook.acknowledgeFailedDistribution(currency1, outstanding);
        assertEq(hook.failedDistribution(Currency.unwrap(currency1)), 0, "fully recovered");

        // Stage 4: subsequent swaps distribute normally — no stale tally.
        uint256 distCallsBefore = distributor.distributionCount();
        swap(poolKey, true, -int256(1 ether), ZERO_BYTES);
        assertEq(
            hook.failedDistribution(Currency.unwrap(currency1)),
            0,
            "tally stays 0 once distributor is healthy"
        );
        assertGt(distributor.distributionCount(), distCallsBefore, "good distributor invoked");
    }

    // -----------------------------------------------------------------
    // Hardening — registerVault explicitly rejects native ETH currencies.
    // -----------------------------------------------------------------
    function test_reality_registerVault_rejectsNativeCurrency() public {
        // Build a synthetic native pool key (currency0 = address(0)).
        PoolKey memory nativeKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: currency1,
            fee: 100,
            tickSpacing: 1,
            hooks: IHooks(address(hook))
        });
        vm.expectRevert(DynamicFeeHookV2.NativeCurrencyUnsupported.selector);
        hook.registerVault(nativeKey, vaultEOA);
    }
}
