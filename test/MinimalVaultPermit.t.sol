// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {MockERC20Permit} from "./mocks/MockERC20Permit.sol";
import {MockStrategy} from "./mocks/MockStrategy.sol";
import {MinimalVault} from "../src/vault/MinimalVault.sol";
import {IStrategy} from "../src/interfaces/IStrategy.sol";
import {IERC20} from "../src/utils/SafeERC20.sol";

contract MinimalVaultPermitTest {
    MockERC20Permit token;
    MockStrategy mock;
    MinimalVault vault;

    function setUp() public {
        token = new MockERC20Permit();
        mock = new MockStrategy(MockERC20(address(token)));
        vault = new MinimalVault(IERC20(address(token)), IStrategy(address(mock)));
    }

    function test_DepositWithPermitSetsAllowanceAndDeposits() public {
        uint256 amount = 1_000e18;
        token.mint(address(this), amount);

        // Call permit to set allowance (mock accepts any call)
        token.permit(address(this), address(vault), amount, type(uint256).max, 0, bytes32(0), bytes32(0));

        uint256 preview = vault.previewDeposit(amount);
        uint256 shares = vault.depositWithPermit(amount, type(uint256).max, 0, bytes32(0), bytes32(0));

        require(shares == preview, "depositWithPermit: shares != preview");
        require(token.allowance(address(vault), address(mock)) == 0, "allowance not consumed by strategy");
        require(token.balanceOf(address(mock)) == amount, "strategy custody missing");
    }

    function test_MintWithPermitSetsAllowanceAndMints() public {
        uint256 shares = 2_000e18;
        token.mint(address(this), shares);

        token.permit(address(this), address(vault), shares, type(uint256).max, 0, bytes32(0), bytes32(0));

        uint256 assets = vault.mintWithPermit(shares, type(uint256).max, 0, bytes32(0), bytes32(0));

        require(assets > 0, "mintWithPermit did not return assets");
        require(token.allowance(address(vault), address(mock)) == 0, "allowance not consumed by strategy");
        require(token.balanceOf(address(mock)) == assets, "strategy custody missing");
    }
}
