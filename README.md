# vaults
An ERC-4626 yield-vault protocol in Solidity with Foundry - vault, strategy interface, fuzz and invariant tests.

## Strategy boundary

`src/interfaces/IStrategy.sol` is the contract every Vault and every strategy in this repository is
built against. All amounts are denominated in the underlying token, never in vault shares.

- `totalAssets() view` - everything the strategy manages, liquid or not. Must not revert.
- `maxWithdraw() view` - the most `withdraw()` can pay out in the current block. Must not revert and
  must be `<= totalAssets()`; the gap is the illiquid part of the position. The Vault reads this to
  answer ERC-4626 `maxWithdraw` / `previewWithdraw` honestly, instead of calling `withdraw()` and
  discovering a shortfall after state has already moved. It is an upper bound, not a promise.
- `deposit(amount)` - moves `amount` in.
- `withdraw(amount) returns (withdrawn)` - moves up to `amount` out and returns what actually moved.
- `harvest() returns (harvested)` - realises gains; the assets stay in the strategy.
- `panic()` - emergency unwind; the recovered assets stay in the strategy and leave via `withdraw()`.

### Custody rule

One rule, in both directions:

- In, pull-based: the caller approves the strategy for at least `amount`, and the strategy pulls with
  `transferFrom(msg.sender, ...)` inside `deposit()`. Never push tokens ahead of the call; a strategy
  must never credit a balance it did not pull itself.
- Out, push-based: `withdraw()` transfers the underlying to `msg.sender` before it returns, and the
  return value is exactly the amount transferred. Callers account on the return value, not on the
  requested `amount`.
- Between the two calls the strategy holds custody. Harvested and panic-unwound assets are released
  only through `withdraw()`.

`SECURITY.md` records the same rule in the trust model; if the three ever disagree,
`src/interfaces/IStrategy.sol` is the source of truth.
