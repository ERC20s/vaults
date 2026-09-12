// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "./MockERC20.sol";

/// @notice Mock token that adds a naive `permit` implementation for tests.
/// @dev This is not a production permit implementation: it accepts any signed data
/// by simply setting the allowance when `permit` is called. Tests should construct
/// the scenario by calling `permit` directly rather than supplying a real signature.
contract MockERC20Permit is MockERC20 {
    function permit(address owner, address spender, uint256 value, uint256, uint8, bytes32, bytes32) external {
        allowance[owner][spender] = value;
        emit Approval(owner, spender, value);
    }
}
