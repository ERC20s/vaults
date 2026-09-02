// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IStrategy} from "../interfaces/IStrategy.sol";
import {SafeERC20, IERC20} from "../utils/SafeERC20.sol";

/// @title MinimalVault
/// @notice A compact, dependency-free ERC-4626-like vault that delegates custody to an IStrategy.
/// @dev Intentionally minimal: no ownership, no fees, no reentrancy guards. Meant as a small,
/// auditable implementation that demonstrates the IStrategy custody boundary and share maths.
contract MinimalVault {
    using SafeERC20 for IERC20;

    IERC20 public immutable token;
    IStrategy public immutable strategy;

    // Simple share accounting
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    constructor(IERC20 token_, IStrategy strategy_) {
        token = token_;
        strategy = strategy_;
    }

    /// @notice Returns total assets as reported by the strategy.
    function totalAssets() public view returns (uint256) {
        return strategy.totalAssets();
    }

    /// @notice Forwards maxWithdraw() to the strategy.
    function maxWithdraw() public view returns (uint256) {
        return strategy.maxWithdraw();
    }

    /// @notice Converts an asset amount to shares (rounds DOWN).
    function convertToShares(uint256 assets) public view returns (uint256 shares) {
        uint256 S = totalSupply;
        uint256 A = strategy.totalAssets();
        if (S == 0 || A == 0) return assets;
        shares = (assets * S) / A;
    }

    /// @notice Converts shares to assets (rounds DOWN).
    function convertToAssets(uint256 shares) public view returns (uint256 assets) {
        uint256 S = totalSupply;
        uint256 A = strategy.totalAssets();
        if (S == 0 || A == 0) return shares;
        assets = (shares * A) / S;
    }

    /// @notice Deposit `assets` from caller; mints shares (round DOWN) to the caller.
    /// @dev deposit is PULL-based to the vault, then vault approves and calls strategy.deposit(amount)
    function deposit(uint256 assets) external returns (uint256 shares) {
        uint256 S = totalSupply;
        uint256 A = strategy.totalAssets();
        if (S == 0 || A == 0) {
            shares = assets; // 1:1 initial
        } else {
            shares = (assets * S) / A; // round down to avoid over-minting
        }
        require(shares > 0, "MinimalVault: zero shares");

        // Pull assets into vault, approve exactly, let strategy pull them
        token.safeTransferFrom(msg.sender, address(this), assets);
        token.safeApprove(address(strategy), assets);
        strategy.deposit(assets);

        // Mint shares to caller
        balanceOf[msg.sender] += shares;
        totalSupply += shares;
    }

    /// @notice Mint `shares` by providing the corresponding assets (round UP).
    function mint(uint256 shares) external returns (uint256 assets) {
        uint256 S = totalSupply;
        uint256 A = strategy.totalAssets();
        if (S == 0 || A == 0) {
            assets = shares; // 1:1 initial
        } else {
            // ceil(shares * A / S)
            uint256 num = shares * A;
            assets = num / S;
            if (num % S != 0) assets += 1;
        }
        require(assets > 0, "MinimalVault: zero assets");

        token.safeTransferFrom(msg.sender, address(this), assets);
        token.safeApprove(address(strategy), assets);
        strategy.deposit(assets);

        balanceOf[msg.sender] += shares;
        totalSupply += shares;
    }

    /// @notice Withdraw up to `assets` from the vault; burns the corresponding shares.
    /// @dev Uses conservative rounding: computes shares to burn by rounding up, then if the
    /// strategy returns fewer assets than requested, mints back the proportional share remainder.
    function withdraw(uint256 assets) external returns (uint256 withdrawn) {
        uint256 S = totalSupply;
        uint256 A = strategy.totalAssets();
        require(S > 0 && A > 0, "MinimalVault: empty");

        // sharesNeeded = ceil(assets * S / A)
        uint256 num = assets * S;
        uint256 sharesNeeded = num / A + (num % A == 0 ? 0 : 1);
        require(balanceOf[msg.sender] >= sharesNeeded, "MinimalVault: insufficient shares");

        // Burn shares up-front
        balanceOf[msg.sender] -= sharesNeeded;
        totalSupply -= sharesNeeded;

        // Ask strategy to push assets. It returns the actual amount transferred.
        withdrawn = strategy.withdraw(assets);

        if (withdrawn > 0) {
            token.safeTransfer(msg.sender, withdrawn);
        }

        // If strategy returned less than requested, restore shares proportional to the shortfall.
        if (withdrawn < assets) {
            // sharesForWithdrawn = floor(withdrawn * S / A)
            uint256 sharesForWithdrawn = (withdrawn * S) / A;
            if (sharesNeeded > sharesForWithdrawn) {
                uint256 toRestore = sharesNeeded - sharesForWithdrawn;
                balanceOf[msg.sender] += toRestore;
                totalSupply += toRestore;
            }
        }
    }

    /// @notice Redeem `shares` for underlying assets. Burns `shares` then calls strategy.withdraw
    /// for the corresponding assets (round UP) and returns the actually withdrawn amount.
    function redeem(uint256 shares) external returns (uint256 withdrawn) {
        uint256 S = totalSupply;
        uint256 A = strategy.totalAssets();
        require(S > 0 && A > 0, "MinimalVault: empty");
        require(balanceOf[msg.sender] >= shares, "MinimalVault: insufficient shares");

        // assetsRequested = ceil(shares * A / S)
        uint256 num = shares * A;
        uint256 assetsRequested = num / S + (num % S == 0 ? 0 : 1);

        // Burn shares up-front
        balanceOf[msg.sender] -= shares;
        totalSupply -= shares;

        withdrawn = strategy.withdraw(assetsRequested);

        if (withdrawn > 0) {
            token.safeTransfer(msg.sender, withdrawn);
        }

        // If shortfall, restore shares proportional to actual withdrawn amount.
        if (withdrawn < assetsRequested) {
            uint256 sharesForWithdrawn = (withdrawn * S) / A;
            if (shares > sharesForWithdrawn) {
                uint256 toRestore = shares - sharesForWithdrawn;
                balanceOf[msg.sender] += toRestore;
                totalSupply += toRestore;
            }
        }
    }
}
