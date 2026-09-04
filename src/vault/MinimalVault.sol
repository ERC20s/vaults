// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IStrategy} from "../interfaces/IStrategy.sol";
import {SafeERC20, IERC20} from "../utils/SafeERC20.sol";

/// @title MinimalVault
/// @notice A small, auditable example vault that demonstrates an ERC-4626-like surface
/// and the exact custody boundary with an IStrategy. It is intentionally minimal: no
/// ownership, fees, pausing or reentrancy guards. Uses SafeERC20 for token ops.
contract MinimalVault {
    using SafeERC20 for IERC20;

    IERC20 public immutable token;
    IStrategy public immutable strategy;

    mapping(address => uint256) public balanceOf;
    uint256 public totalSupply;

    constructor(IERC20 token_, IStrategy strategy_) {
        token = token_;
        strategy = strategy_;
    }

    /// @notice Deposit `amount` underlying and receive shares.
    /// @dev Pulls from caller, approves strategy exactly, calls strategy.deposit(amount)
    /// and mints shares using conservative (floor) rounding. Returns minted shares.
    function deposit(uint256 amount) external returns (uint256 shares) {
        uint256 totalAssetsBefore = strategy.totalAssets();

        // Pull tokens from caller into the vault
        token.safeTransferFrom(msg.sender, address(this), amount);

        // Approve strategy for exactly amount and let it pull
        token.safeApprove(address(strategy), amount);
        strategy.deposit(amount);

        shares = _convertToShares(amount, totalAssetsBefore);
        // Mint shares
        totalSupply += shares;
        balanceOf[msg.sender] += shares;
        return shares;
    }

    /// @notice Mint `shares` by supplying the required underlying.
    /// @dev Computes required assets, pulls them, approves the strategy and deposits.
    function mint(uint256 shares) external returns (uint256 assets) {
        uint256 totalAssetsBefore = strategy.totalAssets();
        assets = _convertToAssetsForMint(shares, totalAssetsBefore);

        token.safeTransferFrom(msg.sender, address(this), assets);
        token.safeApprove(address(strategy), assets);
        strategy.deposit(assets);

        totalSupply += shares;
        balanceOf[msg.sender] += shares;
        return assets;
    }

    /// @notice Withdraw up to `assets` by burning proportional shares from caller.
    /// @dev Calls strategy.withdraw(assets) and burns shares proportional to the
    /// actual amount returned (ceil), then forwards tokens to caller.
    function withdraw(uint256 assets) external returns (uint256 withdrawn) {
        uint256 totalAssetsBefore = strategy.totalAssets();
        require(totalAssetsBefore > 0 && totalSupply > 0, "no-liquidity");

        uint256 before = tokenBalanceOf(address(this));
        uint256 got = strategy.withdraw(assets);
        uint256 balanceAfter = tokenBalanceOf(address(this));
        withdrawn = balanceAfter - before;
        require(got == withdrawn, "MinimalVault: strategy returned mismatch");

        // Burn shares proportional to withdrawn amount (ceil)
        uint256 sharesToBurn = (withdrawn * totalSupply + totalAssetsBefore - 1) / totalAssetsBefore;
        require(balanceOf[msg.sender] >= sharesToBurn, "insufficient shares");
        balanceOf[msg.sender] -= sharesToBurn;
        totalSupply -= sharesToBurn;

        if (withdrawn > 0) {
            token.safeTransfer(msg.sender, withdrawn);
        }
        return withdrawn;
    }

    /// @notice Redeem `shares` for underlying. Attempts to withdraw the assets
    /// corresponding to `shares`, handles strategy shortfalls by burning proportionate
    /// shares for the actual amount returned.
    function redeem(uint256 shares) external returns (uint256 withdrawn) {
        uint256 totalAssetsBefore = strategy.totalAssets();
        require(totalSupply > 0, "no-supply");

        // Compute assets to request (ceil) so we ask for enough to cover the shares.
        uint256 assetsRequested = (shares * totalAssetsBefore + totalSupply - 1) / totalSupply;

        uint256 before = tokenBalanceOf(address(this));
        uint256 got = strategy.withdraw(assetsRequested);
        uint256 balanceAfter = tokenBalanceOf(address(this));
        withdrawn = balanceAfter - before;
        require(got == withdrawn, "MinimalVault: strategy returned mismatch");

        // Compute shares to burn proportional to actual withdrawn (ceil)
        uint256 sharesToBurn = totalAssetsBefore == 0 ? 0 : (withdrawn * totalSupply + totalAssetsBefore - 1) / totalAssetsBefore;
        if (sharesToBurn > shares) {
            // Never burn more shares than caller offered; cap conservatively.
            sharesToBurn = shares;
        }
        require(balanceOf[msg.sender] >= sharesToBurn, "insufficient shares");
        balanceOf[msg.sender] -= sharesToBurn;
        totalSupply -= sharesToBurn;

        if (withdrawn > 0) {
            token.safeTransfer(msg.sender, withdrawn);
        }
        return withdrawn;
    }

    /// @notice Forwarded view of the strategy's totalAssets().
    function totalAssets() external view returns (uint256) {
        return strategy.totalAssets();
    }

    /// @notice Forwarded view of the strategy's maxWithdraw().
    function maxWithdraw() external view returns (uint256) {
        return strategy.maxWithdraw();
    }

    /// @notice Convert `amount` assets to shares using conservative floor rounding.
    function convertToShares(uint256 amount) external view returns (uint256) {
        return _convertToShares(amount, strategy.totalAssets());
    }

    /// @notice Convert `shares` to assets using floor rounding.
    function convertToAssets(uint256 shares) external view returns (uint256) {
        return _convertToAssets(shares, strategy.totalAssets());
    }

    // --- Internals ---
    function _convertToShares(uint256 amount, uint256 totalAssetsBefore) internal view returns (uint256) {
        if (totalSupply == 0 || totalAssetsBefore == 0) {
            // Bootstrap: 1:1 initial share for asset to keep it simple and deterministic.
            return amount;
        }
        return (amount * totalSupply) / totalAssetsBefore; // floor => conservative
    }

    function _convertToAssets(uint256 shares, uint256 totalAssetsBefore) internal view returns (uint256) {
        if (totalSupply == 0 || totalAssetsBefore == 0) {
            return shares;
        }
        return (shares * totalAssetsBefore) / totalSupply; // floor
    }

    function _convertToAssetsForMint(uint256 shares, uint256 totalAssetsBefore) internal view returns (uint256) {
        // When minting, require the caller to send enough assets to cover shares.
        if (totalSupply == 0 || totalAssetsBefore == 0) {
            return shares;
        }
        // Ceil so we collect enough assets to back the minted shares.
        return (shares * totalAssetsBefore + totalSupply - 1) / totalSupply;
    }

    function tokenBalanceOf(address who) internal view returns (uint256) {
        return IERC20(token).balanceOf(who);
    }
}
