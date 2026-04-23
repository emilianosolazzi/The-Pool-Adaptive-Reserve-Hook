// SPDX-License-Identifier: MIT
pragma solidity >=0.8.24 <0.9.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title BootstrapRewards
/// @notice Early-depositor bonus program for The Pool's LiquidityVault.
///
/// Implements the spec in docs/BOOTSTRAP.md:
///   - Accepts the treasury stream from FeeDistributor (this contract becomes
///     the FeeDistributor.treasury for the program window).
///   - Splits incoming payout-asset inflows: BONUS_SHARE bps into the active
///     epoch's bonus pool (capped), the remainder forwarded to the real
///     treasury immediately.
///   - Tracks eligible share-seconds per depositor using a lazy poke model.
///   - Pays rewards pull-style via claim(epoch).
///
/// Design notes:
///   - Eligibility is tracked by the address holding vault shares. Transferring
///     shares drops that address's live balance and therefore its share-second
///     accrual (shares_eligible = min(vault.balanceOf(user), perWalletCap)).
///   - Minimum 7-day dwell: firstDepositTime[user] is set when poke first sees
///     a non-zero balance; accrual starts only after firstDepositTime + DWELL.
///     If balance returns to 0, firstDepositTime resets.
///   - Lazy accounting: poke(user) credits share-seconds from lastPoke[user]
///     up to min(now, currentEpochEnd) using the user's balance AT THE TIME
///     OF THE LAST POKE. This is a conservative accounting choice: balance
///     changes between pokes are attributed to the *old* balance for the
///     unpoked interval. Front-ends should call poke on deposit/withdraw.
///   - Non-payout-asset inflows (FeeDistributor can route any swap currency
///     to treasury) are swept by sweepToken() to the real treasury. Only the
///     payout asset funds the bonus pool.
contract BootstrapRewards is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ---------------------------------------------------------------
    // Immutable / constructor config
    // ---------------------------------------------------------------

    /// @notice Vault whose ERC-20 shares grant eligibility (e.g. LiquidityVault).
    IERC20 public immutable vault;

    /// @notice Asset in which bonuses are paid (vault.asset(), e.g. USDC).
    IERC20 public immutable payoutAsset;

    /// @notice Where the non-bonus portion of every inflow is forwarded,
    ///         and where unclaimed / post-program dust sweeps.
    address public realTreasury;

    /// @notice Start timestamp of the program. Epoch 0 opens at programStart.
    uint64 public immutable programStart;

    /// @notice Length of each epoch in seconds (30 days per spec).
    uint64 public immutable epochLength;

    /// @notice Total number of epochs (6 per spec).
    uint32 public immutable epochCount;

    /// @notice Minimum continuous dwell before share-seconds accrue (7 days).
    uint64 public immutable dwellPeriod;

    /// @notice Claim window after an epoch ends; unclaimed sweeps thereafter.
    uint64 public immutable claimWindow;

    /// @notice Grace period after epochEnd during which only poke() is
    ///         accepted; claims open at epochEnd + finalizationDelay. This
    ///         removes the order-dependency in totalShareSeconds: if any
    ///         user poked between epochEnd and finalization, every other
    ///         user can also poke retroactively to that epochEnd before any
    ///         claim is processed. Frontends should batch-poke all known
    ///         depositors in this window.
    uint64 public immutable finalizationDelay;

    /// @notice Fraction of each inflow (in BPS) routed into the bonus pool.
    ///         Remainder is forwarded to realTreasury. 5000 = 50%.
    uint16 public immutable bonusShareBps;

    /// @notice Max payout asset added to a single epoch's bonus pool.
    uint256 public immutable perEpochCap;

    /// @notice Max eligible shares per wallet (in vault share units).
    uint256 public immutable perWalletShareCap;

    /// @notice Max cumulative eligible shares across all wallets (TVL cap in
    ///         vault share units). When exceeded, new share-seconds stop
    ///         accruing globally. Set to type(uint256).max to disable.
    uint256 public immutable globalShareCap;

    // ---------------------------------------------------------------
    // Per-user state
    // ---------------------------------------------------------------

    struct UserInfo {
        uint128 lastBalance;         // vault share balance at lastPoke
        uint64 lastPoke;              // timestamp of last poke
        uint64 firstDepositTime;      // when current continuous position started
    }

    mapping(address => UserInfo) public users;

    /// @notice user => epoch => accrued share-seconds (scaled to 1e18 for precision
    ///         when dividing by totalShareSeconds).
    mapping(address => mapping(uint256 => uint256)) public userEpochShareSeconds;

    /// @notice user => epoch => claimed flag.
    mapping(address => mapping(uint256 => bool)) public claimed;

    // ---------------------------------------------------------------
    // Per-epoch state
    // ---------------------------------------------------------------

    struct EpochInfo {
        uint128 bonusPool;           // payout-asset units earmarked for this epoch
        uint128 claimedAmount;       // cumulative claimed from bonusPool
        uint256 totalShareSeconds;   // sum of userEpochShareSeconds across users
        bool swept;                  // true once unclaimed dust swept to realTreasury
    }

    mapping(uint256 => EpochInfo) public epochs;

    // ---------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------

    event InflowReceived(uint256 totalAmount, uint256 toBonus, uint256 toTreasury, uint256 indexed epoch);
    event BonusPoolCapped(uint256 indexed epoch, uint256 overflow);
    event Poked(address indexed user, uint256 indexed epoch, uint256 shareSecondsDelta, uint256 eligibleShares);
    event Claimed(address indexed user, uint256 indexed epoch, uint256 amount);
    event EpochSwept(uint256 indexed epoch, uint256 unclaimed);
    event RealTreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    event ForeignTokenSwept(address indexed token, uint256 amount);
    event ProgramEnded(uint256 indexed finalEpoch, uint256 timestamp);

    // ---------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------

    error InvalidConfig();
    error EpochNotFinalized();
    error EpochAlreadySwept();
    error ClaimWindowClosed();
    error AlreadyClaimed();
    error NothingToClaim();
    error ProgramNotStarted();
    error ProgramOver();
    error ZeroAddress();
    error CannotSweepPayoutAsset();

    // ---------------------------------------------------------------
    // Constructor
    // ---------------------------------------------------------------

    struct Config {
        IERC20 vault;
        IERC20 payoutAsset;
        address realTreasury;
        uint64 programStart;
        uint64 epochLength;
        uint32 epochCount;
        uint64 dwellPeriod;
        uint64 claimWindow;
        uint64 finalizationDelay;
        uint16 bonusShareBps;
        uint256 perEpochCap;
        uint256 perWalletShareCap;
        uint256 globalShareCap;
    }

    constructor(Config memory cfg) Ownable(msg.sender) {
        if (address(cfg.vault) == address(0)) revert ZeroAddress();
        if (address(cfg.payoutAsset) == address(0)) revert ZeroAddress();
        if (cfg.realTreasury == address(0)) revert ZeroAddress();
        if (cfg.epochLength == 0 || cfg.epochCount == 0) revert InvalidConfig();
        if (cfg.bonusShareBps > 10_000) revert InvalidConfig();
        if (cfg.programStart == 0) revert InvalidConfig();
        if (cfg.perEpochCap == 0) revert InvalidConfig();
        if (cfg.perWalletShareCap == 0) revert InvalidConfig();
        if (cfg.globalShareCap == 0) revert InvalidConfig();

        vault = cfg.vault;
        payoutAsset = cfg.payoutAsset;
        realTreasury = cfg.realTreasury;
        programStart = cfg.programStart;
        epochLength = cfg.epochLength;
        epochCount = cfg.epochCount;
        dwellPeriod = cfg.dwellPeriod;
        claimWindow = cfg.claimWindow;
        finalizationDelay = cfg.finalizationDelay;
        bonusShareBps = cfg.bonusShareBps;
        perEpochCap = cfg.perEpochCap;
        perWalletShareCap = cfg.perWalletShareCap;
        globalShareCap = cfg.globalShareCap;
    }

    // ---------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------

    function programEnd() public view returns (uint256) {
        return uint256(programStart) + uint256(epochLength) * uint256(epochCount);
    }

    /// @notice Returns the current epoch index, or type(uint256).max if the
    ///         program has not started or has ended.
    function currentEpoch() public view returns (uint256) {
        if (block.timestamp < programStart) return type(uint256).max;
        uint256 elapsed = block.timestamp - programStart;
        uint256 idx = elapsed / epochLength;
        if (idx >= epochCount) return type(uint256).max;
        return idx;
    }

    function epochBounds(uint256 epoch) public view returns (uint256 start, uint256 end) {
        start = uint256(programStart) + epoch * uint256(epochLength);
        end = start + uint256(epochLength);
    }

    /// @notice True once epoch end has passed AND the finalization grace
    ///         period has elapsed (claims open).
    function isEpochFinalized(uint256 epoch) public view returns (bool) {
        (, uint256 end) = epochBounds(epoch);
        return block.timestamp >= end + finalizationDelay;
    }

    /// @notice True between epoch end and epoch end + finalizationDelay.
    ///         Anyone may poke during this window; claims are still locked.
    function isFinalizationWindow(uint256 epoch) public view returns (bool) {
        (, uint256 end) = epochBounds(epoch);
        return block.timestamp >= end && block.timestamp < end + finalizationDelay;
    }

    function isClaimWindowOpen(uint256 epoch) public view returns (bool) {
        (, uint256 end) = epochBounds(epoch);
        uint256 claimStart = end + finalizationDelay;
        return block.timestamp >= claimStart && block.timestamp < claimStart + claimWindow;
    }

    /// @notice Preview the eligible-shares view of a user right now.
    function eligibleSharesOf(address user) public view returns (uint256) {
        uint256 bal = vault.balanceOf(user);
        if (bal == 0) return 0;
        return bal > perWalletShareCap ? perWalletShareCap : bal;
    }

    // ---------------------------------------------------------------
    // Inflow routing (called by FeeDistributor transferring payout asset)
    // ---------------------------------------------------------------

    /// @notice Pulls any payout-asset balance that has accumulated on this
    ///         contract (via FeeDistributor transfers) and splits it between
    ///         the current epoch's bonus pool and realTreasury.
    ///
    /// @dev    Permissionless. Safe to call by anyone (cron, keeper, or UI).
    ///         Idempotent: only processes untracked balance.
    function pullInflow() public nonReentrant returns (uint256 processed) {
        uint256 bal = payoutAsset.balanceOf(address(this));
        uint256 tracked = _trackedPayoutAsset();
        if (bal <= tracked) return 0;
        processed = bal - tracked;

        uint256 epoch = currentEpoch();
        // If program hasn't started or has ended, forward everything to
        // realTreasury. Nothing lands in a bonus pool.
        if (epoch == type(uint256).max) {
            payoutAsset.safeTransfer(realTreasury, processed);
            emit InflowReceived(processed, 0, processed, type(uint256).max);
            return processed;
        }

        uint256 toBonus = Math.mulDiv(processed, bonusShareBps, 10_000);
        uint256 toTreasury = processed - toBonus;

        // Apply per-epoch cap: overflow goes back to treasury forwarding.
        uint256 poolBefore = epochs[epoch].bonusPool;
        uint256 headroom = perEpochCap > poolBefore ? perEpochCap - poolBefore : 0;
        if (toBonus > headroom) {
            uint256 overflow = toBonus - headroom;
            toBonus = headroom;
            toTreasury += overflow;
            emit BonusPoolCapped(epoch, overflow);
        }

        if (toBonus > 0) {
            epochs[epoch].bonusPool = uint128(poolBefore + toBonus);
        }
        if (toTreasury > 0) {
            payoutAsset.safeTransfer(realTreasury, toTreasury);
        }

        emit InflowReceived(processed, toBonus, toTreasury, epoch);
    }

    /// @dev Amount of payoutAsset currently "owned" by bonus pools (unclaimed).
    ///      Anything above this is new inflow.
    function _trackedPayoutAsset() internal view returns (uint256 total) {
        uint256 n = epochCount;
        for (uint256 i = 0; i < n; i++) {
            EpochInfo storage e = epochs[i];
            if (!e.swept) {
                total += uint256(e.bonusPool) - uint256(e.claimedAmount);
            }
        }
    }

    // ---------------------------------------------------------------
    // Share-seconds accounting
    // ---------------------------------------------------------------

    /// @notice Update share-seconds accrual for `user` using their balance
    ///         at the time of the last poke over the interval
    ///         [lastPoke, min(now, programEnd)]. Splits the interval across
    ///         epoch boundaries.
    ///
    ///         Callers (frontends, keepers, users themselves) should poke on
    ///         deposit/withdraw and before claim to attribute share-seconds
    ///         correctly.
    function poke(address user) public {
        _poke(user);
    }

    function _poke(address user) internal {
        UserInfo storage u = users[user];
        uint64 nowTs = uint64(block.timestamp);

        // First-ever interaction: bootstrap firstDepositTime.
        if (u.lastPoke == 0) {
            uint256 bal = vault.balanceOf(user);
            if (bal > 0) {
                u.firstDepositTime = nowTs;
            }
            u.lastPoke = nowTs;
            u.lastBalance = uint128(bal);
            return;
        }

        if (nowTs <= u.lastPoke) {
            // same block; refresh balance only
            u.lastBalance = uint128(vault.balanceOf(user));
            return;
        }

        // Credit share-seconds for [u.lastPoke, accrualEnd] using u.lastBalance.
        uint256 accrualEnd = block.timestamp < programEnd() ? block.timestamp : programEnd();
        if (accrualEnd > u.lastPoke && u.lastBalance > 0 && u.firstDepositTime != 0) {
            // Dwell cutoff: no accrual before firstDepositTime + dwellPeriod.
            uint256 dwellEnd = uint256(u.firstDepositTime) + uint256(dwellPeriod);
            uint256 start = u.lastPoke > dwellEnd ? u.lastPoke : dwellEnd;
            if (accrualEnd > start) {
                _accrueInterval(user, start, accrualEnd, u.lastBalance);
            }
        }

        // Refresh to current balance. Handle dwell reset if balance hit 0.
        uint256 newBal = vault.balanceOf(user);
        if (newBal == 0) {
            u.firstDepositTime = 0;
        } else if (u.firstDepositTime == 0) {
            u.firstDepositTime = nowTs;
        }
        u.lastBalance = uint128(newBal);
        u.lastPoke = nowTs;
    }

    function _accrueInterval(address user, uint256 start, uint256 end, uint256 balance) internal {
        // Cap eligible shares per wallet.
        uint256 eligible = balance > perWalletShareCap ? perWalletShareCap : balance;
        if (eligible == 0) return;

        // Walk across epoch boundaries.
        uint256 cursor = start;
        while (cursor < end) {
            uint256 epoch = (cursor - programStart) / epochLength;
            if (epoch >= epochCount) break;
            (, uint256 epochEnd) = epochBounds(epoch);
            uint256 segEnd = end < epochEnd ? end : epochEnd;
            uint256 dt = segEnd - cursor;

            // Respect global share cap: if epoch already at cap in totalShareSeconds,
            // skip. We use a soft cap: treat globalShareCap as an upper bound on
            // the per-second share mass an epoch may accumulate scaled to epochLength.
            // Simpler: track contribution only if adding it keeps total per-second
            // share mass <= globalShareCap * dt. To avoid O(users) bookkeeping we
            // apply the check in aggregate: totalShareSeconds / (elapsed in epoch)
            // shouldn't exceed globalShareCap. We clamp dt*eligible so cumulative
            // does not exceed globalShareCap * epochLength.
            uint256 contribution = dt * eligible;
            uint256 cap = globalShareCap * uint256(epochLength);
            EpochInfo storage ei = epochs[epoch];
            if (ei.totalShareSeconds + contribution > cap) {
                uint256 remaining = cap > ei.totalShareSeconds ? cap - ei.totalShareSeconds : 0;
                contribution = remaining;
            }
            if (contribution > 0) {
                ei.totalShareSeconds += contribution;
                userEpochShareSeconds[user][epoch] += contribution;
                emit Poked(user, epoch, contribution, eligible);
            }

            cursor = segEnd;
        }
    }

    // ---------------------------------------------------------------
    // Claim
    // ---------------------------------------------------------------

    /// @notice Claim a user's bonus for a finalized epoch. Pokes the user
    ///         first so accrual up to epoch end is credited even if they
    ///         never called poke during the epoch.
    function claim(uint256 epoch) external nonReentrant returns (uint256 amount) {
        if (!isEpochFinalized(epoch)) revert EpochNotFinalized();
        if (!isClaimWindowOpen(epoch)) revert ClaimWindowClosed();
        if (claimed[msg.sender][epoch]) revert AlreadyClaimed();

        _poke(msg.sender);

        EpochInfo storage ei = epochs[epoch];
        uint256 userSS = userEpochShareSeconds[msg.sender][epoch];
        if (userSS == 0 || ei.totalShareSeconds == 0 || ei.bonusPool == 0) {
            revert NothingToClaim();
        }

        amount = Math.mulDiv(uint256(ei.bonusPool), userSS, ei.totalShareSeconds);
        if (amount == 0) revert NothingToClaim();

        // Cap against remaining pool for safety (rounding).
        uint256 remaining = uint256(ei.bonusPool) - uint256(ei.claimedAmount);
        if (amount > remaining) amount = remaining;

        claimed[msg.sender][epoch] = true;
        ei.claimedAmount = uint128(uint256(ei.claimedAmount) + amount);

        payoutAsset.safeTransfer(msg.sender, amount);
        emit Claimed(msg.sender, epoch, amount);
    }

    /// @notice After the claim window closes, anyone can sweep the unclaimed
    ///         dust of an epoch back to the real treasury.
    function sweepEpoch(uint256 epoch) external nonReentrant {
        (, uint256 end) = epochBounds(epoch);
        if (block.timestamp < end + finalizationDelay + claimWindow) revert ClaimWindowClosed();
        EpochInfo storage ei = epochs[epoch];
        if (ei.swept) revert EpochAlreadySwept();

        uint256 unclaimed = uint256(ei.bonusPool) - uint256(ei.claimedAmount);
        ei.swept = true;
        if (unclaimed > 0) {
            payoutAsset.safeTransfer(realTreasury, unclaimed);
        }
        emit EpochSwept(epoch, unclaimed);
    }

    // ---------------------------------------------------------------
    // Admin
    // ---------------------------------------------------------------

    function setRealTreasury(address _newTreasury) external onlyOwner {
        if (_newTreasury == address(0)) revert ZeroAddress();
        address old = realTreasury;
        realTreasury = _newTreasury;
        emit RealTreasuryUpdated(old, _newTreasury);
    }

    /// @notice Sweep any non-payout-asset token (e.g. WETH sent by the
    ///         FeeDistributor when the fee-currency was currency0) to the
    ///         real treasury. Cannot sweep the payout asset.
    function sweepToken(address token) external onlyOwner {
        if (token == address(payoutAsset)) revert CannotSweepPayoutAsset();
        uint256 bal = IERC20(token).balanceOf(address(this));
        if (bal > 0) {
            IERC20(token).safeTransfer(realTreasury, bal);
        }
        emit ForeignTokenSwept(token, bal);
    }
}
