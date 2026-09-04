// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {MockERC20} from "./mocks/MockERC20.sol";
import {MockStrategy} from "./mocks/MockStrategy.sol";
import {MockPartialPullStrategy} from "./mocks/MockPartialPullStrategy.sol";
import {MinimalVault} from "../src/vault/MinimalVault.sol";
import {IStrategy} from "../src/interfaces/IStrategy.sol";
import {IERC20} from "../src/utils/SafeERC20.sol";

contract MinimalVaultTest {
    MockERC20 token;
    MockStrategy mock;
    MinimalVault vault;

    function setUp() public {
        token = new MockERC20();
        mock = new MockStrategy(token);
        vault = new MinimalVault(IERC20(address(token)), IStrategy(address(mock)));
    }

    function test_DepositApprovesAndStrategyConsumesAllowance() public {
        uint256 amount = 1_000e18;
        token.mint(address(this), amount);
        token.approve(address(vault), amount);

        uint256 shares = vault.deposit(amount);

        require(token.allowance(address(vault), address(mock)) == 0, "allowance not consumed");
        require(token.balanceOf(address(mock)) == amount, "strategy custody missing");
        require(shares > 0, "no shares minted");
        require(vault.totalAssets() == mock.totalAssets(), "assets not forwarded");
    }

    function test_WithdrawHandlesShortfallAndForwardsReturn() public {
        uint256 amount = 2_000e18;
        token.mint(address(this), amount);
        token.approve(address(vault), amount);
        vault.deposit(amount);

        // make part illiquid so withdraw will be capped
        mock.setIlliquid(1500e18);

        uint256 before = token.balanceOf(address(this));
        uint256 withdrawn = vault.withdraw(1_000e18);
        uint256 delta = token.balanceOf(address(this)) - before;

        require(withdrawn == delta, "withdraw return mismatch");
        require(withdrawn <= mock.maxWithdraw(), "exceeded strategy maxWithdraw");
    }

    function test_ShareMathBootstrapAndConservativeRounding() public {
        // bootstrap: first depositor gets 1:1
        uint256 a1 = 1e18;
        token.mint(address(this), a1);
        token.approve(address(vault), a1);
        uint256 s1 = vault.deposit(a1);
        require(s1 == a1, "bootstrap not 1:1");

        // second depositor: deposit proportionally
        address other = address(0xBEEF);
        token.mint(other, 3e18);
        // impersonate other by calling deposit via low-level? Simpler: replicate math here.
        // Instead, ensure that convertToShares is floor-rounded and never over-mints.
        uint256 sharesFor2 = vault.convertToShares(1e18);
        uint256 expected = (1e18 * vault.totalSupply()) / vault.totalAssets();
        require(sharesFor2 == expected, "convertToShares rounding mismatch");
    }

    // --- Zero-share guard (donation / first-depositor inflation) ---

    /// @notice A donation straight to the strategy must not let a real deposit mint 0 shares.
    /// @dev MockStrategy.totalAssets() is its own token balance, so anyone can inflate the
    /// share price by transferring the underlying to it. With floor rounding the next
    /// depositor's assets round down to nothing; the vault must reject that rather than
    /// keep the assets and mint nothing.
    function test_DepositRevertsWhenDonationRoundsSharesToZero() public {
        // 1 wei bootstrap deposit: totalSupply == 1
        token.mint(address(this), 1);
        token.approve(address(vault), 1);
        require(vault.deposit(1) == 1, "bootstrap not 1:1");

        // Donation: 1000e18 pushed straight into the strategy, no shares minted for it.
        token.mint(address(mock), 1_000e18);

        // 999e18 now prices at (999e18 * 1) / (1000e18 + 1) == 0 shares.
        require(vault.convertToShares(999e18) == 0, "setup: expected a zero-share quote");

        token.mint(address(this), 999e18);
        token.approve(address(vault), 999e18);
        uint256 balanceBefore = token.balanceOf(address(this));

        try vault.deposit(999e18) returns (uint256) {
            require(false, "deposit minted zero shares instead of reverting");
        } catch {
            // expected: "MinimalVault: zero-shares"
        }

        require(token.balanceOf(address(this)) == balanceBefore, "assets left the depositor");
        require(vault.totalSupply() == 1, "supply moved on a reverted deposit");
    }

    /// @notice deposit(0) and mint(0) are rejected outright.
    function test_ZeroAmountDepositAndMintRevert() public {
        try vault.deposit(0) returns (uint256) {
            require(false, "deposit(0) did not revert");
        } catch {}

        try vault.mint(0) returns (uint256) {
            require(false, "mint(0) did not revert");
        } catch {}

        require(vault.totalSupply() == 0, "supply moved on a reverted call");
    }

    // --- Custody guard (the strategy must pull what the vault pulled in) ---

    /// @notice A strategy that pulls only part of the deposit must be rejected, not
    /// silently under-credited: leftover underlying in the vault is invisible to
    /// totalAssets() and unreachable through withdraw().
    function test_DepositRevertsWhenStrategyPullsOnlyPart() public {
        MockPartialPullStrategy partial = new MockPartialPullStrategy(token);
        MinimalVault v2 = new MinimalVault(IERC20(address(token)), IStrategy(address(partial)));

        partial.setPullBps(5_000); // pulls half

        uint256 amount = 1_000e18;
        token.mint(address(this), amount);
        token.approve(address(v2), amount);

        try v2.deposit(amount) returns (uint256) {
            require(false, "partial pull accepted");
        } catch {
            // expected: "MinimalVault: strategy did not pull"
        }

        require(token.balanceOf(address(v2)) == 0, "tokens stranded in the vault");
        require(v2.totalSupply() == 0, "shares minted for a partial pull");
    }

    /// @notice A strategy that pulls nothing at all is rejected by the same guard.
    function test_DepositRevertsWhenStrategyPullsNothing() public {
        MockPartialPullStrategy partial = new MockPartialPullStrategy(token);
        MinimalVault v2 = new MinimalVault(IERC20(address(token)), IStrategy(address(partial)));

        partial.setPullBps(0);

        uint256 amount = 500e18;
        token.mint(address(this), amount);
        token.approve(address(v2), amount);

        try v2.deposit(amount) returns (uint256) {
            require(false, "no-op strategy deposit accepted");
        } catch {}

        require(token.balanceOf(address(v2)) == 0, "tokens stranded in the vault");
    }

    /// @notice Control: the same fixture at a full pull is accepted, so the guard rejects
    /// misbehaviour rather than the fixture itself.
    function test_DepositAcceptedWhenPartialPullFixturePullsEverything() public {
        MockPartialPullStrategy partial = new MockPartialPullStrategy(token);
        MinimalVault v2 = new MinimalVault(IERC20(address(token)), IStrategy(address(partial)));

        uint256 amount = 1_000e18;
        token.mint(address(this), amount);
        token.approve(address(v2), amount);

        uint256 shares = v2.deposit(amount);

        require(shares == amount, "bootstrap not 1:1");
        require(token.balanceOf(address(partial)) == amount, "strategy custody missing");
        require(token.balanceOf(address(v2)) == 0, "tokens stranded in the vault");
        require(token.allowance(address(v2), address(partial)) == 0, "allowance left dangling");
    }

    /// @notice mint() keeps the same custody and allowance properties as deposit().
    function test_MintTakesCustodyAndLeavesNoAllowance() public {
        uint256 shares = 1_000e18;
        token.mint(address(this), shares);
        token.approve(address(vault), shares);

        uint256 assets = vault.mint(shares);

        require(assets == shares, "bootstrap mint not 1:1");
        require(token.balanceOf(address(mock)) == assets, "strategy custody missing");
        require(token.balanceOf(address(vault)) == 0, "tokens stranded in the vault");
        require(token.allowance(address(vault), address(mock)) == 0, "allowance left dangling");
        require(vault.balanceOf(address(this)) == shares, "shares not credited");
    }
}
