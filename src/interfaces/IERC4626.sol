// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/// @title IERC4626
/// @notice Minimal ERC-4626 interface containing the function signatures and events
/// implemented by MinimalVault. This file is intentionally small and dependency-free.
interface IERC4626 {
    // Events
    event Deposit(address indexed caller, address indexed owner, uint256 assets, uint256 shares);
    event Withdraw(address indexed caller, address indexed receiver, uint256 assets, uint256 shares);

    // Asset accounting
    function asset() external view returns (address);
    function totalAssets() external view returns (uint256);

    // Conversion helpers
    function convertToShares(uint256 amount) external view returns (uint256);
    function convertToAssets(uint256 shares) external view returns (uint256);

    // Deposit/mint/withdraw/redeem
    function previewDeposit(uint256 amount) external view returns (uint256);
    function previewMint(uint256 shares) external view returns (uint256);
    function previewWithdraw(uint256 assets) external view returns (uint256);
    function previewRedeem(uint256 shares) external view returns (uint256);

    function maxDeposit(address owner) external view returns (uint256);
    function maxMint(address owner) external view returns (uint256);
    function maxWithdraw(address owner) external view returns (uint256);
    function maxRedeem(address owner) external view returns (uint256);

    function deposit(uint256 amount) external returns (uint256 shares);
    function mint(uint256 shares) external returns (uint256 assets);
    function withdraw(uint256 assets) external returns (uint256 withdrawn);
    function redeem(uint256 shares) external returns (uint256 withdrawn);
}
