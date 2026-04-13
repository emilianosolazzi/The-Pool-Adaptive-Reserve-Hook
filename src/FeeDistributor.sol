// SPDX-License-Identifier: MIT
pragma solidity >=0.8.24 <0.9.0;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract FeeDistributor is Ownable2Step, ReentrancyGuard {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;

    uint256 public constant TREASURY_SHARE = 20;
    uint256 public constant LP_SHARE = 80;
    uint256 public constant SHARE_DENOMINATOR = 100;

    IPoolManager public immutable poolManager;
    address public hook;
    address public treasury;
    PoolKey public poolKey;

    bool private _poolKeySet;
    uint256 public totalDistributed;
    uint256 public totalToTreasury;
    uint256 public totalToLPs;
    uint256 public distributionCount;

    event FeeDistributed(address indexed currency, uint256 total, uint256 treasury, uint256 lp, uint256 id);
    event PoolKeySet(bytes32 indexed poolId);
    event HookUpdated(address indexed old, address indexed newHook);
    event TreasuryUpdated(address indexed old, address indexed newTreasury);

    constructor(IPoolManager _poolManager, address _treasury, address _hook) Ownable(msg.sender) {
        require(_treasury != address(0), "ZERO_ADDRESS");
        poolManager = _poolManager;
        treasury = _treasury;
        hook = _hook;
    }

    function distribute(Currency currency, uint256 amount) external nonReentrant {
        require(msg.sender == hook, "ONLY_HOOK");
        require(_poolKeySet, "POOL_KEY_NOT_SET");
        require(amount > 0, "ZERO_AMOUNT");

        uint256 treasuryAmount = (amount * TREASURY_SHARE) / SHARE_DENOMINATOR;
        uint256 lpAmount = amount - treasuryAmount;

        currency.transfer(treasury, treasuryAmount);
        totalToTreasury += treasuryAmount;

        bool isToken0 = (currency == poolKey.currency0);
        uint256 amount0 = isToken0 ? lpAmount : 0;
        uint256 amount1 = isToken0 ? 0 : lpAmount;

        poolManager.sync(currency);
        currency.transfer(address(poolManager), lpAmount);
        poolManager.settle();
        poolManager.donate(poolKey, amount0, amount1, "");

        totalToLPs += lpAmount;
        distributionCount++;
        totalDistributed += amount;

        emit FeeDistributed(Currency.unwrap(currency), amount, treasuryAmount, lpAmount, distributionCount);
    }

    function setPoolKey(PoolKey calldata _poolKey) external onlyOwner {
        require(!_poolKeySet, "ALREADY_SET");
        poolKey = _poolKey;
        _poolKeySet = true;
        emit PoolKeySet(PoolId.unwrap(_poolKey.toId()));
    }

    function setHook(address _newHook) external onlyOwner {
        require(_newHook != address(0), "ZERO_ADDRESS");
        address oldHook = hook;
        hook = _newHook;
        emit HookUpdated(oldHook, _newHook);
    }

    function setTreasury(address _newTreasury) external onlyOwner {
        require(_newTreasury != address(0), "ZERO_ADDRESS");
        address oldTreasury = treasury;
        treasury = _newTreasury;
        emit TreasuryUpdated(oldTreasury, _newTreasury);
    }

    function getLPYieldSummary() external view returns (
        uint256 lpBonusRate,
        uint256 totalLPBonusPaid,
        uint256 totalTreasuryPaid,
        uint256 distributions
    ) {
        return (20, totalToLPs, totalToTreasury, distributionCount);
    }
}
