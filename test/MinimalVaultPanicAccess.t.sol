// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {MockERC20} from "./mocks/MockERC20.sol";
import {MockStrategy} from "./mocks/MockStrategy.sol";
import {MinimalVault} from "../src/vault/MinimalVault.sol";
import {IStrategy} from "../src/interfaces/IStrategy.sol";
import {IERC20} from "../src/utils/SafeERC20.sol";

interface Vm {
    function prank(address) external;
    function expectRevert(bytes calldata) external;
}

Vm constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

/// @title MinimalVaultPanicAccess
/// @notice Access control on the strategy wrappers. `panic()` is an emergency unwind that the
/// `IStrategy` contract says "may be restricted by access control in real implementations"; a
/// vault that forwarded it for any caller would let anyone force the unwind (and its slippage or
/// loss) on every holder, and would relay around a strategy that only trusts the vault's address.
/// Only the `guardian` set at construction may call it. `harvest()` stays open, and the strategy
/// itself is immutable, so there is no strategy-change path to restrict.
contract MinimalVaultPanicAccessTest {
    MockERC20 token;
    MockStrategy mock;
    MinimalVault vault;

    address constant STRANGER = address(0x5712A);

    function setUp() public {
        token = new MockERC20();
        mock = new MockStrategy(token);
        vault = new MinimalVault(IERC20(address(token)), IStrategy(address(mock)), address(this));
    }

    function test_GuardianIsTheConstructorArgument() public {
        require(vault.guardian() == address(this), "guardian is not the constructor argument");
        MinimalVault other = new MinimalVault(IERC20(address(token)), IStrategy(address(mock)), STRANGER);
        require(other.guardian() == STRANGER, "guardian did not follow the argument");
    }

    function test_ConstructorRejectsZeroGuardian() public {
        try new MinimalVault(IERC20(address(token)), IStrategy(address(mock)), address(0)) returns (MinimalVault) {
            revert("construction did not revert on a zero guardian");
        } catch Error(string memory reason) {
            require(
                keccak256(bytes(reason)) == keccak256(bytes("MinimalVault: zero-guardian")),
                "unexpected revert message"
            );
        } catch {
            revert("construction reverted with a non-string error");
        }
    }

    function test_PanicRevertsForNonGuardianAndLeavesTheStrategyAlone() public {
        token.mint(address(mock), 1_000e18);
        mock.setIlliquid(600e18);
        require(mock.maxWithdraw() == 400e18, "setup: lock not in place");

        vm.prank(STRANGER);
        vm.expectRevert(bytes("MinimalVault: not guardian"));
        vault.panic();

        require(mock.illiquid() == 600e18, "a stranger unwound the strategy through the vault");
        require(mock.maxWithdraw() == 400e18, "a stranger reopened the position through the vault");
    }

    function test_PanicWorksForTheGuardian() public {
        token.mint(address(mock), 1_000e18);
        mock.setIlliquid(600e18);

        vault.panic();

        require(mock.illiquid() == 0, "the guardian's panic did not unwind");
        require(mock.maxWithdraw() == mock.totalAssets(), "the guardian's panic did not reopen the position");
    }

    function test_HarvestStaysPermissionless() public {
        token.mint(address(mock), 5e18);

        vm.prank(STRANGER);
        uint256 harvested = vault.harvest();

        require(harvested == 5e18, "a stranger's harvest did not realise the gain");
        require(mock.totalAssets() == 5e18, "harvest moved assets out of custody");
    }
}
