// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/// @title IStrategy
/// @notice Minimal interface that a Vault-compatible yield strategy must implement.
/// @dev This interface is intentionally small to reduce early coupling. Implementations
/// should document any additional invariants and units (underlying token units vs vault shares).
///
/// Custody convention (single rule for the whole boundary):
/// - Every amount in this interface is denominated in the UNDERLYING token, never in vault shares.
/// - Deposits are PULL-based: the caller (the Vault) approves the strategy for at least `amount`
///   and the strategy pulls the tokens with transferFrom(msg.sender, ...) inside deposit().
///   A strategy must never expect the caller to push tokens ahead of the call, and must never
///   credit a balance it has not pulled itself.
/// - Withdrawals are PUSH-based: withdraw() transfers the underlying token to msg.sender before
///   it returns, and returns the amount actually transferred.
/// - The strategy therefore holds custody of the assets between deposit() and withdraw(); the
///   Vault holds no strategy-side balance and never relies on a token being sitting in transit.
interface IStrategy {
    /// @notice Returns the total assets managed by the strategy, denominated in the underlying token.
    /// @dev Must not revert. Used by Vault to compute total assets and share price.
    function totalAssets() external view returns (uint256);

    /// @notice Upper bound on what withdraw() can pay out in the current block, denominated in
    /// the underlying token.
    /// @return maxAssets The largest amount withdraw() is expected to return if called now.
    /// @dev Must not revert. Must be less than or equal to totalAssets(): the difference is the
    /// portion of the position that is illiquid this block (locked, in an epoch, or otherwise
    /// not immediately redeemable). A Vault uses this to answer ERC-4626 maxWithdraw/previewWithdraw
    /// honestly instead of calling withdraw() and discovering a shortfall after state has moved.
    /// It is an upper bound, not a promise: rounding or an intra-block change may still make
    /// withdraw() return less, so callers must use withdraw()'s return value for accounting.
    function maxWithdraw() external view returns (uint256 maxAssets);

    /// @notice Deposits `amount` of underlying token into the strategy.
    /// @param amount The amount of underlying tokens to deposit.
    /// @dev PULL-based: the caller must have approved the strategy for at least `amount` of the
    /// underlying token, and the strategy pulls it with transferFrom(msg.sender, ...) inside this
    /// call. Implementations must not assume tokens were transferred to them beforehand.
    function deposit(uint256 amount) external;

    /// @notice Withdraws up to `amount` of underlying token from the strategy.
    /// @param amount The desired amount to withdraw.
    /// @return withdrawn The actual amount withdrawn and transferred to msg.sender.
    /// @dev PUSH-based: the underlying token is transferred to msg.sender before this call
    /// returns, and `withdrawn` is exactly the amount transferred. `withdrawn` may be less than
    /// `amount` (and must not exceed maxWithdraw() at the start of the call); callers must use
    /// the return value, not `amount`, for their own accounting.
    function withdraw(uint256 amount) external returns (uint256 withdrawn);

    /// @notice Harvests yields and returns any harvested amount (if applicable).
    /// @return harvested The amount of underlying token realized during harvest.
    /// @dev This may be a no-op for simple strategies; Vault callers may rely on this
    /// to realise gains before accounting or fee calculation. Harvested assets stay in the
    /// strategy's custody and are visible through totalAssets(); they are not pushed to the caller.
    function harvest() external returns (uint256 harvested);

    /// @notice Emergency hook to unwind positions and make assets available to the Vault.
    /// @dev This function is intended for emergency use and may be restricted by access control
    /// in real implementations. It should aim to maximize recoverable assets, accepting
    /// that some slippage or loss may occur during an emergency exit. Unwound assets remain in
    /// the strategy's custody and are released through withdraw(); after panic() succeeds,
    /// maxWithdraw() should report the recovered, immediately redeemable balance.
    function panic() external;
}
