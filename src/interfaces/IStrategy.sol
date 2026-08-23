// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/// @title IStrategy
/// @notice Minimal interface that a Vault-compatible yield strategy must implement.
/// @dev This interface is intentionally small to reduce early coupling. Implementations
/// should document any additional invariants and units (underlying token units vs vault shares).
interface IStrategy {
    /// @notice Returns the total assets managed by the strategy, denominated in the underlying token.
    /// @dev Must not revert. Used by Vault to compute total assets and share price.
    function totalAssets() external view returns (uint256);

    /// @notice Deposits `amount` of underlying token into the strategy.
    /// @param amount The amount of underlying tokens to deposit.
    /// @dev Implementations should transfer tokens from msg.sender or expect pre-approval.
    function deposit(uint256 amount) external;

    /// @notice Withdraws up to `amount` of underlying token from the strategy.
    /// @param amount The desired amount to withdraw.
    /// @return withdrawn The actual amount withdrawn and returned to the caller.
    /// @dev Implementations should return the actual amount made available to the caller.
    function withdraw(uint256 amount) external returns (uint256 withdrawn);

    /// @notice Harvests yields and returns any harvested amount (if applicable).
    /// @return harvested The amount of underlying token realized during harvest.
    /// @dev This may be a no-op for simple strategies; Vault callers may rely on this
    /// to realise gains before accounting or fee calculation.
    function harvest() external returns (uint256 harvested);

    /// @notice Emergency hook to unwind positions and make assets available to the Vault.
    /// @dev This function is intended for emergency use and may be restricted by access control
    /// in real implementations. It should aim to maximize recoverable assets, accepting
    /// that some slippage or loss may occur during an emergency exit.
    function panic() external;
}
