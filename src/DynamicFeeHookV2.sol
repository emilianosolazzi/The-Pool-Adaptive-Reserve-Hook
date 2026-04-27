// SPDX-License-Identifier: MIT
pragma solidity >=0.8.24 <0.9.0;

import {BaseHook} from "./BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {CurrencySettler} from "v4-core-test/utils/CurrencySettler.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

interface IFeeDistributorV2 {
    function distribute(Currency currency, uint256 amount) external;
}

/// @title  DynamicFeeHookV2
/// @notice V1 dynamic-fee hook + per-pool reserve-sale (limit-order) fills.
/// @dev    Reserve sale lets a registered vault offer single-sided inventory
///         to swappers AT a vault-chosen price. Fills happen in `beforeSwap`
///         via `toBeforeSwapDelta`, taking the swapper's input currency and
///         settling the vault's reserve currency back. Only exact-input swaps
///         qualify. Hook fee logic still applies to the AMM-routed remainder.
contract DynamicFeeHookV2 is BaseHook, Ownable2Step, ReentrancyGuard {
    using Math for uint256;
    using CurrencyLibrary for Currency;
    using CurrencySettler for Currency;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using SafeERC20 for IERC20;

    error InvalidSwapAmount();
    error PendingSwapMismatch(bytes32 expectedPoolId, bytes32 actualPoolId);
    error HookFeeExceedsReturnDelta(uint256 fee);
    error NotRegisteredVault();
    error OfferAlreadyActive();
    error OfferNotActive();
    error OfferExpired();
    error InvalidOffer();
    error UnknownPool();
    error VaultAlreadyRegistered();

    // ---------- Fee plumbing (mirrors V1) ----------
    uint24 public constant LP_FEE = 100;
    uint256 public constant HOOK_FEE_BPS = 25;
    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint256 public maxFeeBps = 50;

    uint256 private constant VOLATILITY_THRESHOLD_BPS = 100;
    uint256 private constant VOLATILITY_FEE_MULTIPLIER = 150;

    uint256 private constant PENDING_MULTIPLIER_SLOT = 0xd1e54fc46e96497529fdb4b5abbcd802754a86c33bab838d6ce7d6ec96497b88;
    uint256 private constant PENDING_POOL_ID_SLOT   = 0x133a216bd676e8f955ffab19625ed7338b8d768a478c1f19ae573da66791ad78;
    uint256 private constant PENDING_ACTIVE_SLOT    = 0x9f335ffcc512b8308a51f958d03ae1d48e958c73fa34515db9db2ad5fb42cb6d;
    uint256 private constant MAX_AFTER_SWAP_RETURN_DELTA = uint256(uint128(type(int128).max));
    uint256 private constant Q96 = 1 << 96;

    IFeeDistributorV2 public feeDistributor;
    mapping(PoolId => uint160) private _lastSqrtPriceX96;
    mapping(PoolId => uint256) private _lastSwapBlock;
    uint256 public totalSwaps;
    uint256 public totalFeesRouted;

    // ---------- Reserve-sale state ----------

    /// @notice Vault that may register / cancel / claim offers on a given pool.
    mapping(PoolId => address) public registeredVault;

    struct ReserveOffer {
        Currency sellCurrency;          // currency the vault is selling (held in escrow by hook)
        Currency buyCurrency;           // currency proceeds accumulate in
        uint128 sellRemaining;          // remaining inventory (units of sellCurrency)
        uint160 vaultSqrtPriceX96;      // vault's chosen exchange price
        uint64  expiry;                 // unix seconds; 0 = no expiry
        bool    sellingCurrency1;       // true if sellCurrency == key.currency1, else currency0
        bool    active;
    }

    mapping(PoolId => ReserveOffer) public offers;
    /// @notice proceedsOwed[vault][buyCurrency] -> claimable amount in hook custody.
    mapping(address => mapping(Currency => uint256)) public proceedsOwed;
    /// @notice escrowedReserve[vault][sellCurrency] -> in-escrow inventory.
    mapping(address => mapping(Currency => uint256)) public escrowedReserve;

    uint256 public totalReserveFills;
    uint256 public totalReserveSold;   // diagnostics; in sellCurrency units (not normalised)

    event FeeRouted(address indexed currency, uint256 amount, uint256 swapIndex);
    event DistributorUpdated(address indexed old, address indexed newDistributor);
    event MaxFeeBpsUpdated(uint256 oldBps, uint256 newBps);
    event VaultRegistered(bytes32 indexed poolId, address indexed vault);
    event VaultUnregistered(bytes32 indexed poolId, address indexed vault);
    event ReserveOfferCreated(
        bytes32 indexed poolId,
        address indexed vault,
        address sellCurrency,
        uint128 sellAmount,
        uint160 vaultSqrtPriceX96,
        uint64 expiry
    );
    event ReserveOfferCancelled(bytes32 indexed poolId, address indexed vault, uint128 returnedAmount);
    event ReserveFilled(
        bytes32 indexed poolId,
        address indexed vault,
        uint256 sellAmount,
        uint256 buyAmount,
        uint160 poolSqrtPriceX96
    );
    event ReserveProceedsClaimed(address indexed vault, address indexed currency, uint256 amount);

    constructor(IPoolManager _poolManager, address _distributor, address _owner)
        BaseHook(_poolManager)
        Ownable(_owner)
    {
        require(_owner != address(0), "OWNER_ZERO");
        feeDistributor = IFeeDistributorV2(_distributor);
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
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // -----------------------------------------------------------------
    // Vault registration
    // -----------------------------------------------------------------

    /// @notice Bind a vault as the sole reserve-offer manager for a pool.
    /// @dev    One-shot per pool: prevents owner from silently swapping out
    ///         the depositor's counterparty.
    function registerVault(PoolKey calldata key, address vault) external onlyOwner {
        require(vault != address(0), "ZERO_VAULT");
        PoolId pid = key.toId();
        if (registeredVault[pid] != address(0)) revert VaultAlreadyRegistered();
        registeredVault[pid] = vault;
        emit VaultRegistered(PoolId.unwrap(pid), vault);
    }

    // -----------------------------------------------------------------
    // Reserve offer lifecycle
    // -----------------------------------------------------------------

    /// @notice Create a one-sided reserve offer. Caller must be the registered
    ///         vault for the pool and must hold/approve `sellAmount` of
    ///         `sellCurrency` (one of the pool currencies) to this hook.
    /// @param  vaultSqrtPriceX96 vault's chosen sqrt-price (Uniswap encoding).
    ///         Fill rate token1/token0 = vaultSqrtPriceX96^2 / 2^192.
    function createReserveOffer(
        PoolKey calldata key,
        Currency sellCurrency,
        uint128 sellAmount,
        uint160 vaultSqrtPriceX96,
        uint64 expiry
    ) external nonReentrant {
        PoolId pid = key.toId();
        if (registeredVault[pid] != msg.sender) revert NotRegisteredVault();
        if (sellAmount == 0 || vaultSqrtPriceX96 == 0) revert InvalidOffer();
        // Match v4 pool bounds. Outside this range, fill-time math (which
        // multiplies sqrtP by sqrtP via two mulDiv steps) can overflow on
        // realistic inventory sizes and DoS the swap.
        if (vaultSqrtPriceX96 < TickMath.MIN_SQRT_PRICE) revert InvalidOffer();
        if (vaultSqrtPriceX96 >= TickMath.MAX_SQRT_PRICE) revert InvalidOffer();
        if (offers[pid].active) revert OfferAlreadyActive();

        bool sellsCurrency1;
        Currency buyCurrency;
        if (Currency.unwrap(sellCurrency) == Currency.unwrap(key.currency1)) {
            sellsCurrency1 = true;
            buyCurrency = key.currency0;
        } else if (Currency.unwrap(sellCurrency) == Currency.unwrap(key.currency0)) {
            sellsCurrency1 = false;
            buyCurrency = key.currency1;
        } else {
            revert UnknownPool();
        }

        // Pull reserve from vault into hook escrow.
        uint256 balBefore = IERC20(Currency.unwrap(sellCurrency)).balanceOf(address(this));
        IERC20(Currency.unwrap(sellCurrency)).safeTransferFrom(msg.sender, address(this), sellAmount);
        uint256 received = IERC20(Currency.unwrap(sellCurrency)).balanceOf(address(this)) - balBefore;
        require(received == sellAmount, "FEE_ON_TRANSFER_NOT_SUPPORTED");

        offers[pid] = ReserveOffer({
            sellCurrency: sellCurrency,
            buyCurrency: buyCurrency,
            sellRemaining: sellAmount,
            vaultSqrtPriceX96: vaultSqrtPriceX96,
            expiry: expiry,
            sellingCurrency1: sellsCurrency1,
            active: true
        });
        escrowedReserve[msg.sender][sellCurrency] += sellAmount;

        emit ReserveOfferCreated(
            PoolId.unwrap(pid), msg.sender, Currency.unwrap(sellCurrency), sellAmount, vaultSqrtPriceX96, expiry
        );
    }

    /// @notice Cancel an active offer; remaining inventory returns to vault.
    function cancelReserveOffer(PoolKey calldata key) external nonReentrant returns (uint128 returned) {
        PoolId pid = key.toId();
        if (registeredVault[pid] != msg.sender) revert NotRegisteredVault();
        ReserveOffer memory o = offers[pid];
        if (!o.active) revert OfferNotActive();

        returned = o.sellRemaining;
        delete offers[pid];

        if (returned > 0) {
            escrowedReserve[msg.sender][o.sellCurrency] -= returned;
            IERC20(Currency.unwrap(o.sellCurrency)).safeTransfer(msg.sender, returned);
        }
        emit ReserveOfferCancelled(PoolId.unwrap(pid), msg.sender, returned);
    }

    /// @notice Pull accumulated reserve-sale proceeds for `currency`.
    function claimReserveProceeds(Currency currency) external nonReentrant returns (uint256 amount) {
        amount = proceedsOwed[msg.sender][currency];
        if (amount == 0) return 0;
        proceedsOwed[msg.sender][currency] = 0;
        IERC20(Currency.unwrap(currency)).safeTransfer(msg.sender, amount);
        emit ReserveProceedsClaimed(msg.sender, Currency.unwrap(currency), amount);
    }

    // -----------------------------------------------------------------
    // Swap hooks
    // -----------------------------------------------------------------

    function beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external
        override
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (address(key.hooks) != address(this)) {
            return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }
        if (params.amountSpecified == type(int256).min) revert InvalidSwapAmount();

        PoolId pid = key.toId();

        // ----- Reserve-sale fill (exact-input only) -----
        BeforeSwapDelta hookDelta = BeforeSwapDeltaLibrary.ZERO_DELTA;
        if (params.amountSpecified < 0) {
            hookDelta = _tryFillReserve(key, pid, params);
        }

        // ----- Volatility multiplier (per-pool oracle) -----
        uint256 multiplier = 100;
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
        return (BaseHook.beforeSwap.selector, hookDelta, 0);
    }

    /// @dev Attempts to fill from a registered reserve offer for the pool.
    ///      Conditions: exact-input, swap direction matches offer side, current
    ///      sqrtPrice satisfies the gate (offer is good for swapper vs AMM
    ///      marginal price), offer not expired.
    function _tryFillReserve(PoolKey calldata key, PoolId pid, SwapParams calldata params)
        internal
        returns (BeforeSwapDelta)
    {
        ReserveOffer storage o = offers[pid];
        if (!o.active || o.sellRemaining == 0) return BeforeSwapDeltaLibrary.ZERO_DELTA;
        if (o.expiry != 0 && block.timestamp > o.expiry) return BeforeSwapDeltaLibrary.ZERO_DELTA;

        // Direction check: vault sells currency1 -> only fillable on zeroForOne
        // (swapper pays token0, gets token1 from vault).
        // Vault sells currency0 -> only fillable on oneForZero.
        if (o.sellingCurrency1 != params.zeroForOne) return BeforeSwapDeltaLibrary.ZERO_DELTA;

        (uint160 poolSqrtP,,,) = poolManager.getSlot0(pid);
        if (poolSqrtP == 0) return BeforeSwapDeltaLibrary.ZERO_DELTA;

        // Price gate: only fill when offer is at-or-better than AMM for swapper.
        // - selling currency1 (zeroForOne): need poolSqrtP <= vaultSqrtP
        //   (vault gives more token1 per token0 than AMM -> swapper benefits).
        // - selling currency0 (oneForZero): need poolSqrtP >= vaultSqrtP.
        if (o.sellingCurrency1) {
            if (poolSqrtP > o.vaultSqrtPriceX96) return BeforeSwapDeltaLibrary.ZERO_DELTA;
        } else {
            if (poolSqrtP < o.vaultSqrtPriceX96) return BeforeSwapDeltaLibrary.ZERO_DELTA;
        }

        uint256 maxInput = uint256(-params.amountSpecified);
        if (maxInput == 0) return BeforeSwapDeltaLibrary.ZERO_DELTA;

        // ----- Overflow-safe price math -----
        // Price P = sqrtP^2 / 2^192. We never materialise sqrtP * sqrtP
        // (would overflow uint256 at sqrtP > 2^128). Instead we compose two
        // FullMath.mulDiv steps against Q96. All intermediate values stay
        // in 512-bit range, which FullMath supports natively.
        //
        // Two cases:
        //   sellingCurrency1 (zeroForOne): give_token1 = take_token0 * P
        //                                  takeCap    = sellRemaining / P
        //   sellingCurrency0 (oneForZero): give_token0 = take_token1 / P
        //                                  takeCap    = sellRemaining * P
        //
        // Inventory exhaustion path is handled exactly: when maxInput >= takeCap
        // we hand out the full sellRemaining and only consume `takeCap` of input.
        // Partial-fill path uses round-down at every step, so giveAmount is
        // strictly < sellRemaining whenever takeAmount < takeCap, which we
        // enforce as an invariant via require below.
        uint256 sqrtP = uint256(o.vaultSqrtPriceX96);
        uint256 takeCap;
        uint256 takeAmount;
        uint256 giveAmount;
        Currency inputCurrency;
        Currency outputCurrency;

        if (o.sellingCurrency1) {
            // zeroForOne. input=token0, output=token1=sellCurrency.
            inputCurrency = key.currency0;
            outputCurrency = key.currency1;

            // takeCap = sellRemaining * 2^192 / sqrtP^2
            //         = (sellRemaining * 2^96 / sqrtP) * 2^96 / sqrtP
            uint256 t1 = FullMath.mulDiv(uint256(o.sellRemaining), Q96, sqrtP);
            takeCap = FullMath.mulDiv(t1, Q96, sqrtP);

            if (maxInput >= takeCap) {
                // Inventory exhaustion: hand out all remaining sellCurrency,
                // consume only takeCap of input. Caller's residual goes to AMM.
                takeAmount = takeCap;
                giveAmount = uint256(o.sellRemaining);
            } else {
                takeAmount = maxInput;
                // give = take * sqrtP^2 / 2^192
                //      = (take * sqrtP / 2^96) * sqrtP / 2^96
                uint256 m1 = FullMath.mulDiv(takeAmount, sqrtP, Q96);
                giveAmount = FullMath.mulDiv(m1, sqrtP, Q96);
                // Invariant: round-down at every step => giveAmount < sellRemaining
                // whenever takeAmount < takeCap. If this ever fires the math is wrong.
                require(giveAmount <= uint256(o.sellRemaining), "RESERVE_MATH");
            }
        } else {
            // oneForZero. input=token1, output=token0=sellCurrency.
            inputCurrency = key.currency1;
            outputCurrency = key.currency0;

            // takeCap = sellRemaining * sqrtP^2 / 2^192
            //         = (sellRemaining * sqrtP / 2^96) * sqrtP / 2^96
            uint256 t2 = FullMath.mulDiv(uint256(o.sellRemaining), sqrtP, Q96);
            takeCap = FullMath.mulDiv(t2, sqrtP, Q96);

            if (maxInput >= takeCap) {
                takeAmount = takeCap;
                giveAmount = uint256(o.sellRemaining);
            } else {
                takeAmount = maxInput;
                // give = take * 2^192 / sqrtP^2
                //      = (take * 2^96 / sqrtP) * 2^96 / sqrtP
                uint256 m2 = FullMath.mulDiv(takeAmount, Q96, sqrtP);
                giveAmount = FullMath.mulDiv(m2, Q96, sqrtP);
                require(giveAmount <= uint256(o.sellRemaining), "RESERVE_MATH");
            }
        }

        if (takeAmount == 0 || giveAmount == 0) return BeforeSwapDeltaLibrary.ZERO_DELTA;

        // Bounds: BeforeSwapDelta legs are int128.
        if (takeAmount > uint256(uint128(type(int128).max))) return BeforeSwapDeltaLibrary.ZERO_DELTA;
        if (giveAmount > uint256(uint128(type(int128).max))) return BeforeSwapDeltaLibrary.ZERO_DELTA;

        // Settle with PoolManager: hook receives input from caller, hook gives output to caller.
        poolManager.take(inputCurrency, address(this), takeAmount);
        outputCurrency.settle(poolManager, address(this), giveAmount, false);

        // Accounting.
        address vault = registeredVault[pid];
        o.sellRemaining -= uint128(giveAmount);
        escrowedReserve[vault][o.sellCurrency] -= giveAmount;
        proceedsOwed[vault][o.buyCurrency] += takeAmount;
        if (o.sellRemaining == 0) o.active = false;

        totalReserveFills++;
        totalReserveSold += giveAmount;
        emit ReserveFilled(PoolId.unwrap(pid), vault, giveAmount, takeAmount, poolSqrtP);

        // BeforeSwapDelta:
        //   specified = +takeAmount (hook absorbed `take` of input)
        //   unspecified = -giveAmount (hook owed `give` of output, settled via PM credit)
        return toBeforeSwapDelta(int128(int256(takeAmount)), -int128(int256(giveAmount)));
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
        if (active == 0) return (BaseHook.afterSwap.selector, 0);

        bytes32 actualPoolId = PoolId.unwrap(key.toId());
        if (pendingPoolId != actualPoolId) revert PendingSwapMismatch(pendingPoolId, actualPoolId);

        bool exactInput = params.amountSpecified < 0;
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
        if (address(feeDistributor) != address(0)) {
            feeCurrency.transfer(address(feeDistributor), fee);
            feeDistributor.distribute(feeCurrency, fee);
        }

        totalFeesRouted += fee;
        emit FeeRouted(Currency.unwrap(feeCurrency), fee, totalSwaps);

        _refreshVolatilityReference(key);
        return (BaseHook.afterSwap.selector, int128(uint128(fee)));
    }

    function _refreshVolatilityReference(PoolKey calldata key) internal {
        PoolId pid = key.toId();
        (uint160 sqrtAfter,,,) = poolManager.getSlot0(pid);
        if (block.number > _lastSwapBlock[pid]) {
            _lastSqrtPriceX96[pid] = sqrtAfter;
            _lastSwapBlock[pid] = block.number;
        }
    }

    // -----------------------------------------------------------------
    // Diagnostics / admin
    // -----------------------------------------------------------------

    function getOffer(PoolKey calldata key) external view returns (ReserveOffer memory) {
        return offers[key.toId()];
    }

    function setMaxFeeBps(uint256 newBps) external onlyOwner {
        require(newBps <= 1000, "BPS_TOO_HIGH");
        emit MaxFeeBpsUpdated(maxFeeBps, newBps);
        maxFeeBps = newBps;
    }

    function setFeeDistributor(address newDistributor) external onlyOwner {
        emit DistributorUpdated(address(feeDistributor), newDistributor);
        feeDistributor = IFeeDistributorV2(newDistributor);
    }

    function getStats() external view returns (uint256, uint256, address, uint256, uint256) {
        return (totalSwaps, totalFeesRouted, address(feeDistributor), totalReserveFills, totalReserveSold);
    }
}
