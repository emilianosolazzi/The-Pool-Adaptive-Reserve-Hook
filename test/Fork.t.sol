// SPDX-License-Identifier: MIT
pragma solidity >=0.8.24 <0.9.0;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

import {LiquidityVault} from "../src/LiquidityVault.sol";

/// @title  Fork.t.sol
/// @notice End-to-end fork tests against canonical Arbitrum One Uniswap v4
///         infrastructure. Run with:
///
///             ARBITRUM_RPC_URL=https://... forge test --match-contract Fork
///
///         If ARBITRUM_RPC_URL is not set, every test is skipped via
///         `vm.skip(true)` so the default `forge test` run still passes
///         on contributors without an RPC.
///
/// Canonical addresses (Arbitrum One, verified at audit time 2026-04-25):
///   - Permit2:         0x000000000022D473030F116dDEE9F6B43aC78BA3
///   - PoolManager:     0x360E68faCcca8cA495c1B759Fd9EEe466db9FB32  (v4)
///   - PositionManager: 0xd88F38F930b7952f2DB2432Cb002E7abbF3dD869  (v4)
///   - USDC (native):   0xaf88d065e77c8cC2239327C5EDb3A432268e5831
///   - WETH:            0x82aF49447D8a07e3bd95BD0d56f35241523fBab1
contract ForkTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    // ---- Canonical Arbitrum addresses ----
    address constant PERMIT2          = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address constant POOL_MANAGER     = 0x360E68faCcca8cA495c1B759Fd9EEe466db9FB32;
    address constant POSITION_MANAGER = 0xd88F38F930b7952f2DB2432Cb002E7abbF3dD869;
    address constant USDC             = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address constant WETH             = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;

    LiquidityVault public vault;
    address public alice = makeAddr("alice_fork");
    PoolKey public poolKey;
    bool public skipAll;

    function setUp() public {
        // Skip silently if no RPC configured.
        try vm.envString("ARBITRUM_RPC_URL") returns (string memory rpc) {
            if (bytes(rpc).length == 0) { skipAll = true; return; }
            vm.createSelectFork(rpc);
        } catch {
            skipAll = true;
            return;
        }

        // Sanity: confirm canonical contracts have code on this fork.
        if (POOL_MANAGER.code.length == 0 || POSITION_MANAGER.code.length == 0) {
            skipAll = true;
            return;
        }

        vault = new LiquidityVault(
            IERC20(USDC),
            IPoolManager(POOL_MANAGER),
            IPositionManager(POSITION_MANAGER),
            "The Pool USDC LP",
            "tpUSDC",
            PERMIT2
        );

        // USDC sorts as currency1 vs WETH on Arbitrum (USDC > WETH addr-wise
        // here actually USDC=0xaf88... > WETH=0x82aF... so USDC = currency1).
        (address lo, address hi) = WETH < USDC ? (WETH, USDC) : (USDC, WETH);
        poolKey = PoolKey({
            currency0: Currency.wrap(lo),
            currency1: Currency.wrap(hi),
            fee: 500,
            tickSpacing: 10,
            hooks: IHooks(address(0))
        });
    }

    function _skipIfNoFork() internal {
        if (skipAll) {
            vm.skip(true);
        }
    }

    /// @notice Smoke: pool key set + deposit path compiles against the live
    ///         PoolManager / PositionManager / Permit2 surfaces. Uses a small
    ///         deposit to exercise the live integration.
    function test_fork_smoke_setPoolKeyAndDeposit() public {
        _skipIfNoFork();

        // Whitelist canonical USDC and seed alice with $100.
        deal(USDC, alice, 100e6);

        vault.setPoolKey(poolKey);

        vm.startPrank(alice);
        IERC20(USDC).approve(address(vault), type(uint256).max);
        // Deposit 50 USDC. This will route through the real PositionManager
        // and Permit2 against the real PoolManager.
        uint256 sharesBefore = vault.balanceOf(alice);
        vault.deposit(50e6, alice);
        uint256 sharesAfter = vault.balanceOf(alice);
        vm.stopPrank();

        assertGt(sharesAfter, sharesBefore, "shares minted");
        assertGt(vault.totalAssets(), 0, "totalAssets > 0");
    }

    /// @notice Confirm vaultStatus() against the live pool slot0 reflects
    ///         IN_RANGE or OUT_OF_RANGE consistently with the configured
    ///         tick window.
    function test_fork_vaultStatus_matchesLiveSlot0() public {
        _skipIfNoFork();
        vault.setPoolKey(poolKey);

        (uint160 sqrtP,,,) = IPoolManager(POOL_MANAGER).getSlot0(poolKey.toId());
        // Pool may not be initialized on this fee tier; if so skip.
        if (sqrtP == 0) { vm.skip(true); }

        LiquidityVault.VaultStatus status = vault.vaultStatus();
        // Just check the value is one of the expected non-PAUSED/UNCONFIGURED.
        assertTrue(
            status == LiquidityVault.VaultStatus.IN_RANGE ||
            status == LiquidityVault.VaultStatus.OUT_OF_RANGE,
            "live status well-defined"
        );
    }

    /// @notice Full deposit -> withdraw round trip on a live fork. Skipped
    ///         when the pool isn't initialized; the smoke test above covers
    ///         the cheaper path.
    function test_fork_depositWithdrawRoundTrip() public {
        _skipIfNoFork();
        vault.setPoolKey(poolKey);

        (uint160 sqrtP,,,) = IPoolManager(POOL_MANAGER).getSlot0(poolKey.toId());
        if (sqrtP == 0) { vm.skip(true); }

        deal(USDC, alice, 1_000e6);
        vm.startPrank(alice);
        IERC20(USDC).approve(address(vault), type(uint256).max);
        uint256 shares = vault.deposit(500e6, alice);
        assertGt(shares, 0);
        // Immediate withdraw — should round-trip with at most O(slippage) loss.
        uint256 navBefore = vault.totalAssets();
        vault.redeem(shares, alice, alice);
        vm.stopPrank();
        // Sanity: nav decreased to ~0 after redemption.
        assertLt(vault.totalAssets(), navBefore);
    }
}
