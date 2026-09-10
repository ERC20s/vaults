// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {MinimalVault} from "../src/vault/MinimalVault.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockStrategy} from "./mocks/MockStrategy.sol";
import {IStrategy} from "../src/interfaces/IStrategy.sol";
import {IERC20} from "../src/utils/SafeERC20.sol";

contract MinimalVaultConstructorTest {
    function test_ConstructRevertsOnZeroToken() public {
        MockStrategy strat = new MockStrategy(MockERC20(address(0)));
        // Attempt to construct with token zero address
        try new MinimalVault(IERC20(address(0)), IStrategy(address(strat))) returns (MinimalVault) {
            revert("construction did not revert on zero token");
        } catch Error(string memory reason) {
            require(keccak256(bytes(reason)) == keccak256(bytes("MinimalVault: zero-token")), "unexpected revert message");
        } catch {
            revert("construction reverted with non-string error");
        }
    }

    function test_ConstructRevertsOnZeroStrategy() public {
        MockERC20 token = new MockERC20();
        // Attempt to construct with strategy zero address
        try new MinimalVault(IERC20(address(token)), IStrategy(address(0))) returns (MinimalVault) {
            revert("construction did not revert on zero strategy");
        } catch Error(string memory reason) {
            require(keccak256(bytes(reason)) == keccak256(bytes("MinimalVault: zero-strategy")), "unexpected revert message");
        } catch {
            revert("construction reverted with non-string error");
        }
    }

    function test_ConstructSucceedsOnNonZeroAddresses() public {
        MockERC20 token = new MockERC20();
        MockStrategy strat = new MockStrategy(token);
        MinimalVault v = new MinimalVault(IERC20(address(token)), IStrategy(address(strat)));
        require(address(v) != address(0), "constructed contract has zero address");
    }
}
