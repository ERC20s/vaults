# vaults
An ERC-4626 yield-vault protocol in Solidity with Foundry - vault, strategy interface, fuzz and invariant tests.

## Layout

- `src/interfaces/IStrategy.sol` - minimal interface a vault-compatible yield strategy must implement.
- `test/` - unit, fuzz and invariant suites (empty for now).
- `foundry.toml` - project manifest: `src`, `out`, `libs`, `test`, solc 0.8.19, optimizer on (200 runs), fuzz and invariant budgets.

## Build and test

Requires [Foundry](https://book.getfoundry.sh/getting-started/installation) (`foundryup`).

```sh
forge install foundry-rs/forge-std   # first checkout only; lands in lib/, which is git-ignored
forge build
forge test -vvv
```

`forge test` currently reports no tests - the suites arrive with the vault
implementation. A heavier fuzz/invariant run uses the `ci` profile:

```sh
FOUNDRY_PROFILE=ci forge test -vvv
```

Formatting follows `[fmt]` in `foundry.toml`:

```sh
forge fmt
```

## Notes

- Build output (`out/`, `cache/`, `broadcast/`) and dependencies (`lib/`) are git-ignored.
- No RPC endpoints or private keys are configured here; nothing in this repository
  reads a secret. Deployment tooling is out of scope until the group votes it in.
- `.d8a` records the governing group and the run entries; `forge test -vvv` is the
  one enabled entry.
