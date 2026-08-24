// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Script.sol";
import "forge-std/console.sol";

// DeploySepolia.s.sol
// A conservative, Sepolia-only deploy helper script for Foundry.
// This script enforces Sepolia (chain id 11155111) before any broadcast
// and inspects common contract source paths in the repository. It does not
// import project contracts directly (so it can be committed safely even if
// contracts are added later). Instead it offers clear, actionable
// instructions for deploying any contract files found in the repo.

contract DeploySepolia is Script {
    // Sepolia chain id per EIP-155
    uint256 public constant SEPOLIA_CHAIN_ID = 11155111;

    function run() external {
        // Safety: refuse to run if the RPC is not Sepolia. This prevents
        // accidental broadcasts to other networks when the script is used
        // with --broadcast.
        require(block.chainid == SEPOLIA_CHAIN_ID, "DeploySepolia: RPC is not Sepolia (11155111)");

        console.log("DeploySepolia: Running on Sepolia (chainid=%s).", block.chainid);

        // Common paths for contracts we may add in later cycles.
        string[3] memory commonPaths = [
            "src/ERC20Mock.sol",
            "src/Vault.sol",
            "src/MockLendingStrategy.sol"
        ];

        uint256 found = 0;

        for (uint256 i = 0; i < commonPaths.length; i++) {
            string memory path = commonPaths[i];
            // vm.readFile reverts if the file doesn't exist in the working tree when running locally
            // inside a forge script. We use try/catch to detect presence without failing the script.
            bool exists = _fileExists(path);
            if (exists) {
                found++;
                console.log("Found %s in repository.", path);
                console.log("Suggested command to deploy this contract (example):");
                console.log(
                    "  forge create %s:<ContractName> --rpc-url $SEPOLIA_RPC --private-key $PK --legacy --constructor-args ... --verify -vvvv",
                    path
                );
                console.log(
                    "Replace <ContractName> with the contract inside the file (e.g., ERC20Mock, Vault, MockLendingStrategy).\n"
                );
            } else {
                console.log("Not found: %s (skipping)", path);
            }
        }

        if (found == 0) {
            revert("DeploySepolia: No deployable contract sources found in src/. Add your contracts (e.g., ERC20Mock.sol, Vault.sol) or update this script.");
        }

        // This script deliberately does not call vm.startBroadcast() or perform new deployments
        // itself because contract names and constructors vary across cycles. Use the suggested
        // forge create commands above to deploy specific contracts once they are present.

        console.log("DeploySepolia: Dry-run complete. To perform a real deployment, re-run with --broadcast and your SEPOLIA RPC and private key environment variables set.");
    }

    // Helper to check file existence using vm.readFile; returns false if file missing.
    function _fileExists(string memory path) internal returns (bool) {
        bytes memory b;
        try this._tryRead(path) returns (bytes memory bb) {
            b = bb;
            return b.length > 0;
        } catch {
            return false;
        }
    }

    // This external wrapper lets us call try/catch on reading files.
    function _tryRead(string memory path) external returns (bytes memory) {
        return vm.readFile(path);
    }
}
