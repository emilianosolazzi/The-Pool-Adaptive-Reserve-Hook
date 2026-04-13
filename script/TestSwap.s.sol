// SPDX-License-Identifier: MIT
pragma solidity >=0.8.24 <0.9.0;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title SwapHelper — deployed on-chain to perform a swap through PoolManager's unlock pattern.
contract SwapHelper is IUnlockCallback {
    IPoolManager public immutable poolManager;

    constructor(IPoolManager _poolManager) {
        poolManager = _poolManager;
    }

    /// @notice Execute a swap. Caller must have approved this contract (via ERC20) for `amountIn`.
    function doSwap(
        PoolKey calldata key,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96
    ) external {
        bytes memory cbData = abi.encode(msg.sender, key, zeroForOne, amountSpecified, sqrtPriceLimitX96);
        poolManager.unlock(cbData);
    }

    function unlockCallback(bytes calldata rawData) external override returns (bytes memory) {
        require(msg.sender == address(poolManager), "NOT_PM");

        (
            address caller,
            PoolKey memory key,
            bool zeroForOne,
            int256 amountSpecified,
            uint160 sqrtPriceLimitX96
        ) = abi.decode(rawData, (address, PoolKey, bool, int256, uint160));

        BalanceDelta delta = poolManager.swap(key, SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: amountSpecified,
            sqrtPriceLimitX96: sqrtPriceLimitX96
        }), "");

        // Settle negative deltas (tokens owed TO the pool) and take positive deltas (owed FROM pool)
        int128 delta0 = delta.amount0();
        int128 delta1 = delta.amount1();

        if (delta0 < 0) {
            // We owe token0 to the pool
            uint256 owed = uint256(uint128(-delta0));
            poolManager.sync(key.currency0);
            IERC20(Currency.unwrap(key.currency0)).transferFrom(caller, address(poolManager), owed);
            poolManager.settle();
        }
        if (delta1 < 0) {
            uint256 owed = uint256(uint128(-delta1));
            poolManager.sync(key.currency1);
            IERC20(Currency.unwrap(key.currency1)).transferFrom(caller, address(poolManager), owed);
            poolManager.settle();
        }
        if (delta0 > 0) {
            uint256 owed = uint256(uint128(delta0));
            poolManager.take(key.currency0, caller, owed);
        }
        if (delta1 > 0) {
            uint256 owed = uint256(uint128(delta1));
            poolManager.take(key.currency1, caller, owed);
        }

        return "";
    }
}

/// @title TestSwap
/// @notice Deploys a SwapHelper and executes a test swap to trigger the DynamicFeeHook.
///
/// @dev Run:
///      forge script script/TestSwap.s.sol --tc TestSwap \
///        --rpc-url $ARBITRUM_TESTNET_RPC_URL --private-key $PRIVATE_KEY --broadcast
contract TestSwap is Script {
    function run() external {
        address poolManagerAddr = vm.envAddress("POOL_MANAGER");
        address token0 = vm.envAddress("TOKEN0");
        address token1 = vm.envAddress("TOKEN1");
        address hookAddr = vm.envAddress("HOOK");
        address distributor = vm.envAddress("FEE_DISTRIBUTOR");
        address vault = vm.envAddress("VAULT");

        IPoolManager poolManager = IPoolManager(poolManagerAddr);

        // Reconstruct the PoolKey (must match the deployed pool exactly)
        uint24 poolFee = uint24(vm.envOr("POOL_FEE", uint256(100)));
        int24 tickSpacing = int24(vm.envOr("TICK_SPACING", int256(1)));
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: poolFee,
            tickSpacing: tickSpacing,
            hooks: IHooks(hookAddr)
        });

        // Swap amount: 1000 units of token1 (buy token0 with token1 = !zeroForOne)
        // This makes sense since our liquidity is single-sided token0
        int256 amountIn = -1000;  // negative = exact input
        bool zeroForOne = false;  // token1 → token0

        // sqrtPriceLimitX96: for !zeroForOne, price goes UP, use MAX - 1
        uint160 sqrtPriceLimit = 1461446703485210103287273052203988822378723970341; // MAX_SQRT_PRICE - 1

        vm.startBroadcast();

        // 1. Deploy SwapHelper
        SwapHelper helper = new SwapHelper(poolManager);
        console2.log("SwapHelper deployed:", address(helper));

        // 2. Approve SwapHelper to pull token1 (input token)
        IERC20(token1).approve(address(helper), type(uint256).max);

        // 3. Execute swap
        helper.doSwap(key, zeroForOne, amountIn, sqrtPriceLimit);

        vm.stopBroadcast();

        // 4. Print results
        console2.log("\n=== Swap Complete ===");
        console2.log("Direction: TOKEN1 -> TOKEN0 (zeroForOne=false)");
        console2.log("Amount in: 1000 units of TOKEN1");

        // Check hook stats
        (bool success, bytes memory data) = hookAddr.staticcall(
            abi.encodeWithSignature("totalSwaps()")
        );
        if (success) {
            uint256 swaps = abi.decode(data, (uint256));
            console2.log("Hook totalSwaps:", swaps);
        }
        (success, data) = hookAddr.staticcall(
            abi.encodeWithSignature("totalFeesRouted()")
        );
        if (success) {
            uint256 fees = abi.decode(data, (uint256));
            console2.log("Hook totalFeesRouted:", fees);
        }
    }
}
