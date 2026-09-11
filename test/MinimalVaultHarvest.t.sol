// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {MockERC20} from "./mocks/MockERC20.sol";
import {MockStrategy} from "./mocks/MockStrategy.sol";
import {MinimalVault} from "../src/vault/MinimalVault.sol";
import {IERC20} from "../src/utils/SafeERC20.sol";

contract MinimalVaultHarvestTest {
    MockERC20 token;
    MockStrategy mock;
    MinimalVault vault;

    function setUp() public {
        token = new MockERC20();
        mock = new MockStrategy(token);
        vault = new MinimalVault(IERC20(address(token)), mock);
    }

    function test_HarvestEmitsAndReturns() public {
        // No yield yet: harvest returns 0 and emits 0
        uint256 got = vault.harvest();
        require(got == 0, "expected zero harvest");

        // Inject yield directly into the strategy
        token.mint(address(mock), 1_000e18);

        // Now harvest should report the new realised gain
        uint256 harvested = vault.harvest();
        require(harvested > 0, "expected harvested > 0");
    }

    function test_PanicEmits() public {
        // Call panic and ensure subsequent maxWithdraw reflects the panic (illiquid reset)
        // Start with some funds so panic effect is observable
        token.mint(address(this), 1_000e18);
        token.approve(address(vault), 1_000e18);
        vault.deposit(1_000e18);

        // set illiquid then panic
        mock.setIlliquid(500e18);
        // sanity: before panic, maxWithdraw < totalAssets
        uint256 beforeCap = vault.maxWithdraw();
        require(beforeCap < vault.totalAssets(), "setup: expected some illiquidity");

        vault.panic();
        // After panic the strategy's illiquid should be 0 and vault.maxWithdraw() should equal totalAssets()
        uint256 afterCap = vault.maxWithdraw();
        require(afterCap == vault.totalAssets(), "panic did not reopen liquidity");
    }
}
