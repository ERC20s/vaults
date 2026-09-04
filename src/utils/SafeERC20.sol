// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/// @notice Minimal IERC20 interface used by SafeERC20.
/// @dev `allowance` is required by `SafeERC20.safeApprove`, which resets a non-zero
/// allowance to zero before setting a new non-zero one (see the library below).
/// `balanceOf` is declared so callers that hold the token as `IERC20` (for example
/// `src/vault/MinimalVault.sol`) can read balances without a second interface.
interface IERC20 {
    function transfer(address to, uint256 value) external returns (bool);
    function transferFrom(address from, address to, uint256 value) external returns (bool);
    function approve(address spender, uint256 value) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
}

/// @title SafeERC20 (minimal, dependency-free)
/// @notice Provides safe wrappers around ERC20 operations that may or may not return a boolean.
/// This mirrors the behaviour of OpenZeppelin's SafeERC20 with a tiny, dependency-free implementation
/// suitable for tests and small fixtures.
library SafeERC20 {
    bytes4 private constant SELECTOR_TRANSFER = bytes4(keccak256("transfer(address,uint256)"));
    bytes4 private constant SELECTOR_TRANSFER_FROM = bytes4(keccak256("transferFrom(address,address,uint256)"));
    bytes4 private constant SELECTOR_APPROVE = bytes4(keccak256("approve(address,uint256)"));

    function safeTransfer(IERC20 token, address to, uint256 value) internal {
        _callOptionalReturn(token, abi.encodeWithSelector(SELECTOR_TRANSFER, to, value));
    }

    function safeTransferFrom(IERC20 token, address from, address to, uint256 value) internal {
        _callOptionalReturn(token, abi.encodeWithSelector(SELECTOR_TRANSFER_FROM, from, to, value));
    }

    /// @notice Sets `spender`'s allowance to exactly `value`, tolerating tokens that
    /// forbid a direct non-zero -> non-zero allowance change (the USDT-style rule).
    /// @dev When the current allowance is non-zero and `value` is non-zero, the allowance
    /// is first written down to zero and only then set to `value`. Setting an allowance to
    /// zero, or setting one from zero, is a single call exactly as before. Both calls go
    /// through `_callOptionalReturn`, so tokens that return nothing are still accepted.
    /// This costs one extra `approve` in the reset case; it is the widely used mitigation.
    function safeApprove(IERC20 token, address spender, uint256 value) internal {
        if (value != 0 && token.allowance(address(this), spender) != 0) {
            _callOptionalReturn(token, abi.encodeWithSelector(SELECTOR_APPROVE, spender, uint256(0)));
        }
        _callOptionalReturn(token, abi.encodeWithSelector(SELECTOR_APPROVE, spender, value));
    }

    function _callOptionalReturn(IERC20 token, bytes memory data) private {
        (bool success, bytes memory returndata) = address(token).call(data);
        require(success, "SafeERC20: low-level call failed");
        if (returndata.length > 0) {
            // Return data is optional
            require(abi.decode(returndata, (bool)), "SafeERC20: ERC20 operation did not succeed");
        }
    }
}
