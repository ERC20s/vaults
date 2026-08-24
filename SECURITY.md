Cycle 1 security assumptions and notes

Scope and purpose
- This file records initial, high-level security assumptions for the "vaults" repository.
- It is intentionally brief and will be expanded as concrete contracts (Vault, strategies, tests)
  are added in later cycles.

Deployment scope
- Code in this repository is intended for Sepolia testnet deployments only at this stage.
- No mainnet deployments or secrets are to be added to the repository in this cycle.
- A Sepolia-only deploy script (scripts/DeploySepolia.s.sol) is included to help contributors
  perform safe, repeatable Sepolia dry-runs and deployments. The script checks chain id and
  refuses to broadcast on non-Sepolia networks. Do not commit private keys or other secrets.

Trust and threat model
- Strategies are considered trusted for cycle 1: they may have permissioned functions and
  could be able to transfer or lock funds. The Vault design in later cycles must either
  account for untrusted strategies or enforce strong access control.

Assumptions about interfaces
- The IStrategy interface defines the minimal boundary between Vault and strategy:
  totalAssets(), deposit(...), withdraw(...), harvest(), and panic(). Implementations
  must document units (underlying token vs vault shares) and whether amounts are gross or net.

Operational assumptions
- No private keys, API keys, or other secrets should be committed to the repository.
- Tests and CI must not rely on external secret management or private infrastructure.

Reentrancy and approvals
- Vault and strategy implementations must consider reentrancy risks. Early cycles will use
  simple guards (e.g., checks-effects-interactions or nonReentrant modifiers) where needed.
- Strategies may require token approvals; callers (Vault) are expected to set approvals
  before calling deposit/withdraw functions.

Fees and accounting
- Fee expectations (e.g., basis points) are not locked in this cycle; any fees introduced
  later must be clearly documented and tested to ensure correct accrual and distribution.

Living document
- This SECURITY.md is a living document. As contracts are added (Vault, mock strategy,
  tests, deployment scripts), this file will be updated with concrete threat models,
  attacker capabilities, and recommended mitigations.
