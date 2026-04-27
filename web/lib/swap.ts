// Universal Router v4 swap encoding for The-Pool's USDC/WETH pool.
//
// Targets the ALREADY-VERIFIED PoolKey:
//   currency0   = WETH  0x82aF...Bab1
//   currency1   = USDC  0xaf88...5831
//   fee         = 500   (literal 0.05%, NOT dynamic-fee sentinel)
//   tickSpacing = 10
//   hooks       = DynamicFeeHook 0x6207...00c4
//
// Flow:
//   1. User has Permit2 approval on the input token (one-time).
//   2. User has Permit2.approve(token, UniversalRouter, amount, expiry).
//   3. UR.execute(commands, inputs, deadline) where:
//        commands = [V4_SWAP] (0x10)
//        inputs[0] = abi.encode(actions, params[])
//          actions = [SWAP_EXACT_IN_SINGLE, SETTLE_ALL, TAKE_ALL]
//          params  = [ExactInputSingleParams, (currencyIn,amountIn), (currencyOut,minOut)]
//
// References (verified at ../../lib/v4-periphery/src/libraries/Actions.sol
// and Universal Router commands enum):
//   - V4_SWAP                = 0x10
//   - SWAP_EXACT_IN_SINGLE   = 0x06
//   - SETTLE_ALL             = 0x0c
//   - TAKE_ALL               = 0x0f

import {
  encodeAbiParameters,
  parseAbiParameters,
  encodePacked,
  type Address,
  type Hex,
} from 'viem';

export const COMMAND_V4_SWAP = 0x10;
export const ACTION_SWAP_EXACT_IN_SINGLE = 0x06;
export const ACTION_SETTLE_ALL = 0x0c;
export const ACTION_TAKE_ALL = 0x0f;

// MIN_SQRT_PRICE_LIMIT + 1 / MAX_SQRT_PRICE_LIMIT - 1 (TickMath bounds)
// In v4, swap params do not take a sqrtPriceLimit at the SWAP_EXACT_IN_SINGLE
// action level — the action passes only (key, zeroForOne, amountIn, minOut, hookData).
// The SwapMath uses extreme bounds internally.

export interface PoolKeyArg {
  currency0: Address;
  currency1: Address;
  fee: number;
  tickSpacing: number;
  hooks: Address;
}

export interface SwapPlan {
  poolKey: PoolKeyArg;
  zeroForOne: boolean;
  amountIn: bigint;          // exact input
  amountOutMinimum: bigint;  // slippage-protected floor
  currencyIn: Address;
  currencyOut: Address;
}

/**
 * Encode the (commands, inputs[]) tuple for UniversalRouter.execute().
 * Returns a single object the caller hands to wagmi's useWriteContract.
 */
export function encodeV4ExactInSingle(plan: SwapPlan): {
  commands: Hex;
  inputs: Hex[];
} {
  const commands = encodePacked(['uint8'], [COMMAND_V4_SWAP]);

  const actions = encodePacked(
    ['uint8', 'uint8', 'uint8'],
    [ACTION_SWAP_EXACT_IN_SINGLE, ACTION_SETTLE_ALL, ACTION_TAKE_ALL],
  );

  // params[0] — ExactInputSingleParams
  const swapParam = encodeAbiParameters(
    [
      {
        type: 'tuple',
        components: [
          {
            type: 'tuple',
            name: 'poolKey',
            components: [
              { name: 'currency0', type: 'address' },
              { name: 'currency1', type: 'address' },
              { name: 'fee', type: 'uint24' },
              { name: 'tickSpacing', type: 'int24' },
              { name: 'hooks', type: 'address' },
            ],
          },
          { name: 'zeroForOne', type: 'bool' },
          { name: 'amountIn', type: 'uint128' },
          { name: 'amountOutMinimum', type: 'uint128' },
          { name: 'hookData', type: 'bytes' },
        ],
      },
    ],
    [
      {
        poolKey: {
          currency0: plan.poolKey.currency0,
          currency1: plan.poolKey.currency1,
          fee: plan.poolKey.fee,
          tickSpacing: plan.poolKey.tickSpacing,
          hooks: plan.poolKey.hooks,
        },
        zeroForOne: plan.zeroForOne,
        amountIn: plan.amountIn,
        amountOutMinimum: plan.amountOutMinimum,
        hookData: '0x',
      },
    ],
  );

  // params[1] — (currencyIn, amountIn) for SETTLE_ALL
  const settleParam = encodeAbiParameters(
    parseAbiParameters('address,uint256'),
    [plan.currencyIn, plan.amountIn],
  );

  // params[2] — (currencyOut, amountOutMinimum) for TAKE_ALL
  const takeParam = encodeAbiParameters(
    parseAbiParameters('address,uint256'),
    [plan.currencyOut, plan.amountOutMinimum],
  );

  // V4_SWAP input = abi.encode(actions, params[])
  const v4SwapInput = encodeAbiParameters(
    parseAbiParameters('bytes,bytes[]'),
    [actions, [swapParam, settleParam, takeParam]],
  );

  return { commands, inputs: [v4SwapInput] };
}

/**
 * V4Quoter.quoteExactInputSingle is non-view (uses unlock callback) but
 * Arbitrum nodes simulate it cleanly via eth_call. wagmi's
 * `simulateContract` / `readContract` (with non-view ABI) returns
 * (amountOut, gasEstimate). We expose the typed param shape here.
 */
export function makeQuoteParams(plan: Pick<SwapPlan, 'poolKey' | 'zeroForOne' | 'amountIn'>) {
  return {
    poolKey: {
      currency0: plan.poolKey.currency0,
      currency1: plan.poolKey.currency1,
      fee: plan.poolKey.fee,
      tickSpacing: plan.poolKey.tickSpacing,
      hooks: plan.poolKey.hooks,
    },
    zeroForOne: plan.zeroForOne,
    exactAmount: plan.amountIn,
    hookData: '0x' as Hex,
  } as const;
}

/** Apply slippage as a floor: out * (10000 - bps) / 10000 */
export function applySlippage(amountOut: bigint, slippageBps: number): bigint {
  if (slippageBps <= 0) return amountOut;
  if (slippageBps >= 10_000) return 0n;
  return (amountOut * BigInt(10_000 - slippageBps)) / 10_000n;
}

/** uint160 max for "infinite" Permit2 allowance */
export const MAX_UINT_160: bigint = (1n << 160n) - 1n;

/** Default Permit2 expiry: now + 30 days */
export function defaultPermit2Expiry(): number {
  return Math.floor(Date.now() / 1000) + 60 * 60 * 24 * 30;
}

/** Default deadline: now + 20 minutes */
export function defaultSwapDeadline(): bigint {
  return BigInt(Math.floor(Date.now() / 1000) + 60 * 20);
}
