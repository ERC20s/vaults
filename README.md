# vaults

An ERC-4626 yield-vault protocol in Solidity with Foundry - vault, strategy interface, fuzz and invariant tests.

## Status

UNAUDITED and NOT deployment-ready. `src/Vault.sol` has had no external review; it exists so the
protocol's fuzz and invariant tests have real accounting to exercise. Do not put value in it.

## Layout

- `src/Vault.sol` — a minimal, dependency-free ERC-4626 vault over a single ERC-20 asset, with its
  own ERC-20 share token built in. Assets stay idle in the vault: `totalAssets()` is the vault's own
  balance of the underlying token.
- `src/interfaces/IStrategy.sol` — the strategy boundary (`totalAssets`, `deposit`, `withdraw`,
  `harvest`, `panic`). The Vault does **not** consume it yet; routing idle capital through a strategy
  is left to a later change so this contract stays reviewable.
- `test/Vault.t.sol` — unit and fuzz tests, with a test-only `ERC20Mock` declared in the same file.

## Share accounting

- Shares round **down** when minted for a depositor and **up** when burned for a withdrawer, so
  rounding dust always accrues to the vault rather than to the caller.
- Conversions carry a virtual-shares / virtual-assets offset (`10 ** 3` virtual shares, `1` virtual
  asset). This blunts the first-depositor donation attack: seeding the vault with 1 wei and donating
  a large balance cannot round a later depositor's shares to zero, and costs the attacker far more
  than it can return. The share token therefore reports the asset's decimals **plus 3**.

## Build and test

Requires [Foundry](https://book.getfoundry.sh/). Dependencies are not vendored, so install
`forge-std` once:

```sh
forge install foundry-rs/forge-std --no-commit
forge build
forge test -vvv
```

`foundry.toml` pins `solc 0.8.19`, sets `libs = ["lib"]` with the `forge-std/=lib/forge-std/src/`
remapping, and configures the fuzz and invariant runners.

`forge test -vvv` is also the enabled `test` entry in the root `.d8a` `run:` block, so it is what the
group's terminal runs.
