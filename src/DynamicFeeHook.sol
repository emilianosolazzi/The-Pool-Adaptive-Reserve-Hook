// SPDX-License-Identifier: MIT
pragma solidity >=0.8.24 <0.9.0;

import {BaseHook} from "./BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IFeeDistributor {
    function distribute(Currency currency, uint256 amount) external;
}

contract DynamicFeeHook is BaseHook {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;

    uint24 public constant LP_FEE = 100;
    uint256 public constant HOOK_FEE_BPS = 30;
    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint256 public constant MAX_FEE_PER_SWAP = 0.02 ether;

    uint256 private constant PENDING_FEE_SLOT =
        0xd1e54fc46e96497529fdb4b5abbcd802754a86c33bab838d6ce7d6ec96497b88;
    uint256 private constant PENDING_CURRENCY_SLOT =
        0x2977767698129b4908fb9b19423b38883970765ad9aba8979e231f45612fa01e;

    IFeeDistributor public feeDistributor;
    uint256 public totalSwaps;
    uint256 public totalFeesRouted;

    event FeeRouted(address indexed currency, uint256 amount, uint256 swapIndex);
    event DistributorUpdated(address indexed old, address indexed newDistributor);

    constructor(IPoolManager _poolManager, address _distributor) BaseHook(_poolManager) {
        feeDistributor = IFeeDistributor(_distributor);
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (address(key.hooks) != address(this)) return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);

        uint256 amountIn = params.amountSpecified < 0 ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);
        uint256 fee = (amountIn * HOOK_FEE_BPS) / BPS_DENOMINATOR;

        if (fee > MAX_FEE_PER_SWAP) fee = MAX_FEE_PER_SWAP;

        Currency feeCurrency = params.zeroForOne ? key.currency1 : key.currency0;
        uint256 currencyAsUint = uint256(uint160(Currency.unwrap(feeCurrency)));

        assembly {
            tstore(PENDING_FEE_SLOT, fee)
            tstore(PENDING_CURRENCY_SLOT, currencyAsUint)
        }

        totalSwaps++;
        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function afterSwap(address, PoolKey calldata, SwapParams calldata, BalanceDelta, bytes calldata)
        external
        override
        returns (bytes4, int128)
    {
        uint256 fee;
        uint256 rawCurrency;
        assembly {
            fee := tload(PENDING_FEE_SLOT)
            rawCurrency := tload(PENDING_CURRENCY_SLOT)
            tstore(PENDING_FEE_SLOT, 0)
            tstore(PENDING_CURRENCY_SLOT, 0)
        }
        Currency feeCurrency = Currency.wrap(address(uint160(rawCurrency)));

        if (fee == 0) return (BaseHook.afterSwap.selector, 0);

        poolManager.take(feeCurrency, address(this), fee);
        feeCurrency.transfer(address(feeDistributor), fee);

        feeDistributor.distribute(feeCurrency, fee);

        totalFeesRouted += fee;
        emit FeeRouted(Currency.unwrap(feeCurrency), fee, totalSwaps);

        return (BaseHook.afterSwap.selector, int128(uint128(fee)));
    }

    function getSwapFeeInfo(uint256 amountIn)
        external
        pure
        returns (uint256 feeAmount, uint256 feeBps, uint256 treasuryBps, uint256 lpBonusBps, string memory description)
    {
        feeAmount = (amountIn * HOOK_FEE_BPS) / BPS_DENOMINATOR;
        if (feeAmount > MAX_FEE_PER_SWAP) feeAmount = MAX_FEE_PER_SWAP;

        feeBps = HOOK_FEE_BPS;
        treasuryBps = 10;
        lpBonusBps = 20;
        description = "0.01% Base LP + 0.30% Hook Fee (20% Treasury / 80% LP Bonus)";
    }

    function getStats() external view returns (uint256, uint256, address) {
        return (totalSwaps, totalFeesRouted, address(feeDistributor));
    }
}
