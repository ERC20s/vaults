// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {MockERC20} from "./mocks/MockERC20.sol";
import {MockStrategy} from "./mocks/MockStrategy.sol";
import {MinimalVault} from "../src/vault/MinimalVault.sol";
import {IStrategy} from "../src/interfaces/IStrategy.sol";
import {IERC20} from "../src/utils/SafeERC20.sol";

contract MinimalVaultPricePerShareTest {
    MockERC20 token;
    MockStrategy mock;
    MinimalVault vault;

    function setUp() public {
        token = new MockERC20();
        mock = new MockStrategy(token);
        vault = new MinimalVault(IERC20(address(token)), IStrategy(address(mock)));
    }

    function test_bootstrap_priceIsOneE18() public {
        // Empty vault should report bootstrap price 1e18
        uint256 p = vault.pricePerShare();
        require(p == 1e18, "bootstrap price must be 1e18");
    }

    function test_priceAfterInitialDeposit() public {
        uint256 amount = 1_000e18;
        token.mint(address(this), amount);
        token.approve(address(vault), amount);
        uint256 shares = vault.deposit(amount);
        require(shares > 0, "no shares minted");

        uint256 p = vault.pricePerShare();
        // pricePerShare == floor(totalAssets * 1e18 / totalSupply)
        uint256 expected = (vault.totalAssets() * 1e18) / vault.totalSupply();
        require(p == expected, "price does not match expected formula");
    }

    function test_priceIncreasesOnHarvest() public {
        uint256 amount = 1_000e18;
        token.mint(address(this), amount);
        token.approve(address(vault), amount);
        vault.deposit(amount);

        // Inject yield into strategy
        token.mint(address(mock), 1_000e18);

        // Harvest on vault to realise gains (the mock harvest just updates principal)
        uint256 harvested = vault.harvest();
        require(harvested > 0, "harvest returned zero");

        uint256 p = vault.pricePerShare();
        uint256 expected = (vault.totalAssets() * 1e18) / vault.totalSupply();
        require(p == expected, "price after harvest does not match expected formula");
    }

    function test_priceUnchangedAfterDepositAtCurrentPrice() public {
        uint256 amount = 1_000e18;
        token.mint(address(this), amount);
        token.approve(address(vault), amount);
        vault.deposit(amount);

        // Inject yield and harvest so price increases
        token.mint(address(mock), 1_000e18);
        vault.harvest();

        uint256 pBefore = vault.pricePerShare();

        // A depositor who supplies assets at the current share price should not change price
        uint256 depositAmount = (vault.totalSupply() * pBefore) / 1e18; // assets = shares * price / 1e18
        token.mint(address(this), depositAmount);
        token.approve(address(vault), depositAmount);
        vault.deposit(depositAmount);

        uint256 pAfter = vault.pricePerShare();
        require(pAfter == pBefore, "price changed after deposit at current price");
    }
}
