// SPDX-License-Identifier: MIT
pragma solidity >=0.8.24 <0.9.0;

import {BaseHook} from "./BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

interface IFeeDistributor {
    function distribute(Currency currency, uint256 amount) external;
}

contract DynamicFeeHook is BaseHook, Ownable2Step {
    using Math for uint256;
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    error InvalidSwapAmount();
    error PendingSwapMismatch(bytes32 expectedPoolId, bytes32 actualPoolId);
    error HookFeeExceedsReturnDelta(uint256 fee);

    uint24 public constant LP_FEE = 100;
    uint256 public constant HOOK_FEE_BPS = 25;
    uint256 public constant BPS_DENOMINATOR = 10_000;
    /// @dev Hard ceiling in BPS: hook fee can never exceed this fraction of amountIn.
    ///      Default 50 BPS (0.5%). Owner-adjustable. Currency-agnostic.
    uint256 public maxFeeBps = 50;

    uint256 private constant VOLATILITY_THRESHOLD_BPS = 100; // 1% inter-swap price move
    uint256 private constant VOLATILITY_FEE_MULTIPLIER = 150; // 1.5x fee in volatile regime

    // Transient slots: only the volatility multiplier and pool-id need to cross
    // beforeSwap -> afterSwap. The fee itself is now derived from BalanceDelta
    // inside afterSwap (Finding 2 fix), so PENDING_FEE_SLOT / PENDING_CURRENCY_SLOT
    // are no longer needed.
    uint256 private constant PENDING_MULTIPLIER_SLOT = 0xd1e54fc46e96497529fdb4b5abbcd802754a86c33bab838d6ce7d6ec96497b88;
    uint256 private constant PENDING_POOL_ID_SLOT   = 0x133a216bd676e8f955ffab19625ed7338b8d768a478c1f19ae573da66791ad78;
    uint256 private constant PENDING_ACTIVE_SLOT    = 0x9f335ffcc512b8308a51f958d03ae1d48e958c73fa34515db9db2ad5fb42cb6d;
    uint256 private constant MAX_AFTER_SWAP_RETURN_DELTA = uint256(uint128(type(int128).max));

    IFeeDistributor public feeDistributor;
    // Per-pool volatility oracle state (Finding 1 fix). The hook may be attached
    // to multiple pools; using global slots let an attacker initialize a side
    // pool, write an extreme sqrtPriceX96 into the shared slot via a tiny
    // (fee==0) swap, and force the 1.5x volatility multiplier on the next
    // legitimate swap of the canonical pool. Keying by PoolId isolates state.
    mapping(PoolId => uint160) private _lastSqrtPriceX96;
    mapping(PoolId => uint256) private _lastSwapBlock;
    uint256 public totalSwaps;
    uint256 public totalFeesRouted;

    event FeeRouted(address indexed currency, uint256 amount, uint256 swapIndex);
    event DistributorUpdated(address indexed old, address indexed newDistributor);
    event MaxFeeBpsUpdated(uint256 oldBps, uint256 newBps);

    /// @param _poolManager Uniswap v4 PoolManager
    /// @param _distributor FeeDistributor that will receive routed fees
    /// @param _owner Initial owner (cannot be address(0)). MUST be passed
    ///        explicitly because this contract is deployed via CREATE2 through
    ///        the Arachnid factory; using `msg.sender` here would lock the
    ///        owner to the factory address (irrecoverable).
    constructor(IPoolManager _poolManager, address _distributor, address _owner)
        BaseHook(_poolManager)
        Ownable(_owner)
    {
        require(_owner != address(0), "OWNER_ZERO");
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
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (address(key.hooks) != address(this)) {
            return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        // amountSpecified < 0  -> exact-input  (specified = input  / unspecified = output)
        // amountSpecified > 0  -> exact-output (specified = output / unspecified = input)
        // The afterSwap return-delta is applied to the UNSPECIFIED currency, so the
        // fee we charge in beforeSwap MUST be denominated in that same currency.
        if (params.amountSpecified == type(int256).min) revert InvalidSwapAmount();

        // Volatility multiplier is computed against per-pool reference price
        // (Finding 1 fix). We only stash the multiplier here -- the fee amount
        // itself is sized in afterSwap from BalanceDelta to avoid the
        // unit-mismatch DoS (Finding 2).
        PoolId pid = key.toId();
        uint256 multiplier = 100; // 1.0x default
        uint160 ref = _lastSqrtPriceX96[pid];
        if (ref != 0) {
            (uint160 currentSqrtPrice,,,) = poolManager.getSlot0(pid);
            uint256 d = currentSqrtPrice > ref ? currentSqrtPrice - ref : ref - currentSqrtPrice;
            if (d.mulDiv(BPS_DENOMINATOR, ref) >= VOLATILITY_THRESHOLD_BPS) {
                multiplier = VOLATILITY_FEE_MULTIPLIER;
            }
        }

        bytes32 poolId = PoolId.unwrap(pid);
        assembly {
            tstore(PENDING_MULTIPLIER_SLOT, multiplier)
            tstore(PENDING_POOL_ID_SLOT, poolId)
            tstore(PENDING_ACTIVE_SLOT, 1)
        }

        totalSwaps++;
        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function afterSwap(address, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        external
        override
        onlyPoolManager
        returns (bytes4, int128)
    {
        uint256 multiplier;
        uint256 active;
        bytes32 pendingPoolId;
        assembly {
            multiplier := tload(PENDING_MULTIPLIER_SLOT)
            pendingPoolId := tload(PENDING_POOL_ID_SLOT)
            active := tload(PENDING_ACTIVE_SLOT)
            tstore(PENDING_MULTIPLIER_SLOT, 0)
            tstore(PENDING_POOL_ID_SLOT, 0)
            tstore(PENDING_ACTIVE_SLOT, 0)
        }

        // No matching beforeSwap (foreign-pool callback / disabled path).
        // Importantly we do NOT refresh the volatility reference here:
        // a caller could attach this hook to a side pool and contaminate
        // the per-pool oracle by routing through afterSwap with active=0.
        if (active == 0) return (BaseHook.afterSwap.selector, 0);

        bytes32 actualPoolId = PoolId.unwrap(key.toId());
        if (pendingPoolId != actualPoolId) revert PendingSwapMismatch(pendingPoolId, actualPoolId);

        // Finding 2 fix: fee is sized from the actual unspecified-currency leg
        // of the BalanceDelta, so the unit matches the currency the hook is
        // about to take from the PoolManager. Computing fee from
        // |amountSpecified| (specified currency) and then taking it in the
        // unspecified currency caused a DoS on cross-decimal pairs (e.g.
        // WETH/USDC: 1e18 wei -> 2.5e15 raw USDC = $2.5B fee, take reverts).
        bool exactInput = params.amountSpecified < 0;
        // Unspecified-currency selection (matches v4 afterSwapReturnDelta):
        //   exactInput  + zeroForOne   -> unspecified = currency1 (output)
        //   exactInput  + oneForZero   -> unspecified = currency0 (output)
        //   exactOutput + zeroForOne   -> unspecified = currency0 (input)
        //   exactOutput + oneForZero   -> unspecified = currency1 (input)
        bool unspecIsCurrency1 = (params.zeroForOne == exactInput);
        Currency feeCurrency = unspecIsCurrency1 ? key.currency1 : key.currency0;
        int128 unspecDelta = unspecIsCurrency1 ? BalanceDeltaLibrary.amount1(delta) : BalanceDeltaLibrary.amount0(delta);
        uint256 absUnspec = unspecDelta < 0
            ? uint256(uint128(-unspecDelta))
            : uint256(uint128(unspecDelta));

        uint256 fee = absUnspec.mulDiv(HOOK_FEE_BPS, BPS_DENOMINATOR).mulDiv(multiplier, 100);
        uint256 feeCap = absUnspec.mulDiv(maxFeeBps, BPS_DENOMINATOR);
        if (fee > feeCap) fee = feeCap;

        if (fee == 0) {
            _refreshVolatilityReference(key);
            return (BaseHook.afterSwap.selector, 0);
        }

        if (fee > MAX_AFTER_SWAP_RETURN_DELTA) revert HookFeeExceedsReturnDelta(fee);

        poolManager.take(feeCurrency, address(this), fee);
        feeCurrency.transfer(address(feeDistributor), fee);

        feeDistributor.distribute(feeCurrency, fee);

        totalFeesRouted += fee;
        emit FeeRouted(Currency.unwrap(feeCurrency), fee, totalSwaps);

        _refreshVolatilityReference(key);

        return (BaseHook.afterSwap.selector, int128(uint128(fee)));
    }

    function _refreshVolatilityReference(PoolKey calldata key) internal {
        PoolId pid = key.toId();
        (uint160 sqrtAfter,,,) = poolManager.getSlot0(pid);
        // Only refresh the reference price at block boundaries.
        // Same-block sandwich: attacker's "reset" swap and "exploit" swap share the same block
        // -> _lastSqrtPriceX96[pid] does not update between them -> exploit swap still sees the
        // large inter-block price delta and pays the 1.5x volatility multiplier.
        if (block.number > _lastSwapBlock[pid]) {
            _lastSqrtPriceX96[pid] = sqrtAfter;
            _lastSwapBlock[pid] = block.number;
        }
    }

    function getSwapFeeInfo(uint256 amountIn)
        external
        view
        returns (uint256 feeAmount, uint256 feeBps, uint256 treasuryBps, uint256 lpBonusBps, string memory description)
    {
        feeAmount = amountIn.mulDiv(HOOK_FEE_BPS, BPS_DENOMINATOR);
        uint256 feeCap = amountIn.mulDiv(maxFeeBps, BPS_DENOMINATOR);
        if (feeAmount > feeCap) feeAmount = feeCap;

        feeBps = HOOK_FEE_BPS;
        treasuryBps = 5; // 20% of base 25 BPS
        lpBonusBps = 20; // 80% of base 25 BPS
        description =
            "Base: 5 BPS treasury / 20 BPS LP; Volatile 1.5x: fee multiplied by 150% before 20/80 split -- capped at maxFeeBps";
    }

    /// @notice Returns the volatility oracle parameters that govern the 1.5x fee multiplier.
    /// @dev    Anti-manipulation: lastSqrtPriceX96 is only refreshed once per block
    ///         (guarded by lastSwapBlock). A flash loan that shifts sqrtPriceX96
    ///         within the same block cannot update the reference price — the
    ///         attacker's own exploit swap already sees the pre-existing large delta
    ///         and pays the 1.5x multiplier, making the attack economically
    ///         self-defeating. The reference price therefore always lags at least one
    ///         block behind the current price, preventing intra-block oracle manipulation.
    function getVolatilityInfo(PoolKey calldata key)
        external
        view
        returns (uint256 thresholdBps, uint256 multiplierPct, uint160 referenceSqrtPriceX96, uint256 referenceBlock)
    {
        PoolId pid = key.toId();
        thresholdBps = VOLATILITY_THRESHOLD_BPS;
        multiplierPct = VOLATILITY_FEE_MULTIPLIER;
        referenceSqrtPriceX96 = _lastSqrtPriceX96[pid];
        referenceBlock = _lastSwapBlock[pid];
    }

    function getStats() external view returns (uint256, uint256, address) {
        return (totalSwaps, totalFeesRouted, address(feeDistributor));
    }

    function setMaxFeeBps(uint256 newBps) external onlyOwner {
        require(newBps <= 1000, "BPS_TOO_HIGH");
        emit MaxFeeBpsUpdated(maxFeeBps, newBps);
        maxFeeBps = newBps;
    }

    function setFeeDistributor(address newDistributor) external onlyOwner {
        require(newDistributor != address(0), "ZERO_ADDRESS");
        emit DistributorUpdated(address(feeDistributor), newDistributor);
        feeDistributor = IFeeDistributor(newDistributor);
    }
}
