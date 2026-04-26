// SPDX-License-Identifier: MIT
pragma solidity >=0.8.24 <0.9.0;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BootstrapRewards} from "../src/BootstrapRewards.sol";

interface ILiquidityVaultLike {
    function asset() external view returns (address);
    function convertToShares(uint256 assets) external view returns (uint256 shares);
}

interface IFeeDistributorLike {
    function treasury() external view returns (address);
    function setTreasury(address newTreasury) external;
}

/// @notice One-shot Bootstrap deployment + wiring.
///
/// Required env vars:
/// - BOOTSTRAP_VAULT       deployed LiquidityVault address
/// - BOOTSTRAP_DISTRIBUTOR deployed FeeDistributor address
/// - BOOTSTRAP_REAL_TREASURY address that should receive non-bonus treasury flow
///
/// Optional env vars:
/// - BOOTSTRAP_PROGRAM_START unix timestamp (defaults to block.timestamp)
contract DeployBootstrap is Script {
    uint64 internal constant EPOCH_LENGTH = 30 days;
    uint32 internal constant EPOCH_COUNT = 6;
    uint64 internal constant DWELL = 7 days;
    uint64 internal constant CLAIM_WINDOW = 90 days;
    uint64 internal constant FINALIZATION_DELAY = 7 days;
    uint16 internal constant BONUS_BPS = 5_000; // 50%
    uint256 internal constant PER_EPOCH_CAP_ASSET = 10_000e6; // $10k USDC
    uint256 internal constant PER_WALLET_CAP_ASSET = 25_000e6; // $25k USDC
    uint256 internal constant GLOBAL_CAP_ASSET = 100_000e6; // $100k USDC

    function run() external {
        address vaultAddr = vm.envAddress("BOOTSTRAP_VAULT");
        address distributorAddr = vm.envAddress("BOOTSTRAP_DISTRIBUTOR");
        address realTreasury = vm.envAddress("BOOTSTRAP_REAL_TREASURY");

        require(vaultAddr != address(0), "BOOTSTRAP_VAULT=0");
        require(distributorAddr != address(0), "BOOTSTRAP_DISTRIBUTOR=0");
        require(realTreasury != address(0), "BOOTSTRAP_REAL_TREASURY=0");

        ILiquidityVaultLike vault = ILiquidityVaultLike(vaultAddr);
        IFeeDistributorLike distributor = IFeeDistributorLike(distributorAddr);

        address payoutAsset = vault.asset();
        uint256 perWalletShareCap = vault.convertToShares(PER_WALLET_CAP_ASSET);
        uint256 globalShareCap = vault.convertToShares(GLOBAL_CAP_ASSET);
        uint64 programStart = uint64(vm.envOr("BOOTSTRAP_PROGRAM_START", uint256(block.timestamp)));

        BootstrapRewards.Config memory cfg = BootstrapRewards.Config({
            vault: IERC20(vaultAddr),
            payoutAsset: IERC20(payoutAsset),
            realTreasury: realTreasury,
            programStart: programStart,
            epochLength: EPOCH_LENGTH,
            epochCount: EPOCH_COUNT,
            dwellPeriod: DWELL,
            claimWindow: CLAIM_WINDOW,
            finalizationDelay: FINALIZATION_DELAY,
            bonusShareBps: BONUS_BPS,
            perEpochCap: PER_EPOCH_CAP_ASSET,
            perWalletShareCap: perWalletShareCap,
            globalShareCap: globalShareCap
        });

        vm.startBroadcast();

        BootstrapRewards bootstrap = new BootstrapRewards(cfg);

        if (distributor.treasury() != address(bootstrap)) {
            distributor.setTreasury(address(bootstrap));
        }

        vm.stopBroadcast();

        console2.log("BootstrapRewards deployed:", address(bootstrap));
        console2.log("Vault:", vaultAddr);
        console2.log("FeeDistributor:", distributorAddr);
        console2.log("Payout asset:", payoutAsset);
        console2.log("Real treasury:", realTreasury);
        console2.log("Program start:", uint256(programStart));
        console2.log("Per-wallet share cap:", perWalletShareCap);
        console2.log("Global share cap:", globalShareCap);
    }
}
