// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {MockERC20} from "./mocks/MockERC20.sol";
import {MockStrategy} from "./mocks/MockStrategy.sol";
import {MinimalVault} from "../src/vault/MinimalVault.sol";
import {IStrategy} from "../src/interfaces/IStrategy.sol";
import {IERC20} from "../src/utils/SafeERC20.sol";

interface Vm {
    function startPrank(address) external;
    function stopPrank() external;
    function expectRevert(bytes calldata) external;
}

Vm constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

/// @title MinimalVaultInflation
/// @notice The first-depositor share-inflation attack against `MinimalVault`, and the bound the
/// virtual share/asset pair puts on it. The zero-share guard alone only stopped the TOTAL loss:
/// with plain proportional pricing an attacker who bootstraps with 1 wei and donates D to the
/// strategy still profits 0.5 D from a victim who deposits 2 D + 1 (floored to a single share).
/// Every test here fails against that pricing.
contract MinimalVaultInflationTest {
    MockERC20 token;
    MockStrategy mock;
    MinimalVault vault;

    address constant ATTACKER = address(0xA11CE);
    address constant VICTIM = address(0xB0B);

    function setUp() public {
        token = new MockERC20();
        mock = new MockStrategy(token);
        vault = new MinimalVault(IERC20(address(token)), IStrategy(address(mock)), address(this));
    }

    function _depositAs(address who, uint256 amount) internal returns (uint256 shares) {
        token.mint(who, amount);
        vm.startPrank(who);
        token.approve(address(vault), amount);
        shares = vault.deposit(amount);
        vm.stopPrank();
    }

    /// @notice The textbook attack, with the exact numbers. Attacker: 1 wei deposit, then a 1e18
    /// donation straight to the strategy. Victim: 2e18 + 1, the amount plain pricing floors to a
    /// single share worth 1.5e18 (attacker's profit 0.5e18). With the virtual pair the victim gets
    /// 3 shares, the pot of 3e18 + 2 is split over 5 shares (4 real, 1 the vault's own), and the
    /// attacker's share is worth 0.6e18: a loss of 0.4e18 on a 1e18 + 1 outlay.
    function test_FirstDepositorInflationAttackIsUnprofitable() public {
        uint256 donation = 1e18;
        uint256 victimDeposit = 2e18 + 1;

        require(_depositAs(ATTACKER, 1) == 1, "attacker bootstrap not 1:1");
        token.mint(address(mock), donation);
        uint256 attackerCost = 1 + donation;

        uint256 victimShares = _depositAs(VICTIM, victimDeposit);
        require(victimShares == 3, "victim must be floored to 3 shares under the virtual pair");

        uint256 assets = vault.totalAssets();
        uint256 supply = vault.totalSupply();
        require(assets == 3e18 + 2 && supply == 4, "setup: pot and supply");

        uint256 attackerClaim = vault.convertToAssets(1);
        uint256 victimClaim = vault.convertToAssets(victimShares);
        require(attackerClaim == (assets + 1) / (supply + 1), "attacker claim is not one virtual-priced share");
        require(attackerClaim == 6e17, "attacker claim");
        require(attackerClaim < attackerCost, "the attack turned a profit");
        require(victimDeposit - victimClaim < attackerCost - attackerClaim, "victim lost more than the attacker");
        require(attackerClaim + victimClaim <= assets, "claims exceed the pot");

        // The claim is what a redemption really pays.
        vm.startPrank(ATTACKER);
        uint256 paid = vault.redeem(1);
        vm.stopPrank();
        require(paid == attackerClaim, "redeem paid other than the quoted claim");
        require(token.balanceOf(ATTACKER) == paid, "attacker holds other than the payout");
        require(paid < attackerCost, "the attacker cashed out a profit");
    }

    /// @notice Fuzz over the attack shape: any bootstrap, any donation, any victim. The attacker's
    /// shares are never worth more than the attacker paid in; the victim loses at most one share's
    /// value to rounding; and everything the real holders lose went to the single virtual share.
    function testFuzz_AttackerNeverProfitsFromInflation(uint96 seedRaw, uint96 donationRaw, uint96 victimRaw) public {
        // Alternate between the attack's natural shape (a dust bootstrap) and an arbitrary one.
        uint256 seed = seedRaw % 2 == 0 ? (uint256(seedRaw) % 1_000) + 1 : (uint256(seedRaw) % 1e24) + 1;
        uint256 donation = uint256(donationRaw) % 1e24;
        uint256 victimDeposit = (uint256(victimRaw) % 1e24) + 1;

        require(_depositAs(ATTACKER, seed) == seed, "attacker bootstrap not 1:1");
        if (donation > 0) {
            token.mint(address(mock), donation);
        }
        uint256 attackerCost = seed + donation;

        token.mint(VICTIM, victimDeposit);
        vm.startPrank(VICTIM);
        token.approve(address(vault), victimDeposit);
        uint256 quote = vault.previewDeposit(victimDeposit);
        if (quote == 0) {
            vm.expectRevert(bytes("MinimalVault: zero-shares"));
            vault.deposit(victimDeposit);
            vm.stopPrank();
            require(token.balanceOf(VICTIM) == victimDeposit, "assets left the victim on a refused deposit");
            require(vault.totalSupply() == seed, "supply moved on a refused deposit");
            return;
        }
        uint256 victimShares = vault.deposit(victimDeposit);
        vm.stopPrank();
        require(victimShares == quote, "deposit minted other than the preview");

        uint256 assets = vault.totalAssets();
        uint256 supply = vault.totalSupply();
        uint256 attackerClaim = vault.convertToAssets(seed);
        uint256 victimClaim = vault.convertToAssets(victimShares);
        uint256 shareValue = (assets + 1) / (supply + 1);

        require(attackerClaim <= attackerCost, "attacker profited from inflation");
        require(victimDeposit - victimClaim <= shareValue + 2, "victim lost more than one share's value");
        require(attackerClaim + victimClaim <= assets, "claims exceed the pot");
        require(
            assets - attackerClaim - victimClaim <= shareValue + 2,
            "the virtual share took more than one share's value"
        );

        vm.startPrank(ATTACKER);
        uint256 paid = vault.redeem(seed);
        vm.stopPrank();
        require(paid == attackerClaim, "redeem paid other than the quoted claim");
        require(paid <= attackerCost, "the attacker cashed out a profit");
    }

    /// @notice The textbook attack carried through to the end: both parties exit, which leaves the
    /// virtual share's cut (6e17 here) in the strategy with `totalSupply == 0`. A vault that
    /// re-bootstraps 1:1 at that point hands the cut to whoever deposits next, so the attacker
    /// re-enters, takes it back and turns the attack into a profit of about 0.2e18 - exactly what
    /// the victim lost. Priced with the virtual pair, the empty-but-funded vault charges
    /// `totalAssets + 1` per share and the re-entry pays back no more than it put in.
    function test_InflationAttackStaysUnprofitableAfterTheVaultEmpties() public {
        uint256 donation = 1e18;
        uint256 reentry = 1e24;
        uint256 budget = 1 + donation + reentry;
        token.mint(ATTACKER, budget);

        vm.startPrank(ATTACKER);
        token.approve(address(vault), type(uint256).max);
        require(vault.deposit(1) == 1, "attacker bootstrap not 1:1");
        token.transfer(address(mock), donation);
        vm.stopPrank();

        uint256 victimDeposit = 2e18 + 1;
        uint256 victimShares = _depositAs(VICTIM, victimDeposit);
        require(victimShares == 3, "setup: victim floored to 3 shares");

        vm.startPrank(ATTACKER);
        require(vault.redeem(1) == 6e17, "setup: attacker redeem");
        vm.stopPrank();
        vm.startPrank(VICTIM);
        require(vault.redeem(victimShares) == 18e17 + 2, "setup: victim redeem");
        vm.stopPrank();

        uint256 residue = vault.totalAssets();
        require(vault.totalSupply() == 0 && residue == 6e17, "setup: empty vault holding the virtual share's cut");
        require(token.balanceOf(VICTIM) + 2e17 - 1 == victimDeposit, "setup: victim's loss");

        vm.startPrank(ATTACKER);
        uint256 shares = vault.deposit(reentry);
        vault.redeem(shares);
        vm.stopPrank();

        require(token.balanceOf(ATTACKER) <= budget, "the attacker reclaimed the residue at a profit");
        require(vault.totalAssets() >= residue, "the virtual share's cut left the vault");
    }

    /// @notice An empty vault that still holds assets (the virtual share's cut after everyone left,
    /// yield that landed after the last exit, a donation before the first deposit) is priced with
    /// the virtual pair like any other state: one share costs `totalAssets + 1`, never 1.
    function test_EmptyVaultHoldingAssetsIsPricedAgainstThem() public {
        uint256 residue = 6e17;
        token.mint(address(mock), residue);
        require(vault.totalSupply() == 0, "setup: vault is empty");

        require(vault.previewDeposit(residue + 1) == 1, "previewDeposit ignored the assets already held");
        require(vault.convertToShares(residue) == 0, "convertToShares ignored the assets already held");
        require(vault.previewMint(1) == residue + 1, "previewMint ignored the assets already held");
        require(vault.convertToAssets(1) == residue + 1, "convertToAssets ignored the assets already held");

        token.mint(VICTIM, residue);
        vm.startPrank(VICTIM);
        token.approve(address(vault), residue);
        vm.expectRevert(bytes("MinimalVault: zero-shares"));
        vault.deposit(residue);
        vm.stopPrank();

        token.mint(ATTACKER, residue + 1);
        vm.startPrank(ATTACKER);
        token.approve(address(vault), residue + 1);
        require(vault.mint(1) == residue + 1, "mint(1) did not charge totalAssets + 1");
        vm.stopPrank();
    }

    /// @notice Fuzzed: whatever an empty vault already holds, a deposit-then-redeem and a
    /// mint-then-redeem round trip through it never pays out more than went in.
    function testFuzz_RoundTripThroughAnEmptyFundedVaultNeverProfits(uint96 residueRaw, uint96 amountRaw) public {
        uint256 residue = (uint256(residueRaw) % 1e24) + 1;
        uint256 amount = (uint256(amountRaw) % 1e24) + 1;
        token.mint(address(mock), residue);

        token.mint(ATTACKER, amount);
        vm.startPrank(ATTACKER);
        token.approve(address(vault), amount);
        uint256 quote = vault.previewDeposit(amount);
        if (quote == 0) {
            vm.expectRevert(bytes("MinimalVault: zero-shares"));
            vault.deposit(amount);
            vm.stopPrank();
            return;
        }
        uint256 shares = vault.deposit(amount);
        require(shares == quote, "deposit minted other than the preview");
        uint256 paid = vault.redeem(shares);
        vm.stopPrank();
        require(paid <= amount, "deposit/redeem round trip through an empty funded vault profited");
        require(vault.totalSupply() == 0, "shares outstanding after a full redeem");

        uint256 mintShares = (amount % 1_000) + 1;
        uint256 cost = vault.previewMint(mintShares);
        token.mint(ATTACKER, cost);
        vm.startPrank(ATTACKER);
        token.approve(address(vault), cost);
        require(vault.mint(mintShares) == cost, "mint charged other than the preview");
        uint256 back = vault.redeem(mintShares);
        vm.stopPrank();
        require(back <= cost, "mint/redeem round trip through an empty funded vault profited");
    }

    /// @notice What the virtual pair costs an honest holder: a single depositor who collects
    /// yield y and redeems everything gets back at most deposit + y, and at least
    /// deposit + y - y / (deposit + 1) - 1: the virtual share's cut of the YIELD only, never of
    /// the principal.
    function testFuzz_SingleHolderGetsDepositPlusYieldLessTheVirtualShareCut(uint96 depositRaw, uint96 yieldRaw)
        public
    {
        uint256 amount = (uint256(depositRaw) % 1e24) + 1;
        uint256 yieldAmount = uint256(yieldRaw) % 1e24;

        require(_depositAs(VICTIM, amount) == amount, "bootstrap not 1:1");
        if (yieldAmount > 0) {
            token.mint(address(mock), yieldAmount);
        }

        vm.startPrank(VICTIM);
        uint256 paid = vault.redeem(amount);
        vm.stopPrank();

        require(paid <= amount + yieldAmount, "paid more than deposit plus yield");
        require(paid + yieldAmount / (amount + 1) + 1 >= amount + yieldAmount, "virtual share took more than its cut");
        require(paid >= amount, "the virtual share took principal");
        require(vault.totalSupply() == 0, "shares outstanding after a full redeem");
        require(token.balanceOf(VICTIM) == paid, "holder balance is not the payout");
    }
}
