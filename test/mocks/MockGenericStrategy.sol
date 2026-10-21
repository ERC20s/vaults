// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IStrategy} from "../../src/interfaces/IStrategy.sol";
import {IERC20} from "../../src/utils/SafeERC20.sol";

/// @title MockGenericStrategy
/// @notice `MockStrategy` over the plain `IERC20` interface instead of the concrete `MockERC20`,
/// so a vault can be built over the fee-on-transfer, rebasing and permit fixtures. Same custody
/// behaviour: pull-based deposit, push-based withdraw capped at `maxWithdraw()`, `totalAssets()` is
/// its own token balance, `harvest()` reports the gain above `principal`, `panic()` reopens the
/// position. TEST FIXTURE, NOT AN AUDITED STRATEGY.
contract MockGenericStrategy is IStrategy {
    IERC20 public immutable token;

    uint256 public illiquid;
    uint256 public principal;

    constructor(IERC20 token_) {
        token = token_;
    }

    function setIlliquid(uint256 amount) external {
        illiquid = amount;
    }

    function totalAssets() public view override returns (uint256) {
        return token.balanceOf(address(this));
    }

    function maxWithdraw() public view override returns (uint256 maxAssets) {
        uint256 total = totalAssets();
        maxAssets = illiquid >= total ? 0 : total - illiquid;
    }

    function deposit(uint256 amount) external override {
        require(token.transferFrom(msg.sender, address(this), amount), "MockGenericStrategy: pull failed");
        principal += amount;
    }

    function withdraw(uint256 amount) external override returns (uint256 withdrawn) {
        uint256 cap = maxWithdraw();
        withdrawn = amount > cap ? cap : amount;
        principal = withdrawn >= principal ? 0 : principal - withdrawn;
        if (withdrawn > 0) {
            require(token.transfer(msg.sender, withdrawn), "MockGenericStrategy: push failed");
        }
    }

    function harvest() external override returns (uint256 harvested) {
        uint256 total = totalAssets();
        harvested = total > principal ? total - principal : 0;
        principal = total > principal ? total : principal;
    }

    function panic() external override {
        illiquid = 0;
    }
}
