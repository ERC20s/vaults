Cycle 1 security assumptions and notes

Scope and purpose
- This file records initial, high-level security assumptions for the "vaults" repository.
- It is intentionally brief and will be expanded as concrete contracts (Vault, strategies, tests)
  are added in later cycles.

Deployment scope
- Code in this repository is intended for Sepolia testnet deployments only at this stage.
- No mainnet deployments or secrets are to be added to the repository in this cycle.

Trust and threat model
- Strategies are considered trusted for cycle 1: they may have permissioned functions and
  could be able to transfer or lock funds. The Vault design in later cycles must either
  account for untrusted strategies or enforce strong access control.

Assumptions about interfaces
- The IStrategy interface defines the minimal boundary between Vault and strategy:
  asset(), totalAssets(), deposit(...), withdraw(...), harvest(), and panic().
- asset() returns the ERC-20 token the strategy accepts, holds and accounts in. It must not
  revert and must be immutable for the life of the strategy.
- Wiring rule: a Vault must reject any strategy whose asset differs from its own, at the
  moment the strategy is bound - require(strategy.asset() == asset()). Without this check a
  mis-wired strategy is not a revert but a silent share-price corruption: deposits land in a
  strategy denominated in a different token and totalAssets() returns numbers in the wrong units.
- Units are fixed by the interface, not by convention: every uint256 amount in IStrategy
  (arguments, return values and event fields) is in underlying-token units as reported by
  asset(), never in vault shares.
- Amounts returned are net, i.e. the amount actually moved. deposit(uint256) returns the amount
  actually deposited and withdraw(uint256) returns the amount actually withdrawn; both may be
  less than requested (caps, rounding, fee-on-transfer assets). Vault accounting must use the
  returned value and never the requested value.
- IStrategy declares the events Deposited, Withdrawn, Harvested and Panicked so that strategy
  behaviour is observable off-chain and assertable in tests; implementations are expected to
  emit them.

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
