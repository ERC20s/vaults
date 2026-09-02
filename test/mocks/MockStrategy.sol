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
contract MockStrategy is IStrategy {
    MockERC20 public immutable token;

    /// @notice Portion of the position that is NOT redeemable this block (locked, in an epoch, ...).
    uint256 public illiquid;

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
    }

    /// @inheritdoc IStrategy
    /// @dev PUSH: pays out min(amount, maxWithdraw()) and returns exactly what was transferred.
    function withdraw(uint256 amount) external override returns (uint256 withdrawn) {
        uint256 cap = maxWithdraw();
        withdrawn = amount > cap ? cap : amount;
        if (withdrawn > 0) {
            require(token.transfer(msg.sender, withdrawn), "MockStrategy: push failed");
        }
    }

    /// @inheritdoc IStrategy
    /// @dev No yield source: a no-op that keeps custody of everything it holds.
    function harvest() external pure override returns (uint256 harvested) {
        harvested = 0;
    }

    /// @inheritdoc IStrategy
    /// @dev Emergency unwind: the whole balance becomes immediately redeemable, and it is
    /// released through withdraw(), never pushed to the caller here.
    function panic() external override {
        illiquid = 0;
    }
}
