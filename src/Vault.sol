// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

/// Minimal interfaces to avoid external dependencies
interface IERC20 {
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function decimals() external view returns (uint8);
}

/// @notice A minimal ERC-4626-like Vault implementing shares as an internal ERC20
contract Vault {
    // ERC20-like state for share token
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    // Asset token
    IERC20 public immutable asset;

    // Fees
    uint256 public immutable withdrawFeeBps; // basis points (parts per 10,000)
    address public immutable feeRecipient;

    // Reentrancy guard
    uint256 private _status;
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;

    event Deposit(address indexed caller, address indexed owner, uint256 assets, uint256 shares);
    event Withdraw(address indexed caller, address indexed receiver, address indexed owner, uint256 assets, uint256 shares, uint256 fee);
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor(IERC20 _asset, string memory _name, string memory _symbol, uint256 _withdrawFeeBps, address _feeRecipient) {
        require(_feeRecipient != address(0), "feeRecipient-zero");
        require(_withdrawFeeBps <= 5000, "fee-too-high"); // arbitrary safety cap
        asset = _asset;
        name = _name;
        symbol = _symbol;
        withdrawFeeBps = _withdrawFeeBps;
        feeRecipient = _feeRecipient;
        _status = _NOT_ENTERED;
    }

    modifier nonReentrant() {
        require(_status != _ENTERED, "reentrant");
        _status = _ENTERED;
        _;
        _status = _NOT_ENTERED;
    }

    // Basic ERC20 share functions
    function approve(address spender, uint256 amount) public returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) public returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) public returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (msg.sender != from && allowed != type(uint256).max) {
            require(allowed >= amount, "insufficient-allowance");
            allowance[from][msg.sender] = allowed - amount;
            emit Approval(from, msg.sender, allowance[from][msg.sender]);
        }
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        require(balanceOf[from] >= amount, "insufficient-shares");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
    }

    // Vault accounting
    function totalAssets() public view returns (uint256) {
        return asset.balanceOf(address(this));
    }

    function convertToShares(uint256 assets) public view returns (uint256) {
        if (totalSupply == 0 || totalAssets() == 0) {
            return assets;
        }
        // round down: shares = assets * totalSupply / totalAssets
        return (assets * totalSupply) / totalAssets();
    }

    function convertToAssets(uint256 shares) public view returns (uint256) {
        if (totalSupply == 0) return shares;
        return (shares * totalAssets()) / totalSupply;
    }

    // deposit assets and mint shares to receiver
    function deposit(uint256 assets, address receiver) external nonReentrant returns (uint256 shares) {
        require(assets > 0, "zero-assets");
        // Transfer assets in
        require(asset.transferFrom(msg.sender, address(this), assets), "asset-transfer-failed");
        // Calculate shares
        shares = convertToShares(assets);
        // If initial deposit and shares==0 due to rounding, give at least 1 share
        if (shares == 0) {
            shares = assets;
        }
        _mint(receiver, shares);
        emit Deposit(msg.sender, receiver, assets, shares);
    }

    // withdraw by redeeming shares; sends assets minus fee to receiver, fee to feeRecipient
    function withdraw(uint256 shares, address receiver, address owner) external nonReentrant returns (uint256 assets) {
        require(shares > 0, "zero-shares");
        if (msg.sender != owner) {
            uint256 allowed = allowance[owner][msg.sender];
            require(allowed >= shares, "insufficient-allowance");
            if (allowed != type(uint256).max) {
                allowance[owner][msg.sender] = allowed - shares;
                emit Approval(owner, msg.sender, allowance[owner][msg.sender]);
            }
        }
        assets = convertToAssets(shares);
        require(assets > 0, "zero-assets-out");
        uint256 fee = (assets * withdrawFeeBps) / 10000;
        uint256 assetsToReceiver = assets - fee;

        _burn(owner, shares);

        // Transfer out
        require(asset.transfer(receiver, assetsToReceiver), "asset-transfer-out-failed");
        if (fee > 0) {
            require(asset.transfer(feeRecipient, fee), "asset-transfer-fee-failed");
        }

        emit Withdraw(msg.sender, receiver, owner, assets, shares, fee);
    }

    // internal mint/burn for share token
    function _mint(address to, uint256 amount) internal {
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function _burn(address from, uint256 amount) internal {
        require(balanceOf[from] >= amount, "burn-exceeds-balance");
        balanceOf[from] -= amount;
        totalSupply -= amount;
        emit Transfer(from, address(0), amount);
    }
}
