// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import "../src/mocks/ERC20Mock.sol";

contract MockERC20Test is Test {
    ERC20Mock token;
    address alice = address(0xA11CE);

    function setUp() public {
        token = new ERC20Mock("Mock Token", "MKT");
    }

    function testMintAndTransfer() public {
        token.mint(alice, 1 ether);
        assertEq(token.balanceOf(alice), 1 ether);

        vm.prank(alice);
        token.approve(address(this), 0.5 ether);
        assertEq(token.allowance(alice, address(this)), 0.5 ether);

        vm.prank(alice);
        token.transfer(address(0xBEEF), 0.25 ether);
        assertEq(token.balanceOf(address(0xBEEF)), 0.25 ether);
        assertEq(token.balanceOf(alice), 0.75 ether);

        vm.prank(alice);
        token.transferFrom(alice, address(0xCAFE), 0.5 ether);
        assertEq(token.balanceOf(address(0xCAFE)), 0.5 ether);
        assertEq(token.balanceOf(alice), 0.25 ether);
    }
}
