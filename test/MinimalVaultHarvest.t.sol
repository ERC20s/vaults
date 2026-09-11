// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockStrategy} from "./mocks/MockStrategy.sol";
import {MinimalVault} from "../src/vault/MinimalVault.sol";
import {IERC20} from "../src/utils/SafeERC20.sol";

contract MinimalVaultHarvestTest is Test {
    MockERC20 token;
    MockStrategy strategy;
    MinimalVault vault;

    function setUp() public {
        token = new MockERC20();
        strategy = new MockStrategy(token);
        vault = new MinimalVault(IERC20(address(token)), strategy);
    }

    function test_harvest_emits_event_and_returns_harvested_amount() public {
        // deposit some principal to the strategy through the vault
        uint256 amount = 1_000e18;
        token.mint(address(this), amount);
        token.approve(address(vault), amount);
        vault.deposit(amount);

        // create realised gain by minting tokens directly into the strategy
        token.mint(address(strategy), 500e18);

        // expect the Harvest event with caller = this and harvested = 500e18
        vm.expectEmit(true, false, false, true);
        emit MinimalVault.Harvest(address(this), 500e18);

        uint256 harvested = vault.harvest();
        require(harvested == 500e18, "harvest returned wrong amount");
    }

    function test_panic_emits_event_and_unlocks_liquidity() public {
        // deposit some principal and make part illiquid
        uint256 amount = 1_000e18;
        token.mint(address(this), amount);
        token.approve(address(vault), amount);
        vault.deposit(amount);

        strategy.setIlliquid(800e18);
        // strategy.maxWithdraw should now be 200e18
        require(strategy.maxWithdraw() == 200e18, "setup wrong");

        // expect Panic event
        vm.expectEmit(true, false, false, true);
        emit MinimalVault.Panic(address(this));

        vault.panic();

        // after panic, illiquid is 0 and strategy.maxWithdraw() should be full balance
        require(strategy.maxWithdraw() == strategy.totalAssets(), "panic did not unlock liquidity");
    }
}
