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
  totalAssets(), maxWithdraw(), deposit(...), withdraw(...), harvest(), and panic(). Implementations
  must document units (underlying token vs vault shares) and whether amounts are gross or net.
- All IStrategy amounts are denominated in the underlying token, never in vault shares.
- totalAssets() and maxWithdraw() are views that must not revert. maxWithdraw() is the amount the
  strategy can pay out in the current block and must satisfy maxWithdraw() <= totalAssets(); the
  difference is the illiquid part of the position. A Vault uses maxWithdraw() to answer ERC-4626
  maxWithdraw/previewWithdraw honestly instead of calling withdraw() and discovering a shortfall
  after state has already moved.
- maxWithdraw() is an upper bound, not a settlement guarantee. Callers must still use the value
  returned by withdraw() for accounting; a strategy that reports more than it can pay is a bug and
  must be treated as such in tests.

Operational assumptions
- No private keys, API keys, or other secrets should be committed to the repository.
- Tests and CI must not rely on external secret management or private infrastructure.

Reentrancy and approvals
- Vault and strategy implementations must consider reentrancy risks. Early cycles will use
  simple guards (e.g., checks-effects-interactions or nonReentrant modifiers) where needed.
- Custody is pull-based on the way in and push-based on the way out, and this is the single rule
  for the whole boundary:
  - deposit(amount): the caller (the Vault) approves the strategy for at least `amount` of the
    underlying token, and the strategy pulls it with transferFrom(msg.sender, ...) inside the call.
    A strategy must never expect tokens to be pushed to it ahead of the call, and must never credit
    a balance it has not pulled itself.
  - withdraw(amount): the strategy transfers the underlying token to msg.sender before returning,
    and returns the amount actually transferred. No approval by the strategy is required or assumed.
  - Harvested and panic-unwound assets stay in the strategy's custody and are released only through
    withdraw().
- Because the strategy pulls, the Vault should approve exactly what it is depositing rather than
  leaving a standing unlimited allowance, and should treat any leftover allowance after deposit()
  as a finding.
- Exact approvals mean the Vault repeatedly writes a non-zero allowance, and some widely held
  tokens (USDT and its imitators) revert when a non-zero allowance is changed straight to another
  non-zero value. `SafeERC20.safeApprove` in `src/utils/SafeERC20.sol` therefore resets the
  allowance to zero first whenever the current allowance and the new value are both non-zero;
  setting an allowance from zero, or back to zero, is still a single call. Any new call site that
  sets an allowance must go through `safeApprove` rather than calling `approve` directly.

Fees and accounting
- Fee expectations (e.g., basis points) are not locked in this cycle; any fees introduced
  later must be clearly documented and tested to ensure correct accrual and distribution.

Living document
- This SECURITY.md is a living document. As contracts are added (Vault, mock strategy,
  tests, deployment scripts), this file will be updated with concrete threat models,
  attacker capabilities, and recommended mitigations.
