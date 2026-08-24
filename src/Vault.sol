// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IStrategy} from "./interfaces/IStrategy.sol";

interface IERC20 {
    function totalSupply() external view returns (uint256);
    function balanceOf(address) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
}

/// @title Minimal ERC-4626-like Vault
/// @notice Implements basic deposit/withdraw logic, simple fee accounting, and integrates with IStrategy.
contract Vault {
    // Minimal ERC20 shares bookkeeping
    string public name;
    string public symbol;
    uint8 public decimals = 18;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    IERC20 public immutable asset;
    IStrategy public immutable strategy;

    address public feeRecipient;
    uint16 public feeBasisPoints; // e.g. 100 = 1.00%

    // Simple reentrancy guard
    uint8 private _locked = 1;
    modifier nonReentrant() {
        require(_locked == 1, "reentrant");
        _locked = 2;
        _;
        _locked = 1;
    }

    event Deposit(address indexed caller, address indexed owner, uint256 assets, uint256 shares);
    event Withdraw(address indexed caller, address indexed receiver, address indexed owner, uint256 assets, uint256 shares);
    event FeesUpdated(address indexed recipient, uint16 basisPoints);

    constructor(
        address _asset,
        address _strategy,
        string memory _name,
        string memory _symbol,
        address _feeRecipient,
        uint16 _feeBasisPoints
    ) {
        require(_asset != address(0), "zero asset");
        require(_strategy != address(0), "zero strategy");
        asset = IERC20(_asset);
        strategy = IStrategy(_strategy);
        name = _name;
        symbol = _symbol;
        feeRecipient = _feeRecipient;
        feeBasisPoints = _feeBasisPoints;
        // approve the strategy so it may pull funds if it uses transferFrom
        // note: be aware some ERC20s do not allow approving from constructor for non-existent spender but this is acceptable for tests
        asset.approve(_strategy, type(uint256).max);
    }

    // --- minimal ERC20 shares functions ---
    function _mint(address to, uint256 amount) internal {
        totalSupply += amount;
        balanceOf[to] += amount;
    }

    function _burn(address from, uint256 amount) internal {
        require(balanceOf[from] >= amount, "insufficient shares");
        balanceOf[from] -= amount;
        totalSupply -= amount;
    }

    // --- accounting helpers ---
    /// @notice Total underlying assets managed by the Vault (strategy + tokens held in Vault)
    function totalAssets() public view returns (uint256) {
        uint256 vaultBal = asset.balanceOf(address(this));
        uint256 strat = strategy.totalAssets();
        return vaultBal + strat;
    }

    function convertToShares(uint256 assets) public view returns (uint256) {
        uint256 _totalAssets = totalAssets();
        if (totalSupply == 0 || _totalAssets == 0) {
            return assets; // 1:1 initial
        }
        return assets * totalSupply / _totalAssets;
    }

    function convertToAssets(uint256 shares) public view returns (uint256) {
        uint256 _totalAssets = totalAssets();
        if (totalSupply == 0) return shares; // avoid div by zero; mirror convertToShares
        return shares * _totalAssets / totalSupply;
    }

    // --- fee helpers ---
    function _chargeFee(uint256 amount) internal view returns (uint256 fee, uint256 net) {
        if (feeRecipient == address(0) || feeBasisPoints == 0) return (0, amount);
        fee = amount * feeBasisPoints / 10000;
        net = amount - fee;
    }

    // --- actions ---
    /// @notice Deposit exact `assets` of the underlying asset and receive shares
    function deposit(uint256 assets, address receiver) external nonReentrant returns (uint256 shares) {
        require(assets > 0, "zero assets");
        // transfer assets from caller to Vault
        require(asset.transferFrom(msg.sender, address(this), assets), "asset transfer failed");

        (uint256 fee, uint256 net) = _chargeFee(assets);
        if (fee > 0) {
            require(asset.transfer(feeRecipient, fee), "fee transfer failed");
        }

        uint256 _totalAssetsBefore = totalAssets() - net; // subtract net because totalAssets includes the just-transferred amount
        // compute shares
        if (totalSupply == 0 || _totalAssetsBefore == 0) {
            shares = net; // initial 1:1
        } else {
            shares = net * totalSupply / _totalAssetsBefore;
        }

        require(shares > 0, "zero shares");

        // send net to strategy (strategy implementations may expect tokens already in their balance)
        require(asset.transfer(address(strategy), net), "transfer to strategy failed");
        // notify strategy
        try strategy.deposit(net) {
        } catch {
            // if strategy.deposit reverts, we revert to avoid losing funds
            revert("strategy deposit failed");
        }

        _mint(receiver, shares);
        emit Deposit(msg.sender, receiver, assets, shares);
    }

    /// @notice Withdraw underlying assets by redeeming `shares`
    function withdraw(uint256 shares, address receiver, address owner) external nonReentrant returns (uint256 assets) {
        require(shares > 0, "zero shares");

        if (msg.sender != owner) {
            // allow approval-less tests; in a real ERC20 this would check allowance
            revert("only owner can withdraw in this minimal Vault");
        }

        assets = convertToAssets(shares);
        (uint256 fee, uint256 net) = _chargeFee(assets);

        _burn(owner, shares);

        uint256 vaultBal = asset.balanceOf(address(this));
        uint256 needed = assets;
        if (vaultBal < needed) {
            uint256 toWithdraw = needed - vaultBal;
            uint256 withdrawn = strategy.withdraw(toWithdraw);
            // withdrawn is expected to be credited to Vault balance
            // accept shortfall: adjust assets downward
            uint256 newVaultBal = asset.balanceOf(address(this));
            if (newVaultBal < needed) {
                assets = newVaultBal; // cap
                (fee, net) = _chargeFee(assets);
            }
        }

        if (fee > 0) {
            require(asset.transfer(feeRecipient, fee), "fee transfer failed");
        }

        uint256 pay = assets - fee;
        require(asset.transfer(receiver, pay), "pay transfer failed");

        emit Withdraw(msg.sender, receiver, owner, assets, shares);
    }

    // governance utilities
    function setFees(address _recipient, uint16 _basisPoints) external {
        // in cycle-1 this is an open function; in later cycles this should be access-controlled
        feeRecipient = _recipient;
        feeBasisPoints = _basisPoints;
        emit FeesUpdated(_recipient, _basisPoints);
    }
}
