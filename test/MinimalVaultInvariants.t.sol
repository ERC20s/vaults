// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {MinimalVault} from "../src/vault/MinimalVault.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockStrategy} from "./mocks/MockStrategy.sol";
import {VaultHandler, VaultActor} from "./handlers/VaultHandler.sol";

/// @title MinimalVaultInvariants
/// @notice The stateful half of the vault suite. `test/MinimalVault.t.sol` checks one deposit, one
/// mint, one withdraw, one redeem and one re-entrant callback at a time; every guard merged into
/// `src/vault/MinimalVault.sol` this run - the zero-share and strategy-pull guards, the "no-price"
/// refusal, the floor-priced redeem, the reentrancy guard - is covered only by those single-call
/// tests. This file checks that the accounting still holds after an ARBITRARY SEQUENCE of deposits,
/// mints, withdrawals, redemptions, harvests, lockups and injected yield, which is where ERC-4626
/// share-price bugs actually live.
///
/// @dev Dependency-free, like the rest of the suite: no `forge-std`, no cheatcodes, no submodule.
/// Foundry picks up any public function whose name starts with `invariant` and runs it after each
/// random sequence; assertions are plain `require`, and a reverting invariant is a failing test.
///
/// Targeting: `targetContracts()` / `excludeContracts()` are the standard hooks Foundry reads off
/// the test contract's ABI (`forge-std`'s `StdInvariant` only implements the same two signatures),
/// so the fuzzer drives `VaultHandler` and nothing else - exactly as
/// `test/IStrategyInvariants.t.sol` does. The actors are unreachable anyway: each one refuses any
/// caller but its handler. If a future Foundry ever ignored the hooks, the token and the strategy
/// could be called directly and assets would appear from outside the handler's ledger; the ledger
/// invariants below detect that (`_ledgerIsIsolated()`) and stand down, while the structural
/// invariants and the handler's recorded post-conditions keep running.
contract MinimalVaultInvariantsTest {
    VaultHandler internal handler;
    MockERC20 internal token;
    MockStrategy internal strategy;
    MinimalVault internal vault;

    function setUp() public {
        handler = new VaultHandler();
        token = handler.token();
        strategy = handler.strategy();
        vault = handler.vault();
    }

    /// @notice The only contract the invariant fuzzer may call.
    function targetContracts() public view returns (address[] memory targets) {
        targets = new address[](1);
        targets[0] = address(handler);
    }

    /// @notice The fixtures the fuzzer must NOT call directly: the token mints without access
    /// control and the strategy locks without it, so a direct call would model an actor that cannot
    /// exist behind a vault. The vault itself is excluded because a random sender holds no tokens:
    /// every call it could make would revert and drown the run in dead sequences.
    function excludeContracts() public view returns (address[] memory excluded) {
        excluded = new address[](3);
        excluded[0] = address(token);
        excluded[1] = address(strategy);
        excluded[2] = address(vault);
    }

    // --- structural invariants (always asserted) ---------------------------------------

    /// Assets per share never fall. Compared CROSS-MULTIPLIED against the (assets, supply) pair the
    /// handler recorded when the last action STARTED, so there is no division and no dust
    /// tolerance: `assetsAfter * supplyBefore >= assetsBefore * supplyAfter`. Every rounding step in
    /// the vault is supposed to favour the holders who stay - floor on the shares a deposit mints,
    /// ceil on the assets a mint collects, floor on the assets a redemption asks for, ceil on the
    /// shares a payout burns - and this is that promise stated once, over any sequence.
    ///
    /// Not skipped when a side of the step has no shares outstanding: the virtual pair prices an
    /// empty vault too, and a deposit into an empty vault that still holds assets (the virtual
    /// share's cut after the last exit, or yield that landed since) must pay that price.
    function invariant_SharePriceNeverFalls() public view {
        uint256 supplyBefore = handler.prevSupply();
        uint256 supplyAfter = vault.totalSupply();
        // The price the vault quotes includes one virtual share and one virtual asset.
        require(
            (strategy.totalAssets() + 1) * (supplyBefore + 1) >= (handler.prevAssets() + 1) * (supplyAfter + 1),
            "invariant: assets per share fell"
        );
    }

    /// No free shares. Every share in existence was created by a `deposit()` or `mint()` whose
    /// price the handler checked on the spot, and destroyed only by a `withdraw()` or `redeem()`:
    /// the supply is exactly minted minus burned, so nothing else - a transfer, a harvest, a panic,
    /// a callback - can have created one.
    function invariant_NoFreeShares() public view {
        require(
            vault.totalSupply() == handler.sharesMinted() - handler.sharesBurned(),
            "invariant: shares exist that no priced deposit or mint created"
        );
    }

    /// totalAssets accounting: what the strategy holds is exactly what was deposited, less what
    /// was paid out, plus the yield that really arrived. `harvest()` and `panic()` report and
    /// reopen, they never move a token; nothing accrues from nowhere.
    function invariant_TotalAssetsAccounting() public view {
        if (!_ledgerIsIsolated()) return;
        require(
            strategy.totalAssets() == handler.assetsIn() + handler.yieldInjected() - handler.assetsOut(),
            "invariant: totalAssets drifted from deposits + yield - payouts"
        );
    }

    /// Solvency per holder: the floor value of every holder's shares, summed, fits inside what
    /// the strategy holds, so no holder's quoted claim is backed by another holder's deposit.
    function invariant_HolderClaimsAreCovered() public view {
        uint256 claims;
        for (uint256 i = 0; i < handler.actorCount(); i++) {
            claims += vault.convertToAssets(vault.balanceOf(address(handler.actors(i))));
        }
        require(claims <= strategy.totalAssets(), "invariant: quoted claims exceed the assets held");
    }

    /// The per-owner limits are honest in any reachable state: never above the owner's balance or
    /// floor-priced claim, never above the strategy's liquidity, and `maxRedeem` never asks for a
    /// zero-asset redemption the vault would refuse.
    function invariant_OwnerLimitsAreHonest() public view {
        uint256 liquidity = strategy.maxWithdraw();
        for (uint256 i = 0; i < handler.actorCount(); i++) {
            address owner = address(handler.actors(i));
            uint256 maxShares = vault.maxRedeem(owner);
            uint256 maxAssets = vault.maxWithdraw(owner);
            require(maxShares <= vault.balanceOf(owner), "invariant: maxRedeem above balance");
            require(maxAssets <= vault.convertToAssets(vault.balanceOf(owner)), "invariant: maxWithdraw above claim");
            require(maxAssets <= liquidity, "invariant: maxWithdraw above strategy liquidity");
            require(vault.previewRedeem(maxShares) <= liquidity, "invariant: maxRedeem not serviceable");
            require(maxShares == 0 || vault.previewRedeem(maxShares) > 0, "invariant: maxRedeem quotes a zero-asset redeem");
        }
    }

    /// Every share belongs to somebody. `totalSupply` is maintained by hand in `deposit`, `mint`,
    /// `withdraw` and `redeem`, and a burn that misses the supply (or a mint that misses a balance)
    /// silently re-prices every other holder.
    function invariant_SharesAreFullyAttributed() public view {
        require(
            handler.totalActorShares() == vault.totalSupply(),
            "invariant: holder balances do not add up to totalSupply"
        );
    }

    /// The vault is a pass-through: `deposit()`'s `_assertStrategyPulled` promises no underlying is
    /// ever stranded where `totalAssets()` cannot see it and `withdraw()` cannot reach it, and
    /// `withdraw()` / `redeem()` forward the whole payout. So between calls the vault holds nothing.
    function invariant_VaultHoldsNoStrandedUnderlying() public view {
        require(
            token.balanceOf(address(vault)) == 0,
            "invariant: underlying stranded in the vault between calls"
        );
    }

    /// Solvency, from the outside: the vault can never have paid out more than was put into it plus
    /// the yield that really arrived. A share-inflation bug (the reentrancy window, a mispriced
    /// deposit into a wiped-out vault) shows up here as assets leaving that were never paid in.
    function invariant_PayoutsNeverExceedDepositsPlusYield() public view {
        if (!_ledgerIsIsolated()) return;
        require(
            handler.assetsOut() <= handler.assetsIn() + handler.yieldInjected(),
            "invariant: more assets left the vault than were deposited plus yield"
        );
    }

    /// Conservation: every token the handler ever minted is either in a holder's hands or in the
    /// strategy's custody - nothing burned, mislaid or parked in the vault.
    function invariant_TokenLedgerBalances() public view {
        if (!_ledgerIsIsolated()) return;
        require(
            handler.totalActorTokens() + strategy.totalAssets() + token.balanceOf(address(vault))
                == handler.mintedTotal(),
            "invariant: tokens left the holder/vault/strategy set"
        );
    }

    /// Every per-call post-condition the handler checked - the return value is the caller's balance
    /// delta, a successful deposit never priced a wiped-out vault, a redemption never took more than
    /// the shares offered were worth, a withdrawal never burned too few shares - must have held on
    /// every single call of the sequence. The reason is attached to the failure.
    function invariant_HandlerPostconditionsHold() public view {
        require(handler.failureCount() == 0, handler.lastFailure());
    }

    /// The pricing views may never revert: a caller that cannot read them cannot price a share, and
    /// a wiped-out vault must answer 0 rather than throw.
    function invariant_ViewsNeverRevert() public view {
        vault.totalAssets();
        vault.maxWithdraw();
        vault.convertToShares(1e18);
        vault.convertToAssets(1e18);
    }

    /// @dev True while every token in existence was minted by the handler - i.e. while targeting
    /// really is restricted to the handler and the ledger totals describe the whole world.
    function _ledgerIsIsolated() internal view returns (bool) {
        return token.totalSupply() == handler.mintedTotal();
    }

    // --- a deterministic sequence, so the fixture is proven even if targeting is off -----

    /// Not an invariant: a plain test that drives the handler by hand through the sequence the
    /// single-call suite cannot express - bootstrap, yield, harvest, a second depositor at the new
    /// price, a full redemption, a lockup and a capped withdrawal - and checks the numbers exactly.
    /// It fails on its own if the handler or the vault accounting is broken, whatever the fuzzer's
    /// targeting does.
    function test_HandlerSequenceKeepsSharePrice() public {
        VaultActor first = handler.actors(0);
        VaultActor second = handler.actors(1);

        // Bootstrap: an empty vault prices 1:1.
        handler.deposit(0, 1_000e18);
        require(vault.totalSupply() == 1_000e18, "bootstrap must mint 1:1");
        require(vault.balanceOf(address(first)) == 1_000e18, "the depositor must hold the shares");
        require(strategy.totalAssets() == 1_000e18, "the strategy must have pulled the deposit");
        require(token.balanceOf(address(vault)) == 0, "the vault must hold no underlying");

        // An external yield source pays the strategy: the price doubles, no share is created.
        handler.injectYield(1_000e18);
        handler.harvest();
        require(handler.harvested() == 1_000e18, "harvest() must realise the injected yield");
        require(strategy.totalAssets() == 2_000e18, "harvest() must keep the gain in custody");
        require(vault.totalSupply() == 1_000e18, "harvest() must not change the share supply");

        // A second depositor pays the NEW price: 1,000 assets buys 500 shares, not 1,000.
        handler.deposit(1, 1_000e18);
        require(vault.balanceOf(address(second)) == 500e18, "the second deposit must be priced 2:1");
        require(vault.totalSupply() == 1_500e18, "supply must follow the priced deposit");
        require(strategy.totalAssets() == 3_000e18, "the strategy must hold both deposits and the yield");

        // Full redemption at the floor price: it takes back what it paid, less the one wei the
        // virtual share keeps - floor(500e18 * (3,000e18 + 1) / (1,500e18 + 1)) == 1,000e18 - 1.
        uint256 redeemed = (uint256(500e18) * (uint256(3_000e18) + 1)) / (uint256(1_500e18) + 1);
        require(redeemed == 1_000e18 - 1, "setup: redeem arithmetic");
        handler.redeem(1, 500e18);
        require(vault.balanceOf(address(second)) == 0, "the redeemer must hold no shares afterwards");
        require(token.balanceOf(address(second)) == redeemed, "the redeemer must be paid what its shares were worth");
        require(vault.totalSupply() == 1_000e18, "the burn must reach totalSupply");
        require(strategy.totalAssets() == 2_000e18 + 1, "the remaining holder keeps the doubled price");

        // Lock most of the position: the withdrawal is capped and burns only what it was paid for.
        handler.setIlliquid(1_500e18);
        require(strategy.maxWithdraw() == 500e18 + 1, "the lockup must cap the redeemable amount");

        // The strategy serves 500e18 + 1; the burn is ceil((500e18 + 1) * (1,000e18 + 1) / (2,000e18 + 2))
        // == 250e18 + 1 shares, so 750e18 - 1 remain.
        handler.withdraw(0, 1_000e18);
        require(token.balanceOf(address(first)) == 500e18 + 1, "a capped withdrawal pays what the strategy could serve");
        require(vault.balanceOf(address(first)) == 750e18 - 1, "a capped withdrawal burns only the shares it paid for");
        require(vault.totalSupply() == 750e18 - 1, "supply must follow the capped burn");
        require(strategy.totalAssets() == 1_500e18, "custody must fall by exactly what was pushed");

        // The price never fell across the whole sequence (virtual pair, cross-multiplied):
        // (1,500e18 + 1) / (750e18 - 1 + 1) >= (2,000e18 + 1 + 1) / (1,000e18 + 1).
        require(
            (strategy.totalAssets() + 1) * (1_000e18 + 1) >= (2_000e18 + 2) * (vault.totalSupply() + 1),
            "assets per share fell across the sequence"
        );

        require(handler.failureCount() == 0, handler.lastFailure());
        require(handler.totalActorShares() == vault.totalSupply(), "holder balances must add up to totalSupply");
        require(token.balanceOf(address(vault)) == 0, "the vault must hold no underlying at the end");
        require(
            handler.assetsOut() <= handler.assetsIn() + handler.yieldInjected(),
            "more assets left the vault than were deposited plus yield"
        );
        require(
            handler.totalActorTokens() + strategy.totalAssets() == handler.mintedTotal(),
            "ledger: tokens left the holder/vault/strategy set"
        );
    }
}
