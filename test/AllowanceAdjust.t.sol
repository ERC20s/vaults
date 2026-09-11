// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {MockERC20} from "./mocks/MockERC20.sol";
import {MockStrategy} from "./mocks/MockStrategy.sol";
import {MinimalVault} from "../src/vault/MinimalVault.sol";
import {IStrategy} from "../src/interfaces/IStrategy.sol";
import {IERC20} from "../src/utils/SafeERC20.sol";

contract AllowanceAdjustTest {
    MockERC20 token;
    MockStrategy mock;
    MinimalVault vault;

    function setUp() public {
        token = new MockERC20();
        mock = new MockStrategy(token);
        vault = new MinimalVault(IERC20(address(token)), IStrategy(address(mock)));
    }

    function test_increaseAllowanceFromZeroAndExisting() public {
        address spender = address(0xBEEF);

        // Mint tokens to this contract and deposit to receive shares
        uint256 amount = 1_000e18;
        token.mint(address(this), amount);
        token.approve(address(vault), amount);
        vault.deposit(amount);

        // Initially zero
        require(vault.allowance(address(this), spender) == 0, "initial allowance non-zero");

        // Increase from zero
        bool ok = vault.increaseAllowance(spender, 200e18);
        require(ok, "increaseAllowance failed");
        require(vault.allowance(address(this), spender) == 200e18, "allowance not increased from zero");

        // Increase again
        ok = vault.increaseAllowance(spender, 100e18);
        require(ok, "second increaseAllowance failed");
        require(vault.allowance(address(this), spender) == 300e18, "allowance not increased cumulatively");
    }

    function test_decreaseAllowanceAndRevertOnUnderflow() public {
        address spender = address(this);

        // Mint tokens to this contract and deposit to receive shares
        uint256 amount = 1_000e18;
        token.mint(address(this), amount);
        token.approve(address(vault), amount);
        vault.deposit(amount);

        // Approve some allowance
        uint256 allowanceVal = 500e18;
        vault.approve(spender, allowanceVal);
        require(vault.allowance(address(this), spender) == allowanceVal, "approve did not set allowance");

        // Decrease by a smaller amount
        bool ok = vault.decreaseAllowance(spender, 200e18);
        require(ok, "decreaseAllowance failed");
        require(vault.allowance(address(this), spender) == allowanceVal - 200e18, "allowance not decreased");

        // Decrease by the remaining amount
        ok = vault.decreaseAllowance(spender, 300e18);
        require(ok, "decreaseAllowance to zero failed");
        require(vault.allowance(address(this), spender) == 0, "allowance not zero after decrease");

        // Underflow: try to decrease below zero and expect a revert
        try vault.decreaseAllowance(spender, 1) returns (bool) {
            // If it returns, that's a failure
            require(false, "decreaseAllowance underflow did not revert");
        } catch {
            // expected
        }
    }
}
