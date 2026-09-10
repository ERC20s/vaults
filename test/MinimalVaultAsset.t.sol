// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {MockERC20} from "./mocks/MockERC20.sol";
import {MockStrategy} from "./mocks/MockStrategy.sol";
import {MinimalVault} from "../src/vault/MinimalVault.sol";
import {IERC20} from "../src/utils/SafeERC20.sol";

contract MinimalVaultAssetTest {
    MockERC20 token;
    MockStrategy mock;
    MinimalVault vault;

    function setUp() public {
        token = new MockERC20();
        mock = new MockStrategy(token);
        vault = new MinimalVault(IERC20(address(token)), mock);
    }

    function test_AssetReturnsTokenAddressAndMetadataPresent() public {
        // asset() should return the underlying token address
        address a = vault.asset();
        require(a == address(token), "asset() mismatch");

        // Ensure existing metadata and views remain callable
        uint8 d = vault.decimals();
        require(d == token.decimals(), "decimals mismatch");

        string memory n = vault.name();
        string memory s = vault.symbol();
        require(bytes(n).length > 0, "name missing");
        require(bytes(s).length > 0, "symbol missing");
    }
}
