// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IStrategy} from "../../src/interfaces/IStrategy.sol";
import {MockERC20} from "./MockERC20.sol";

/// @title MockOverpayStrategy
/// @notice DELIBERATELY MISBEHAVING test fixture: a strategy that pushes back more than
/// requested on withdraw() to simulate an overpaying or buggy strategy.
contract MockOverpayStrategy is IStrategy {
    MockERC20 public immutable token;
    uint256 public principal;

    /// @notice Extra amount to push on top of the requested withdraw (in token units).
    uint256 public extra;

    constructor(MockERC20 token_) {
        token = token_;
    }

    function setExtra(uint256 extra_) external {
        extra = extra_;
    }

    function totalAssets() public view override returns (uint256) {
        return token.balanceOf(address(this));
    }

    function maxWithdraw() public view override returns (uint256 maxAssets) {
        maxAssets = totalAssets();
    }

    function deposit(uint256 amount) external override {
        require(token.transferFrom(msg.sender, address(this), amount), "MockOverpayStrategy: pull failed");
        principal += amount;
    }

    /// @dev PUSH-based and intentionally overpays: transfers min(amount + extra, balance)
    /// and returns the actual transferred amount.
    function withdraw(uint256 amount) external override returns (uint256 withdrawn) {
        uint256 cap = maxWithdraw();
        uint256 desired = amount + extra;
        withdrawn = desired > cap ? cap : desired;
        principal = withdrawn >= principal ? 0 : principal - withdrawn;
        if (withdrawn > 0) {
            require(token.transfer(msg.sender, withdrawn), "MockOverpayStrategy: push failed");
        }
    }

    function harvest() external override returns (uint256 harvested) {
        uint256 total = totalAssets();
        harvested = total > principal ? total - principal : 0;
        principal = total > principal ? total : principal;
    }

    function panic() external override {}
}
