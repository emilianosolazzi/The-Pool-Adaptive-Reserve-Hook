// SPDX-License-Identifier: MIT
pragma solidity >=0.8.24 <0.9.0;

import {Test} from "forge-std/Test.sol";
import {BootstrapRewards} from "../src/BootstrapRewards.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract BootstrapRewardsTest is Test {
    BootstrapRewards public bootstrap;

    MockERC20 public vaultShares; // stands in for LiquidityVault ERC-20 shares
    MockERC20 public usdc;

    address public owner = makeAddr("owner");
    address public treasury = makeAddr("realTreasury");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public carol = makeAddr("carol");

    uint64 public constant PROGRAM_START_OFFSET = 1 days;
    uint64 public constant EPOCH_LEN = 30 days;
    uint32 public constant EPOCH_COUNT = 6;
    uint64 public constant DWELL = 7 days;
    uint64 public constant CLAIM_WINDOW = 90 days;
    uint64 public constant FINALIZATION_DELAY = 7 days;
    uint16 public constant BONUS_BPS = 5000; // 50%
    uint256 public constant PER_EPOCH_CAP = 10_000e6; // $10k USDC
    uint256 public constant PER_WALLET_CAP = 25_000e6 * 1e12; // $25k scaled (shares ~= USDC * 1e12 to emulate 18-dec vault shares over 6-dec asset)
    uint256 public constant GLOBAL_CAP = 100_000e6 * 1e12; // $100k

    uint64 public programStart;

    function setUp() public {
        vaultShares = new MockERC20("Vault Shares", "vPOOL", 18);
        usdc = new MockERC20("USD Coin", "USDC", 6);

        programStart = uint64(block.timestamp + PROGRAM_START_OFFSET);

        BootstrapRewards.Config memory cfg = BootstrapRewards.Config({
            vault: IERC20(address(vaultShares)),
            payoutAsset: IERC20(address(usdc)),
            realTreasury: treasury,
            programStart: programStart,
            epochLength: EPOCH_LEN,
            epochCount: EPOCH_COUNT,
            dwellPeriod: DWELL,
            claimWindow: CLAIM_WINDOW,
            finalizationDelay: FINALIZATION_DELAY,
            bonusShareBps: BONUS_BPS,
            perEpochCap: PER_EPOCH_CAP,
            perWalletShareCap: PER_WALLET_CAP,
            globalShareCap: GLOBAL_CAP
        });

        vm.prank(owner);
        bootstrap = new BootstrapRewards(cfg);
    }

    // ---------------------------------------------------------------
    // Constructor guards
    // ---------------------------------------------------------------

    function test_constructor_revertsZeroVault() public {
        BootstrapRewards.Config memory cfg = _baseCfg();
        cfg.vault = IERC20(address(0));
        vm.expectRevert(BootstrapRewards.ZeroAddress.selector);
        new BootstrapRewards(cfg);
    }

    function test_constructor_revertsZeroBonusShareBpsOverflow() public {
        BootstrapRewards.Config memory cfg = _baseCfg();
        cfg.bonusShareBps = 10_001;
        vm.expectRevert(BootstrapRewards.InvalidConfig.selector);
        new BootstrapRewards(cfg);
    }

    function test_constructor_revertsZeroEpochLen() public {
        BootstrapRewards.Config memory cfg = _baseCfg();
        cfg.epochLength = 0;
        vm.expectRevert(BootstrapRewards.InvalidConfig.selector);
        new BootstrapRewards(cfg);
    }

    // ---------------------------------------------------------------
    // Inflow routing
    // ---------------------------------------------------------------

    function test_pullInflow_splits_50_50_toBonusAndTreasury() public {
        vm.warp(programStart + 1 days);
        usdc.mint(address(bootstrap), 1_000e6);

        uint256 treasuryBefore = usdc.balanceOf(treasury);
        uint256 processed = bootstrap.pullInflow();

        assertEq(processed, 1_000e6, "processed");
        assertEq(usdc.balanceOf(treasury) - treasuryBefore, 500e6, "treasury got 50%");

        (uint128 bonusPool,,,) = bootstrap.epochs(0);
        assertEq(bonusPool, 500e6, "bonus pool got 50%");
    }

    function test_pullInflow_beforeProgram_forwardsAllToTreasury() public {
        // Still before programStart.
        usdc.mint(address(bootstrap), 1_000e6);

        uint256 treasuryBefore = usdc.balanceOf(treasury);
        bootstrap.pullInflow();
        assertEq(usdc.balanceOf(treasury) - treasuryBefore, 1_000e6, "forward all");
    }

    function test_pullInflow_afterProgramEnd_forwardsAllToTreasury() public {
        vm.warp(uint256(programStart) + EPOCH_LEN * EPOCH_COUNT + 1);
        usdc.mint(address(bootstrap), 500e6);
        bootstrap.pullInflow();
        assertEq(usdc.balanceOf(treasury), 500e6);
    }

    function test_pullInflow_epochCap_overflowToTreasury() public {
        vm.warp(programStart + 1 days);
        // 50% of 30k = 15k > cap 10k -> 10k to bonus, 20k forwarded.
        usdc.mint(address(bootstrap), 30_000e6);
        bootstrap.pullInflow();

        (uint128 bonusPool,,,) = bootstrap.epochs(0);
        assertEq(bonusPool, PER_EPOCH_CAP, "pool at cap");
        assertEq(usdc.balanceOf(treasury), 30_000e6 - PER_EPOCH_CAP, "overflow forwarded");
    }

    function test_pullInflow_idempotent() public {
        vm.warp(programStart + 1 days);
        usdc.mint(address(bootstrap), 1_000e6);
        bootstrap.pullInflow();
        uint256 processed2 = bootstrap.pullInflow();
        assertEq(processed2, 0, "no double count");
    }

    // ---------------------------------------------------------------
    // Dwell period
    // ---------------------------------------------------------------

    function test_poke_noAccrualBeforeDwell() public {
        vm.warp(programStart);
        vaultShares.mint(alice, 1_000e18);
        bootstrap.poke(alice);

        // Advance 6 days (< 7 day dwell).
        vm.warp(programStart + 6 days);
        bootstrap.poke(alice);

        assertEq(bootstrap.userEpochShareSeconds(alice, 0), 0, "no accrual before dwell");
    }

    function test_poke_accruesAfterDwell() public {
        vm.warp(programStart);
        vaultShares.mint(alice, 1_000e18);
        bootstrap.poke(alice);

        // 14 days in -> 7 days of accrual past dwell.
        vm.warp(programStart + 14 days);
        bootstrap.poke(alice);

        uint256 ss = bootstrap.userEpochShareSeconds(alice, 0);
        assertEq(ss, 1_000e18 * 7 days, "7 days * 1000 shares");
    }

    function test_poke_balanceTo0ResetsDwell() public {
        vm.warp(programStart);
        vaultShares.mint(alice, 1_000e18);
        bootstrap.poke(alice);

        vm.warp(programStart + 14 days);
        // Burn balance to 0.
        vm.prank(alice);
        vaultShares.transfer(bob, 1_000e18);
        bootstrap.poke(alice);

        // Alice starts fresh; mint again.
        vaultShares.mint(alice, 500e18);
        bootstrap.poke(alice);
        // Only 5 days later -> still inside new dwell.
        vm.warp(programStart + 19 days);
        bootstrap.poke(alice);

        // POST H-3 FIX: the unpoked interval is credited at
        // min(lastBalance, currentBalance). At day 14 lastBalance was still
        // 1000 (set at day 0) but currentBalance dropped to 0, so the
        // [day0..day14] interval credits 0 share-seconds. This is the
        // documented defensive behavior: depositors must call poke() before
        // any balance reduction or they forfeit the unaccrued window.
        uint256 ss = bootstrap.userEpochShareSeconds(alice, 0);
        assertEq(ss, 0, "no credit when poke skipped before transfer");
    }

    /// @notice Regression for H-3: without the min(lastBalance, currentBalance)
    /// floor in _poke, an attacker could hold X shares briefly, withdraw to
    /// dust without poking, and later receive credit for the full interval at
    /// the snapshot balance X. Verify that path now credits ~zero (only the
    /// dust balance accrues).
    function test_H3_lazyPoke_overClaim_isMitigated() public {
        // T=0: alice deposits 1000 shares, pokes (lastBalance=1000, dwell starts).
        vm.warp(programStart);
        vaultShares.mint(alice, 1_000e18);
        bootstrap.poke(alice);

        // T=10d: alice withdraws all but 1 wei to bob. She does NOT poke.
        vm.warp(programStart + 10 days);
        vm.prank(alice);
        vaultShares.transfer(bob, 1_000e18 - 1);
        // Alice's storage still says lastBalance=1000e18; on-chain balance is 1.

        // T=29d: long after dwell, just before epoch 0 ends, alice pokes.
        vm.warp(programStart + 29 days);
        bootstrap.poke(alice);

        // Pre-fix, alice would have been credited (29 - 7) days * 1000e18.
        // Post-fix, the interval is clamped to min(1000e18, 1) = 1, so the
        // accrual is at most 22 days * 1 = 22 wei-shares-seconds.
        uint256 ss = bootstrap.userEpochShareSeconds(alice, 0);
        uint256 attackerCeiling = 22 days * 1;
        assertLe(ss, attackerCeiling, "over-claim attack neutralized");
    }

    // ---------------------------------------------------------------
    // Per-wallet cap
    // ---------------------------------------------------------------

    function test_perWalletCap_clipsEligibleShares() public {
        uint256 whaleBalance = PER_WALLET_CAP * 10; // 10x the cap
        vm.warp(programStart);
        vaultShares.mint(alice, whaleBalance);
        bootstrap.poke(alice);

        vm.warp(programStart + 14 days);
        bootstrap.poke(alice);

        uint256 ss = bootstrap.userEpochShareSeconds(alice, 0);
        // 7 days of accrual at PER_WALLET_CAP (not whaleBalance).
        assertEq(ss, PER_WALLET_CAP * 7 days, "clipped to wallet cap");
    }

    // ---------------------------------------------------------------
    // Full lifecycle: two users, claim proportional
    // ---------------------------------------------------------------

    function test_claim_proportionalSplit_twoUsers() public {
        // Both deposit at programStart.
        vm.warp(programStart);
        vaultShares.mint(alice, 1_000e18);
        vaultShares.mint(bob, 3_000e18);
        bootstrap.poke(alice);
        bootstrap.poke(bob);

        // Fund bonus pool in epoch 0.
        vm.warp(programStart + 1 days);
        usdc.mint(address(bootstrap), 2_000e6); // 50% -> 1000 to bonus
        bootstrap.pullInflow();

        // End of epoch 0; both users poke during finalization window.
        vm.warp(programStart + EPOCH_LEN + 1);
        bootstrap.poke(alice);
        bootstrap.poke(bob);

        // Advance past finalization delay -> claim opens.
        vm.warp(uint256(programStart) + EPOCH_LEN + FINALIZATION_DELAY + 1);

        // Alice claims.
        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        bootstrap.claim(0);
        uint256 aliceBonus = usdc.balanceOf(alice) - aliceBefore;

        // Bob claims.
        uint256 bobBefore = usdc.balanceOf(bob);
        vm.prank(bob);
        bootstrap.claim(0);
        uint256 bobBonus = usdc.balanceOf(bob) - bobBefore;

        // Ratio should be 1:3 (Alice:Bob).
        assertApproxEqRel(bobBonus, aliceBonus * 3, 1e15, "3:1 split");
        // Total distributed <= bonus pool.
        assertLe(aliceBonus + bobBonus, 1_000e6);
        // Should distribute most of the pool (rounding only).
        assertGe(aliceBonus + bobBonus, 1_000e6 - 10);
    }

    function test_claim_revertsIfEpochNotFinalized() public {
        vm.warp(programStart + 1 days);
        vaultShares.mint(alice, 1_000e18);
        bootstrap.poke(alice);

        vm.prank(alice);
        vm.expectRevert(BootstrapRewards.EpochNotFinalized.selector);
        bootstrap.claim(0);
    }

    function test_claim_revertsIfAlreadyClaimed() public {
        vm.warp(programStart);
        vaultShares.mint(alice, 1_000e18);
        bootstrap.poke(alice);

        vm.warp(programStart + 1 days);
        usdc.mint(address(bootstrap), 2_000e6);
        bootstrap.pullInflow();

        vm.warp(uint256(programStart) + EPOCH_LEN + FINALIZATION_DELAY + 1);
        vm.prank(alice);
        bootstrap.claim(0);

        vm.prank(alice);
        vm.expectRevert(BootstrapRewards.AlreadyClaimed.selector);
        bootstrap.claim(0);
    }

    function test_claim_revertsAfterClaimWindow() public {
        vm.warp(programStart);
        vaultShares.mint(alice, 1_000e18);
        bootstrap.poke(alice);

        vm.warp(programStart + 1 days);
        usdc.mint(address(bootstrap), 2_000e6);
        bootstrap.pullInflow();

        vm.warp(uint256(programStart) + EPOCH_LEN + FINALIZATION_DELAY + CLAIM_WINDOW + 1);
        vm.prank(alice);
        vm.expectRevert(BootstrapRewards.ClaimWindowClosed.selector);
        bootstrap.claim(0);
    }

    // ---------------------------------------------------------------
    // Sweep unclaimed
    // ---------------------------------------------------------------

    function test_sweepEpoch_unclaimedGoesToTreasury() public {
        vm.warp(programStart);
        vaultShares.mint(alice, 1_000e18);
        bootstrap.poke(alice);

        vm.warp(programStart + 1 days);
        usdc.mint(address(bootstrap), 2_000e6);
        bootstrap.pullInflow();

        // Advance past claim window without any claim.
        vm.warp(uint256(programStart) + EPOCH_LEN + FINALIZATION_DELAY + CLAIM_WINDOW + 1);
        uint256 treasuryBefore = usdc.balanceOf(treasury);
        bootstrap.sweepEpoch(0);
        assertEq(usdc.balanceOf(treasury) - treasuryBefore, 1_000e6, "unclaimed swept");
    }

    function test_sweepEpoch_revertsBeforeWindowClose() public {
        vm.warp(programStart + 1 days);
        usdc.mint(address(bootstrap), 2_000e6);
        bootstrap.pullInflow();

        vm.warp(programStart + EPOCH_LEN + 1);
        vm.expectRevert(BootstrapRewards.ClaimWindowClosed.selector);
        bootstrap.sweepEpoch(0);
    }

    function test_sweepEpoch_revertsIfAlreadySwept() public {
        vm.warp(programStart + 1 days);
        usdc.mint(address(bootstrap), 2_000e6);
        bootstrap.pullInflow();

        vm.warp(uint256(programStart) + EPOCH_LEN + FINALIZATION_DELAY + CLAIM_WINDOW + 1);
        bootstrap.sweepEpoch(0);
        vm.expectRevert(BootstrapRewards.EpochAlreadySwept.selector);
        bootstrap.sweepEpoch(0);
    }

    // ---------------------------------------------------------------
    // Foreign token sweep
    // ---------------------------------------------------------------

    function test_sweepToken_forwardsNonPayoutToken() public {
        MockERC20 weth = new MockERC20("WETH", "WETH", 18);
        weth.mint(address(bootstrap), 1e18);

        vm.prank(owner);
        bootstrap.sweepToken(address(weth));
        assertEq(weth.balanceOf(treasury), 1e18);
    }

    function test_sweepToken_revertsOnPayoutAsset() public {
        vm.prank(owner);
        vm.expectRevert(BootstrapRewards.CannotSweepPayoutAsset.selector);
        bootstrap.sweepToken(address(usdc));
    }

    function test_sweepToken_onlyOwner() public {
        MockERC20 weth = new MockERC20("WETH", "WETH", 18);
        vm.prank(alice);
        vm.expectRevert();
        bootstrap.sweepToken(address(weth));
    }

    // ---------------------------------------------------------------
    // Admin
    // ---------------------------------------------------------------

    function test_setRealTreasury_ownerOnly() public {
        address newT = makeAddr("newTreasury");
        vm.prank(owner);
        bootstrap.setRealTreasury(newT);
        assertEq(bootstrap.realTreasury(), newT);
    }

    function test_setRealTreasury_revertsNonOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        bootstrap.setRealTreasury(alice);
    }

    function test_setRealTreasury_revertsZero() public {
        vm.prank(owner);
        vm.expectRevert(BootstrapRewards.ZeroAddress.selector);
        bootstrap.setRealTreasury(address(0));
    }

    // ---------------------------------------------------------------
    // Share-transfer forfeit behavior
    // ---------------------------------------------------------------

    function test_transferringSharesForfeitsFutureAccrual() public {
        // Alice deposits, dwells, accrues for a week, then transfers shares
        // to Carol. Carol starts her own dwell. Alice stops accruing.
        vm.warp(programStart);
        vaultShares.mint(alice, 1_000e18);
        bootstrap.poke(alice);

        vm.warp(programStart + 14 days);
        bootstrap.poke(alice);
        uint256 aliceSsBefore = bootstrap.userEpochShareSeconds(alice, 0);
        assertGt(aliceSsBefore, 0);

        // Alice transfers all shares to Carol.
        vm.prank(alice);
        vaultShares.transfer(carol, 1_000e18);
        bootstrap.poke(alice);
        bootstrap.poke(carol);

        // 10 more days elapse.
        vm.warp(programStart + 24 days);
        bootstrap.poke(alice);
        bootstrap.poke(carol);

        uint256 aliceSsAfter = bootstrap.userEpochShareSeconds(alice, 0);
        uint256 carolSs = bootstrap.userEpochShareSeconds(carol, 0);

        assertEq(aliceSsAfter, aliceSsBefore, "Alice frozen after transfer");
        // Carol's first poke at day 14 set firstDepositTime=day14, dwellEnd=day21.
        // Her second poke at day 24 accrues from day 21 -> day 24 = 3 days * 1000.
        assertEq(carolSs, 3 days * 1_000e18, "Carol accrued past dwell after day 21");

        // 10 more days (total 34d since programStart; epoch 0 ends at day 30).
        vm.warp(programStart + 34 days);
        bootstrap.poke(carol);
        uint256 carolSsLater = bootstrap.userEpochShareSeconds(carol, 0);
        // Carol accrues from day 24 to min(day 34, epochEnd day 30) = 6 more days.
        // Total in epoch 0: 3 + 6 = 9 days * 1000.
        assertEq(carolSsLater, 9 days * 1_000e18, "Carol accrued 9 days in epoch 0");
    }

    // ---------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------

    function _baseCfg() internal view returns (BootstrapRewards.Config memory) {
        return BootstrapRewards.Config({
            vault: IERC20(address(vaultShares)),
            payoutAsset: IERC20(address(usdc)),
            realTreasury: treasury,
            programStart: programStart,
            epochLength: EPOCH_LEN,
            epochCount: EPOCH_COUNT,
            dwellPeriod: DWELL,
            claimWindow: CLAIM_WINDOW,
            finalizationDelay: FINALIZATION_DELAY,
            bonusShareBps: BONUS_BPS,
            perEpochCap: PER_EPOCH_CAP,
            perWalletShareCap: PER_WALLET_CAP,
            globalShareCap: GLOBAL_CAP
        });
    }
}
