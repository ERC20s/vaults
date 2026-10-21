// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {MockERC20} from "./mocks/MockERC20.sol";
import {MockStrategy} from "./mocks/MockStrategy.sol";
import {MinimalVault} from "../src/vault/MinimalVault.sol";
import {IStrategy} from "../src/interfaces/IStrategy.sol";
import {IERC20} from "../src/utils/SafeERC20.sol";

contract RedeemOverflowTest {
    MockERC20 token;
    MockStrategy mock;
    MinimalVault vault;

    function setUp() public {
        token = new MockERC20();
        mock = new MockStrategy(token);
        vault = new MinimalVault(IERC20(address(token)), IStrategy(address(mock)), address(this));

        // Strategy boundary: the vault must be wired to exactly this strategy and this underlying,
        // otherwise the custody checks below would be measuring the wrong contracts.
        require(address(vault.strategy()) == address(mock), "vault not bound to the mock strategy");
        require(vault.asset() == address(token), "vault not bound to the mock token");
    }

    /// @notice Redeem with `shares * (totalAssets + 1)` larger than 2^256 - 1. A naive
    /// `shares * (totalAssets + 1) / (totalSupply + 1)` would panic on overflow; `_mulDivFloor`
    /// must return the exact floored quotient, and the strategy must pay out exactly that amount.
    function test_RedeemHandlesExtremeInputs() public {
        // Bootstrap 3 shares 1:1 against 3 assets.
        token.mint(address(this), 3);
        token.approve(address(vault), 3);
        require(vault.deposit(3) == 3, "bootstrap failed");

        // Inflate the strategy to `big` assets (as yield paid straight into it).
        uint256 big = type(uint256).max / 2 + 2;
        token.mint(address(mock), big - 3);
        require(vault.totalAssets() == big, "strategy not inflated");

        // The product the naive formula would form really does overflow.
        uint256 shares = 2;
        require(big + 1 > type(uint256).max / shares, "inputs do not overflow naive multiplication");

        // floor(2 * (big + 1) / (3 + 1)) - the virtual-pair price - computed without overflow.
        uint256 expected = ((big + 1) / 4) * shares + (((big + 1) % 4) * shares) / 4;

        uint256 callerBefore = token.balanceOf(address(this));
        uint256 withdrawn = vault.redeem(shares);

        require(withdrawn == expected, "redeem did not pay floor(shares * totalAssets / totalSupply)");
        // Custody rule: the strategy pushed exactly `withdrawn`, the vault forwarded all of it and
        // kept nothing, and the strategy still answers maxWithdraw() <= totalAssets().
        require(token.balanceOf(address(this)) - callerBefore == withdrawn, "caller balance delta != withdrawn");
        require(mock.totalAssets() == big - withdrawn, "strategy custody off by more than withdrawn");
        require(token.balanceOf(address(vault)) == 0, "underlying stranded in vault");
        require(mock.maxWithdraw() <= mock.totalAssets(), "strategy maxWithdraw above totalAssets");
        // Served in full, so every offered share is burned.
        require(vault.totalSupply() == 1, "wrong shares burned");
        require(vault.balanceOf(address(this)) == 1, "caller share balance wrong");
    }
}
