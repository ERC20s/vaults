// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IStrategy} from "../../src/interfaces/IStrategy.sol";
import {MockERC20} from "./MockERC20.sol";

/// @notice The callback a re-entrant strategy fires while the vault is mid-call.
interface IReentrancyHook {
    /// @dev Called by `MockReentrantStrategy` after it has pushed (or pulled) the underlying
    /// and BEFORE it returns to the vault - the window the guard has to close.
    function onReentrancyWindow() external;
}

/// @notice The slice of `MinimalVault` the attacker helper below needs. Declared here so the
/// fixtures stay independent of the vault's full surface.
interface IVaultLike {
    function deposit(uint256 amount) external returns (uint256 shares);
    function mint(uint256 shares) external returns (uint256 assets);
    function convertToShares(uint256 amount) external view returns (uint256);
    function totalAssets() external view returns (uint256);
    function totalSupply() external view returns (uint256);
}

/// @title MockReentrantStrategy
/// @notice DELIBERATELY MISBEHAVING test fixture: a conforming `IStrategy` that, once armed,
/// calls back into a hook contract before returning from `deposit()` or `withdraw()`.
/// @dev TEST FIXTURE, NOT A STRATEGY. It stands in for everything that can hand control back
/// mid-call in the real world - a hookful underlying (ERC-777 / ERC-1363), a strategy that
/// routes through another protocol, a router with a callback - without needing any of them as
/// a dependency.
///
/// The window it opens is the one `MinimalVault.nonReentrant` closes: `withdraw()` PUSHES the
/// underlying to the vault first, so during the callback the assets have left this strategy
/// (`totalAssets()` is low) while the vault has not burned the redeemed shares yet
/// (`totalSupply` unchanged). A nested `deposit()` priced against that pair mints far more
/// shares than the assets are worth.
///
/// Custody behaviour is otherwise exactly `MockStrategy`'s: pull-based deposits, push-based
/// withdrawals capped at `maxWithdraw()`, `totalAssets()` is its own token balance. Disarmed
/// (the default) it is a conforming fixture, which is what makes the control tests meaningful.
contract MockReentrantStrategy is IStrategy {
    MockERC20 public immutable token;

    /// @notice The contract called back inside the window. Unset = never call back.
    address public hook;

    /// @notice Fire the callback from inside `withdraw()`, after the push.
    bool public reenterOnWithdraw;

    /// @notice Fire the callback from inside `deposit()`, after the pull.
    bool public reenterOnDeposit;

    /// @notice Set once the callback has fired, so a re-entrant fixture can never loop.
    bool public fired;

    /// @notice Assets pulled in through deposit() and not yet withdrawn.
    uint256 public principal;

    constructor(MockERC20 token_) {
        token = token_;
    }

    // --- Test hooks ---

    function setHook(address hook_) external {
        hook = hook_;
    }

    function armWithdraw(bool on) external {
        reenterOnWithdraw = on;
        fired = false;
    }

    function armDeposit(bool on) external {
        reenterOnDeposit = on;
        fired = false;
    }

    // --- IStrategy ---

    /// @inheritdoc IStrategy
    function totalAssets() public view override returns (uint256) {
        return token.balanceOf(address(this));
    }

    /// @inheritdoc IStrategy
    function maxWithdraw() public view override returns (uint256 maxAssets) {
        maxAssets = totalAssets();
    }

    /// @inheritdoc IStrategy
    /// @dev PULL-based and conforming: takes the whole `amount`, then (if armed) hands control
    /// to the hook before returning to the vault.
    function deposit(uint256 amount) external override {
        if (amount > 0) {
            require(token.transferFrom(msg.sender, address(this), amount), "MockReentrantStrategy: pull failed");
            principal += amount;
        }
        _maybeReenter(reenterOnDeposit);
    }

    /// @inheritdoc IStrategy
    /// @dev PUSH-based and conforming: pays out min(amount, maxWithdraw()) and returns exactly
    /// what was transferred. The callback fires AFTER the push, which is precisely the moment
    /// the assets are in transit and the vault's price is wrong.
    function withdraw(uint256 amount) external override returns (uint256 withdrawn) {
        uint256 cap = maxWithdraw();
        withdrawn = amount > cap ? cap : amount;
        principal = withdrawn >= principal ? 0 : principal - withdrawn;
        if (withdrawn > 0) {
            require(token.transfer(msg.sender, withdrawn), "MockReentrantStrategy: push failed");
        }
        _maybeReenter(reenterOnWithdraw);
    }

    /// @inheritdoc IStrategy
    function harvest() external override returns (uint256 harvested) {
        uint256 total = totalAssets();
        harvested = total > principal ? total - principal : 0;
        principal = total > principal ? total : principal;
    }

    /// @inheritdoc IStrategy
    function panic() external override {}

    /// @dev Fires the callback at most once. A revert inside the hook - which is what the
    /// vault's guard produces - bubbles up and reverts the vault's outer call whole, which is
    /// exactly the behaviour the tests assert.
    function _maybeReenter(bool armed) internal {
        if (!armed || hook == address(0) || fired) {
            return;
        }
        fired = true;
        IReentrancyHook(hook).onReentrancyWindow();
    }
}

/// @title ReentrantDepositor
/// @notice The attacker helper `MockReentrantStrategy` calls back into.
/// @dev TEST FIXTURE. It holds its OWN underlying (minted straight to it, never to the
/// strategy, so it stays out of `strategy.totalAssets()`) and approves the vault for it, so the
/// nested call is a fully funded, otherwise-legitimate deposit or mint. Modes:
/// - Mode.Deposit - re-enters with `vault.deposit(amount)`;
/// - Mode.Mint    - re-enters with `vault.mint(amount)`;
/// - Mode.Observe - touches no state-changing function, only records the quote the vault gives
///   inside the window (views are NOT guarded), which is how the tests show the mispricing is
///   real and that the guard, not the arithmetic, is what stops it.
contract ReentrantDepositor is IReentrancyHook {
    enum Mode {
        Deposit,
        Mint,
        Observe
    }

    IVaultLike public immutable vault;
    MockERC20 public immutable token;

    Mode public mode;
    uint256 public amount;
    bool public armed;

    /// @notice Number of times the callback ran.
    uint256 public callbacks;

    /// @notice Quote the vault gave for `amount` assets inside the window (Observe mode).
    uint256 public observedShares;
    /// @notice `totalAssets()` seen inside the window (Observe mode).
    uint256 public observedAssets;
    /// @notice `totalSupply()` seen inside the window (Observe mode).
    uint256 public observedSupply;

    constructor(IVaultLike vault_, MockERC20 token_) {
        vault = vault_;
        token = token_;
    }

    /// @notice Arms the helper for exactly one nested call of `mode_` for `amount_` units.
    function arm(Mode mode_, uint256 amount_) external {
        mode = mode_;
        amount = amount_;
        armed = true;
    }

    /// @inheritdoc IReentrancyHook
    function onReentrancyWindow() external override {
        if (!armed) {
            return;
        }
        armed = false; // one shot, whatever happens next
        callbacks += 1;

        if (mode == Mode.Observe) {
            observedShares = vault.convertToShares(amount);
            observedAssets = vault.totalAssets();
            observedSupply = vault.totalSupply();
            return;
        }

        token.approve(address(vault), amount);
        if (mode == Mode.Deposit) {
            vault.deposit(amount); // reverts "MinimalVault: reentrancy" and takes the outer call with it
        } else {
            vault.mint(amount);
        }
    }
}
