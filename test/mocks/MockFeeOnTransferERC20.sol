// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/// @title MockFeeOnTransferERC20
/// @notice An ERC-20 that burns `feeBps` of every `transfer` / `transferFrom` before crediting the
/// recipient, the way deflationary tokens do. TEST FIXTURE ONLY: unrestricted `mint`, settable fee.
/// With `feeBps == 0` it behaves like a plain token, which is the control case in the tests.
contract MockFeeOnTransferERC20 {
    string public name = "Fee Token";
    string public symbol = "FEE";
    uint8 public constant decimals = 18;

    uint256 public totalSupply;
    uint256 public feeBps;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor(uint256 feeBps_) {
        require(feeBps_ <= 10_000, "MockFeeOnTransferERC20: fee above 100%");
        feeBps = feeBps_;
    }

    function setFeeBps(uint256 feeBps_) external {
        require(feeBps_ <= 10_000, "MockFeeOnTransferERC20: fee above 100%");
        feeBps = feeBps_;
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
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amount, "MockFeeOnTransferERC20: insufficient allowance");
        if (allowed != type(uint256).max) {
            allowance[from][msg.sender] = allowed - amount;
        }
        _transfer(from, to, amount);
        return true;
    }

    /// @dev The sender is debited `amount`; the recipient is credited `amount` less the fee, which
    /// is burned. This is the behaviour the vault must refuse: shares priced on `amount` against a
    /// smaller delivery.
    function _transfer(address from, address to, uint256 amount) internal {
        require(balanceOf[from] >= amount, "MockFeeOnTransferERC20: insufficient balance");
        uint256 fee = (amount * feeBps) / 10_000;
        balanceOf[from] -= amount;
        balanceOf[to] += amount - fee;
        totalSupply -= fee;
        emit Transfer(from, to, amount - fee);
    }
}
