// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/// @notice Minimal ERC-20 surface the Vault needs from its underlying asset.
/// @dev Declared here so the Vault stays dependency-free; `transfer`/`transferFrom`
/// are called through low-level helpers that tolerate tokens returning no value.
interface IERC20 {
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @title Vault
/// @notice A minimal, dependency-free ERC-4626 tokenised vault over a single ERC-20 asset.
/// @dev Assets are held idle by the vault itself: `totalAssets()` is the vault's own balance of
/// the underlying token. No `IStrategy` is wired in yet — routing `totalAssets()` and idle capital
/// through `src/interfaces/IStrategy.sol` is deliberately left to a later change so this contract
/// stays small enough to review line by line.
///
/// Share accounting:
/// - Shares are rounded DOWN when they are minted for a depositor and rounded UP when they are
///   burned for a withdrawer, so rounding dust always accrues to the vault (never to the caller).
/// - Conversions use a virtual-shares / virtual-assets offset: every conversion behaves as if the
///   vault held `1` extra asset and `10 ** _DECIMALS_OFFSET` extra shares. This is the standard
///   defence against the "first depositor" / donation inflation attack: an attacker who mints 1 wei
///   of shares and then donates a large balance can only steal a fraction bounded by the offset
///   (here `10 ** 3`, i.e. the attack costs roughly 1000x what it can steal), instead of rounding a
///   later depositor's shares to zero.
///
/// This contract is UNAUDITED and is not deployment-ready. It exists so the protocol's fuzz and
/// invariant tests have something real to exercise.
contract Vault {
    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice ERC-4626 deposit event.
    event Deposit(address indexed sender, address indexed owner, uint256 assets, uint256 shares);

    /// @notice ERC-4626 withdraw event.
    event Withdraw(
        address indexed sender, address indexed receiver, address indexed owner, uint256 assets, uint256 shares
    );

    /// @notice ERC-20 transfer event for the share token.
    event Transfer(address indexed from, address indexed to, uint256 value);

    /// @notice ERC-20 approval event for the share token.
    event Approval(address indexed owner, address indexed spender, uint256 value);

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error ZeroAddress();
    error ZeroShares();
    error InsufficientBalance();
    error InsufficientAllowance();
    error ExceedsMaxWithdraw();
    error ExceedsMaxRedeem();
    error TransferFailed();
    error Reentrancy();

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice The underlying ERC-20 token this vault accounts in.
    IERC20 private immutable _asset;

    /// @dev Decimals of the share token; mirrors the asset's decimals plus the offset.
    uint8 private immutable _decimals;

    /// @dev Virtual-shares exponent used by every conversion. See the contract NatSpec.
    uint8 private constant _DECIMALS_OFFSET = 3;

    /// @notice Share token name.
    string public name;

    /// @notice Share token symbol.
    string public symbol;

    /// @notice Total shares in circulation.
    uint256 public totalSupply;

    /// @notice Share balance of an account.
    mapping(address => uint256) public balanceOf;

    /// @notice Share allowance of `spender` over `owner`'s shares.
    mapping(address => mapping(address => uint256)) public allowance;

    /// @dev Simple non-reentrancy latch: 1 = unlocked, 2 = entered.
    uint256 private _locked = 1;

    modifier nonReentrant() {
        if (_locked != 1) revert Reentrancy();
        _locked = 2;
        _;
        _locked = 1;
    }

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @param asset_ The underlying ERC-20 token. Must be a plain, non-rebasing, non-fee-on-transfer token.
    /// @param name_ Name of the share token.
    /// @param symbol_ Symbol of the share token.
    constructor(IERC20 asset_, string memory name_, string memory symbol_) {
        if (address(asset_) == address(0)) revert ZeroAddress();
        _asset = asset_;
        name = name_;
        symbol = symbol_;
        _decimals = _tryAssetDecimals(address(asset_)) + _DECIMALS_OFFSET;
    }

    /*//////////////////////////////////////////////////////////////
                            ERC-4626 METADATA
    //////////////////////////////////////////////////////////////*/

    /// @notice The address of the underlying token used for accounting, depositing and withdrawing.
    function asset() public view returns (address) {
        return address(_asset);
    }

    /// @notice Decimals of the share token: the asset's decimals plus the virtual-shares offset.
    function decimals() public view returns (uint8) {
        return _decimals;
    }

    /// @notice Total amount of the underlying asset managed by the vault.
    /// @dev Idle-only for now: the vault's own balance. A later change may add strategy holdings here.
    function totalAssets() public view returns (uint256) {
        return _asset.balanceOf(address(this));
    }

    /*//////////////////////////////////////////////////////////////
                              CONVERSIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Shares that `assets` would buy at the current exchange rate, ignoring limits. Rounds down.
    function convertToShares(uint256 assets) public view returns (uint256) {
        return _mulDivDown(assets, totalSupply + 10 ** _DECIMALS_OFFSET, totalAssets() + 1);
    }

    /// @notice Assets that `shares` are worth at the current exchange rate, ignoring limits. Rounds down.
    function convertToAssets(uint256 shares) public view returns (uint256) {
        return _mulDivDown(shares, totalAssets() + 1, totalSupply + 10 ** _DECIMALS_OFFSET);
    }

    /// @notice Shares minted for a `deposit` of `assets`. Rounds down (in the vault's favour).
    function previewDeposit(uint256 assets) public view returns (uint256) {
        return convertToShares(assets);
    }

    /// @notice Assets required to `mint` exactly `shares`. Rounds up (in the vault's favour).
    function previewMint(uint256 shares) public view returns (uint256) {
        return _mulDivUp(shares, totalAssets() + 1, totalSupply + 10 ** _DECIMALS_OFFSET);
    }

    /// @notice Shares burned to `withdraw` exactly `assets`. Rounds up (in the vault's favour).
    function previewWithdraw(uint256 assets) public view returns (uint256) {
        return _mulDivUp(assets, totalSupply + 10 ** _DECIMALS_OFFSET, totalAssets() + 1);
    }

    /// @notice Assets returned for a `redeem` of `shares`. Rounds down (in the vault's favour).
    function previewRedeem(uint256 shares) public view returns (uint256) {
        return convertToAssets(shares);
    }

    /*//////////////////////////////////////////////////////////////
                                 LIMITS
    //////////////////////////////////////////////////////////////*/

    /// @notice Maximum assets `receiver` may deposit. Unlimited in this implementation.
    function maxDeposit(address) public pure returns (uint256) {
        return type(uint256).max;
    }

    /// @notice Maximum shares `receiver` may mint. Unlimited in this implementation.
    function maxMint(address) public pure returns (uint256) {
        return type(uint256).max;
    }

    /// @notice Maximum assets `owner` may withdraw, given their share balance.
    function maxWithdraw(address owner) public view returns (uint256) {
        return convertToAssets(balanceOf[owner]);
    }

    /// @notice Maximum shares `owner` may redeem.
    function maxRedeem(address owner) public view returns (uint256) {
        return balanceOf[owner];
    }

    /*//////////////////////////////////////////////////////////////
                          DEPOSIT / WITHDRAWAL
    //////////////////////////////////////////////////////////////*/

    /// @notice Deposit exactly `assets` of the underlying and mint shares to `receiver`.
    /// @return shares The number of shares minted.
    function deposit(uint256 assets, address receiver) public nonReentrant returns (uint256 shares) {
        if (receiver == address(0)) revert ZeroAddress();
        shares = previewDeposit(assets);
        if (shares == 0) revert ZeroShares();

        // Pull assets first, then mint: totalAssets() must not include the incoming
        // deposit while the share price is being computed above.
        _safeTransferFrom(_asset, msg.sender, address(this), assets);
        _mint(receiver, shares);

        emit Deposit(msg.sender, receiver, assets, shares);
    }

    /// @notice Mint exactly `shares` to `receiver`, pulling however many assets that costs.
    /// @return assets The amount of underlying pulled from the caller.
    function mint(uint256 shares, address receiver) public nonReentrant returns (uint256 assets) {
        if (receiver == address(0)) revert ZeroAddress();
        if (shares == 0) revert ZeroShares();
        assets = previewMint(shares);

        _safeTransferFrom(_asset, msg.sender, address(this), assets);
        _mint(receiver, shares);

        emit Deposit(msg.sender, receiver, assets, shares);
    }

    /// @notice Burn shares from `owner` and send exactly `assets` of the underlying to `receiver`.
    /// @dev If `msg.sender != owner`, the caller must hold a share allowance from `owner`.
    /// @return shares The number of shares burned.
    function withdraw(uint256 assets, address receiver, address owner) public nonReentrant returns (uint256 shares) {
        if (receiver == address(0)) revert ZeroAddress();
        if (assets > maxWithdraw(owner)) revert ExceedsMaxWithdraw();

        shares = previewWithdraw(assets);
        if (shares == 0) revert ZeroShares();

        if (msg.sender != owner) _spendAllowance(owner, msg.sender, shares);

        _burn(owner, shares);
        _safeTransfer(_asset, receiver, assets);

        emit Withdraw(msg.sender, receiver, owner, assets, shares);
    }

    /// @notice Burn exactly `shares` from `owner` and send the corresponding assets to `receiver`.
    /// @dev If `msg.sender != owner`, the caller must hold a share allowance from `owner`.
    /// @return assets The amount of underlying sent.
    function redeem(uint256 shares, address receiver, address owner) public nonReentrant returns (uint256 assets) {
        if (receiver == address(0)) revert ZeroAddress();
        if (shares > maxRedeem(owner)) revert ExceedsMaxRedeem();
        if (shares == 0) revert ZeroShares();

        if (msg.sender != owner) _spendAllowance(owner, msg.sender, shares);

        assets = previewRedeem(shares);

        _burn(owner, shares);
        _safeTransfer(_asset, receiver, assets);

        emit Withdraw(msg.sender, receiver, owner, assets, shares);
    }

    /*//////////////////////////////////////////////////////////////
                            ERC-20 SHARE TOKEN
    //////////////////////////////////////////////////////////////*/

    /// @notice Approve `spender` to move `amount` of the caller's shares.
    function approve(address spender, uint256 amount) public returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    /// @notice Move `amount` of the caller's shares to `to`.
    function transfer(address to, uint256 amount) public returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    /// @notice Move `amount` of `from`'s shares to `to`, spending the caller's allowance.
    function transferFrom(address from, address to, uint256 amount) public returns (bool) {
        if (msg.sender != from) _spendAllowance(from, msg.sender, amount);
        _transfer(from, to, amount);
        return true;
    }

    /*//////////////////////////////////////////////////////////////
                                INTERNALS
    //////////////////////////////////////////////////////////////*/

    function _transfer(address from, address to, uint256 amount) internal {
        if (to == address(0)) revert ZeroAddress();
        uint256 fromBalance = balanceOf[from];
        if (fromBalance < amount) revert InsufficientBalance();
        unchecked {
            balanceOf[from] = fromBalance - amount;
            balanceOf[to] += amount;
        }
        emit Transfer(from, to, amount);
    }

    function _spendAllowance(address owner, address spender, uint256 amount) internal {
        uint256 allowed = allowance[owner][spender];
        if (allowed != type(uint256).max) {
            if (allowed < amount) revert InsufficientAllowance();
            unchecked {
                allowance[owner][spender] = allowed - amount;
            }
            emit Approval(owner, spender, allowance[owner][spender]);
        }
    }

    function _mint(address to, uint256 amount) internal {
        totalSupply += amount;
        unchecked {
            balanceOf[to] += amount;
        }
        emit Transfer(address(0), to, amount);
    }

    function _burn(address from, uint256 amount) internal {
        uint256 fromBalance = balanceOf[from];
        if (fromBalance < amount) revert InsufficientBalance();
        unchecked {
            balanceOf[from] = fromBalance - amount;
            totalSupply -= amount;
        }
        emit Transfer(from, address(0), amount);
    }

    /// @dev floor(x * y / d). Reverts on division by zero; the virtual offset keeps `d` non-zero.
    function _mulDivDown(uint256 x, uint256 y, uint256 d) internal pure returns (uint256) {
        return (x * y) / d;
    }

    /// @dev ceil(x * y / d).
    function _mulDivUp(uint256 x, uint256 y, uint256 d) internal pure returns (uint256) {
        uint256 p = x * y;
        return p == 0 ? 0 : ((p - 1) / d) + 1;
    }

    /// @dev Reads `decimals()` from the asset, defaulting to 18 for tokens that do not expose it.
    function _tryAssetDecimals(address token) internal view returns (uint8) {
        (bool ok, bytes memory data) = token.staticcall(abi.encodeWithSignature("decimals()"));
        if (ok && data.length >= 32) {
            uint256 value = abi.decode(data, (uint256));
            if (value <= 32) return uint8(value);
        }
        return 18;
    }

    /// @dev ERC-20 transfer that accepts tokens returning either nothing or `true`.
    function _safeTransfer(IERC20 token, address to, uint256 amount) internal {
        (bool ok, bytes memory data) = address(token).call(abi.encodeWithSelector(IERC20.transfer.selector, to, amount));
        if (!ok || (data.length != 0 && !abi.decode(data, (bool)))) revert TransferFailed();
    }

    /// @dev ERC-20 transferFrom that accepts tokens returning either nothing or `true`.
    function _safeTransferFrom(IERC20 token, address from, address to, uint256 amount) internal {
        (bool ok, bytes memory data) =
            address(token).call(abi.encodeWithSelector(IERC20.transferFrom.selector, from, to, amount));
        if (!ok || (data.length != 0 && !abi.decode(data, (bool)))) revert TransferFailed();
    }
}
