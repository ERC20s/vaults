// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {MockERC20} from "./mocks/MockERC20.sol";
import {MockStrategy} from "./mocks/MockStrategy.sol";
import {ReferenceVault} from "./mocks/ReferenceVault.sol";

/// @notice Tests for the test-only ReferenceVault that demonstrate the custody rule.
contract ReferenceVaultTest {
    MockERC20 token;
    MockStrategy mock;
    ReferenceVault vault;

    function setUp() public {
        token = new MockERC20();
        mock = new MockStrategy(token);
        vault = new ReferenceVault(token, IStrategy(address(mock)));
    }

    // Confirm deposit flow: vault pulls from caller, approves strategy exactly, strategy pulls
    // and consumes the allowance.
    function test_DepositApprovesExactlyAndLeavesNoAllowance() public {
        uint256 amount = 1_000e18;
        token.mint(address(this), amount);
        token.approve(address(vault), amount);

        // Caller deposits into the vault; vault should pull the tokens and then let the strategy
        // pull them from the vault. After the call, the vault's allowance for the strategy
        // must be zero and custody should be in the strategy.
        vault.deposit(amount);

        require(token.allowance(address(vault), address(mock)) == 0, "vault allowance not consumed");
        require(token.balanceOf(address(mock)) == amount, "strategy did not get custody");
        require(mock.totalAssets() == amount, "strategy totalAssets mismatch");
    }

    // Confirm withdraw flow: vault calls strategy.withdraw(), forwards the returned amount to caller.
    function test_WithdrawForwardsStrategyReturn() public {
        uint256 amount = 2_000e18;
        token.mint(address(this), amount);
        token.approve(address(vault), amount);

        vault.deposit(amount);

        // Make part of position illiquid to test cap behavior.
        mock.setIlliquid(500e18);

        uint256 before = token.balanceOf(address(this));
        uint256 withdrawn = vault.withdraw(1_000e18);
        uint256 delta = token.balanceOf(address(this)) - before;

        require(withdrawn == delta, "vault returned mismatch");
        require(withdrawn <= mock.maxWithdraw(), "withdraw exceeded maxWithdraw");
    }

    // Views are forwarded to the strategy.
    function test_ViewsForwarded() public {
        token.mint(address(this), 300e18);
        token.approve(address(vault), 300e18);
        vault.deposit(300e18);
        require(vault.totalAssets() == mock.totalAssets(), "totalAssets not forwarded");
        require(vault.maxWithdraw() == mock.maxWithdraw(), "maxWithdraw not forwarded");
    }
}
