// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IStrategy} from "./interfaces/IStrategy.sol";

/// @notice Minimal IERC20 subset used by this Vault implementation.
interface IERC20 {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
    function balanceOf(address who) external view returns (uint256);
}

/// @title Vault
/// @notice A tiny Vault that delegates custody to an IStrategy following the repository's
/// custody convention. This contract is deliberately minimal: no shares, no fees, just
/// the transfer plumbing that demonstrates the strategy boundary.
///
/// Behaviour (summary):
/// - deposit(amount): pulls `amount` from msg.sender into this Vault, approves exactly
///   `amount` to the strategy, calls strategy.deposit(amount) and asserts the allowance was
///   consumed and the strategy's reported totalAssets() increased by `amount`.
/// - withdraw(amount): calls strategy.withdraw(amount), uses the returned `withdrawn` as
///   the canonical amount received, forwards the tokens to the caller and returns it.
/// - totalAssets(), maxWithdraw(): forward to the strategy.
///
/// Security notes: this contract makes external calls to token and strategy. Callers must
/// approve this Vault for deposits. Implementations that extend this contract should
/// consider reentrancy guards; this minimal implementation relies on the checks-effects-
/// interactions pattern in its callers and documents the requirement rather than imposing
/// a particular guard.
contract Vault {
    IERC20 public immutable token;
    IStrategy public immutable strategy;

    constructor(IERC20 token_, IStrategy strategy_) {
        token = token_;
        strategy = strategy_;
    }

    /// @notice Deposit `amount` of underlying from the caller into the strategy through this Vault.
    /// @dev Pulls tokens from msg.sender, approves the strategy for exactly `amount` and calls
    ///      strategy.deposit(amount). As the custody rule requires, the strategy must pull from
    ///      the Vault with transferFrom and the Vault asserts the allowance was consumed.
    function deposit(uint256 amount) external {
        // Pull from the depositor into this Vault.
        require(token.transferFrom(msg.sender, address(this), amount), "Vault: pull failed");

        // Approve exactly `amount` to the strategy and call deposit.
        require(token.approve(address(strategy), amount), "Vault: approve failed");

        uint256 before = strategy.totalAssets();
        strategy.deposit(amount);

        // The strategy must have pulled the allowance. Check it was consumed.
        uint256 remaining = token.allowance(address(this), address(strategy));
        require(remaining == 0, "Vault: allowance not consumed");

        // For the reference strategy used in tests the totalAssets() increases by `amount`.
        uint256 after = strategy.totalAssets();
        require(after >= before, "Vault: strategy lost assets");
        require(after - before == amount, "Vault: strategy assets not increased by amount");
    }

    /// @notice Withdraw up to `amount` of underlying from the strategy and forward it to the caller.
    /// @dev Calls strategy.withdraw(amount). The strategy transfers the underlying to this Vault
    ///      (msg.sender = this contract) before returning, and returns the actual `withdrawn`.
    ///      The Vault then forwards the tokens to the original caller and returns `withdrawn`.
    function withdraw(uint256 amount) external returns (uint256 withdrawn) {
        uint256 before = token.balanceOf(address(this));
        withdrawn = strategy.withdraw(amount);
        uint256 received = token.balanceOf(address(this)) - before;
        require(withdrawn == received, "Vault: withdraw return mismatch");

        if (withdrawn > 0) {
            require(token.transfer(msg.sender, withdrawn), "Vault: transfer to caller failed");
        }
        return withdrawn;
    }

    /// @notice Forwarding view: total assets as reported by the strategy.
    function totalAssets() external view returns (uint256) {
        return strategy.totalAssets();
    }

    /// @notice Forwarding view: the strategy's reported maxWithdraw bound.
    function maxWithdraw() external view returns (uint256) {
        return strategy.maxWithdraw();
    }
}
