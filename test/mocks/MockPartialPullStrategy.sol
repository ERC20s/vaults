// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IStrategy} from "../../src/interfaces/IStrategy.sol";
import {MockERC20} from "./MockERC20.sol";

/// @title MockPartialPullStrategy
/// @notice DELIBERATELY MISBEHAVING test fixture: a strategy whose deposit() pulls only a
/// settable fraction of the amount it was asked to take.
/// @dev TEST FIXTURE, NOT A STRATEGY. It exists to exercise one assertion in
/// `src/vault/MinimalVault.sol`: after `strategy.deposit(amount)` the vault must hold no
/// leftover underlying. The custody rule in `src/interfaces/IStrategy.sol` says deposits are
/// PULL-based and the strategy must take the whole `amount`; a strategy that pulls less
/// leaves tokens stranded in the vault, invisible to `totalAssets()` and unreachable through
/// `withdraw()`. `MockStrategy` is the conforming fixture; this one is the counter-example.
///
/// `pullBps` is the fraction of `amount` that deposit() actually pulls, in basis points:
/// 10_000 = the full amount (conforming), 5_000 = half, 0 = pulls nothing at all.
contract MockPartialPullStrategy is IStrategy {
    uint256 public constant BPS = 10_000;

    MockERC20 public immutable token;

    /// @notice Fraction of the requested amount that deposit() pulls, in basis points.
    uint256 public pullBps = BPS;

    /// @notice Assets pulled in through deposit() and not yet withdrawn.
    uint256 public principal;

    constructor(MockERC20 token_) {
        token = token_;
    }

    /// @notice Test hook: sets how much of a requested deposit this strategy actually pulls.
    function setPullBps(uint256 bps) external {
        require(bps <= BPS, "MockPartialPullStrategy: bps > 100%");
        pullBps = bps;
    }

    /// @inheritdoc IStrategy
    function totalAssets() public view override returns (uint256) {
        return token.balanceOf(address(this));
    }

    /// @inheritdoc IStrategy
    function maxWithdraw() public view override returns (uint256 maxAssets) {
        maxAssets = totalAssets();
    }

    /// @inheritdoc IStrategy
    /// @dev PULL-based, but only `pullBps` of what it was asked for. Everything above that is
    /// left with the caller on purpose.
    function deposit(uint256 amount) external override {
        uint256 pulled = (amount * pullBps) / BPS;
        if (pulled > 0) {
            require(token.transferFrom(msg.sender, address(this), pulled), "MockPartialPullStrategy: pull failed");
            principal += pulled;
        }
    }

    /// @inheritdoc IStrategy
    /// @dev PUSH: pays out min(amount, maxWithdraw()) and returns exactly what was transferred.
    function withdraw(uint256 amount) external override returns (uint256 withdrawn) {
        uint256 cap = maxWithdraw();
        withdrawn = amount > cap ? cap : amount;
        principal = withdrawn >= principal ? 0 : principal - withdrawn;
        if (withdrawn > 0) {
            require(token.transfer(msg.sender, withdrawn), "MockPartialPullStrategy: push failed");
        }
    }

    /// @inheritdoc IStrategy
    /// @dev Realises anything held above `principal` and keeps it in custody.
    function harvest() external override returns (uint256 harvested) {
        uint256 total = totalAssets();
        harvested = total > principal ? total - principal : 0;
        principal = total > principal ? total : principal;
    }

    /// @inheritdoc IStrategy
    /// @dev Nothing is ever locked here, so the emergency unwind is a no-op.
    function panic() external override {}
}
