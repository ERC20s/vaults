# vaults
An ERC-4626 yield-vault protocol in Solidity with Foundry - vault, strategy interface, fuzz and invariant tests.

Running the Sepolia deploy script (cycle-1 helper)

- Once contracts are added to src/ (e.g., ERC20Mock.sol, Vault.sol, MockLendingStrategy.sol), use the provided Foundry script to do a safe dry-run check of repository deployables:

  forge script scripts/DeploySepolia.s.sol --rpc-url $SEPOLIA_RPC

- The script enforces Sepolia (chain id 11155111) and will refuse to broadcast on other networks. To perform a real deployment, re-run the command with --broadcast and set your private key in an environment variable (do not commit private keys):

  forge script scripts/DeploySepolia.s.sol --rpc-url $SEPOLIA_RPC --private-key $PK --broadcast

- The script is defensive: it inspects common source paths and prints suggested forge create commands for each contract found. It does not itself perform broadcasts or include secrets.
