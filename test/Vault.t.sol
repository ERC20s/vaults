// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Vault} from "../src/Vault.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockStrategy} from "./mocks/MockStrategy.sol";

contract VaultTest {
    MockERC20 token;
    MockStrategy mock;
    Vault vault;

    function setUp() public {
        token = new MockERC20();
        mock = new MockStrategy(token);
        vault = new Vault(token, mock);
    }

    function test_DepositApprovesExactlyAndLeavesNoAllowance() public {
        uint256 amount = 1_000e18;
        token.mint(address(this), amount);
        token.approve(address(vault), amount);

        vault.deposit(amount);

        // Vault should have approved strategy and the strategy pulled it, leaving no allowance.
        require(token.allowance(address(vault), address(mock)) == 0, "vault allowance not consumed");
        require(mock.totalAssets() == amount, "strategy did not receive amount");
        require(token.balanceOf(address(this)) == 0, "caller should have paid the amount");
    }

    function test_MaxWithdrawForwardsToStrategy() public {
        token.mint(address(this), 500e18);
        token.approve(address(vault), 500e18);
        vault.deposit(500e18);

        mock.setIlliquid(200e18);
        require(vault.maxWithdraw() == mock.maxWithdraw(), "maxWithdraw mismatch");
    }

    function test_WithdrawUsesReturnValueAndForwards() public {
        // deposit via vault so strategy custody increases
        token.mint(address(this), 800e18);
        token.approve(address(vault), 800e18);
        vault.deposit(800e18);

        // lock some
        mock.setIlliquid(300e18);

        uint256 before = token.balanceOf(address(this));
        uint256 withdrawn = vault.withdraw(400e18);
        uint256 delta = token.balanceOf(address(this)) - before;

        require(withdrawn == delta, "vault must forward the strategy's return value");
        require(withdrawn == 400e18, "vault should receive full requested amount under maxWithdraw");
        require(mock.totalAssets() == 400e18, "strategy custody must fall by forwarded amount");
    }

    function test_WithdrawRespectsMaxWithdrawWhenCapped() public {
        token.mint(address(this), 600e18);
        token.approve(address(vault), 600e18);
        vault.deposit(600e18);

        mock.setIlliquid(500e18);
        uint256 cap = vault.maxWithdraw();

        uint256 before = token.balanceOf(address(this));
        uint256 withdrawn = vault.withdraw(1_000e18);
        uint256 delta = token.balanceOf(address(this)) - before;

        require(withdrawn == delta, "withdraw return must equal forwarded amount");
        require(withdrawn == cap, "withdraw must be capped by maxWithdraw");
    }
}
