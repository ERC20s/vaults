// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {MockERC20} from "./mocks/MockERC20.sol";
import {MockStrategy} from "./mocks/MockStrategy.sol";
import {MinimalVault} from "../src/vault/MinimalVault.sol";
import {IStrategy} from "../src/interfaces/IStrategy.sol";
import {IERC20} from "../src/utils/SafeERC20.sol";

interface Vm {
    function expectEmit(bool, bool, bool, bool) external;
}

Vm constant vm = Vm(address(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D));

contract MinimalVaultHarvestTest {
    MockERC20 token;
    MockStrategy mock;
    MinimalVault vault;

    // Local declarations of the event signatures the vault emits so vm.expectEmit can match them.
    event Harvest(address indexed caller, uint256 harvested);
    event Panic(address indexed caller);

    function setUp() public {
        token = new MockERC20();
        mock = new MockStrategy(token);
        vault = new MinimalVault(IERC20(address(token)), IStrategy(address(mock)));
    }

    function test_harvest_emitsEventAndReturnsHarvested() public {
        // Setup: mint some realised gain into the strategy
        token.mint(address(mock), 1_000e18);

        // Compute the expected harvested amount without consuming it here.
        uint256 expected = mock.totalAssets() - mock.principal();

        // Expect the Harvest event with caller == address(this) and the harvested amount
        vm.expectEmit(true, false, false, true);
        emit Harvest(address(this), expected);

        uint256 harvested = vault.harvest();
        require(harvested == expected, "harvest returned unexpected value");
    }

    function test_panic_emitsEventAndMakesAssetsWithdrawable() public {
        // Make some of the strategy illiquid so maxWithdraw is limited
        token.mint(address(mock), 1_000e18);
        mock.setIlliquid(500e18);

        vm.expectEmit(true, false, false, false);
        emit Panic(address(this));

        vault.panic();
        require(mock.maxWithdraw() == mock.totalAssets(), "panic did not recover assets");
    }
}
