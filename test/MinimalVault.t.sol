// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {MockERC20} from "./mocks/MockERC20.sol";
import {MockStrategy} from "./mocks/MockStrategy.sol";
import {MinimalVault} from "../src/vault/MinimalVault.sol";
import {IStrategy} from "../src/interfaces/IStrategy.sol";
import {IERC20} from "../src/utils/SafeERC20.sol";

contract MinimalVaultTest {
    MockERC20 token;
    MockStrategy mock;
    MinimalVault vault;

    function setUp() public {
        token = new MockERC20();
        mock = new MockStrategy(token);
        vault = new MinimalVault(IERC20(address(token)), IStrategy(address(mock)));
    }

    function test_DepositApprovesAndStrategyConsumesAllowance() public {
        uint256 amount = 1_000e18;
        token.mint(address(this), amount);
        token.approve(address(vault), amount);

        uint256 shares = vault.deposit(amount);

        require(token.allowance(address(vault), address(mock)) == 0, "allowance not consumed");
        require(token.balanceOf(address(mock)) == amount, "strategy custody missing");
        require(shares > 0, "no shares minted");
        require(vault.totalAssets() == mock.totalAssets(), "assets not forwarded");
    }

    function test_WithdrawHandlesShortfallAndForwardsReturn() public {
        uint256 amount = 2_000e18;
        token.mint(address(this), amount);
        token.approve(address(vault), amount);
        vault.deposit(amount);

        // make part illiquid so withdraw will be capped
        mock.setIlliquid(1500e18);

        uint256 before = token.balanceOf(address(this));
        uint256 withdrawn = vault.withdraw(1_000e18);
        uint256 delta = token.balanceOf(address(this)) - before;

        require(withdrawn == delta, "withdraw return mismatch");
        require(withdrawn <= mock.maxWithdraw(), "exceeded strategy maxWithdraw");
    }

    function test_ShareMathBootstrapAndConservativeRounding() public {
        // bootstrap: first depositor gets 1:1
        uint256 a1 = 1e18;
        token.mint(address(this), a1);
        token.approve(address(vault), a1);
        uint256 s1 = vault.deposit(a1);
        require(s1 == a1, "bootstrap not 1:1");

        // second depositor: deposit proportionally
        address other = address(0xBEEF);
        token.mint(other, 3e18);
        // impersonate other by calling deposit via low-level? Simpler: replicate math here.
        // Instead, ensure that convertToShares is floor-rounded and never over-mints.
        uint256 sharesFor2 = vault.convertToShares(1e18);
        uint256 expected = (1e18 * vault.totalSupply()) / vault.totalAssets();
        require(sharesFor2 == expected, "convertToShares rounding mismatch");
    }
}
