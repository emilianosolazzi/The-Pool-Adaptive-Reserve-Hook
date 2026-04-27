// SPDX-License-Identifier: MIT
pragma solidity >=0.8.24 <0.9.0;

import {Test, console2} from "forge-std/Test.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

import {LiquidityVaultV2} from "../src/LiquidityVaultV2.sol";
import {SwapRouter02ZapAdapter, ISwapRouter02ExactInputSingle} from "../src/SwapRouter02ZapAdapter.sol";

/// @notice Arbitrum fork coverage for the V2 USDC zap path.
/// @dev Skips automatically when ARBITRUM_RPC_URL is not configured.
contract LiquidityVaultV2ForkTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address constant POOL_MANAGER = 0x360E68faCcca8cA495c1B759Fd9EEe466db9FB32;
    address constant POSITION_MANAGER = 0xd88F38F930b7952f2DB2432Cb002E7abbF3dD869;
    address constant SWAP_ROUTER_02 = 0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45;
    address constant WETH = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
    address constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address constant HOOK = 0x453CFf45DAC5116f8D49f7cfE6AEB56107a780c4;

    uint24 constant HOOKED_POOL_FEE = 500;
    int24 constant HOOKED_TICK_SPACING = 60;
    uint24 constant EXTERNAL_V3_FEE = 500;

    LiquidityVaultV2 public vault;
    SwapRouter02ZapAdapter public zapAdapter;
    PoolKey public poolKey;
    address public alice = makeAddr("alice_v2_fork");
    bool public skipAll;

    function setUp() public {
        try vm.envString("ARBITRUM_RPC_URL") returns (string memory rpc) {
            if (bytes(rpc).length == 0) {
                skipAll = true;
                return;
            }
            vm.createSelectFork(rpc);
        } catch {
            skipAll = true;
            return;
        }

        if (POOL_MANAGER.code.length == 0 || POSITION_MANAGER.code.length == 0 || SWAP_ROUTER_02.code.length == 0) {
            skipAll = true;
            return;
        }

        poolKey = PoolKey({
            currency0: Currency.wrap(WETH),
            currency1: Currency.wrap(USDC),
            fee: HOOKED_POOL_FEE,
            tickSpacing: HOOKED_TICK_SPACING,
            hooks: IHooks(HOOK)
        });

        (uint160 sqrtPriceX96, int24 currentTick,,) = IPoolManager(POOL_MANAGER).getSlot0(poolKey.toId());
        if (sqrtPriceX96 == 0) {
            skipAll = true;
            return;
        }

        zapAdapter = new SwapRouter02ZapAdapter(ISwapRouter02ExactInputSingle(SWAP_ROUTER_02), EXTERNAL_V3_FEE);

        vault = new LiquidityVaultV2(
            IERC20(USDC),
            IPoolManager(POOL_MANAGER),
            IPositionManager(POSITION_MANAGER),
            "The Pool Zap LP Vault",
            "pZAP-LPV",
            PERMIT2,
            address(zapAdapter)
        );
        vault.setPoolKey(poolKey);

        int24 baseTick = _floorToSpacing(currentTick, HOOKED_TICK_SPACING);
        vault.rebalance(baseTick - HOOKED_TICK_SPACING, baseTick + (HOOKED_TICK_SPACING * 2), 0);
        console2.log("fork currentTick:", int256(currentTick));
        console2.log("fork tickLower  :", int256(vault.tickLower()));
        console2.log("fork tickUpper  :", int256(vault.tickUpper()));
    }

    function testFork_depositWithZap_swapsViaExternalV3AndMintsLiveV4Liquidity() public {
        _skipIfNoFork();

        uint256 depositAmount = 100e6;
        uint256 swapAmount = 50e6;
        deal(USDC, alice, depositAmount);

        vm.startPrank(alice);
        IERC20(USDC).approve(address(vault), type(uint256).max);
        uint256 shares = vault.depositWithZap(depositAmount, alice, swapAmount, 1, 1, 0, block.timestamp + 300);
        vm.stopPrank();

        assertGt(shares, 0, "shares minted");
        assertGt(vault.totalLiquidityDeployed(), 0, "live v4 liquidity minted");
        assertGt(vault.positionTokenId(), 0, "position NFT tracked");
        assertEq(uint256(vault.vaultStatus()), uint256(LiquidityVaultV2.VaultStatus.IN_RANGE), "vault active");
        assertGt(vault.totalAssets(), 0, "NAV positive");
    }

    function testFork_withdrawWithZap_convertsOtherTokenBackToUSDC() public {
        _skipIfNoFork();

        uint256 depositAmount = 100e6;
        uint256 swapAmount = 50e6;
        uint256 withdrawAmount = 80e6;
        deal(USDC, alice, depositAmount);

        vm.startPrank(alice);
        IERC20(USDC).approve(address(vault), type(uint256).max);
        vault.depositWithZap(depositAmount, alice, swapAmount, 1, 1, 0, block.timestamp + 300);

        uint256 usdcBefore = IERC20(USDC).balanceOf(alice);
        uint256 sharesBurned = vault.withdrawWithZap(
            withdrawAmount,
            alice,
            alice,
            type(uint160).max,
            1,
            block.timestamp + 300
        );
        vm.stopPrank();

        assertGt(sharesBurned, 0, "shares burned");
        assertEq(IERC20(USDC).balanceOf(alice), usdcBefore + withdrawAmount, "USDC returned");
        assertGt(vault.balanceOf(alice), 0, "partial shares remain");
    }

    function _skipIfNoFork() internal {
        if (skipAll) vm.skip(true);
    }

    function _floorToSpacing(int24 tick, int24 spacing) internal pure returns (int24) {
        int24 compressed = tick / spacing;
        if (tick < 0 && tick % spacing != 0) compressed--;
        return compressed * spacing;
    }
}