// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/// @title IStrategy
/// @notice Minimal interface that a Vault-compatible yield strategy must implement.
/// @dev This interface is intentionally small to reduce early coupling.
///
/// Units: every `uint256` amount in this interface — arguments, return values and event
/// fields — is denominated in the strategy's underlying token, as reported by {asset}.
/// Amounts are NEVER vault shares. Implementations must not scale, wrap or otherwise
/// re-denominate these values.
///
/// Asset immutability: {asset} must return the same address for the whole life of the
/// strategy. A Vault is expected to bind a strategy once and to reject any strategy whose
/// {asset} differs from the Vault's own asset:
///
///     require(strategy.asset() == asset(), "asset mismatch");
///
/// Gross vs net: returned amounts are the amounts actually moved (net of any internal fee
/// or slippage the strategy applies), not the amounts requested.
interface IStrategy {
    /// @notice Emitted when underlying tokens are deposited into the strategy.
    /// @param caller The account that called {deposit} (normally the Vault).
    /// @param requested The amount of underlying tokens requested for deposit.
    /// @param deposited The amount of underlying tokens actually deposited.
    event Deposited(address indexed caller, uint256 requested, uint256 deposited);

    /// @notice Emitted when underlying tokens are withdrawn from the strategy.
    /// @param caller The account that called {withdraw} (normally the Vault).
    /// @param requested The amount of underlying tokens requested for withdrawal.
    /// @param withdrawn The amount of underlying tokens actually returned to the caller.
    event Withdrawn(address indexed caller, uint256 requested, uint256 withdrawn);

    /// @notice Emitted when the strategy realises yield.
    /// @param caller The account that called {harvest}.
    /// @param harvested The amount of underlying token realised during the harvest.
    event Harvested(address indexed caller, uint256 harvested);

    /// @notice Emitted when the strategy performs an emergency unwind.
    /// @param caller The account that called {panic}.
    event Panicked(address indexed caller);

    /// @notice The underlying token this strategy accepts, holds and accounts in.
    /// @return The ERC-20 token address that denominates every amount in this interface.
    /// @dev Must not revert and must be immutable for the life of the strategy. A Vault
    /// must check this against its own asset before wiring the strategy in.
    function asset() external view returns (address);

    /// @notice Returns the total assets managed by the strategy, denominated in {asset}.
    /// @dev Must not revert. Used by Vault to compute total assets and share price.
    function totalAssets() external view returns (uint256);

    /// @notice Deposits up to `amount` of the underlying token into the strategy.
    /// @param amount The amount of underlying tokens the caller wishes to deposit.
    /// @return deposited The amount of underlying tokens actually deposited, which may be
    /// less than `amount` (deposit caps, rounding, fee-on-transfer assets). The caller must
    /// account using this return value, not `amount`.
    /// @dev Implementations should transfer tokens from msg.sender or expect pre-approval,
    /// and should emit {Deposited}.
    function deposit(uint256 amount) external returns (uint256 deposited);

    /// @notice Withdraws up to `amount` of the underlying token from the strategy.
    /// @param amount The desired amount to withdraw.
    /// @return withdrawn The actual amount withdrawn and returned to the caller.
    /// @dev Implementations should return the actual amount made available to the caller
    /// and should emit {Withdrawn}.
    function withdraw(uint256 amount) external returns (uint256 withdrawn);

    /// @notice Harvests yields and returns any harvested amount (if applicable).
    /// @return harvested The amount of underlying token realized during harvest.
    /// @dev This may be a no-op for simple strategies; Vault callers may rely on this
    /// to realise gains before accounting or fee calculation. Should emit {Harvested}.
    function harvest() external returns (uint256 harvested);

    /// @notice Emergency hook to unwind positions and make assets available to the Vault.
    /// @dev This function is intended for emergency use and may be restricted by access control
    /// in real implementations. It should aim to maximize recoverable assets, accepting
    /// that some slippage or loss may occur during an emergency exit. Should emit {Panicked}.
    function panic() external;
}
