// Universal Router v4 swap encoding for The-Pool's USDC/WETH pool.
//
// Targets the ALREADY-VERIFIED PoolKey:
//   currency0   = WETH  0x82aF...Bab1
//   currency1   = USDC  0xaf88...5831
//   fee         = 500   (literal 0.05%, NOT dynamic-fee sentinel)
//   tickSpacing = 60
//   hooks       = DynamicFeeHookV2 (address comes from env/deployment config)
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

export const MAX_UINT_128: bigint = (1n << 128n) - 1n;

function assertUint128(value: bigint, label: string): void {
  if (value < 0n || value > MAX_UINT_128) {
    throw new Error(`${label}_OUT_OF_UINT128_RANGE`);
  }
}

function sameAddress(a: Address, b: Address): boolean {
  return a.toLowerCase() === b.toLowerCase();
}

/**
 * Infer zeroForOne from the input currency. v4 PoolKey requires
 * currency0 < currency1, so the direction is fully determined by
 * which side the user is paying in.
 */
export function inferZeroForOne(poolKey: PoolKeyArg, currencyIn: Address): boolean {
  if (sameAddress(currencyIn, poolKey.currency0)) return true;
  if (sameAddress(currencyIn, poolKey.currency1)) return false;
  throw new Error('INPUT_NOT_IN_POOL');
}

/**
 * Validate a SwapPlan against the target PoolKey before encoding.
 * Catches direction mismatches, zero amounts, uint128 overflow, and
 * tokens that are not part of the pool. Throws on any inconsistency.
 */
export function validateSwapPlan(plan: SwapPlan): void {
  assertUint128(plan.amountIn, 'AMOUNT_IN');
  assertUint128(plan.amountOutMinimum, 'AMOUNT_OUT_MINIMUM');
  if (plan.amountIn === 0n) throw new Error('ZERO_AMOUNT_IN');

  const inIs0 = sameAddress(plan.currencyIn, plan.poolKey.currency0);
  const inIs1 = sameAddress(plan.currencyIn, plan.poolKey.currency1);
  const outIs0 = sameAddress(plan.currencyOut, plan.poolKey.currency0);
  const outIs1 = sameAddress(plan.currencyOut, plan.poolKey.currency1);

  if (!(inIs0 || inIs1)) throw new Error('INPUT_NOT_IN_POOL');
  if (!(outIs0 || outIs1)) throw new Error('OUTPUT_NOT_IN_POOL');
  if (sameAddress(plan.currencyIn, plan.currencyOut)) throw new Error('SAME_TOKEN');

  const expectedZeroForOne = inIs0;
  if (plan.zeroForOne !== expectedZeroForOne) {
    throw new Error('ZERO_FOR_ONE_MISMATCH');
  }
}

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
  validateSwapPlan(plan);
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
