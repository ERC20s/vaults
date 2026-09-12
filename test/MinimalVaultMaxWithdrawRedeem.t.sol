// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {MockERC20} from "./mocks/MockERC20.sol";
import {MockStrategy} from "./mocks/MockStrategy.sol";
import {MinimalVault} from "../src/vault/MinimalVault.sol";
import {IStrategy} from "../src/interfaces/IStrategy.sol";
import {IERC20} from "../src/utils/SafeERC20.sol";

contract MinimalVaultMaxWithdrawRedeemTest {
    MockERC20 token;
    MockStrategy mock;
    MinimalVault vault;

    function setUp() public {
        token = new MockERC20();
        mock = new MockStrategy(token);
        vault = new MinimalVault(IERC20(address(token)), IStrategy(address(mock)));
    }

    /// Owner cap vs strategy liquidity: when the strategy reports less redeemable than
    /// the owner's floor-priced claim, the owner's maxWithdraw is the strategy cap and
    /// maxRedeem corresponds to the floor-priced shares that fit under that cap.
    function test_OwnerCapVsStrategyLiquidity() public {
        uint256 amount = 1_000e18;
        token.mint(address(this), amount);
        token.approve(address(vault), amount);
        vault.deposit(amount);

        // Make most of the position illiquid so strategy.maxWithdraw() < ownerClaim
        mock.setIlliquid(800e18);

        uint256 totalAssetsBefore = vault.totalAssets();
        uint256 ownerShares = vault.balanceOf(address(this));
        uint256 ownerClaim = vault.convertToAssets(ownerShares);
        uint256 strategyCap = mock.maxWithdraw();

        uint256 expectedWithdraw = ownerClaim <= strategyCap ? ownerClaim : strategyCap;
        require(vault.maxWithdraw(address(this)) == expectedWithdraw, "maxWithdraw mismatch when capped");

        uint256 expectedRedeem = (expectedWithdraw * vault.totalSupply()) / totalAssetsBefore; // floor
        require(vault.maxRedeem(address(this)) == expectedRedeem, "maxRedeem mismatch when capped");

        // When strategy has full liquidity the owner claim is the limiting factor
        mock.setIlliquid(0);
        strategyCap = mock.maxWithdraw();
        ownerClaim = vault.convertToAssets(ownerShares);
        require(strategyCap >= ownerClaim, "setup: expected strategy to be >= ownerClaim");
        require(vault.maxWithdraw(address(this)) == ownerClaim, "maxWithdraw should match owner claim when uncapped");
        require(vault.maxRedeem(address(this)) == ownerShares, "maxRedeem should allow burning all owned shares when uncapped");
    }

    /// When the strategy is drained (totalAssets == 0) but shares remain, owner-facing
    /// maxWithdraw and maxRedeem must both report zero.
    function test_WipedOutVaultReportsZeroCaps() public {
        uint256 amount = 100e18;
        token.mint(address(this), amount);
        token.approve(address(vault), amount);
        vault.deposit(amount);

        // Drain the strategy to reach the wiped-out state
        mock.setIlliquid(0);
        uint256 drained = mock.withdraw(mock.totalAssets());
        require(mock.totalAssets() == 0, "strategy not drained");
        require(vault.totalAssets() == 0, "vault still sees assets");
        require(vault.totalSupply() > 0, "setup: no shares outstanding");

        require(vault.maxWithdraw(address(this)) == 0, "wiped-out vault maxWithdraw must be 0");
        require(vault.maxRedeem(address(this)) == 0, "wiped-out vault maxRedeem must be 0");
    }

    /// Edge case: an empty vault (no shares outstanding) must report zero per-owner
    /// redeem capacity and zero maxWithdraw for a holder with no shares.
    function test_EmptyVaultReturnsZeroForOwnerViews() public {
        require(vault.totalSupply() == 0, "setup: vault not empty");
        require(vault.maxWithdraw(address(this)) == 0, "empty vault maxWithdraw non-zero");
        require(vault.maxRedeem(address(this)) == 0, "empty vault maxRedeem non-zero");
    }
}
