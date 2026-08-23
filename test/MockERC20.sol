// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "./utils/Vm.sol";

contract MockERC20 {
    string public name = "Mock Token";
    string public symbol = "MCK";
    uint8 public decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(uint256 _initial) {
        totalSupply = _initial;
        balanceOf[msg.sender] = _initial;
    }

    function mint(address to, uint256 amount) public {
        totalSupply += amount;
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) public returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) public returns (bool) {
        require(balanceOf[msg.sender] >= amount, "insufficient");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) public returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (from != msg.sender && allowed != type(uint256).max) {
            require(allowed >= amount, "insufficient-allowance");
            allowance[from][msg.sender] = allowed - amount;
        }
        require(balanceOf[from] >= amount, "insufficient-balance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    // helper for tests
    function setBalance(address who, uint256 amount) public {
        uint256 prev = balanceOf[who];
        if (amount > prev) {
            totalSupply += (amount - prev);
        } else {
            totalSupply -= (prev - amount);
        }
        balanceOf[who] = amount;
    }
}
