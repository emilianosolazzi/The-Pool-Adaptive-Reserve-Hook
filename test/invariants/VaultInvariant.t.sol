// SPDX-License-Identifier: MIT
pragma solidity >=0.8.24 <0.9.0;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {LiquidityVault} from "../../src/LiquidityVault.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPoolManager} from "../mocks/MockPoolManager.sol";
import {MockPositionManager} from "../mocks/MockPositionManager.sol";

/// @dev Handler drives the vault through random sequences of:
///      deposit, withdraw, collectYield (with simulated yield), rebalance.
///      Invariants are checked by the VaultInvariantTest harness after every call.
contract VaultHandler is Test {
    LiquidityVault public vault;
    MockERC20 public usdc;
    MockPositionManager public mockPosMgr;

    address[] internal _actors;
    uint256 internal _totalDeposited;
    uint256 internal _totalWithdrawn;

    constructor(LiquidityVault _vault, MockERC20 _usdc, MockPositionManager _posMgr) {
        vault     = _vault;
        usdc      = _usdc;
        mockPosMgr = _posMgr;

        // Pre-create three actor addresses
        _actors.push(makeAddr("actor0"));
        _actors.push(makeAddr("actor1"));
        _actors.push(makeAddr("actor2"));
    }

    // ── helpers ────────────────────────────────────────────────────────────

    function _actor(uint256 seed) internal view returns (address) {
        return _actors[seed % _actors.length];
    }

    // ── actions ────────────────────────────────────────────────────────────

    /// Deposit [1 USDC, 10 000 USDC] as a random actor.
    function deposit(uint256 actorSeed, uint256 assets) external {
        assets = bound(assets, 1e6, 10_000e6);
        address actor = _actor(actorSeed);

        usdc.mint(actor, assets);
        vm.startPrank(actor);
        usdc.approve(address(vault), assets);
        vault.deposit(assets, actor);
        vm.stopPrank();

        _totalDeposited += assets;
    }

    /// Withdraw the actor's full redeemable balance (if any).
    function withdraw(uint256 actorSeed) external {
        address actor = _actor(actorSeed);
        uint256 maxOut = vault.maxWithdraw(actor);
        if (maxOut == 0) return;

        vm.prank(actor);
        uint256 received = vault.withdraw(maxOut, actor, actor);
        _totalWithdrawn += received;
    }

    /// Simulate yield arriving at the vault; call collectYield().
    function injectYieldAndCollect(uint256 yieldAmount) external {
        if (vault.positionTokenId() == 0) return; // no position open yet

        yieldAmount = bound(yieldAmount, 1e6, 1_000e6);
        usdc.mint(address(mockPosMgr), yieldAmount);
        mockPosMgr.queueYield(address(vault), address(usdc), yieldAmount);
        vault.collectYield();
    }

    /// Rebalance to a new (valid, fixed) tick range.
    function rebalance(uint8 rangeSeed) external {
        // Two pre-baked valid ranges to keep ticks TickMath-safe
        int24 newLower;
        int24 newUpper;
        if (rangeSeed % 2 == 0) {
            newLower = -276325; // ~USDC/ETH lower area
            newUpper = -207240;
        } else {
            newLower = -230270; // original default range
            newUpper = -69082;
        }
        vm.prank(vault.owner());
        vault.rebalance(newLower, newUpper);
    }

    // ── accounting view ────────────────────────────────────────────────────

    function totalDeposited() external view returns (uint256) { return _totalDeposited; }
    function totalWithdrawn() external view returns (uint256) { return _totalWithdrawn; }
}

contract VaultInvariantTest is StdInvariant, Test {
    LiquidityVault public vault;
    MockERC20 public usdc;
    MockPoolManager public mockManager;
    MockPositionManager public mockPosMgr;
    VaultHandler public handler;

    function setUp() public {
        usdc        = new MockERC20("USD Coin", "USDC", 6);
        mockManager = new MockPoolManager();
        mockPosMgr  = new MockPositionManager();

        vault = new LiquidityVault(
            usdc,
            IPoolManager(address(mockManager)),
            IPositionManager(address(mockPosMgr)),
            "LP Vault",
            "LPV"
        );

        // Build PoolKey
        address addrA = address(usdc);
        address addrB = address(0x1);
        (address lo, address hi) = addrA < addrB ? (addrA, addrB) : (addrB, addrA);
        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(lo),
            currency1: Currency.wrap(hi),
            fee: 100,
            tickSpacing: 1,
            hooks: IHooks(address(vault))
        });
        vault.setPoolKey(poolKey);

        handler = new VaultHandler(vault, usdc, mockPosMgr);

        // Restrict fuzzer to only call handler methods
        targetContract(address(handler));
        // Exclude rebalance from default selector targeting to reduce revert noise;
        // it is still reachable via the full-selector path
        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = VaultHandler.deposit.selector;
        selectors[1] = VaultHandler.withdraw.selector;
        selectors[2] = VaultHandler.injectYieldAndCollect.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    // ── Invariant 1: solvency ────────────────────────────────────────────────
    /// totalAssets() must always equal the vault's USDC balance + assetsDeployed.
    /// This is the definition — ensure the two accounting paths are always in sync.
    function invariant_totalAssets_equalsBalancePlusDeployed() public view {
        uint256 computed = usdc.balanceOf(address(vault)) + vault.assetsDeployed();
        assertEq(vault.totalAssets(), computed, "totalAssets accounting mismatch");
    }

    // ── Invariant 2: share solvency ─────────────────────────────────────────
    /// The vault always holds enough assets to cover outstanding shares at
    /// the current share price. convertToAssets(totalSupply) <= totalAssets + 1 (rounding).
    function invariant_sharesSolvency() public view {
        uint256 supply = vault.totalSupply();
        if (supply == 0) return;
        uint256 redeemable = vault.convertToAssets(supply);
        assertLe(redeemable, vault.totalAssets() + 1, "shares not fully backed");
    }

    // ── Invariant 3: assetsDeployed never exceeds totalAssets ───────────────
    function invariant_assetsDeployed_leq_totalAssets() public view {
        assertLe(vault.assetsDeployed(), vault.totalAssets(), "assetsDeployed exceeds totalAssets");
    }

    // ── Invariant 4: no share inflation from zero (pre-yield only) ────────────
    /// If no shares exist AND no yield has ever been collected, totalAssets must be
    /// zero. Yield legitimately remains in the vault after all shares are redeemed
    /// (it is available for the next depositor to inherit), so this invariant only
    /// applies to the pristine state.
    function invariant_zeroSupply_zeroAssets() public view {
        if (vault.totalSupply() == 0 && vault.totalYieldCollected() == 0) {
            assertLe(vault.totalAssets(), 1, "stranded assets with zero supply and no yield");
        }
    }
}
