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

    // --- Redemption rounding (a redeem must never dilute the holders who stay) ---

    /// @notice The donation case: a dust redeem against an inflated share price must not
    /// pay out more than the burned share is worth.
    /// @dev Deposit 3 wei (totalSupply 3), then push 7 wei straight into the strategy so
    /// totalAssets is 10 and one share is worth 3.33. The old code asked for
    /// ceil(1 * 10 / 3) == 4, was paid 4, computed ceil(4 * 3 / 10) == 2 shares to burn and
    /// then capped the burn at the 1 share offered - paying 4 for 3.33 and dropping assets
    /// per share for everyone left from 3.33 to 3.00. Floor pricing asks for 3 and burns 1.
    function test_RedeemDoesNotOverpayOnDonationInflatedPrice() public {
        token.mint(address(this), 3);
        token.approve(address(vault), 3);
        require(vault.deposit(3) == 3, "bootstrap not 1:1");

        // Donation straight to the strategy: no shares minted for it.
        token.mint(address(mock), 7);

        uint256 taBefore = vault.totalAssets();
        uint256 tsBefore = vault.totalSupply();
        require(taBefore == 10 && tsBefore == 3, "setup: expected 10 assets over 3 shares");

        uint256 balBefore = token.balanceOf(address(this));
        uint256 withdrawn = vault.redeem(1);
        uint256 delta = token.balanceOf(address(this)) - balBefore;

        require(withdrawn == delta, "redeem return mismatch");
        require(withdrawn == 3, "redeem paid more than the share was worth");
        require(vault.balanceOf(address(this)) == 2, "wrong number of shares burned");

        uint256 taAfter = vault.totalAssets();
        uint256 tsAfter = vault.totalSupply();
        // assets per share must not fall: taAfter/tsAfter >= taBefore/tsBefore
        require(taAfter * tsBefore >= taBefore * tsAfter, "assets per share fell on redeem");
    }

    /// @notice A strategy shortfall burns only the shares the payout actually covers.
    function test_RedeemShortfallBurnsOnlyWhatWasPaidFor() public {
        uint256 amount = 1_000e18;
        token.mint(address(this), amount);
        token.approve(address(vault), amount);
        vault.deposit(amount);

        // Only 400e18 of the 1000e18 position is redeemable this block.
        mock.setIlliquid(600e18);

        uint256 taBefore = vault.totalAssets();
        uint256 tsBefore = vault.totalSupply();

        uint256 balBefore = token.balanceOf(address(this));
        uint256 withdrawn = vault.redeem(amount); // asks for all 1000e18, gets 400e18
        uint256 delta = token.balanceOf(address(this)) - balBefore;

        require(withdrawn == delta, "redeem return mismatch");
        require(withdrawn == 400e18, "unexpected shortfall payout");
        require(vault.balanceOf(address(this)) == 600e18, "burned shares the payout did not cover");
        require(vault.totalSupply() == 600e18, "supply and balance disagree");

        uint256 taAfter = vault.totalAssets();
        uint256 tsAfter = vault.totalSupply();
        require(taAfter * tsBefore >= taBefore * tsAfter, "assets per share fell on a shortfall redeem");
    }

    /// @notice redeem(0) and a redeem above the caller's balance are rejected outright.
    function test_RedeemRevertsOnZeroSharesAndOnOverdraft() public {
        uint256 amount = 100e18;
        token.mint(address(this), amount);
        token.approve(address(vault), amount);
        vault.deposit(amount);

        try vault.redeem(0) returns (uint256) {
            require(false, "redeem(0) did not revert");
        } catch {}

        try vault.redeem(amount + 1) returns (uint256) {
            require(false, "redeem above balance did not revert");
        } catch {}

        require(vault.balanceOf(address(this)) == amount, "shares moved on a reverted redeem");
        require(vault.totalSupply() == amount, "supply moved on a reverted redeem");
    }

    /// @notice Fuzz: over any deposit, any donated yield and any redeem size, the assets
    /// backing each remaining share never fall, and a redeem is never paid more than the
    /// floor value of the shares it burns.
    function testFuzz_RedeemNeverDilutesRemainingHolders(
        uint96 depositRaw,
        uint96 yieldRaw,
        uint96 redeemRaw
    ) public {
        uint256 depositAmount = (uint256(depositRaw) % 1e24) + 2;
        uint256 yieldAmount = uint256(yieldRaw) % 1e24;

        token.mint(address(this), depositAmount);
        token.approve(address(vault), depositAmount);
        require(vault.deposit(depositAmount) == depositAmount, "bootstrap not 1:1");

        if (yieldAmount > 0) {
            // "Yield" in this fixture is underlying transferred straight to the strategy.
            token.mint(address(mock), yieldAmount);
        }

        uint256 shares = (uint256(redeemRaw) % vault.balanceOf(address(this))) + 1;

        uint256 taBefore = vault.totalAssets();
        uint256 tsBefore = vault.totalSupply();
        uint256 floorAssets = (shares * taBefore) / tsBefore;
        if (floorAssets == 0) {
            // Dust worth less than one wei of underlying: the vault must refuse it.
            try vault.redeem(shares) returns (uint256) {
                require(false, "redeem paid out for a zero-asset quote");
            } catch {}
            return;
        }

        uint256 balBefore = token.balanceOf(address(this));
        uint256 withdrawn = vault.redeem(shares);
        require(withdrawn == token.balanceOf(address(this)) - balBefore, "redeem return mismatch");
        require(withdrawn <= floorAssets, "redeem paid more than the shares were worth");

        uint256 taAfter = vault.totalAssets();
        uint256 tsAfter = vault.totalSupply();
        require(taAfter * tsBefore >= taBefore * tsAfter, "assets per share fell on redeem");
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

    // --- No-price guard (shares outstanding, strategy wiped out) ---

    /// @dev Drains the strategy completely and returns the amount taken out.
    /// MockStrategy.withdraw() has no access control and pays `msg.sender`, so a total
    /// loss / emergency-unwind-that-ended-empty state is reachable with the existing
    /// fixture: no new mock is needed.
    function _drainStrategy() internal returns (uint256 drained) {
        mock.setIlliquid(0);
        drained = mock.withdraw(mock.totalAssets());
        require(mock.totalAssets() == 0, "setup: strategy not drained");
    }

    /// @notice With shares outstanding and totalAssets() at 0 the vault has no exchange
    /// rate, and a deposit must revert rather than mint 1:1 against dead shares.
    /// @dev Before the fix, _convertToShares treated "empty vault" and "wiped-out vault"
    /// as the same case: Alice deposits 100 and holds 100 shares, the strategy goes to 0,
    /// Bob deposits 100 and is minted 100 shares against totalAssets 100 / totalSupply
    /// 200 - Bob's redeem then prices at floor(100 * 100 / 200) == 50 and half of his
    /// deposit has revived Alice's worthless shares.
    function test_DepositRevertsWhenStrategyReportsZeroAssets() public {
        uint256 alice = 100e18;
        token.mint(address(this), alice);
        token.approve(address(vault), alice);
        require(vault.deposit(alice) == alice, "bootstrap not 1:1");

        _drainStrategy();
        require(vault.totalAssets() == 0, "setup: vault still sees assets");
        require(vault.totalSupply() == alice, "setup: supply moved");

        // The views must not quote a price for a vault backed by nothing.
        require(vault.convertToShares(50e18) == 0, "priced a deposit into a wiped-out vault");
        require(vault.convertToAssets(alice) == 0, "dead shares still quoted as valuable");

        uint256 bob = 100e18;
        token.mint(address(this), bob);
        token.approve(address(vault), bob);
        uint256 balanceBefore = token.balanceOf(address(this));

        try vault.deposit(bob) returns (uint256) {
            require(false, "deposit into a wiped-out vault did not revert");
        } catch {
            // expected: "MinimalVault: no-price"
        }

        require(token.balanceOf(address(this)) == balanceBefore, "assets left the depositor");
        require(vault.totalSupply() == alice, "supply moved on a reverted deposit");
        require(vault.balanceOf(address(this)) == alice, "balance moved on a reverted deposit");
        require(token.balanceOf(address(vault)) == 0, "tokens stranded in the vault");
    }

    /// @notice mint() is refused by the same guard, on the same state.
    function test_MintRevertsWhenStrategyReportsZeroAssets() public {
        uint256 alice = 40e18;
        token.mint(address(this), alice);
        token.approve(address(vault), alice);
        vault.deposit(alice);

        _drainStrategy();

        token.mint(address(this), 40e18);
        token.approve(address(vault), 40e18);
        uint256 balanceBefore = token.balanceOf(address(this));

        try vault.mint(10e18) returns (uint256) {
            require(false, "mint into a wiped-out vault did not revert");
        } catch {
            // expected: "MinimalVault: no-price"
        }

        require(token.balanceOf(address(this)) == balanceBefore, "assets left the minter");
        require(vault.totalSupply() == alice, "supply moved on a reverted mint");
        require(vault.balanceOf(address(this)) == alice, "balance moved on a reverted mint");
    }

    /// @notice An EMPTY vault still bootstraps 1:1 - the guard rejects the wiped-out
    /// state, not the first deposit. Redeem everything, then deposit again.
    function test_EmptyVaultStillBootstrapsOneToOne() public {
        uint256 amount = 10e18;
        token.mint(address(this), amount);
        token.approve(address(vault), amount);
        vault.deposit(amount);

        vault.redeem(amount);
        require(vault.totalSupply() == 0, "setup: shares outstanding after full redeem");
        require(vault.totalAssets() == 0, "setup: strategy still holds assets");

        token.approve(address(vault), amount);
        require(vault.deposit(amount) == amount, "empty vault did not bootstrap 1:1");
    }

    /// @notice Fuzz: a deposit that succeeds never lowers what an existing holder can
    /// claim, and a deposit that cannot be priced changes nothing at all.
    function testFuzz_DepositNeverLowersAnExistingHoldersClaim(
        uint96 firstRaw,
        uint96 yieldRaw,
        uint96 secondRaw,
        bool wipeOut
    ) public {
        uint256 first = (uint256(firstRaw) % 1e24) + 2;
        uint256 yieldAmount = uint256(yieldRaw) % 1e24;
        uint256 second = (uint256(secondRaw) % 1e24) + 1;

        token.mint(address(this), first);
        token.approve(address(vault), first);
        require(vault.deposit(first) == first, "bootstrap not 1:1");

        if (yieldAmount > 0) {
            // "Yield" in this fixture is underlying transferred straight to the strategy.
            token.mint(address(mock), yieldAmount);
        }
        if (wipeOut) {
            _drainStrategy();
        }

        uint256 sharesHeld = vault.balanceOf(address(this));
        uint256 supplyBefore = vault.totalSupply();
        uint256 assetsBefore = vault.totalAssets();
        uint256 claimBefore = vault.convertToAssets(sharesHeld);

        token.mint(address(this), second);
        token.approve(address(vault), second);
        uint256 walletBefore = token.balanceOf(address(this));

        try vault.deposit(second) returns (uint256 minted) {
            require(!wipeOut, "deposit priced against a wiped-out vault");
            require(minted > 0, "zero shares minted");
            require(vault.totalSupply() == supplyBefore + minted, "supply and mint disagree");
            require(vault.totalAssets() == assetsBefore + second, "strategy custody missing");
            // The claim of the shares held before the deposit must not fall.
            uint256 claimAfter =
                (sharesHeld * vault.totalAssets()) / vault.totalSupply();
            require(claimAfter >= claimBefore, "a deposit diluted an existing holder");
        } catch {
            // Refused: either "no-price" (wiped out) or "zero-shares" (dust against an
            // inflated price). Either way nothing may have moved.
            require(token.balanceOf(address(this)) == walletBefore, "assets left on a reverted deposit");
            require(vault.totalSupply() == supplyBefore, "supply moved on a reverted deposit");
            require(vault.totalAssets() == assetsBefore, "assets moved on a reverted deposit");
            require(token.balanceOf(address(vault)) == 0, "tokens stranded in the vault");
        }
    }
}
