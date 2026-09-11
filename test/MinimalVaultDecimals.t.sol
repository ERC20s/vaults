// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {MockERC20} from "./mocks/MockERC20.sol";
import {MockNonStandardERC20} from "./mocks/MockNonStandardERC20.sol";
import {MockNoDecimals} from "./mocks/MockNoDecimals.sol";
import {MockStrategy} from "./mocks/MockStrategy.sol";
import {MinimalVault} from "../src/vault/MinimalVault.sol";
import {IERC20} from "../src/utils/SafeERC20.sol";
import {IStrategy} from "../src/interfaces/IStrategy.sol";

contract NullStrategy is IStrategy {
    function totalAssets() external pure returns (uint256) { return 0; }
    function maxWithdraw() external pure returns (uint256) { return 0; }
    function deposit(uint256) external pure { revert("NullStrategy: unused"); }
    function withdraw(uint256) external pure returns (uint256) { revert("NullStrategy: unused"); }
    function harvest() external pure returns (uint256) { return 0; }
    function panic() external pure { }
}

contract MinimalVaultDecimalsTest {
    function test_DecimalsMatchAssetAndFallback() public {
        // Standard 18-decimal token
        MockERC20 t18 = new MockERC20();
        MockStrategy s18 = new MockStrategy(t18);
        MinimalVault v18 = new MinimalVault(IERC20(address(t18)), IStrategy(address(s18)));
        require(v18.decimals() == t18.decimals(), "expected 18 decimal match");

        // Non-standard token with 6 decimals
        MockNonStandardERC20 t6 = new MockNonStandardERC20();
        MockStrategy s6 = new MockStrategy(MockERC20(address(t6)));
        MinimalVault v6 = new MinimalVault(IERC20(address(t6)), IStrategy(address(s6)));
        require(v6.decimals() == t6.decimals(), "expected 6 decimal match");

        // Token with no decimals() method should cause the vault to fall back to 18
        MockNoDecimals none = new MockNoDecimals();
        IStrategy nullStrat = IStrategy(address(new NullStrategy()));
        MinimalVault vnone = new MinimalVault(IERC20(address(none)), nullStrat);
        require(vnone.decimals() == 18, "expected fallback to 18 when token has no decimals()");
    }
}
