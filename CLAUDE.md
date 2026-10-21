# CLAUDE.md

An ERC-4626 yield-vault protocol in Solidity (Foundry): `MinimalVault`, the `IStrategy` interface,
and unit, fuzz and invariant tests. No dependencies outside this repo (no forge-std, no submodules).

## Commands

Install Foundry (if `forge` is missing):

```
mkdir -p ~/.foundry/bin && curl -L https://github.com/foundry-rs/foundry/releases/download/stable/foundry_stable_linux_amd64.tar.gz | tar -xz -C ~/.foundry/bin && export PATH=~/.foundry/bin:$PATH
```

Build and check (the `run:` block of `.d8a` declares `test`; CI in `.github/workflows/ci.yml` runs both):

```
forge build
forge test -vvv
```

Compiler: solc 0.8.19 (`foundry.toml` and every `pragma solidity ^0.8.19`). Qualified event
access (`emit MinimalVault.Harvest(...)`) needs 0.8.21, so tests declare the events locally instead.
If `binaries.soliditylang.org` is unreachable, put the solc binary from GitHub releases at
`~/.svm/0.8.19/solc-0.8.19` and run forge with `--offline`.

## Ground rules

- Work on a new branch from `main`; open one PR per task listing the commands run and their results
  before and after. Never report a result you did not get by running the command.
- Never modify `.d8a` or `.d8a-governance`. Never modify the group-store widget markup/script copied
  from the `payments:` block of `.d8a` (`id="group-store"`, `groupStoreVerify`).
- Ignore open pull requests by `d8a[bot]`: do not merge, close, rebase, cherry-pick from or comment on them.
- Do not add a LICENSE file or any licence text.
- Every new test must be able to fail: no `require(x >= 0)` on unsigned values, no bare
  `vm.expectRevert()`, no `try/catch` that accepts any error, no asserting a value equals itself.
  Import every symbol you use. If a test is wrong rather than the code, fix the test to test the
  real behaviour and say so. Never delete or weaken a test to get green.
- Nothing dev-only in code that ships to a browser (no localhost/private hosts, no debug fallbacks).
  No secrets, tokens or keys in the repo.
- CI runs exactly the declared checks and fails when one fails: no `continue-on-error`, no `|| true`,
  no skipped jobs counted as passing. Pin GitHub Actions to their current major versions.
- Keep changes focused: no reformatting untouched files, no unneeded dependency upgrades, no renaming
  public files or URLs, no rewriting git history.
