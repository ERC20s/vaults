// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/// @notice Minimal IERC20Permit interface for tests and vault helpers.
/// @dev Matches the EIP-2612 `permit` function signature.
interface IERC20Permit {
    function permit(address owner, address spender, uint256 value, uint256 deadline, uint8 v, bytes32 r, bytes32 s) external;
}
