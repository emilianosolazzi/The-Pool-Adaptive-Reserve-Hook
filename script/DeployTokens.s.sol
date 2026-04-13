// SPDX-License-Identifier: MIT
pragma solidity >=0.8.24 <0.9.0;

import {Script, console2} from "forge-std/Script.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev Minimal mintable ERC-20 for testnet use only.
contract TestToken is ERC20 {
    uint8 private immutable _dec;

    constructor(string memory name, string memory symbol, uint8 decimals_) ERC20(name, symbol) {
        _dec = decimals_;
        _mint(msg.sender, 1_000_000 * 10 ** decimals_); // 1 M tokens to deployer
    }

    function decimals() public view override returns (uint8) { return _dec; }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @title DeployTokens
/// @notice Deploys two test ERC-20 tokens on Arbitrum Sepolia for use with the protocol.
///         Sorts them and prints the correct TOKEN0 / TOKEN1 assignment for .env.
///
/// @dev Run:
///      forge script script/DeployTokens.s.sol \
///        --rpc-url $ARBITRUM_TESTNET_RPC_URL \
///        --private-key $PRIVATE_KEY \
///        --broadcast
contract DeployTokens is Script {
    function run() external {
        vm.startBroadcast();

        TestToken usdc = new TestToken("USD Coin",        "USDC", 6);
        TestToken weth = new TestToken("Wrapped Ether",   "WETH", 18);

        vm.stopBroadcast();

        // Uniswap v4 requires currency0 < currency1 (by address).
        (address token0, address token1) = address(usdc) < address(weth)
            ? (address(usdc), address(weth))
            : (address(weth), address(usdc));

        console2.log("\n=== Test Tokens Deployed ===");
        console2.log("USDC :", address(usdc));
        console2.log("WETH :", address(weth));
        console2.log("\nAdd to .env:");
        console2.log("TOKEN0=%s  # (lower address)", token0);
        console2.log("TOKEN1=%s", token1);
    }
}
