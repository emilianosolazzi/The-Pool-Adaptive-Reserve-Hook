// SPDX-License-Identifier: MIT
pragma solidity >=0.8.24 <0.9.0;

import {Test} from "forge-std/Test.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {LiquidityVaultV2} from "../src/LiquidityVaultV2.sol";
import {IZapRouter} from "../src/interfaces/IZapRouter.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockPoolManager} from "./mocks/MockPoolManager.sol";
import {MockPositionManager} from "./mocks/MockPositionManager.sol";

contract MockZapRouter is IZapRouter {
    uint256 public amountOut;

    function setAmountOut(uint256 newAmountOut) external {
        amountOut = newAmountOut;
    }

    function swapExactInput(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        address recipient,
        uint256 deadline
    ) external returns (uint256) {
        require(deadline >= block.timestamp, "DEADLINE");
        require(amountOut >= minAmountOut, "MOCK_MIN_OUT");
        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        IERC20(tokenOut).transfer(recipient, amountOut);
        return amountOut;
    }
}

contract MockReserveHook {
    // proceedsOwed[vault][currency_addr] = amount
    mapping(address => mapping(address => uint256)) public proceeds;
    // escrowedReserve[vault][currency_addr] = amount  (live offer inventory)
    mapping(address => mapping(address => uint256)) public escrow;
    address public lastSellCurrency;
    uint128 public lastSellAmount;
    uint160 public lastSqrtPriceX96;
    uint64  public lastExpiry;
    bool    public cancelCalled;
    uint128 public escrowToReturnOnCancel;
    bool    public hasActiveOffer;
    bool    public forceCancelRevert;

    function setProceedsOwed(address vault_, address currency_, uint256 amt) external {
        proceeds[vault_][currency_] = amt;
    }

    function setEscrow(address vault_, address currency_, uint256 amt) external {
        escrow[vault_][currency_] = amt;
    }

    function setEscrowToReturnOnCancel(uint128 amt, bool active) external {
        escrowToReturnOnCancel = amt;
        hasActiveOffer = active;
    }

    function setForceCancelRevert(bool v) external {
        forceCancelRevert = v;
    }

    function proceedsOwed(address vault_, Currency c) external view returns (uint256) {
        return proceeds[vault_][Currency.unwrap(c)];
    }

    function escrowedReserve(address vault_, Currency c) external view returns (uint256) {
        return escrow[vault_][Currency.unwrap(c)];
    }

    function offerActive(PoolKey calldata) external view returns (bool) {
        return hasActiveOffer;
    }

    function claimReserveProceeds(Currency c) external returns (uint256 a) {
        address ca = Currency.unwrap(c);
        a = proceeds[msg.sender][ca];
        if (a > 0) {
            proceeds[msg.sender][ca] = 0;
            // Mock holds the tokens; transfer to caller.
            IERC20(ca).transfer(msg.sender, a);
        }
    }

    function cancelReserveOffer(PoolKey calldata) external returns (uint128 returned) {
        cancelCalled = true;
        if (forceCancelRevert) revert("MOCK_CANCEL_FORCED_REVERT");
        if (!hasActiveOffer) revert("NO_OFFER");
        returned = escrowToReturnOnCancel;
        if (returned > 0 && lastSellCurrency != address(0)) {
            escrow[msg.sender][lastSellCurrency] = 0;
            IERC20(lastSellCurrency).transfer(msg.sender, returned);
        }
        hasActiveOffer = false;
    }

    function createReserveOffer(
        PoolKey calldata,
        Currency sellCurrency,
        uint128 sellAmount,
        uint160 sqrtPriceX96,
        uint64 expiry
    ) external {
        lastSellCurrency = Currency.unwrap(sellCurrency);
        lastSellAmount = sellAmount;
        lastSqrtPriceX96 = sqrtPriceX96;
        lastExpiry = expiry;
        hasActiveOffer = true;
        IERC20(lastSellCurrency).transferFrom(msg.sender, address(this), sellAmount);
        escrow[msg.sender][lastSellCurrency] += sellAmount;
    }

    /// @notice Test-only helper to simulate a swap fill: reduce escrow in
    ///         sellCurrency, credit proceeds in buyCurrency.
    function simulateFill(
        address vault_,
        address sellCurrency_,
        uint256 escrowConsumed,
        address buyCurrency_,
        uint256 proceedsCredited
    ) external {
        require(escrow[vault_][sellCurrency_] >= escrowConsumed, "MOCK_OVERFILL");
        escrow[vault_][sellCurrency_] -= escrowConsumed;
        proceeds[vault_][buyCurrency_] += proceedsCredited;
    }
}

/// @notice Records every poke; can be configured to revert.
contract MockBootstrapRewards {
    event Poked(address user);

    bool public revertOnPoke;
    address[] public pokes;

    function setRevertOnPoke(bool v) external { revertOnPoke = v; }

    function pokeCount() external view returns (uint256) { return pokes.length; }

    function pokeAt(uint256 i) external view returns (address) { return pokes[i]; }

    function poke(address user) external {
        if (revertOnPoke) revert("MOCK_POKE_REVERT");
        pokes.push(user);
        emit Poked(user);
    }
}

contract LiquidityVaultV2Test is Test {
    LiquidityVaultV2 public vault;
    MockERC20 public usdc;
    MockERC20 public weth;
    MockPoolManager public mockManager;
    MockPositionManager public mockPosMgr;
    MockZapRouter public zapRouter;

    address public alice = makeAddr("alice");
    PoolKey public poolKey;

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        mockManager = new MockPoolManager();
        mockPosMgr = new MockPositionManager();
        zapRouter = new MockZapRouter();

        vault = new LiquidityVaultV2(
            usdc,
            IPoolManager(address(mockManager)),
            IPositionManager(address(mockPosMgr)),
            "LP Vault V2",
            "LPV2",
            address(0),
            address(zapRouter)
        );

        address lo = address(weth) < address(usdc) ? address(weth) : address(usdc);
        address hi = address(weth) < address(usdc) ? address(usdc) : address(weth);
        poolKey = PoolKey({
            currency0: Currency.wrap(lo),
            currency1: Currency.wrap(hi),
            fee: 500,
            tickSpacing: 60,
            hooks: IHooks(address(vault))
        });

        mockManager.setSlot0(TickMath.getSqrtPriceAtTick(-198900), -198900);
        vault.setPoolKey(poolKey);
    }

    function test_depositWithZap_buysOtherTokenAndMintsActiveLiquidity() public {
        usdc.mint(alice, 100e6);
        weth.mint(address(zapRouter), 1 ether);
        zapRouter.setAmountOut(1 ether);

        vm.startPrank(alice);
        usdc.approve(address(vault), type(uint256).max);
        uint256 shares = vault.depositWithZap(100e6, alice, 50e6, 1 ether, 1, 0, block.timestamp + 1);
        vm.stopPrank();

        assertGt(shares, 0);
        assertEq(vault.totalDepositors(), 1);
        assertGt(vault.totalLiquidityDeployed(), 0);
        assertEq(mockPosMgr.callCount(), 1);
        assertEq(usdc.balanceOf(address(zapRouter)), 50e6);
    }

    function test_depositWithZap_revertsWhenRouterOutputBelowMinimum() public {
        usdc.mint(alice, 100e6);
        weth.mint(address(zapRouter), 1 ether);
        zapRouter.setAmountOut(0.5 ether);

        vm.startPrank(alice);
        usdc.approve(address(vault), type(uint256).max);
        vm.expectRevert("MOCK_MIN_OUT");
        vault.depositWithZap(100e6, alice, 50e6, 1 ether, 1, 0, block.timestamp + 1);
        vm.stopPrank();
    }

    function test_depositWithZap_revertsWhenRouterNotSet() public {
        vault.setZapRouter(address(0));
        usdc.mint(alice, 100e6);

        vm.startPrank(alice);
        usdc.approve(address(vault), type(uint256).max);
        vm.expectRevert("ZAP_ROUTER_NOT_SET");
        vault.depositWithZap(100e6, alice, 50e6, 1, 1, 0, block.timestamp + 1);
        vm.stopPrank();
    }

    function test_depositWithZap_revertsWhenSharesBelowMinimum() public {
        usdc.mint(alice, 100e6);
        weth.mint(address(zapRouter), 1 ether);
        zapRouter.setAmountOut(1 ether);

        vm.startPrank(alice);
        usdc.approve(address(vault), type(uint256).max);
        // Mint produces a finite share amount; require a wildly high minimum
        // so the post-zap fair-share calc cannot satisfy it -> MIN_SHARES_OUT.
        vm.expectRevert("MIN_SHARES_OUT");
        vault.depositWithZap(100e6, alice, 50e6, 1 ether, 1, type(uint256).max, block.timestamp + 1);
        vm.stopPrank();
    }

    function test_setReserveHook_setsAddress() public {
        address hookStub = address(new MockPoolManager()); // any contract is fine for code-length check
        vault.setReserveHook(hookStub);
        assertEq(vault.reserveHook(), hookStub);
    }

    function test_offerReserveToHook_revertsWhenHookNotSet() public {
        weth.mint(address(vault), 1 ether);
        vm.expectRevert("HOOK_NOT_SET");
        vault.offerReserveToHook(Currency.wrap(address(weth)), uint128(1 ether), uint160(1 << 96), 0);
    }

    function test_mintRunsVaultDepositControls() public {
        uint256 sharesToMint = vault.previewDeposit(vault.MIN_DEPOSIT());
        uint256 assetsRequired = vault.previewMint(sharesToMint);

        usdc.mint(alice, assetsRequired);
        vm.startPrank(alice);
        usdc.approve(address(vault), type(uint256).max);
        uint256 spent = vault.mint(sharesToMint, alice);
        vm.stopPrank();

        assertEq(spent, assetsRequired, "mint consumed previewed assets");
        assertEq(vault.balanceOf(alice), sharesToMint, "shares minted");
        assertEq(vault.totalDepositors(), 1, "mint path updates depositor accounting");
    }

    function test_totalAssetsHandlesLargeSqrtPriceWithoutOverflow() public {
        weth.mint(address(vault), 1 ether);
        mockManager.setSlot0(type(uint160).max, -198900);
        vault.totalAssets();
    }

    // ---------------------------------------------------------------
    // P0 #3 — setRemoveLiquiditySlippageBps capped at 100 bps (1%).
    // ---------------------------------------------------------------
    function test_setRemoveLiquiditySlippageBps_acceptsAtCap() public {
        vault.setRemoveLiquiditySlippageBps(100);
        assertEq(vault.removeLiquiditySlippageBps(), 100);
    }

    function test_setRemoveLiquiditySlippageBps_revertsAboveCap() public {
        vm.expectRevert("SLIPPAGE_TOO_HIGH");
        vault.setRemoveLiquiditySlippageBps(101);
    }

    function test_setRemoveLiquiditySlippageBps_onlyOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        vault.setRemoveLiquiditySlippageBps(50);
    }

    // ---------------------------------------------------------------
    // P0 #2 — setInitialTicks: pre-deposit-only tick band config.
    // ---------------------------------------------------------------
    function test_setInitialTicks_alignsAndUpdates() public {
        // poolKey.tickSpacing = 60 (set in setUp).
        vault.setInitialTicks(-3000, 3000);
        assertEq(vault.tickLower(), -3000);
        assertEq(vault.tickUpper(), 3000);
    }

    function test_setInitialTicks_revertsWhenNotSpacingAligned() public {
        vm.expectRevert("TICK_NOT_ALIGNED");
        vault.setInitialTicks(-3001, 3000);
    }

    function test_setInitialTicks_revertsWhenInverted() public {
        vm.expectRevert("INVALID_TICKS");
        vault.setInitialTicks(3000, -3000);
    }

    function test_setInitialTicks_onlyOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        vault.setInitialTicks(-3000, 3000);
    }

    // ---------------------------------------------------------------
    // P0 #1 — totalAssets() includes pendingProceeds (asset currency).
    // ---------------------------------------------------------------
    function test_totalAssets_includesPendingProceedsInAssetCurrency() public {
        MockReserveHook mh = new MockReserveHook();
        vault.setReserveHook(address(mh));

        // Pre-state: vault owns no token1, no liquidity. totalAssets = 0.
        uint256 t0 = vault.totalAssets();

        // Stage 12.5 USDC of pending proceeds for the vault.
        // Asset currency is USDC.
        usdc.mint(address(mh), 12_500_000); // 12.5 USDC (6 decimals)
        mh.setProceedsOwed(address(vault), address(usdc), 12_500_000);

        uint256 t1 = vault.totalAssets();
        assertEq(t1 - t0, 12_500_000, "NAV must include hook-side pending proceeds in asset currency");
    }

    // ---------------------------------------------------------------
    // P0 #1 — entry path auto-claims proceeds before share math.
    // ---------------------------------------------------------------
    function test_deposit_autoClaimsProceedsFromHook() public {
        MockReserveHook mh = new MockReserveHook();
        vault.setReserveHook(address(mh));

        // Stage proceeds in BOTH currencies.
        usdc.mint(address(mh), 5_000_000); // 5 USDC
        weth.mint(address(mh), 0.25 ether);
        mh.setProceedsOwed(address(vault), address(usdc), 5_000_000);
        mh.setProceedsOwed(address(vault), address(weth), 0.25 ether);

        // Alice deposits MIN_DEPOSIT to trigger _pullReserveProceedsBoth.
        uint256 dep = vault.MIN_DEPOSIT();
        usdc.mint(alice, dep);
        // Pre-fund zap + lp side so depositWithZap is not strictly needed —
        // the simple deposit path also runs the proceeds pull.
        vm.startPrank(alice);
        usdc.approve(address(vault), type(uint256).max);
        vault.deposit(dep, alice);
        vm.stopPrank();

        // After: vault must have received the staged proceeds physically,
        // and hook ledger must be drained.
        assertEq(mh.proceeds(address(vault), address(usdc)), 0, "hook proceeds USDC drained");
        assertEq(mh.proceeds(address(vault), address(weth)), 0, "hook proceeds WETH drained");
        // Vault USDC balance includes the 5 USDC pulled + the deposit (deposit
        // currency is USDC, so post-deposit balance contains both).
        assertGe(usdc.balanceOf(address(vault)), 5_000_000);
        assertEq(weth.balanceOf(address(vault)), 0.25 ether);
    }

    // ---------------------------------------------------------------
    // P1 #B1 — rebalanceOffer is atomic: cancel → claim both → repost.
    // ---------------------------------------------------------------
    function test_rebalanceOffer_atomicCancelClaimRepost() public {
        MockReserveHook mh = new MockReserveHook();
        vault.setReserveHook(address(mh));

        // Pre-stage: an active offer of 1 WETH already escrowed in the hook,
        // plus 0.4 WETH proceeds owed to the vault from a prior partial fill.
        weth.mint(address(mh), 1 ether);   // escrow held by hook
        weth.mint(address(mh), 0.4 ether); // proceeds also held by hook
        mh.setProceedsOwed(address(vault), address(weth), 0.4 ether);
        // Tell mock about the active offer so cancel returns escrow.
        // Pretend prior offer was for WETH:
        vm.store(
            address(mh),
            bytes32(uint256(1)), // lastSellCurrency slot — easier to set directly via call:
            bytes32(0)
        );
        // Actually, just call createReserveOffer once with vault's tokens to populate state cleanly.
        // To do that we need vault to have allowance + balance — skip this and rely on direct setter:
        mh.setEscrowToReturnOnCancel(1 ether, true);
        // Inject lastSellCurrency by calling create from vault for 0 amount? Use a tiny helper-style:
        // Use vm.store to set the lastSellCurrency address at slot computed manually is fragile;
        // instead, use a fresh approach: have the MOCK transfer escrow back from its own balance
        // regardless of "lastSellCurrency", by patching mock. (Already does so only when
        // lastSellCurrency != 0). So we set it via a one-time helper:
        // Workaround: have vault create an initial offer via offerReserveToHook style? Too coupled.
        // Cleanest: pre-fund by minting vault, calling offerReserveToHook (which forwards to mock).
        weth.mint(address(vault), 1 ether);
        vm.prank(vault.owner());
        vault.offerReserveToHook(Currency.wrap(address(weth)), 1 ether, uint160(1 << 96), 0);
        // Now mock has lastSellCurrency=weth and active=true (overwrites direct setter).
        mh.setEscrowToReturnOnCancel(1 ether, true);

        // Fund vault with NEW inventory for the repost (0.6 WETH).
        weth.mint(address(vault), 0.6 ether);

        uint160 newSqrt = uint160(2 << 96);
        uint64 newExpiry = uint64(block.timestamp + 3600);
        vm.prank(vault.owner());
        vault.rebalanceOffer(Currency.wrap(address(weth)), 0.6 ether, newSqrt, newExpiry);

        // Assertions:
        // 1) Cancel was called.
        assertTrue(mh.cancelCalled(), "cancel was called");
        // 2) Both claim slots drained (only weth was non-zero).
        assertEq(mh.proceeds(address(vault), address(weth)), 0, "weth proceeds drained");
        // 3) New offer is active with the new params.
        assertTrue(mh.hasActiveOffer(), "new offer is active");
        assertEq(mh.lastSellCurrency(), address(weth));
        assertEq(uint256(mh.lastSellAmount()), 0.6 ether);
        assertEq(uint256(mh.lastSqrtPriceX96()), uint256(newSqrt));
        assertEq(uint256(mh.lastExpiry()), uint256(newExpiry));
    }

    // ---------------------------------------------------------------
    // P0 #1++ — NAV is continuous across the FULL reserve-offer lifecycle:
    //          baseline → posted (escrow) → partial fill → full fill → claim.
    //          (Plus a separate cancel branch.)
    //
    // Drives bookkeeping in the asset currency (USDC) so the cross-currency
    // sqrt-price math doesn't drown out the assertion. The point being
    // measured is: "vault NAV does not drop when reserve inventory leaves the
    // idle balance and lives at the hook (escrowed or as pending proceeds)."
    // ---------------------------------------------------------------
    function test_totalAssets_continuousAcrossOfferLifecycle() public {
        MockReserveHook mh = new MockReserveHook();
        vault.setReserveHook(address(mh));

        // Seed: 1.0 USDC of vault inventory parked idle.
        uint256 SEED = 1_000_000; // 1 USDC
        usdc.mint(address(vault), SEED);

        // (1) Baseline.
        uint256 navBaseline = vault.totalAssets();
        assertEq(navBaseline, SEED, "baseline = idle balance");

        // (2) Post offer: idle USDC moves from vault into hook escrow.
        vm.prank(address(vault));
        usdc.transfer(address(mh), SEED);
        mh.setEscrow(address(vault), address(usdc), SEED);

        uint256 navPosted = vault.totalAssets();
        assertEq(navPosted, navBaseline, "NAV unchanged when offer is posted (escrow counts)");

        // (3) Partial fill: 0.4 USDC of escrow consumed, 0.4 USDC credited as proceeds.
        mh.simulateFill(address(vault), address(usdc), 400_000, address(usdc), 400_000);

        uint256 navPartial = vault.totalAssets();
        assertEq(navPartial, navBaseline, "NAV unchanged after partial fill (escrow + proceeds)");

        // (4) Full fill: remaining 0.6 USDC of escrow consumed → all proceeds.
        mh.simulateFill(address(vault), address(usdc), 600_000, address(usdc), 600_000);

        uint256 navFilled = vault.totalAssets();
        assertEq(navFilled, navBaseline, "NAV unchanged at full fill (proceeds only)");
        assertEq(mh.escrow(address(vault), address(usdc)), 0);
        assertEq(mh.proceeds(address(vault), address(usdc)), SEED);

        // (5) Claim: vault pulls proceeds physically. NAV unchanged; tokens
        //     just shift from "pending at hook" to "idle at vault".
        vault.collectReserveProceeds(Currency.wrap(address(usdc)));
        uint256 navClaimed = vault.totalAssets();
        assertEq(navClaimed, navBaseline, "NAV unchanged after claim");
        assertEq(usdc.balanceOf(address(vault)), SEED, "tokens are physically back in the vault");
        assertEq(mh.proceeds(address(vault), address(usdc)), 0);
    }

    function test_totalAssets_continuousAcrossOfferCancel() public {
        MockReserveHook mh = new MockReserveHook();
        vault.setReserveHook(address(mh));

        uint256 SEED = 1_000_000;
        usdc.mint(address(vault), SEED);
        uint256 navBaseline = vault.totalAssets();

        // Post via the real vault path so the mock's lastSellCurrency is set
        // and a future cancel can faithfully transfer escrow back.
        vm.prank(vault.owner());
        vault.offerReserveToHook(Currency.wrap(address(usdc)), uint128(SEED), uint160(1 << 96), 0);
        mh.setEscrowToReturnOnCancel(uint128(SEED), true);

        uint256 navPosted = vault.totalAssets();
        assertEq(navPosted, navBaseline, "NAV unchanged when offer is posted via real path");

        // Cancel: escrow returns to vault.
        vm.prank(vault.owner());
        uint128 returned = vault.cancelReserveOffer(Currency.wrap(address(usdc)));
        assertEq(uint256(returned), SEED);

        uint256 navCancelled = vault.totalAssets();
        assertEq(navCancelled, navBaseline, "NAV unchanged after cancel");
        assertEq(usdc.balanceOf(address(vault)), SEED, "escrow physically returned to vault");
    }

    // ---------------------------------------------------------------
    // Hardening — setPoolKey rejects native ETH currencies explicitly.
    // ---------------------------------------------------------------
    function test_setPoolKey_revertsOnNativeCurrency() public {
        // Fresh vault (setUp's vault already has a poolKey set).
        LiquidityVaultV2 v2 = new LiquidityVaultV2(
            usdc,
            IPoolManager(address(mockManager)),
            IPositionManager(address(mockPosMgr)),
            "LP Vault V2 native test",
            "LPV2N",
            address(0),
            address(zapRouter)
        );

        PoolKey memory nativeKey = PoolKey({
            currency0: Currency.wrap(address(0)), // native ETH
            currency1: Currency.wrap(address(usdc)),
            fee: 500,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });

        vm.expectRevert("NATIVE_NOT_SUPPORTED");
        v2.setPoolKey(nativeKey);
    }

    // ---------------------------------------------------------------
    // Hardening — rebalanceOffer skips cancel cleanly when no offer is
    //             active (offerActive view returns false).
    // ---------------------------------------------------------------
    function test_rebalanceOffer_skipsCancelWhenNoActiveOffer() public {
        MockReserveHook mh = new MockReserveHook();
        vault.setReserveHook(address(mh));

        // No prior offer — hasActiveOffer remains false.
        // Fund vault with inventory for the new offer.
        weth.mint(address(vault), 0.5 ether);

        vm.prank(vault.owner());
        vault.rebalanceOffer(Currency.wrap(address(weth)), 0.5 ether, uint160(1 << 96), 0);

        // Cancel must NOT have been called when offerActive returned false.
        assertFalse(mh.cancelCalled(), "cancel skipped when no active offer");
        assertTrue(mh.hasActiveOffer(), "new offer is now active");
        assertEq(uint256(mh.lastSellAmount()), 0.5 ether);
    }

    // ---------------------------------------------------------------
    // Hardening — rebalanceOffer no longer swallows real cancel failures.
    //             A reverting cancel must bubble up, not be silently
    //             treated as "no offer".
    // ---------------------------------------------------------------
    function test_rebalanceOffer_revertsOnRealCancelFailure() public {
        MockReserveHook mh = new MockReserveHook();
        vault.setReserveHook(address(mh));

        // Post a real offer so offerActive == true.
        weth.mint(address(vault), 1 ether);
        vm.prank(vault.owner());
        vault.offerReserveToHook(Currency.wrap(address(weth)), 1 ether, uint160(1 << 96), 0);
        assertTrue(mh.hasActiveOffer());

        // Force the next cancel to revert (simulates hook bug / accounting error).
        mh.setForceCancelRevert(true);

        weth.mint(address(vault), 0.6 ether);
        vm.prank(vault.owner());
        vm.expectRevert("MOCK_CANCEL_FORCED_REVERT");
        vault.rebalanceOffer(Currency.wrap(address(weth)), 0.6 ether, uint160(2 << 96), 0);
    }

    // ---------------------------------------------------------------
    // BootstrapRewards auto-poke — vault must poke the rewards program
    // on every share movement, must tolerate a reverting rewards
    // contract, and must allow the owner to disable it.
    // ---------------------------------------------------------------
    function test_setBootstrapRewards_onlyOwner() public {
        MockBootstrapRewards rewards = new MockBootstrapRewards();
        vm.prank(alice);
        vm.expectRevert();
        vault.setBootstrapRewards(address(rewards));
    }

    function test_setBootstrapRewards_acceptsZeroToDisable() public {
        MockBootstrapRewards rewards = new MockBootstrapRewards();
        vault.setBootstrapRewards(address(rewards));
        assertEq(vault.bootstrapRewards(), address(rewards));
        vault.setBootstrapRewards(address(0));
        assertEq(vault.bootstrapRewards(), address(0));
    }

    function test_setBootstrapRewards_revertsOnNonContract() public {
        vm.expectRevert("NOT_CONTRACT");
        vault.setBootstrapRewards(address(0xBEEF));
    }

    function test_autoPoke_firesOnMintAndBurn() public {
        MockBootstrapRewards rewards = new MockBootstrapRewards();
        vault.setBootstrapRewards(address(rewards));

        // Deposit (zap) — should poke `alice` (the receiver). `from` is zero
        // for mints, so the only poke target is the receiver.
        usdc.mint(alice, 100e6);
        weth.mint(address(zapRouter), 1 ether);
        zapRouter.setAmountOut(1 ether);
        vm.startPrank(alice);
        usdc.approve(address(vault), type(uint256).max);
        uint256 shares = vault.depositWithZap(100e6, alice, 50e6, 1 ether, 1, 0, block.timestamp + 1);
        vm.stopPrank();

        uint256 mintPokes = rewards.pokeCount();
        assertGe(mintPokes, 1, "mint must poke receiver at least once");
        // Receiver appears among pokes.
        bool sawAlice;
        for (uint256 i = 0; i < mintPokes; i++) {
            if (rewards.pokeAt(i) == alice) sawAlice = true;
        }
        assertTrue(sawAlice, "alice not poked on mint");

        // Transfer between holders pokes both `from` and `to`.
        address bob = makeAddr("bob");
        vm.prank(alice);
        vault.transfer(bob, shares / 2);
        // Both alice and bob must appear after the transfer.
        bool sawAliceXfer;
        bool sawBob;
        for (uint256 i = mintPokes; i < rewards.pokeCount(); i++) {
            address u = rewards.pokeAt(i);
            if (u == alice) sawAliceXfer = true;
            if (u == bob) sawBob = true;
        }
        assertTrue(sawAliceXfer, "from not poked on transfer");
        assertTrue(sawBob, "to not poked on transfer");
    }

    function test_autoPoke_revertingRewardsDoesNotBlockTransfer() public {
        MockBootstrapRewards rewards = new MockBootstrapRewards();
        vault.setBootstrapRewards(address(rewards));

        // Mint shares first while rewards is happy.
        usdc.mint(alice, 100e6);
        weth.mint(address(zapRouter), 1 ether);
        zapRouter.setAmountOut(1 ether);
        vm.startPrank(alice);
        usdc.approve(address(vault), type(uint256).max);
        uint256 shares = vault.depositWithZap(100e6, alice, 50e6, 1 ether, 1, 0, block.timestamp + 1);
        vm.stopPrank();
        assertGt(shares, 0);

        // Now break the rewards contract. Transfer must still succeed and
        // emit BootstrapPokeFailed for both ends.
        rewards.setRevertOnPoke(true);
        address bob = makeAddr("bob");
        vm.prank(alice);
        vault.transfer(bob, shares / 4);
        assertEq(vault.balanceOf(bob), shares / 4);
        assertEq(vault.balanceOf(alice), shares - shares / 4);
    }

    function test_autoPoke_disabledWhenRewardsZero() public {
        // Default is address(0) — confirm deposit still works and no poke
        // attempt is made (we can't directly assert "no call", but a
        // reverting rewards contract bound to address(0) by definition
        // can't be called).
        usdc.mint(alice, 100e6);
        weth.mint(address(zapRouter), 1 ether);
        zapRouter.setAmountOut(1 ether);
        vm.startPrank(alice);
        usdc.approve(address(vault), type(uint256).max);
        uint256 shares = vault.depositWithZap(100e6, alice, 50e6, 1 ether, 1, 0, block.timestamp + 1);
        vm.stopPrank();
        assertGt(shares, 0);
        assertEq(vault.bootstrapRewards(), address(0));
    }

    // ---------------------------------------------------------------
    // NAV pricing rule — deviation guard against navReferenceSqrtPriceX96
    // ---------------------------------------------------------------

    /// @dev Move the mocked pool spot to the price at `tick`. Bootstrap
    ///      reference is set on the first deposit at setUp's price.
    function _setPoolTick(int24 tick) internal {
        mockManager.setSlot0(TickMath.getSqrtPriceAtTick(tick), tick);
    }

    /// @dev Bootstrap the NAV reference by performing a tiny deposit at the
    ///      current pool price. After this returns, navReferenceSqrtPriceX96
    ///      is non-zero and equal to the current spot.
    function _bootstrapNavRef() internal {
        usdc.mint(alice, 10e6);
        vm.startPrank(alice);
        usdc.approve(address(vault), type(uint256).max);
        vault.deposit(10e6, alice);
        vm.stopPrank();
        assertGt(vault.navReferenceSqrtPriceX96(), 0, "ref bootstrap failed");
    }

    function test_nav_deviation_revertsOnDeposit_aboveTolerance() public {
        _bootstrapNavRef();
        // Default cap is 100 bps (1% PRICE = ~50 bps in sqrt). Each tick is
        // ~1 bps in price. Move 200 ticks up → ~2% price deviation, well
        // beyond tolerance.
        _setPoolTick(-198700);

        usdc.mint(alice, 100e6);
        vm.startPrank(alice);
        usdc.approve(address(vault), type(uint256).max);
        vm.expectRevert(LiquidityVaultV2.NAV_PRICE_DEVIATION.selector);
        vault.deposit(100e6, alice);
        vm.stopPrank();
    }

    function test_nav_deviation_revertsOnRedeemAndWithdraw_aboveTolerance() public {
        _bootstrapNavRef();
        // Capture share balance from the bootstrap deposit.
        uint256 shares = vault.balanceOf(alice);
        assertGt(shares, 0);

        _setPoolTick(-198700); // ~2% over reference

        vm.startPrank(alice);
        vm.expectRevert(LiquidityVaultV2.NAV_PRICE_DEVIATION.selector);
        vault.redeem(shares, alice, alice);

        vm.expectRevert(LiquidityVaultV2.NAV_PRICE_DEVIATION.selector);
        vault.withdraw(1e6, alice, alice);
        vm.stopPrank();
    }

    function test_nav_refreshNavReference_restoresOperations() public {
        // Widen range so that post-refresh spot stays in-range. Liquidity
        // deployment requires sqrtPrice within [sqrtLower, sqrtUpper).
        vault.setInitialTicks(-199500, -198000);
        _bootstrapNavRef();
        _setPoolTick(-198700); // breach (>1% price deviation, still in range)

        // Deposit blocked.
        usdc.mint(alice, 100e6);
        vm.startPrank(alice);
        usdc.approve(address(vault), type(uint256).max);
        vm.expectRevert(LiquidityVaultV2.NAV_PRICE_DEVIATION.selector);
        vault.deposit(100e6, alice);
        vm.stopPrank();

        // Owner re-anchors to the new spot.
        vault.refreshNavReference();
        assertEq(vault.navReferenceSqrtPriceX96(), TickMath.getSqrtPriceAtTick(-198700));

        // Now the deposit succeeds.
        vm.startPrank(alice);
        uint256 shares = vault.deposit(100e6, alice);
        vm.stopPrank();
        assertGt(shares, 0);
    }

    function test_nav_withinTolerance_priceMovementWorks() public {
        _bootstrapNavRef();
        // Move only ~30 ticks (~0.3% price) — well inside the 1% tolerance.
        _setPoolTick(-198870);

        usdc.mint(alice, 100e6);
        vm.startPrank(alice);
        usdc.approve(address(vault), type(uint256).max);
        uint256 shares = vault.deposit(100e6, alice);
        vm.stopPrank();
        assertGt(shares, 0);
    }

    function test_nav_oorClamp_doesNotOverquoteOtherToken() public {
        _bootstrapNavRef();
        // Open the deviation cap so we can push the pool well out of range
        // without tripping the guard. The clamp is what we're verifying here,
        // not the deviation gate.
        vault.setMaxNavDeviationBps(2000);
        // Push spot ABOVE sqrtUpper. Default range is [-199020, -198840];
        // jumping to tick -198000 puts spot well above sqrtUpper.
        _setPoolTick(-198000);

        // Mint a large slug of WETH directly to the vault as idle other-token.
        uint256 wethAmount = 1 ether;
        weth.mint(address(vault), wethAmount);

        // Compute expected clamp: other-token quoted at the range edge
        // (sqrtUpper), not at the unclamped spot.
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(vault.tickUpper());
        // weth address < usdc address by chance? Compute layout dynamically.
        bool wethIsToken0 = address(weth) < address(usdc);
        uint256 expectedClamped;
        if (wethIsToken0) {
            // other (token0) → asset (token1): quote = amt0 * sqrt^2 / 2^192.
            uint256 q96 = 1 << 96;
            uint256 part = FullMathLite.mulDiv(wethAmount, uint256(sqrtUpper), q96);
            expectedClamped = FullMathLite.mulDiv(part, uint256(sqrtUpper), q96);
        } else {
            // other (token1) → asset (token0): quote = amt1 * 2^192 / sqrt^2.
            uint256 q96 = 1 << 96;
            uint256 part = FullMathLite.mulDiv(wethAmount, q96, uint256(sqrtUpper));
            expectedClamped = FullMathLite.mulDiv(part, q96, uint256(sqrtUpper));
        }

        uint256 idleAsset = usdc.balanceOf(address(vault));
        uint256 totalA = vault.totalAssets();
        // No active position, no reserve hook proceeds: totalAssets ==
        // idleAsset + clamped(other).
        assertEq(totalA, idleAsset + expectedClamped, "OOR-clamp must pin other-token quote to range edge");

        // Sanity: an unclamped spot quote would be strictly larger because
        // spot > sqrtUpper and price = sqrt^2 is monotone increasing.
        uint160 sqrtSpot = TickMath.getSqrtPriceAtTick(-198000);
        uint256 unclamped;
        if (wethIsToken0) {
            uint256 q96 = 1 << 96;
            uint256 part = FullMathLite.mulDiv(wethAmount, uint256(sqrtSpot), q96);
            unclamped = FullMathLite.mulDiv(part, uint256(sqrtSpot), q96);
        } else {
            uint256 q96 = 1 << 96;
            uint256 part = FullMathLite.mulDiv(wethAmount, q96, uint256(sqrtSpot));
            unclamped = FullMathLite.mulDiv(part, q96, uint256(sqrtSpot));
        }
        if (wethIsToken0) {
            assertGt(unclamped, expectedClamped, "spot-based quote exceeds clamp");
        } else {
            assertLt(unclamped, expectedClamped, "OOR-up makes 1->0 quote shrink; clamp protects");
        }
    }
}

/// @dev Minimal mulDiv helper to avoid pulling FullMath into the test file.
library FullMathLite {
    function mulDiv(uint256 a, uint256 b, uint256 d) internal pure returns (uint256) {
        return (a * b) / d;
    }
}