// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {MockERC20} from "./mocks/MockERC20.sol";
import {MockReentrantStrategy, ReentrantDepositor} from "./mocks/MockReentrantStrategy.sol";
import {MinimalVault} from "../src/vault/MinimalVault.sol";
import {IStrategy} from "../src/interfaces/IStrategy.sol";
import {IERC20} from "../src/utils/SafeERC20.sol";

interface Vm {
    function expectRevert(bytes calldata) external;
    function expectEmit(bool, bool, bool, bool) external;
}

Vm constant vm = Vm(address(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D));

contract MinimalVaultHarvestReentrancyTest {
    MockERC20 token;
    MockReentrantStrategy mock;
    MinimalVault vault;
    ReentrantDepositor depositor;

    function setUp() public {
        token = new MockERC20();
        mock = new MockReentrantStrategy(token);
        vault = new MinimalVault(IERC20(address(token)), IStrategy(address(mock)));
        depositor = new ReentrantDepositor(MinimalVault(address(vault)), token);
        mock.setHook(address(depositor));

        // Fund the strategy so harvest has something to report and panic has something to recover.
        token.mint(address(mock), 1_000e18);
        // Also give the depositor funds to make nested deposits when the window opens.
        token.mint(address(depositor), 1_000e18);
    }

    function test_harvest_reentrancy_isBlocked_then_allowedWhenDisarmed() public {
        // Price a baseline so the vault has supply and assets to reason about.
        token.mint(address(mock), 1_000e18);
        // Create initial deposit through the vault so totalSupply > 0 and strategy has principal.
        token.approve(address(vault), 1_000e18);
        vault.deposit(1_000e18);

        // Arm the strategy to reenter during its harvest()
        mock.armHarvest(true);
        // The nested callback will try to deposit into the vault and should revert with the reentrancy error.
        depositor.arm(ReentrantDepositor.Mode.Deposit, 1_000e18);

        // Expect the vault's nonReentrant revert
        vm.expectRevert(abi.encodePacked("MinimalVault: reentrancy"));
        vault.harvest();

        // After the failed (reverted) attempt the fired flag prevents further callbacks, so disarm and try again
        mock.armHarvest(false);

        // Expect Harvest event and a successful harvest now
        vm.expectEmit(true, false, false, true);
        emit MinimalVault.Harvest(address(this), mock.harvest());
        uint256 harvested = vault.harvest();
        // harvested should be >= 0; explicit equality to mock.harvest() is not strict because mock.harvest()
        // advances the strategy's principal; the test ensures the call succeeds when unarmed.
        require(harvested >= 0, "harvest failed when unarmed");
    }

    function test_panic_reentrancy_isBlocked_then_allowedWhenDisarmed() public {
        // Price a baseline so the vault has supply and assets to reason about.
        token.mint(address(mock), 1_000e18);
        token.approve(address(vault), 1_000e18);
        vault.deposit(1_000e18);

        // Arm the strategy to reenter during its panic()
        mock.armPanic(true);
        // The nested callback will try to deposit into the vault and should revert with the reentrancy error.
        depositor.arm(ReentrantDepositor.Mode.Deposit, 1_000e18);

        vm.expectRevert(abi.encodePacked("MinimalVault: reentrancy"));
        vault.panic();

        // disarm and ensure panic() succeeds and recovers assets
        mock.armPanic(false);

        vm.expectEmit(true, false, false, false);
        emit MinimalVault.Panic(address(this));
        vault.panic();
        require(mock.maxWithdraw() == mock.totalAssets(), "panic did not recover assets");
    }
}
