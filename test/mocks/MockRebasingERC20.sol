// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/// @title MockRebasingERC20
/// @notice An ERC-20 whose balances are `internalShares * index / 1e18`, so a change of `index`
/// (a "rebase") moves every holder's balance at once without a transfer. TEST FIXTURE ONLY:
/// unrestricted `mint`, anyone may rebase. Transfers are converted to internal shares with floor
/// rounding, exactly as real rebasing tokens do, which is why a recipient can be credited a wei
/// less than the amount transferred once the index is not 1e18.
contract MockRebasingERC20 {
    string public name = "Rebasing Token";
    string public symbol = "RBS";
    uint8 public constant decimals = 18;

    uint256 public index = 1e18;
    uint256 public totalInternalShares;
    mapping(address => uint256) internal _internalShares;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    /// @notice Moves every balance by `newIndex / index`.
    function rebase(uint256 newIndex) external {
        require(newIndex > 0, "MockRebasingERC20: zero index");
        index = newIndex;
    }

    function totalSupply() external view returns (uint256) {
        return (totalInternalShares * index) / 1e18;
    }

    function balanceOf(address who) public view returns (uint256) {
        return (_internalShares[who] * index) / 1e18;
    }

    function mint(address to, uint256 amount) external {
        uint256 shares = _toShares(amount);
        totalInternalShares += shares;
        _internalShares[to] += shares;
        emit Transfer(address(0), to, amount);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amount, "MockRebasingERC20: insufficient allowance");
        if (allowed != type(uint256).max) {
            allowance[from][msg.sender] = allowed - amount;
        }
        _transfer(from, to, amount);
        return true;
    }

    function _toShares(uint256 amount) internal view returns (uint256) {
        return (amount * 1e18) / index;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        uint256 shares = _toShares(amount);
        require(_internalShares[from] >= shares, "MockRebasingERC20: insufficient balance");
        _internalShares[from] -= shares;
        _internalShares[to] += shares;
        emit Transfer(from, to, amount);
    }
}
