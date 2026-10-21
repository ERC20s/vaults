Security assumptions, findings and notes

Scope and purpose
- This file records the security assumptions for the "vaults" repository and the findings of the
  review of `src/vault/MinimalVault.sol`, the `IStrategy` boundary, `harvest()` / `panic()` and the
  permit-enabled deposit and mint (the "Review findings" section below). It is updated whenever a
  contract or a guard changes.

Deployment scope
- Code in this repository is intended for Sepolia testnet deployments only at this stage.
- No mainnet deployments or secrets are to be added to the repository in this cycle.

Trust and threat model
- Strategies are trusted. `MinimalVault` reads `totalAssets()` and `maxWithdraw()` from the strategy
  and prices every share on them; a strategy that lies about either can mint or burn at the wrong
  price. The vault asserts the custody rule on every call (the strategy pulled exactly what the
  vault received, the strategy pushed exactly what it reported) and refuses nested calls, but it
  cannot defend against a strategy that mis-reports.
- The strategy is immutable: there is no `setStrategy`, no migration path and no upgrade, so there
  is no strategy-change privilege to protect. Moving funds to a new strategy means a new vault.
- The `guardian` is trusted to call `panic()` at the right moment and at no other. It is immutable,
  set at construction, and may not be the zero address. It holds no other power: it cannot move
  funds, change the price, pause deposits or touch allowances.
- `harvest()` is permissionless. The `IStrategy` contract lets `harvest()` realise gains only and
  requires the assets to stay in the strategy's custody; a strategy whose harvest is sensitive to
  WHEN it is called (a reward swap that can be sandwiched, for example) must restrict its own
  `harvest()` to callers it trusts, because the vault relays the call for anyone.
- Everyone else is untrusted: depositors, redeemers, holders of shares, anyone who can donate the
  underlying to the strategy, and anyone who can see the mempool.

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
- Every state-changing entry point of the vault that reaches the strategy or the asset
  (`deposit`, `depositWithPermit`, `mint`, `mintWithPermit`, `withdraw`, `redeem`, `harvest`,
  `panic`) is single-entry (`nonReentrant`). The ERC-20 share functions (`transfer`,
  `transferFrom`, `approve`, `permit`, `increaseAllowance`, `decreaseAllowance`) make no external
  call and are not guarded. The views are deliberately not guarded either: see "Read-only
  reentrancy" under residual risks.
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
- Because the strategy pulls, the Vault approves exactly what it is depositing rather than leaving
  a standing unlimited allowance, and clears any leftover allowance after deposit().
- Exact approvals mean the Vault repeatedly writes a non-zero allowance, and some widely held
  tokens (USDT and its imitators) revert when a non-zero allowance is changed straight to another
  non-zero value. `SafeERC20.safeApprove` in `src/utils/SafeERC20.sol` therefore resets the
  allowance to zero first whenever the current allowance and the new value are both non-zero;
  setting an allowance from zero, or back to zero, is still a single call. Any new call site that
  sets an allowance must go through `safeApprove` rather than calling `approve` directly.

Share pricing
- Shares are priced with one virtual share and one virtual asset (the ERC-4626 "decimals offset"
  scheme, offset 0): `shares = assets * (totalSupply + 1) / (totalAssets + 1)` floored on deposit,
  `assets = shares * (totalAssets + 1) / (totalSupply + 1)` floored on redeem, and the ceilings of
  the same ratios on mint and withdraw. A vault with no shares and no assets bootstraps 1:1; a
  vault with no shares that still holds assets is priced by the same formula (one share costs
  `totalAssets + 1`), so nothing left in the strategy is handed to the next depositor.
- Every rounding step favours the vault, and the price `(totalAssets + 1) / (totalSupply + 1)`
  never falls across any call (`invariant_SharePriceNeverFalls`).
- A wiped-out vault (shares outstanding, `totalAssets() == 0`) has no price: `deposit()` / `mint()`
  revert "no-price", the views quote 0, and the dead shares stay locked. A recovery path is out of
  scope for this example vault.

Unsupported assets
- Fee-on-transfer (deflationary) assets are NOT supported. The vault prices shares on the amount
  it asked for, so a smaller delivery would dilute every other holder. `_pullIntoStrategy`
  requires the vault's balance to rise by exactly `amount` and reverts "MinimalVault:
  fee-on-transfer" otherwise, with nothing moved. A token whose fee can be switched on later is
  refused from that moment on; existing holders' claims are unaffected.
- Rebasing assets are NOT supported. A rebase between calls is simply a change of `totalAssets()`
  and is socialised across holders like yield or loss, but transfers of amounts the token's index
  does not divide evenly deliver a wei short, and the vault's exact-delta checks fail closed
  ("fee-on-transfer" on the way in, "strategy returned mismatch" on the way out). Deposits and
  redemptions of such amounts revert with nothing moved. `test/MinimalVaultUnsupportedAssets.t.sol`
  shows both behaviours.
- ERC-777 / ERC-1363 and other hookful assets are tolerated only because every state-changing
  entry point is single-entry: a hook that re-enters the vault reverts the outer call.
- Assets with more than 255 decimals, or whose `decimals()` cannot be read, are shown as 18
  decimals by the share token; nothing in the accounting depends on it.

Review findings
  Severity | Where | Finding | Status
  -------- | ----- | ------- | ------
  High | `deposit` / `mint` pricing | First-depositor share inflation. The zero-share guard stopped the TOTAL loss only: bootstrap 1 wei, donate D to the strategy, and a victim depositing 2D + 1 was floored to one share worth 1.5D, a 0.5D profit for the attacker. | Fixed: virtual share/asset pair (`_convertToShares`). The attacker can no longer profit and loses at least as much as the victim to within a couple of wei (`test/MinimalVaultInflation.t.sol`, deterministic and fuzzed).
  High | `panic()` | Unrestricted emergency unwind. Anyone could force the strategy's `panic()`, which the interface allows to realise slippage or loss, on every holder, and the vault relayed around any access control a strategy put on it. | Fixed: `onlyGuardian`, immutable guardian set at construction, zero address refused (`test/MinimalVaultPanicAccess.t.sol`).
  High | `deposit` / `mint` pricing, empty vault | Follow-up review of the fix above: `totalSupply == 0` still bootstrapped 1:1 even when the strategy held assets. The virtual share's cut stays in the strategy when the last holder leaves (0.6D after the attack above), so once the victim exited the attacker re-entered at 1:1, took the cut back and ended with a profit equal to the victim's loss; the same shortcut handed any yield or donation sitting in an empty vault to the next depositor. | Fixed: the virtual-pair formula applies with `totalSupply == 0` too (`_convertToShares`, `_convertToAssets`, `_convertToAssetsForMint`); `invariant_SharePriceNeverFalls` no longer skips empty-vault steps (`test_InflationAttackStaysUnprofitableAfterTheVaultEmpties`, `test_EmptyVaultHoldingAssetsIsPricedAgainstThem`, `testFuzz_RoundTripThroughAnEmptyFundedVaultNeverProfits`).
  Medium | `depositWithPermit` / `mintWithPermit` | Permit front-running DoS. A signature in the mempool could be submitted to `token.permit()` by anyone; the nonce was consumed and the owner's own deposit reverted inside `permit()` with the allowance already in place, on every retry. | Fixed: `_tryPermit` tolerates a failed permit and lets `safeTransferFrom` gate the deposit on the allowance (`test/MinimalVaultAssetPermit.t.sol`). Replayed, expired and forged permits still move nothing.
  Medium | `maxRedeem(owner)` | Dishonest limit. `floor(cap * totalSupply / totalAssets)` under-reported: with 3 shares over 10 assets a holder of one share was told 0 although `redeem(1)` pays. ERC-4626 requires the maximum that will not revert. | Fixed: exact largest share count whose floor value fits the cap; 0 when the cap is 0 (`test/MinimalVaultRounding.t.sol`, `invariant_OwnerLimitsAreHonest`).
  Medium | fee-on-transfer assets | A deflationary asset failed inside the strategy's pull with an opaque reason, and a strategy that tolerates a short pull would have minted shares priced on the full amount. | Fixed: explicit exact-delta check and revert reason in `_pullIntoStrategy`; documented as unsupported above (`test/MinimalVaultUnsupportedAssets.t.sol`).
  Low | share `permit` | `DOMAIN_SEPARATOR` frozen at construction: a signature made before a chain fork was valid on both sides of it. | Fixed: cached for the deployment chain, rebuilt for any other `block.chainid` (`test_permit_signed_before_a_chain_fork_is_rejected_after_it`).
  Low | rounding | Deposit floor, mint ceil, withdraw ceil, redeem floor were already in the vault's favour. | Verified, not changed: preview round trips and action-equals-preview fuzzed in `test/MinimalVaultRounding.t.sol`.
  Low | reentrancy | `harvest()`, `panic()` and the four share-moving entry points were already `nonReentrant`; callbacks from the strategy during `deposit`, `withdraw`, `harvest` and `panic` revert the outer call. | Verified, not changed: existing single-shot tests; the invariant handler now also drives `panic()` and `transfer()`.
  Low | share `permit` | Signature malleability (high-s signatures) is not rejected. | Justified: the nonce is consumed by the first use, so the malleated twin of a used signature is refused; a malleated twin of an UNUSED signature grants the same allowance the owner signed for. No replay is possible.
  Low | `mintWithPermit` | The permit must be signed over the exact `previewMint(shares)` at execution; a price move between signing and execution leaves the signature for the wrong value and the mint reverts. | Justified: fails closed with nothing moved (tested); `depositWithPermit` is the robust gasless path. Documented in the function's NatSpec.
  Low | `withdraw(assets)` | Returns a partial payout on a strategy shortfall instead of reverting as ERC-4626 prescribes. | Justified: documented "withdraw up to" semantics, the burn follows the amount actually paid, and callers must account on the return value (README, `IStrategy`). Changing it is a behaviour change outside this review.
  Informational | views | Read-only reentrancy: during `withdraw` / `redeem` the strategy has pushed but the shares are not burned, so a view called from a callback quotes a depressed price. | Justified: no vault state can be changed from that window (every writer is `nonReentrant`), and the test suite shows the quote. Integrators that price `mVLT` shares from another contract must not do so from inside a callback of this vault's asset or strategy.
  Informational | `rebasing` assets | See "Unsupported assets". | Documented and tested.

Residual risks
- Griefing by inflation. With an offset of 0 the inflation attack cannot profit, but an attacker
  who spends D can still make a victim lose up to one share's value (about D / 3 in the worst
  shape for a 1 wei bootstrap), paying at least as much themselves to within a couple of wei of
  rounding. Raising the virtual share count (a larger decimals
  offset) shrinks the victim's loss by the same factor; it was left at 0 so a vault with no shares
  and no assets still bootstraps 1:1. Whatever the virtual share holds when the last holder leaves
  stays in the strategy and raises the price the next depositor pays; it is not redeemable by
  anyone. Front ends should quote `previewDeposit` and refuse a deposit whose share value
  is far below the assets paid.
- Read-only reentrancy, as above.
- Rebasing and fee-on-transfer assets, as above.
- The guardian is a single immutable key. Losing it means `panic()` can never be called through
  the vault; compromising it means the strategy can be unwound at will (but nothing can be taken).

Slither triage
- CI runs `slither . --fail-medium` with `slither.config.json` (sources only, optimisation findings
  excluded). Each medium-or-higher result on the current code is a known false positive that
  carries an inline `slither-disable-next-line` on the function it names, for these reasons:
  - `incorrect-equality` (dangerous strict equality) on `deposit`, `depositWithPermit`, `mint`,
    `mintWithPermit`, `withdraw`, `redeem`, `pricePerShare`, `previewWithdraw`, `maxRedeem`,
    `_pullIntoStrategy`, `_assertStrategyPulled`, `_convertToShares`, `_convertToAssets`,
    `_mulDivFloor`, `_mulDivCeil`. Every comparison is intentional:
    `totalSupply == 0` / `totalAssets == 0` are the empty and wiped-out branches; `balance == before + amount` and
    `balance == before` are the custody rule stated exactly (a token that delivers less is refused
    on purpose); `got == withdrawn` is the push rule; `withdrawn == assetsRequested` separates a
    full redemption from a shortfall; `prod1 == 0` and `mulmod(...) == 0` are the exact-division
    branches of the 512-bit `mulDiv`.
  - `reentrancy-balance`, `reentrancy-no-eth`, `reentrancy-benign` on `withdraw`, `redeem`,
    `_pullIntoStrategy` and the four deposit/mint entry points. The balance is read before the
    external call BECAUSE the delta across it is what the custody rule checks, and the state
    writes after the call are protected by `nonReentrant` (Slither does not credit the modifier
    once a variable is also read by unguarded views). `test/MinimalVault.t.sol` and
    `test/MinimalVaultHarvestReentrancy.t.sol` prove the guard on every path.
  - `incorrect-exp` and `divide-before-multiply` on `_mulDivFloor`: `(3 * denominator) ^ 2` is the
    bitwise XOR seed of the Newton-Raphson inverse and the divisions by `twos` are the 512-bit
    `mulDiv` algorithm (OpenZeppelin `Math.mulDiv`), exact by construction and covered by
    `test/MinimalVaultRedeemOverflow.t.sol`.
- Low and informational results (benign reentrancy already covered above, `timestamp` in `permit`
  for the deadline, assembly and low-level calls in `_mulDivFloor` / `_readDecimals` /
  `SafeERC20`, naming of the EIP-712 constants, the pinned `^0.8.19` range) are left visible and do
  not fail the job.

Fees and accounting
- Fee expectations (e.g., basis points) are not locked in this cycle; any fees introduced
  later must be clearly documented and tested to ensure correct accrual and distribution.

Living document
- This SECURITY.md is a living document. As contracts are added (strategies, deployment scripts),
  this file will be updated with concrete threat models, attacker capabilities, and recommended
  mitigations.
