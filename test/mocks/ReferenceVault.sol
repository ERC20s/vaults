// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IStrategy} from "../../src/interfaces/IStrategy.sol";
import {MockERC20} from "./MockERC20.sol";
import {SafeERC20, IERC20} from "../../src/utils/SafeERC20.sol";

/// @title ReferenceVault (test-only)
/// @notice Minimal, deliberately underspecified vault used only by the test-suite as a
/// reference implementation of how a Vault must interact with an IStrategy. TEST FIXTURE:
/// do not treat this as production code (no ownership, no reentrancy guards, no share
/// accounting).
///
/// Behaviour it demonstrates:
/// - deposit: PULLs tokens from the caller into this contract, approves the strategy
///   for exactly that amount and calls strategy.deposit(amount); the allowance must be
///   consumed by the strategy's deposit() call.
/// - totalAssets/maxWithdraw: forwarded to the strategy's read views.
/// - withdraw: calls strategy.withdraw(amount), receives the pushed tokens, then forwards
///   the exact amount the strategy returned to the original caller and returns it.
contract ReferenceVault {
    using SafeERC20 for IERC20;

    MockERC20 public immutable token;
    IStrategy public immutable strategy;

    constructor(MockERC20 token_, IStrategy strategy_) {
        token = token_;
        strategy = strategy_;
    }

    /// @dev The token as the interface SafeERC20 is written against. MockERC20 does not
    /// inherit IERC20, so the library is attached to IERC20 and the mock is wrapped here.
    function _token() internal view returns (IERC20) {
        return IERC20(address(token));
    }

    /// @notice Pulls `amount` from the caller into this contract, approves the strategy
    /// for exactly `amount`, and calls strategy.deposit(amount). After the call the
    /// contract's allowance for the strategy MUST be 0 (the strategy pulled the funds).
    function deposit(uint256 amount) external {
        // Pull from caller into the vault first.
        _token().safeTransferFrom(msg.sender, address(this), amount);

        // Approve the strategy for exactly the amount we intend to send it.
        _token().safeApprove(address(strategy), amount);

        // Let the strategy pull from this vault. It must consume the allowance.
        strategy.deposit(amount);

        // Note: we do not keep any balance: strategy.deposit MUST pull the tokens.
        // The tests assert the allowance was consumed and custody moved to the strategy.
    }

    /// @notice Calls strategy.withdraw(amount), receives the pushed tokens and forwards
    /// exactly the amount the strategy returned to msg.sender. Returns the amount forwarded.
    function withdraw(uint256 amount) external returns (uint256 withdrawn) {
        uint256 before = token.balanceOf(address(this));
        withdrawn = strategy.withdraw(amount);
        uint256 delta = token.balanceOf(address(this)) - before;
        require(withdrawn == delta, "ReferenceVault: strategy returned mismatch");
        if (withdrawn > 0) {
            _token().safeTransfer(msg.sender, withdrawn);
        }
        return withdrawn;
    }

    /// @notice Forwarding view of the strategy's totalAssets().
    function totalAssets() external view returns (uint256) {
        return strategy.totalAssets();
    }

    /// @notice Forwarding view of the strategy's maxWithdraw().
    function maxWithdraw() external view returns (uint256) {
        return strategy.maxWithdraw();
    }
}
