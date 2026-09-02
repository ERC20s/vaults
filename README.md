# vaults
An ERC-4626 yield-vault protocol in Solidity with Foundry - vault, strategy interface, fuzz and invariant tests.

## Strategy interface

`src/interfaces/IStrategy.sol` is the boundary every strategy implementation and every future
Vault is written against. It declares six functions:

- `asset() external view returns (address)` - the ERC-20 token the strategy accepts, holds and
  accounts in. Must not revert, and is immutable for the life of the strategy.
- `totalAssets() external view returns (uint256)` - total assets managed, in underlying units.
  Must not revert.
- `deposit(uint256 amount) external returns (uint256 deposited)` - deposits up to `amount`;
  returns the amount actually deposited, which may be less than requested.
- `withdraw(uint256 amount) external returns (uint256 withdrawn)` - withdraws up to `amount`;
  returns the amount actually returned to the caller.
- `harvest() external returns (uint256 harvested)` - realises yield; may be a no-op.
- `panic() external` - emergency unwind, maximising recoverable assets.

It also declares the events `Deposited`, `Withdrawn`, `Harvested` and `Panicked`.

Units rule: every `uint256` amount in the interface - arguments, return values and event
fields - is denominated in the underlying token reported by `asset()`, never in vault shares.
Returned amounts are net (what actually moved), so a caller must account using the return value
and not the requested amount.

Wiring rule: a Vault binds a strategy only after checking the assets match.

```solidity
require(strategy.asset() == asset(), "asset mismatch");
```
