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
    ///
    /// Two guards make the floor rounding safe to keep:
    /// - the share amount is computed BEFORE any token moves and must be non-zero, so a
    ///   depositor can never hand over assets and be minted nothing (the classic ERC-4626
    ///   first-depositor / donation inflation loss: donate to the strategy, and a later
    ///   deposit rounds down to 0 shares);
    /// - the strategy must have pulled exactly `amount` out of this vault by the time
    ///   `deposit()` returns, which is the pull-based custody rule in
    ///   `src/interfaces/IStrategy.sol` stated as an assertion instead of a comment.
    function deposit(uint256 amount) external returns (uint256 shares) {
        require(amount > 0, "MinimalVault: zero-assets");

        uint256 totalAssetsBefore = strategy.totalAssets();

        // Price the deposit against pre-deposit state, before any token moves.
        shares = _convertToShares(amount, totalAssetsBefore);
        require(shares > 0, "MinimalVault: zero-shares");

        // Pull tokens from caller into the vault
        uint256 vaultBefore = tokenBalanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), amount);

        // Approve strategy for exactly amount and let it pull
        token.safeApprove(address(strategy), amount);
        strategy.deposit(amount);
        _assertStrategyPulled(vaultBefore);

        // Mint shares
        totalSupply += shares;
        balanceOf[msg.sender] += shares;
        return shares;
    }

    /// @notice Mint `shares` by supplying the required underlying.
    /// @dev Computes required assets, pulls them, approves the strategy and deposits.
    /// Mirrors the two guards in `deposit()`: no zero-share mint, and the strategy must
    /// take custody of everything this call pulled in.
    function mint(uint256 shares) external returns (uint256 assets) {
        require(shares > 0, "MinimalVault: zero-shares");

        uint256 totalAssetsBefore = strategy.totalAssets();
        assets = _convertToAssetsForMint(shares, totalAssetsBefore);
        require(assets > 0, "MinimalVault: zero-assets");

        uint256 vaultBefore = tokenBalanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), assets);
        token.safeApprove(address(strategy), assets);
        strategy.deposit(assets);
        _assertStrategyPulled(vaultBefore);

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

    /// @dev Asserts the strategy took custody of everything the vault just pulled in, and
    /// clears any allowance the strategy left behind.
    ///
    /// The check reads the VAULT's own token balance, not `strategy.totalAssets()`, so a
    /// strategy that charges a deposit fee or reports assets in its own way is unaffected:
    /// all that is required is that no underlying is left stranded here. Stranded tokens
    /// would be invisible to `totalAssets()` and unreachable through `withdraw()`, which
    /// measures only its own balance delta.
    function _assertStrategyPulled(uint256 vaultBefore) internal {
        require(tokenBalanceOf(address(this)) == vaultBefore, "MinimalVault: strategy did not pull");
        // A conforming strategy consumes the whole allowance; clear any residue either way.
        if (token.allowance(address(this), address(strategy)) != 0) {
            token.safeApprove(address(strategy), 0);
        }
    }

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
