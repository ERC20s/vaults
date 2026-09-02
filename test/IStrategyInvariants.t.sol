// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IStrategy} from "../src/interfaces/IStrategy.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockStrategy} from "./mocks/MockStrategy.sol";
import {StrategyHandler} from "./handlers/StrategyHandler.sol";

/// @title IStrategyInvariants
/// @notice The stateful half of the strategy-boundary suite: `test/IStrategyConformance.t.sol`
/// checks one deposit / one lock / one withdraw at a time, this file checks that the custody rule
/// in `src/interfaces/IStrategy.sol` still holds after an ARBITRARY SEQUENCE of deposits,
/// withdrawals, harvests, lockups, panics and injected yield.
///
/// @dev Dependency-free, like the rest of the suite: no `forge-std`, no cheatcodes, no submodule.
/// Foundry picks up any public function whose name starts with `invariant` and runs it after each
/// random sequence; assertions are plain `require`, and a reverting invariant is a failing test.
///
/// Targeting: `targetContracts()` / `excludeContracts()` are the standard hooks Foundry reads off
/// the test contract's ABI (`forge-std`'s `StdInvariant` only implements the same two signatures),
/// so the fuzzer drives `StrategyHandler` and nothing else. If a future Foundry ever ignored them,
/// the token and the strategy would be called directly and tokens could appear from outside the
/// handler's ledger; the two ledger invariants below guard for exactly that
/// (`_ledgerIsIsolated()`) and stand down, while the structural invariants and the handler's own
/// recorded post-conditions keep running. That is the fallback the proposal flagged, written down
/// in code rather than left to a reader.
contract IStrategyInvariantsTest {
    StrategyHandler internal handler;
    MockERC20 internal token;
    MockStrategy internal mock;
    IStrategy internal strategy;

    function setUp() public {
        handler = new StrategyHandler();
        token = handler.token();
        mock = handler.strategy();
        strategy = IStrategy(address(mock));
    }

    /// @notice The only contract the invariant fuzzer may call.
    function targetContracts() public view returns (address[] memory targets) {
        targets = new address[](1);
        targets[0] = address(handler);
    }

    /// @notice The fixtures the fuzzer must NOT call directly: they have no access control, so a
    /// direct `mint` or `setIlliquid` would model an actor that cannot exist behind a Vault.
    function excludeContracts() public view returns (address[] memory excluded) {
        excluded = new address[](2);
        excluded[0] = address(token);
        excluded[1] = address(mock);
    }

    // --- structural invariants (always asserted) --------------------------------------

    /// The advertised bound can never promise more than the position holds. A Vault answers
    /// ERC-4626 `maxWithdraw`/`previewWithdraw` from this number, so it may not drift.
    function invariant_MaxWithdrawNeverExceedsTotalAssets() public view {
        require(
            strategy.maxWithdraw() <= strategy.totalAssets(),
            "invariant: maxWithdraw() > totalAssets()"
        );
    }

    /// Custody is a token balance, not a number the strategy keeps for itself: after any sequence
    /// the reported total must still be the tokens the strategy actually holds.
    function invariant_TotalAssetsEqualsStrategyTokenBalance() public view {
        require(
            strategy.totalAssets() == token.balanceOf(address(mock)),
            "invariant: totalAssets() drifted from the strategy's token balance"
        );
    }

    /// Every per-call post-condition the handler checked (return value equals balance delta,
    /// withdraw within the advertised cap, harvest and panic keep custody) must have held on
    /// every single call of the sequence.
    function invariant_HandlerPostconditionsHold() public view {
        require(handler.failureCount() == 0, handler.lastFailure());
    }

    /// Neither view may revert, at any point in any sequence: `IStrategy` says so, and a Vault
    /// that cannot read them cannot price a share.
    function invariant_ViewsNeverRevert() public view {
        strategy.totalAssets();
        strategy.maxWithdraw();
    }

    // --- ledger invariants (asserted while the handler owns every token) ----------------

    /// Nothing leaves the strategy except through `withdraw()`: the assets the handler got back
    /// can never exceed what it put in plus the yield paid to the strategy.
    function invariant_PushedNeverExceedsPulledPlusYield() public view {
        if (!_ledgerIsIsolated()) return;
        require(
            handler.pushed() <= handler.pulled() + handler.yieldInjected(),
            "invariant: more assets came out of the strategy than went in"
        );
    }

    /// Conservation: every token the handler ever minted is either in the handler's own hands or
    /// in the strategy's custody. A strategy that burned, mislaid or forwarded assets to a third
    /// party fails here.
    function invariant_CustodyLedgerBalances() public view {
        if (!_ledgerIsIsolated()) return;
        require(
            token.balanceOf(address(handler)) + strategy.totalAssets() == handler.mintedTotal(),
            "invariant: tokens left the handler/strategy pair"
        );
    }

    /// `harvest()` may only realise gains that really arrived: the sum of all harvests can never
    /// exceed the yield that was actually paid into the strategy.
    function invariant_HarvestedNeverExceedsInjectedYield() public view {
        if (!_ledgerIsIsolated()) return;
        require(
            handler.harvested() <= handler.yieldInjected(),
            "invariant: harvest() realised gains that were never paid in"
        );
    }

    /// @dev True while every token in existence was minted by the handler - i.e. while targeting
    /// really is restricted to the handler and the ledger totals describe the whole world.
    function _ledgerIsIsolated() internal view returns (bool) {
        return token.totalSupply() == handler.mintedTotal();
    }

    // --- a deterministic sequence, so the fixture is proven even if targeting is off -----

    /// Not an invariant: a plain test that drives the handler by hand through the sequence the
    /// old single-shot suite could not express (deposit, yield, harvest, lock, panic, withdraw)
    /// and checks the ghosts afterwards. It fails on its own if the handler or the harvest
    /// accounting is broken, whatever the fuzzer's targeting does.
    function test_HandlerSequenceKeepsCustody() public {
        handler.deposit(1_000e18);
        handler.simulateYield(250e18);

        require(mock.principal() == 1_000e18, "fixture: principal must track the deposit");
        handler.harvest();
        require(handler.harvested() == 250e18, "harvest() must realise the injected yield");
        require(strategy.totalAssets() == 1_250e18, "harvest() must keep the gain in custody");

        handler.setIlliquid(1_250e18);
        require(strategy.maxWithdraw() == 0, "a fully locked position must advertise 0");

        handler.panic();
        require(strategy.maxWithdraw() == 1_250e18, "panic() must reopen the whole balance");

        handler.withdraw(1_250e18);
        require(handler.pushed() == 1_250e18, "the whole position must leave through withdraw()");
        require(strategy.totalAssets() == 0, "custody must be empty after a full withdrawal");

        require(handler.failureCount() == 0, handler.lastFailure());
        require(
            token.balanceOf(address(handler)) + strategy.totalAssets() == handler.mintedTotal(),
            "ledger: tokens left the handler/strategy pair"
        );
    }
}
