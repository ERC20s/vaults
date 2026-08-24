// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "../interfaces/IStrategy.sol";

/// @notice Minimal ERC20 interface used by the mock strategy.
interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

/// @title MockLendingStrategy
/// @notice A small, auditable test-focused strategy implementation of IStrategy.
/// @dev This contract is intended for unit and fuzz tests only. It holds ERC20 tokens
///      and exposes a helper accrueProfit that pulls test tokens from the owner to
///      simulate yield. It intentionally keeps logic simple and owner-restricted helpers
///      to avoid production assumptions.
contract MockLendingStrategy is IStrategy {
    IERC20 public immutable asset;
    address public owner;
    bool public panicked;

    event Deposited(address indexed from, uint256 amount);
    event Withdrawn(address indexed to, uint256 amount);
    event Harvested(uint256 amount);
    event Panic(uint256 recovered);
    event ProfitAccrued(uint256 amount);
    event OwnerChanged(address indexed oldOwner, address indexed newOwner);

    modifier onlyOwner() {
        require(msg.sender == owner, "MockLendingStrategy: only owner");
        _;
    }

    /// @param _asset Underlying ERC20 token address used by the strategy.
    /// @param _owner Admin address with access to test-only helpers and panic.
    constructor(address _asset, address _owner) {
        require(_asset != address(0), "asset=0");
        require(_owner != address(0), "owner=0");
        asset = IERC20(_asset);
        owner = _owner;
    }

    /// @notice Updates the owner/admin.
    function setOwner(address newOwner) external onlyOwner {
        require(newOwner != address(0), "owner=0");
        emit OwnerChanged(owner, newOwner);
        owner = newOwner;
    }

    /// @inheritdoc IStrategy
    /// @dev This mock expects either the Vault transfers tokens into this contract
    ///      before calling deposit, or that the caller has approved this contract
    ///      to pull tokens. We use a transferFrom attempt to cover the common cases.
    function deposit(uint256 amount) external override {
        if (amount == 0) return;
        _safeTransferFrom(msg.sender, address(this), amount);
        emit Deposited(msg.sender, amount);
    }

    /// @inheritdoc IStrategy
    /// @dev Withdraw up to `amount` from the strategy. Returns the actual withdrawn amount.
    function withdraw(uint256 amount) external override returns (uint256 withdrawn) {
        uint256 bal = asset.balanceOf(address(this));
        withdrawn = amount <= bal ? amount : bal;
        if (withdrawn > 0) {
            _safeTransfer(msg.sender, withdrawn);
        }
        emit Withdrawn(msg.sender, withdrawn);
        return withdrawn;
    }

    /// @inheritdoc IStrategy
    /// @dev Returns the actual ERC20 balance held by the strategy.
    function totalAssets() external view override returns (uint256) {
        return asset.balanceOf(address(this));
    }

    /// @inheritdoc IStrategy
    /// @dev This mock has no native yield engine. harvest is a no-op and returns 0.
    function harvest() external override returns (uint256 harvested) {
        harvested = 0;
        emit Harvested(harvested);
        return harvested;
    }

    /// @inheritdoc IStrategy
    /// @dev Emergency hook: mark panicked and transfer all held assets to the owner.
    function panic() external override onlyOwner {
        panicked = true;
        uint256 bal = asset.balanceOf(address(this));
        if (bal > 0) {
            _safeTransfer(owner, bal);
        }
        emit Panic(bal);
    }

    /// @notice Test-only helper: owner can simulate protocol yield by transferring
    ///         `extra` tokens from owner into the strategy. The owner must hold
    ///         or mint these test tokens in the test environment.
    /// @dev This function calls transferFrom(owner, this, extra) and will revert
    ///      if the owner has not approved the strategy or lacks balance.
    function accrueProfit(uint256 extra) external onlyOwner {
        if (extra == 0) return;
        _safeTransferFrom(msg.sender, address(this), extra);
        emit ProfitAccrued(extra);
    }

    // --- Internal helpers ---
    function _safeTransferFrom(address from, address to, uint256 amount) internal {
        (bool success, bytes memory data) = address(asset).call(
            abi.encodeWithSelector(IERC20.transferFrom.selector, from, to, amount)
        );
        require(success && (data.length == 0 || abi.decode(data, (bool))), "transferFrom failed");
    }

    function _safeTransfer(address to, uint256 amount) internal {
        (bool success, bytes memory data) = address(asset).call(
            abi.encodeWithSelector(IERC20.transfer.selector, to, amount)
        );
        require(success && (data.length == 0 || abi.decode(data, (bool))), "transfer failed");
    }
}
