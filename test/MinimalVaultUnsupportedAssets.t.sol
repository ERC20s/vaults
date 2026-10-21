// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {MockFeeOnTransferERC20} from "./mocks/MockFeeOnTransferERC20.sol";
import {MockRebasingERC20} from "./mocks/MockRebasingERC20.sol";
import {MockGenericStrategy} from "./mocks/MockGenericStrategy.sol";
import {MinimalVault} from "../src/vault/MinimalVault.sol";
import {IStrategy} from "../src/interfaces/IStrategy.sol";
import {IERC20} from "../src/utils/SafeERC20.sol";

interface Vm {
    function expectRevert(bytes calldata) external;
}

Vm constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

/// @title MinimalVaultUnsupportedAssets
/// @notice What the vault does with the two asset classes SECURITY.md lists as unsupported.
/// - Fee-on-transfer: the vault prices shares on the `amount` it asked for, so a smaller delivery
///   would dilute every other holder. The vault must refuse the deposit with nothing moved, and
///   say why ("MinimalVault: fee-on-transfer") rather than fail somewhere inside the strategy.
/// - Rebasing: a rebase between calls is simply a change of `totalAssets()` and is socialised like
///   yield or loss; but transfers of amounts the index does not divide evenly deliver a wei short,
///   and the vault's exact-delta checks fail closed on them. Such assets are not supported.
contract MinimalVaultUnsupportedAssetsTest {
    function _vaultOver(address asset) internal returns (MinimalVault vault, MockGenericStrategy strat) {
        strat = new MockGenericStrategy(IERC20(asset));
        vault = new MinimalVault(IERC20(asset), IStrategy(address(strat)), address(this));
    }

    // --- fee-on-transfer ----------------------------------------------------------------

    function test_FeeOnTransferDepositIsRefusedWithNothingMoved() public {
        MockFeeOnTransferERC20 token = new MockFeeOnTransferERC20(100); // 1 %
        (MinimalVault vault, MockGenericStrategy strat) = _vaultOver(address(token));
        uint256 amount = 1_000e18;
        token.mint(address(this), amount);
        token.approve(address(vault), amount);

        vm.expectRevert(bytes("MinimalVault: fee-on-transfer"));
        vault.deposit(amount);

        require(token.balanceOf(address(this)) == amount, "assets left the depositor");
        require(token.allowance(address(this), address(vault)) == amount, "allowance consumed on a refused deposit");
        require(vault.totalSupply() == 0, "shares minted on a refused deposit");
        require(token.balanceOf(address(vault)) == 0, "underlying stranded in the vault");
        require(strat.totalAssets() == 0, "underlying reached the strategy");
    }

    function test_FeeOnTransferMintIsRefusedWithNothingMoved() public {
        MockFeeOnTransferERC20 token = new MockFeeOnTransferERC20(30); // 0.3 %
        (MinimalVault vault, MockGenericStrategy strat) = _vaultOver(address(token));
        uint256 shares = 1_000e18;
        uint256 assets = vault.previewMint(shares);
        token.mint(address(this), assets);
        token.approve(address(vault), assets);

        vm.expectRevert(bytes("MinimalVault: fee-on-transfer"));
        vault.mint(shares);

        require(token.balanceOf(address(this)) == assets, "assets left the minter");
        require(vault.totalSupply() == 0, "shares minted on a refused mint");
        require(strat.totalAssets() == 0, "underlying reached the strategy");
    }

    /// @notice Control: the same token with the fee switched off is an ordinary asset, and a fee
    /// switched on later refuses new deposits while leaving the existing holder's claim intact.
    function test_FeeOnTransferTokenWorksAtZeroFeeAndIsRefusedOnceTheFeeStarts() public {
        MockFeeOnTransferERC20 token = new MockFeeOnTransferERC20(0);
        (MinimalVault vault, MockGenericStrategy strat) = _vaultOver(address(token));
        uint256 amount = 1_000e18;
        token.mint(address(this), 2 * amount);
        token.approve(address(vault), 2 * amount);

        require(vault.deposit(amount) == amount, "zero-fee deposit not 1:1");
        require(strat.totalAssets() == amount, "zero-fee deposit did not reach the strategy");

        token.setFeeBps(1);
        vm.expectRevert(bytes("MinimalVault: fee-on-transfer"));
        vault.deposit(amount);

        require(vault.totalSupply() == amount, "supply moved on a refused deposit");
        require(vault.convertToAssets(amount) == amount, "the existing holder's claim moved");
    }

    // --- rebasing -----------------------------------------------------------------------

    /// @notice A rebase between calls is socialised: up is yield to every holder, down is a loss
    /// to every holder, and a withdrawal of an amount the index divides evenly settles at the
    /// rebased price. The holder is never paid more than deposit plus the rebase gain.
    function test_RebaseBetweenCallsIsSocialisedAsYieldOrLoss() public {
        MockRebasingERC20 token = new MockRebasingERC20();
        (MinimalVault vault, MockGenericStrategy strat) = _vaultOver(address(token));
        uint256 amount = 1_000e18;
        token.mint(address(this), amount);
        token.approve(address(vault), amount);
        require(vault.deposit(amount) == amount, "bootstrap not 1:1");

        // Positive rebase: the strategy's balance doubles, no share is created.
        token.rebase(2e18);
        require(vault.totalAssets() == 2 * amount, "rebase did not reach totalAssets");
        require(vault.totalSupply() == amount, "rebase changed the share supply");
        uint256 claim = vault.convertToAssets(amount);
        require(claim == (amount * (2 * amount + 1)) / (amount + 1), "claim is not the virtual-pair price");
        require(claim <= 2 * amount && claim >= 2 * amount - 1, "claim did not follow the rebase");

        // An even amount withdraws cleanly at the doubled price and burns half as many shares + 1.
        uint256 sharesBefore = vault.balanceOf(address(this));
        uint256 got = vault.withdraw(amount);
        require(got == amount, "withdraw after a rebase was not served in full");
        uint256 burned = sharesBefore - vault.balanceOf(address(this));
        // ceil(amount * (supply + 1) / (assets + 1)) with supply == amount and assets == 2 * amount.
        require(burned == (amount * (amount + 1) + 2 * amount) / (2 * amount + 1), "burn is not the ceil at the rebased price");
        require(burned * (2 * amount + 1) >= amount * (amount + 1), "burned fewer shares than the payout was worth");
        require(got <= amount + amount, "paid more than deposit plus the rebase gain");

        // Negative rebase: the remaining position loses half; the claim follows it down.
        token.rebase(1e18);
        uint256 remaining = strat.totalAssets();
        require(remaining == amount / 2, "setup: balance after the negative rebase");
        uint256 claimAfterLoss = vault.convertToAssets(vault.balanceOf(address(this)));
        require(claimAfterLoss <= remaining, "claim exceeds what is held after a loss");
        require(claimAfterLoss >= remaining - 1, "claim did not follow the loss down to the holder");
    }

    /// @notice An amount the index does not divide evenly is delivered a wei short, and the
    /// vault's exact-delta check refuses it with nothing moved - the same guard that refuses
    /// fee-on-transfer assets.
    function test_RebasingTokenDepositOfAnUnevenAmountIsRefused() public {
        MockRebasingERC20 token = new MockRebasingERC20();
        (MinimalVault vault, MockGenericStrategy strat) = _vaultOver(address(token));
        token.rebase(1.5e18);
        uint256 amount = 1_001;
        token.mint(address(this), 3_000);
        token.approve(address(vault), amount);

        vm.expectRevert(bytes("MinimalVault: fee-on-transfer"));
        vault.deposit(amount);

        require(vault.totalSupply() == 0, "shares minted on a refused deposit");
        require(token.balanceOf(address(vault)) == 0, "underlying stranded in the vault");
        require(strat.totalAssets() == 0, "underlying reached the strategy");
    }

    /// @notice A full redemption after a rebase asks the strategy for an odd amount, the push
    /// lands a wei short, and the vault's custody check fails closed rather than mis-account.
    function test_RebasingTokenFullRedeemAfterRebaseFailsClosed() public {
        MockRebasingERC20 token = new MockRebasingERC20();
        (MinimalVault vault, MockGenericStrategy strat) = _vaultOver(address(token));
        uint256 amount = 1_000e18;
        token.mint(address(this), amount);
        token.approve(address(vault), amount);
        vault.deposit(amount);
        token.rebase(2e18);

        uint256 claim = vault.previewRedeem(amount);
        require(claim % 2 == 1, "setup: the full claim must be an odd amount");

        vm.expectRevert(bytes("MinimalVault: strategy returned mismatch"));
        vault.redeem(amount);

        require(vault.balanceOf(address(this)) == amount, "shares burned on a failed redeem");
        require(strat.totalAssets() == 2 * amount, "custody moved on a failed redeem");
        require(token.balanceOf(address(vault)) == 0, "underlying stranded in the vault");
    }
}
