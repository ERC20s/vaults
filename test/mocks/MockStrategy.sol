// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IStrategy} from "../../src/interfaces/IStrategy.sol";
import {MockERC20} from "./MockERC20.sol";

/// @title MockStrategy
/// @notice Reference implementation of `IStrategy` used as the fixture for the conformance suite.
/// @dev TEST FIXTURE, NOT AN AUDITED STRATEGY. It earns nothing, has no access control and lets
/// anyone set the illiquid portion; it lives under `test/` for exactly that reason. What it does
/// model faithfully is the custody rule written down in `src/interfaces/IStrategy.sol`:
/// - deposit() is PULL-based: it calls `transferFrom(msg.sender, address(this), amount)` and never
///   credits a balance it did not pull itself;
/// - withdraw() is PUSH-based: it transfers to `msg.sender` before returning and returns exactly
///   the amount transferred, capped at `maxWithdraw()` read at the start of the call;
/// - `maxWithdraw() <= totalAssets()`, the gap being `illiquid`;
/// - harvested and panic-unwound assets stay in the strategy and leave only through withdraw().
///
/// It has no yield source of its own: "yield" is modelled by transferring the underlying token
/// straight to this contract (the invariant handler mints it there). `principal` is what was pulled
/// in through deposit() and not yet withdrawn, so anything held above it is a realised gain that
/// harvest() reports - without moving a token, which is the rule harvest() exists to prove.
contract MockStrategy is IStrategy {
    MockERC20 public immutable token;

    /// @notice Portion of the position that is NOT redeemable this block (locked, in an epoch, ...).
    uint256 public illiquid;

    /// @notice Assets pulled in through deposit() (plus already-harvested gains) and not yet paid out.
    /// @dev The baseline harvest() measures against; it never moves tokens by itself.
    uint256 public principal;

    constructor(MockERC20 token_) {
        token = token_;
    }

    /// @notice Test hook: sets how much of the position is locked this block.
    function setIlliquid(uint256 amount) external {
        illiquid = amount;
    }

    /// @inheritdoc IStrategy
    function totalAssets() public view override returns (uint256) {
        return token.balanceOf(address(this));
    }

    /// @inheritdoc IStrategy
    /// @dev Never reverts and never exceeds totalAssets(), even if `illiquid` was set above it.
    function maxWithdraw() public view override returns (uint256 maxAssets) {
        uint256 total = totalAssets();
        maxAssets = illiquid >= total ? 0 : total - illiquid;
    }

    /// @inheritdoc IStrategy
    /// @dev PULL: the caller must have approved this contract for at least `amount`.
    function deposit(uint256 amount) external override {
        require(token.transferFrom(msg.sender, address(this), amount), "MockStrategy: pull failed");
        principal += amount;
    }

    /// @inheritdoc IStrategy
    /// @dev PUSH: pays out min(amount, maxWithdraw()) and returns exactly what was transferred.
    function withdraw(uint256 amount) external override returns (uint256 withdrawn) {
        uint256 cap = maxWithdraw();
        withdrawn = amount > cap ? cap : amount;
        principal = withdrawn >= principal ? 0 : principal - withdrawn;
        if (withdrawn > 0) {
            require(token.transfer(msg.sender, withdrawn), "MockStrategy: push failed");
        }
    }

    /// @inheritdoc IStrategy
    /// @dev Realises the gain held above `principal` and KEEPS IT: no token moves, the amount stays
    /// visible through totalAssets(), and the caller is paid only through withdraw(). Returns 0 when
    /// there is nothing above the baseline, so it stays a safe no-op for a strategy that earns
    /// nothing.
    function harvest() external override returns (uint256 harvested) {
        uint256 total = totalAssets();
        harvested = total > principal ? total - principal : 0;
        principal = total > principal ? total : principal;
    }

    /// @inheritdoc IStrategy
    /// @dev Emergency unwind: the whole balance becomes immediately redeemable, and it is
    /// released through withdraw(), never pushed to the caller here.
    function panic() external override {
        illiquid = 0;
    }
}
