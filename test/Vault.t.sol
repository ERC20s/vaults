// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import "../src/Vault.sol";

contract MockERC20 {
    string public name = "Mock";
    string public symbol = "M";
    uint8 public decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(uint256 initial) {
        totalSupply = initial;
        balanceOf[msg.sender] = initial;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "insufficient");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (from != msg.sender) {
            uint256 a = allowance[from][msg.sender];
            require(a >= amount, "allowance");
            allowance[from][msg.sender] = a - amount;
        }
        require(balanceOf[from] >= amount, "insufficient");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }
}

contract MockStrategy is IStrategy {
    MockERC20 public token;
    uint256 public assets;

    constructor(address _token) {
        token = MockERC20(_token);
    }

    function totalAssets() external view returns (uint256) {
        return assets;
    }

    function deposit(uint256 amount) external {
        // expect tokens to be held by this contract already
        // simulate investing: increase assets and keep balance
        assets += amount;
    }

    function withdraw(uint256 amount) external returns (uint256 withdrawn) {
        uint256 available = token.balanceOf(address(this));
        uint256 take = amount;
        if (take > assets) take = assets;
        if (take > available) take = available;
        if (take == 0) return 0;
        // reduce accounting and transfer to caller (Vault)
        assets -= take;
        token.transfer(msg.sender, take);
        return take;
    }

    function harvest() external returns (uint256 harvested) {
        return 0;
    }

    function panic() external {
        // noop
    }
}

contract VaultTest is Test {
    MockERC20 token;
    MockStrategy strategy;
    Vault vault;

    address alice = address(0x1);
    address bob = address(0x2);
    address feeTo = address(0xF);

    function setUp() public {
        token = new MockERC20(1_000_000 ether);
        strategy = new MockStrategy(address(token));
        vault = new Vault(address(token), address(strategy), "Vault", "vA", feeTo, 100); // 1% fee

        // fund alice and bob
        token.transfer(alice, 1000 ether);
        token.transfer(bob, 1000 ether);

        // approve
        vm.startPrank(alice);
        token.approve(address(vault), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(bob);
        token.approve(address(vault), type(uint256).max);
        vm.stopPrank();
    }

    function testDepositAndWithdraw() public {
        vm.startPrank(alice);
        uint256 assets = 100 ether;
        uint256 shares = vault.deposit(assets, alice);
        assertGt(shares, 0);
        vm.stopPrank();

        // strategy should show assets invested
        assertEq(strategy.totalAssets(), 99 ether); // 1% fee removed

        // withdraw
        vm.startPrank(alice);
        uint256 before = token.balanceOf(alice);
        uint256 withdrawAssets = vault.withdraw(shares, alice, alice);
        uint256 after = token.balanceOf(alice);
        assertEq(after - before, 99 ether); // net after fee on withdraw applied to whole assets (but in this simple path, withdraw fee applies too)
        vm.stopPrank();
    }

    function testFeesAccrueToRecipient() public {
        vm.startPrank(alice);
        vault.deposit(200 ether, alice);
        vm.stopPrank();

        // fee recipient should have received deposit fee
        assertEq(token.balanceOf(feeTo), 2 ether);
    }

    function testFuzzDeposit(uint256 amt) public {
        vm.assume(amt > 0 && amt < 1_000 ether);
        vm.startPrank(alice);
        token.approve(address(vault), type(uint256).max);
        uint256 beforeShares = vault.balanceOf(alice);
        uint256 shares = vault.deposit(amt, alice);
        assertGt(shares, 0);
        vm.stopPrank();
    }

    function testInvariant_TotalAssetsGrowsOnDeposit() public {
        uint256 before = vault.totalAssets();
        vm.startPrank(alice);
        vault.deposit(50 ether, alice);
        vm.stopPrank();
        uint256 after = vault.totalAssets();
        assertGe(after, before);
    }
}
