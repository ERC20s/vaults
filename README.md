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

## Running the tests

The repository is a standard Foundry project (`foundry.toml`, `src = "src"`, `test = "test"`,
solc 0.8.19). The test suite imports nothing outside this repository - no `forge-std`, no
cheatcodes, no submodule - so a clone runs straight away:

```
forge build
forge test -vvv
```

The same command is the `test` entry of the root `.d8a` `run:` block, so it is what the ▶ button
in the VS Code extension and the group's server launch.

### What the tests enforce

`test/IStrategyConformance.t.sol` turns the custody rule above into executable checks against a
reference implementation:

- `deposit()` reverts when the caller has not approved the strategy (the pull really is a pull).
- `deposit(amount)` consumes exactly `amount` of allowance and leaves none behind.
- `maxWithdraw() <= totalAssets()` when empty, funded, partly locked and over-locked.
- `withdraw()` returns exactly the balance delta of `msg.sender`.
- `withdraw(x)` never returns more than `maxWithdraw()` read before the call.
- `panic()` keeps custody and reopens `maxWithdraw()`; the assets leave only via `withdraw()`.
- a fuzz case over `(deposit, illiquid, requested)` re-checks all of the above at once.

Each of those cases is a single shot. `test/IStrategyInvariants.t.sol` is the stateful half: Foundry
drives random SEQUENCES of deposits, withdrawals, harvests, lockups, panics and injected yield
through `test/handlers/StrategyHandler.sol`, and after every sequence it asserts

- `maxWithdraw() <= totalAssets()`, and `totalAssets()` is still the strategy's own token balance;
- neither view reverts, at any point in any sequence;
- everything the handler got back is at most what it put in plus the yield paid in
  (`pushed <= pulled + yieldInjected`);
- conservation: every minted token is either in the handler's hands or in the strategy's custody;
- `harvest()` never realises a gain that was not actually paid in;
- every per-call post-condition the handler checked held on every call - the handler records
  failures in a counter instead of reverting, so nothing is swallowed by the fuzzer.

The handler is the only contract the fuzzer may call (`targetContracts()` / `excludeContracts()` on
the test); the two ledger invariants stand down if a token ever appears from outside it, so a change
in Foundry's targeting turns them off rather than producing a false failure. Run counts and depth
live in the `[profile.default.invariant]` section of `foundry.toml` (`[profile.ci.invariant]` is the
longer CI setting).

`test/SafeERC20Approve.t.sol` covers the approval helper the vaults use. Because the vault approves
the strategy for exactly the amount it is depositing, it writes a non-zero allowance again and
again, and some real tokens (USDT and its imitators) revert on a non-zero to non-zero change.
`SafeERC20.safeApprove` resets the allowance to zero first when both the current allowance and the
new value are non-zero, and the tests prove it against `test/mocks/MockNonStandardERC20.sol` - a
fixture that reverts on exactly that change and returns no boolean from `approve`, `transfer` or
`transferFrom` - while leaving the single-call behaviour intact for a well-behaved token.

`test/MinimalVault.t.sol` covers the deposit and mint paths of `src/vault/MinimalVault.sol`,
including the guards that keep the conservative (floor) share rounding safe. A deposit whose
share amount rounds down to zero reverts instead of taking the assets and minting nothing - the
donation case in the tests inflates `MockStrategy.totalAssets()` with a direct transfer and then
proves the next deposit reverts rather than paying for zero shares. And after
`strategy.deposit(amount)` the vault requires its own token balance to be back where it started, so
underlying can never be stranded in the vault where `totalAssets()` cannot see it and `withdraw()`
cannot reach it; any allowance the strategy left unused is reset to zero.

One state has no exchange rate at all, and the vault now says so. An EMPTY vault
(`totalSupply == 0`) bootstraps 1:1, but a WIPED-OUT vault - shares outstanding while
`strategy.totalAssets()` reads 0, after a total loss, an emergency unwind that ended empty or a
strategy drained from outside - cannot price a deposit. `deposit()` and `mint()` require
`totalSupply == 0 || totalAssets > 0` ("MinimalVault: no-price"), `convertToShares` returns 0
instead of quoting 1:1, and `convertToAssets` reports 0 for shares backed by nothing. Without this
guard a deposit into a wiped-out vault was minted 1:1 alongside the dead shares and lost a share of
itself to them on the way out. The consequence is deliberate: after a total loss the vault is
un-depositable and the existing shares stay locked, since `withdraw()` and `redeem()` already revert
with "no-liquidity". Locking beats silently paying new money to dead shares; a production vault
would need an explicit recovery path, which is out of scope for this example.

The same rounding discipline governs the exit. `redeem()` prices the assets it asks the strategy for
with FLOOR (`shares * totalAssets / totalSupply`), so a redeemer is never paid more than the burned
shares are worth: served in full it burns exactly `shares`, and on a strategy shortfall it burns only
`ceil(withdrawn * totalSupply / totalAssets)` - the shares the payout actually covers. Every rounding
step therefore favours the holders who stay, and the tests assert it directly as
`totalAssetsAfter * totalSupplyBefore >= totalAssetsBefore * totalSupplyAfter` (assets per share
never fall) in a donation case, a shortfall case and a fuzz run over deposit, yield and redeem sizes.

Every guard above protects a single call, and none of them survives a nested one - so the four
state-changing entry points (`deposit`, `mint`, `withdraw`, `redeem`) are now single-entry
(`nonReentrant`, revert string "MinimalVault: reentrancy"); the views are deliberately left open.
The vault opens the window itself: `withdraw()` and `redeem()` call `strategy.withdraw()` BEFORE
they burn shares, so between the strategy's push and its return the assets have left the strategy
(`totalAssets()` is low) while `totalSupply` still counts the shares being redeemed, and
`_convertToShares` prices against exactly that pair. With 100 assets over 100 shares, a redeem of 50
that calls back - a hookful underlying, an ERC-777/ERC-1363 asset, a strategy routing through
another contract - lets a nested `deposit(50)` mint 100 shares instead of 50: 150 shares against 100
assets, half the vault taken from the holders who stayed. The earlier guards all pass on that path,
because `_assertStrategyPulled` measures against a snapshot that already includes the in-transit
assets. `test/MinimalVault.t.sol` proves the window is real (a read-only callback records the
doubled quote) and then that every nested `deposit` and `mint` during `withdraw()`, `redeem()` and
`strategy.deposit()` reverts the outer call whole with nothing moved, and that the flag is released
afterwards. The cost is one warm SSTORE per call, and a strategy that legitimately re-enters the
vault is refused - deliberate.

Fixtures live under `test/mocks/`: `MockERC20.sol` (a minimal mint/approve/transferFrom token),
`MockNonStandardERC20.sol` (the USDT-style token described above),
`MockPartialPullStrategy.sol` (a deliberately misbehaving `IStrategy` whose `deposit()` pulls only a
settable fraction, `pullBps`, so the vault's custody assertion is exercised),
`MockReentrantStrategy.sol` (a conforming `IStrategy` that, once armed, calls back into the
`ReentrantDepositor` helper in the same file before returning from `deposit()` or `withdraw()`) and
`MockStrategy.sol` (a reference `IStrategy` with a settable illiquid portion, and a `principal`
baseline so `harvest()` reports realised gain while keeping custody). All are test fixtures only -
unrestricted minting, no access control, no real yield source - and must never be deployed or
treated as an audited strategy.
