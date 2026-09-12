// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {MockERC20} from "./mocks/MockERC20.sol";
import {MockOverpayStrategy} from "./mocks/MockOverpayStrategy.sol";
import {MinimalVault} from "../src/vault/MinimalVault.sol";
import {IStrategy} from "../src/interfaces/IStrategy.sol";
import {IERC20} from "../src/utils/SafeERC20.sol";

contract WithdrawOverpayTest {
    MockERC20 token;
    MockOverpayStrategy mock;
    MinimalVault vault;

    function setUp() public {
        token = new MockERC20();
        mock = new MockOverpayStrategy(token);
        vault = new MinimalVault(IERC20(address(token)), IStrategy(address(mock)));
    }

    function test_WithdrawRevertsOnStrategyOverpay() public {
        // Deposit some tokens and let strategy hold them
        uint256 amount = 1_000e18;
        token.mint(address(this), amount);
        token.approve(address(vault), amount);
        vault.deposit(amount);

        // Arm the strategy to overpay by 1 token unit
        mock.setExtra(1);

        // Attempt a withdraw and expect it to revert due to strategy overpay
        try vault.withdraw(500e18) returns (uint256) {
            revert("withdraw did not revert on overpay");
        } catch {
            // expected: revert bubbles up from the vault's require
        }
    }
}
