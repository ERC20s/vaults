// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {MockERC20} from "./mocks/MockERC20.sol";
import {MockStrategy} from "./mocks/MockStrategy.sol";
import {MinimalVault} from "../src/vault/MinimalVault.sol";
import {IStrategy} from "../src/interfaces/IStrategy.sol";
import {IERC20} from "../src/utils/SafeERC20.sol";

contract TransferFromApprovalTest {
    MockERC20 token;
    MockStrategy mock;
    MinimalVault vault;

    function setUp() public {
        token = new MockERC20();
        mock = new MockStrategy(token);
        vault = new MinimalVault(IERC20(address(token)), IStrategy(address(mock)));
    }

    function test_transferFromEmitsApprovalWhenAllowanceReduced() public {
        address spender = address(this);
        address to = address(0xDEAD);

        // Mint tokens to this contract and deposit to receive shares
        uint256 amount = 1_000e18;
        token.mint(address(this), amount);
        token.approve(address(vault), amount);
        vault.deposit(amount);

        // Approve spender for some value
        uint256 allowanceVal = 500e18;
        vault.approve(spender, allowanceVal);

        // Now call transferFrom(from = address(this), to, value) as spender (this contract)
        bool ok = vault.transferFrom(address(this), to, 200e18);
        require(ok, "transferFrom failed");

        // Check that the stored allowance decreased as expected
        uint256 expected = allowanceVal - 200e18;
        require(vault.allowance(address(this), spender) == expected, "allowance not decreased");
    }
}
