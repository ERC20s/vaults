// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/// @title MockNonStandardERC20
/// @notice A USDT-style test token: `approve` REVERTS when it would change a non-zero
/// allowance straight to another non-zero value, and none of `approve`, `transfer` or
/// `transferFrom` return a boolean.
/// @dev Test fixture only (unrestricted `mint`, no events beyond the two standard ones).
/// It exists so `SafeERC20.safeApprove` can be proved to work against tokens that enforce
/// the zero-reset rule; `approveCalls` counts how many times `approve` was entered so a
/// test can show the library made two calls (reset + set) instead of one.
contract MockNonStandardERC20 {
    string public name = "Non-Standard Token";
    string public symbol = "NSTD";
    uint8 public constant decimals = 6;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    /// @notice Number of times `approve` was entered (including the reverting attempts
    /// that happen before the revert takes effect only if they succeed — a revert undoes
    /// the increment, so this counts successful approvals).
    uint256 public approveCalls;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    /// @notice USDT-style approve: no return value, and a non-zero -> non-zero change reverts.
    function approve(address spender, uint256 amount) external {
        require(
            amount == 0 || allowance[msg.sender][spender] == 0,
            "NSTD: approve from non-zero to non-zero"
        );
        approveCalls += 1;
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
    }

    /// @notice No boolean return, on purpose.
    function transfer(address to, uint256 amount) external {
        _transfer(msg.sender, to, amount);
    }

    /// @notice No boolean return, on purpose.
    function transferFrom(address from, address to, uint256 amount) external {
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amount, "NSTD: insufficient allowance");
        if (allowed != type(uint256).max) {
            allowance[from][msg.sender] = allowed - amount;
        }
        _transfer(from, to, amount);
    }

    function _transfer(address from, address to, uint256 amount) internal {
        require(balanceOf[from] >= amount, "NSTD: insufficient balance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
    }
}
