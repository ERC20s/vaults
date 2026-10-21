// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {MockERC20} from "./mocks/MockERC20.sol";
import {MockReentrantStrategy, ReentrantDepositor, IVaultLike} from "./mocks/MockReentrantStrategy.sol";
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

    // Local declarations of the event signatures the vault emits so vm.expectEmit can match them
    // (qualified `emit MinimalVault.Harvest` needs solc >= 0.8.21; this repo pins 0.8.19).
    event Harvest(address indexed caller, uint256 harvested);
    event Panic(address indexed caller);

    function setUp() public {
        token = new MockERC20();
        mock = new MockReentrantStrategy(token);
        vault = new MinimalVault(IERC20(address(token)), IStrategy(address(mock)), address(this));
        depositor = new ReentrantDepositor(IVaultLike(address(vault)), token);
        mock.setHook(address(depositor));

        // The strategy is funded in each test AFTER the first deposit: an empty vault that already
        // holds assets prices a deposit against them, so a 1,000e18 deposit into 2,000e18 of
        // pre-funded assets would mint zero shares. Harvest and panic see the same gain either way.
        // Give the depositor funds to make nested deposits when the window opens.
        token.mint(address(depositor), 1_000e18);
    }

    function test_harvest_reentrancy_isBlocked_then_allowedWhenDisarmed() public {
        // Create initial deposit through the vault so totalSupply > 0 and strategy has principal.
        token.mint(address(this), 1_000e18);
        token.approve(address(vault), 1_000e18);
        vault.deposit(1_000e18);
        // Fund the strategy so harvest has something to report.
        token.mint(address(mock), 2_000e18);

        // Arm the strategy to reenter during its harvest()
        mock.armHarvest(true);
        // The nested callback will try to deposit into the vault and should revert with the reentrancy error.
        depositor.arm(ReentrantDepositor.Mode.Deposit, 1_000e18);

        // Expect the vault's nonReentrant revert
        vm.expectRevert(abi.encodePacked("MinimalVault: reentrancy"));
        vault.harvest();

        // After the failed (reverted) attempt the fired flag prevents further callbacks, so disarm and try again
        mock.armHarvest(false);

        // The reverted attempt realised nothing, so the gain above principal is still unharvested.
        // Read it without calling mock.harvest(), which would consume it before the vault does.
        uint256 expected = mock.totalAssets() - mock.principal();
        require(expected > 0, "no gain to harvest");

        // Expect Harvest event and a successful harvest now
        vm.expectEmit(true, false, false, true);
        emit Harvest(address(this), expected);
        uint256 harvested = vault.harvest();
        require(harvested == expected, "harvest returned unexpected value when unarmed");
    }

    function test_panic_reentrancy_isBlocked_then_allowedWhenDisarmed() public {
        // Price a baseline so the vault has supply and assets to reason about.
        token.mint(address(this), 1_000e18);
        token.approve(address(vault), 1_000e18);
        vault.deposit(1_000e18);
        // Fund the strategy so panic has something to recover.
        token.mint(address(mock), 2_000e18);

        // Arm the strategy to reenter during its panic()
        mock.armPanic(true);
        // The nested callback will try to deposit into the vault and should revert with the reentrancy error.
        depositor.arm(ReentrantDepositor.Mode.Deposit, 1_000e18);

        vm.expectRevert(abi.encodePacked("MinimalVault: reentrancy"));
        vault.panic();

        // disarm and ensure panic() succeeds and recovers assets
        mock.armPanic(false);

        vm.expectEmit(true, false, false, false);
        emit Panic(address(this));
        vault.panic();
        require(mock.maxWithdraw() == mock.totalAssets(), "panic did not recover assets");
    }
}
