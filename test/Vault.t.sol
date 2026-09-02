// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {Vault, IERC20} from "../src/Vault.sol";

/// @notice Test-only ERC-20. Declared here on purpose: no mock is added under src/.
contract ERC20Mock {
    string public name;
    string public symbol;
    uint8 public decimals;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor(string memory name_, string memory symbol_, uint8 decimals_) {
        name = name_;
        symbol = symbol_;
        decimals = decimals_;
    }

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        return _transfer(msg.sender, to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            require(allowed >= amount, "ERC20: allowance");
            allowance[from][msg.sender] = allowed - amount;
        }
        return _transfer(from, to, amount);
    }

    function _transfer(address from, address to, uint256 amount) internal returns (bool) {
        require(balanceOf[from] >= amount, "ERC20: balance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }
}

contract VaultTest is Test {
    event Deposit(address indexed sender, address indexed owner, uint256 assets, uint256 shares);
    event Withdraw(
        address indexed sender, address indexed receiver, address indexed owner, uint256 assets, uint256 shares
    );

    ERC20Mock internal token;
    Vault internal vault;

    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal attacker = address(0xBAD);

    function setUp() public {
        token = new ERC20Mock("Mock USD", "mUSD", 18);
        vault = new Vault(IERC20(address(token)), "Vault mUSD", "vmUSD");
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    function _fund(address who, uint256 amount) internal {
        token.mint(who, amount);
        vm.prank(who);
        token.approve(address(vault), type(uint256).max);
    }

    function _deposit(address who, uint256 amount) internal returns (uint256 shares) {
        _fund(who, amount);
        vm.prank(who);
        shares = vault.deposit(amount, who);
    }

    /*//////////////////////////////////////////////////////////////
                                METADATA
    //////////////////////////////////////////////////////////////*/

    function test_Metadata() public {
        assertEq(vault.asset(), address(token));
        assertEq(vault.name(), "Vault mUSD");
        assertEq(vault.symbol(), "vmUSD");
        // asset decimals (18) + the virtual-shares offset (3)
        assertEq(vault.decimals(), 21);
        assertEq(vault.totalAssets(), 0);
        assertEq(vault.totalSupply(), 0);
    }

    function test_EmptyVaultConversions() public {
        assertEq(vault.convertToShares(1e18), 1e18 * 1000);
        assertEq(vault.convertToAssets(1e18 * 1000), 1e18);
        assertEq(vault.maxDeposit(alice), type(uint256).max);
        assertEq(vault.maxMint(alice), type(uint256).max);
        assertEq(vault.maxWithdraw(alice), 0);
        assertEq(vault.maxRedeem(alice), 0);
    }

    /*//////////////////////////////////////////////////////////////
                             ROUND TRIPS
    //////////////////////////////////////////////////////////////*/

    function test_DepositRedeemRoundTrip() public {
        uint256 amount = 1_000e18;
        uint256 shares = _deposit(alice, amount);

        assertEq(shares, vault.balanceOf(alice));
        assertEq(vault.totalAssets(), amount);
        assertEq(token.balanceOf(alice), 0);

        vm.prank(alice);
        uint256 assets = vault.redeem(shares, alice, alice);

        // Rounding may keep at most a wei or two in the vault; never more than it took.
        assertLe(assets, amount);
        assertGe(assets, amount - 2);
        assertEq(token.balanceOf(alice), assets);
        assertEq(vault.balanceOf(alice), 0);
        assertEq(vault.totalSupply(), 0);
    }

    function test_MintThenWithdraw() public {
        uint256 shares = 500e21;
        _fund(alice, 1_000e18);

        vm.prank(alice);
        uint256 paid = vault.mint(shares, alice);

        assertEq(vault.balanceOf(alice), shares);
        assertEq(vault.totalAssets(), paid);

        uint256 withdrawable = vault.maxWithdraw(alice);
        vm.prank(alice);
        uint256 burned = vault.withdraw(withdrawable, alice, alice);

        assertLe(burned, shares);
        assertEq(token.balanceOf(alice), 1_000e18 - paid + withdrawable);
    }

    function test_DepositEmitsEvent() public {
        _fund(alice, 1e18);
        uint256 expectedShares = vault.previewDeposit(1e18);

        vm.expectEmit(true, true, false, true, address(vault));
        emit Deposit(alice, alice, 1e18, expectedShares);

        vm.prank(alice);
        vault.deposit(1e18, alice);
    }

    function test_SecondDepositorGetsProportionalShares() public {
        _deposit(alice, 100e18);
        uint256 bobShares = _deposit(bob, 300e18);
        uint256 aliceShares = vault.balanceOf(alice);

        // Bob paid 3x, so he holds ~3x the shares (within rounding).
        assertApproxEqRel(bobShares, aliceShares * 3, 1e12);
        assertEq(vault.totalAssets(), 400e18);
    }

    /*//////////////////////////////////////////////////////////////
                              ALLOWANCES
    //////////////////////////////////////////////////////////////*/

    function test_WithdrawOnBehalfSpendsShareAllowance() public {
        uint256 shares = _deposit(alice, 100e18);

        vm.prank(alice);
        vault.approve(bob, shares);

        vm.prank(bob);
        uint256 burned = vault.withdraw(40e18, bob, alice);

        assertEq(token.balanceOf(bob), 40e18);
        assertEq(vault.allowance(alice, bob), shares - burned);
        assertEq(vault.balanceOf(alice), shares - burned);
    }

    function test_RedeemOnBehalfWithoutAllowanceReverts() public {
        uint256 shares = _deposit(alice, 100e18);

        vm.prank(bob);
        vm.expectRevert(Vault.InsufficientAllowance.selector);
        vault.redeem(shares, bob, alice);
    }

    function test_WithdrawMoreThanOwnedReverts() public {
        _deposit(alice, 10e18);

        vm.prank(alice);
        vm.expectRevert(Vault.ExceedsMaxWithdraw.selector);
        vault.withdraw(11e18, alice, alice);
    }

    function test_InfiniteAllowanceIsNotDecremented() public {
        uint256 shares = _deposit(alice, 100e18);

        vm.prank(alice);
        vault.approve(bob, type(uint256).max);

        vm.prank(bob);
        vault.redeem(shares, bob, alice);

        assertEq(vault.allowance(alice, bob), type(uint256).max);
    }

    /*//////////////////////////////////////////////////////////////
                       DONATION / INFLATION ATTACK
    //////////////////////////////////////////////////////////////*/

    function test_DonationDoesNotStealFromLaterDepositor() public {
        // Attacker seeds the vault with 1 wei, then donates a large balance directly.
        _deposit(attacker, 1);
        uint256 donation = 10_000e18;
        token.mint(attacker, donation);
        vm.prank(attacker);
        token.transfer(address(vault), donation);

        // Victim deposits after the donation.
        uint256 victimDeposit = 10_000e18;
        uint256 victimShares = _deposit(bob, victimDeposit);
        assertGt(victimShares, 0, "victim shares must not round to zero");

        uint256 victimValue = vault.previewRedeem(victimShares);
        uint256 attackerValue = vault.previewRedeem(vault.balanceOf(attacker));

        // The victim keeps essentially all of their deposit...
        assertGe(victimValue, (victimDeposit * 99) / 100);
        // ...and the attack costs the attacker far more than it returns.
        assertLt(attackerValue, donation + 1);
    }

    /*//////////////////////////////////////////////////////////////
                                  FUZZ
    //////////////////////////////////////////////////////////////*/

    /// @dev Converting assets to shares and back may never hand out more than went in.
    function testFuzz_ConvertRoundTripNeverInflates(uint128 assets, uint128 seed) public {
        uint256 seeded = bound(uint256(seed), 0, type(uint96).max);
        if (seeded > 0) _deposit(alice, seeded);

        uint256 a = uint256(assets);
        assertLe(vault.convertToAssets(vault.convertToShares(a)), a);
    }

    /// @dev A depositor can never redeem more assets than they deposited, with no yield in between.
    function testFuzz_DepositThenRedeemNeverProfits(uint96 first, uint96 second) public {
        uint256 a1 = bound(uint256(first), 1, type(uint96).max);
        uint256 a2 = bound(uint256(second), 1, type(uint96).max);

        _deposit(alice, a1);
        uint256 bobShares = _deposit(bob, a2);

        vm.prank(bob);
        uint256 out = vault.redeem(bobShares, bob, bob);

        assertLe(out, a2, "redeem returned more than deposited");
    }

    /// @dev Withdrawing costs at least as many shares as the plain conversion (rounds up).
    function testFuzz_PreviewWithdrawRoundsUp(uint96 deposited, uint96 assets) public {
        uint256 d = bound(uint256(deposited), 1, type(uint96).max);
        _deposit(alice, d);

        uint256 a = bound(uint256(assets), 0, d);
        assertGe(vault.previewWithdraw(a), vault.convertToShares(a));
        assertLe(vault.previewRedeem(vault.previewDeposit(a)), a);
    }

    /// @dev Total assets always cover what every holder could redeem.
    function testFuzz_TotalAssetsCoverAllShares(uint96 a1, uint96 a2) public {
        _deposit(alice, bound(uint256(a1), 1, type(uint96).max));
        _deposit(bob, bound(uint256(a2), 1, type(uint96).max));

        uint256 claims = vault.previewRedeem(vault.balanceOf(alice)) + vault.previewRedeem(vault.balanceOf(bob));
        assertLe(claims, vault.totalAssets(), "claims exceed assets held");
    }
}
