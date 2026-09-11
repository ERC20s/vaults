// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IStrategy} from "../interfaces/IStrategy.sol";
import {SafeERC20, IERC20} from "../utils/SafeERC20.sol";

/// @title MinimalVault
/// @notice A small, auditable example vault that demonstrates an ERC-4626-like surface
/// and the exact custody boundary with an IStrategy. It is intentionally minimal: no
/// ownership, fees or pausing. The four state-changing entry points are single-entry
/// (`nonReentrant`); the views are not. Uses SafeERC20 for token ops.
contract MinimalVault {
    using SafeERC20 for IERC20;

    IERC20 public immutable token;
    IStrategy public immutable strategy;

    mapping(address => uint256) public balanceOf;
    uint256 public totalSupply;

    /// @dev ERC-20 allowances for vault shares. Spender-approved amounts are consumed by
    /// `transferFrom`; a max (`type(uint256).max`) approval is left untouched, matching the
    /// common infinite-approval convention.
    mapping(address => mapping(address => uint256)) public allowance;

    /// @notice Cosmetic ERC-20 metadata so wallets and tooling show a sensible label. Purely
    /// informational: nothing in the vault's accounting reads these.
    string public constant name = "MinimalVault Share";
    string public constant symbol = "mVLT";

    /// @notice Matches the underlying asset's own `decimals()` so a share's displayed
    /// magnitude always tracks the raw units it is minted 1:1 against at bootstrap (see
    /// `_convertToShares`). Falls back to 18 when the asset does not expose `decimals()`,
    /// or exposes it in a way that cannot be read as a `uint8` - the same defensive
    /// convention used by OpenZeppelin's and Solmate's ERC-4626 wrappers.
    uint8 public immutable decimals;

    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;

    /// @dev Standard ERC-4626 Deposit and Withdraw events, plus ERC20 Transfer/Approval for shares.
    event Deposit(address indexed caller, address indexed owner, uint256 assets, uint256 shares);
    event Withdraw(address indexed caller, address indexed receiver, uint256 assets, uint256 shares);
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    /// @dev Single-entry flag for the state-changing entry points. Starts (and returns) at
    /// `_NOT_ENTERED`, so the slot is warm and every call after the first pays only a warm
    /// SSTORE for the guard.
    uint256 private _locked = _NOT_ENTERED;

    /// @dev Rejects a nested call into `deposit`, `mint`, `withdraw` or `redeem`.
    ///
    /// Every other guard in this contract protects a SINGLE call: zero-share, no-price,
    /// strategy-pulled, floor-priced redeem. None of them survives a nested one, and this
    /// vault opens the window itself: `withdraw()` and `redeem()` call `strategy.withdraw()`
    /// BEFORE they burn shares, so between the strategy's push and its return the assets have
    /// already left the strategy - `strategy.totalAssets()` is low - while `totalSupply` still
    /// counts the shares being redeemed. `_convertToShares` prices against exactly that pair.
    ///
    /// Concretely, with totalSupply 100 and totalAssets 100: a holder redeems 50, the strategy
    /// pushes 50 to the vault and, before returning, a callback (a hookful underlying, an
    /// ERC-777/ERC-1363 asset, or a strategy that routes through another contract) re-enters
    /// with `deposit(50)`. That nested deposit reads totalAssets 50 against totalSupply 100 and
    /// mints 100 shares for 50 assets instead of 50. Every existing guard passes:
    /// `_assertStrategyPulled` compares against a snapshot that already includes the in-transit
    /// 50, and the outer `got == withdrawn` check still holds. End state: 150 shares against
    /// 100 assets, and the caller has taken half the vault from the other holders.
    ///
    /// The trade-off is deliberate: a strategy that legitimately re-enters the vault during
    /// `deposit()` or `withdraw()` is now refused. See `test/mocks/MockReentrantStrategy.sol`.
    modifier nonReentrant() {
        require(_locked == _NOT_ENTERED, "MinimalVault: reentrancy");
        _locked = _ENTERED;
        _;
        _locked = _NOT_ENTERED;
    }

    constructor(IERC20 token_, IStrategy strategy_) {
        require(address(token_) != address(0), "MinimalVault: zero-token");
        require(address(strategy_) != address(0), "MinimalVault: zero-strategy");
        token = token_;
        strategy = strategy_;
        decimals = _readDecimals(token_);
    }

    /// @dev Reads `decimals()` off the underlying asset through a bounded staticcall, since
    /// `IERC20` (declared in `src/utils/SafeERC20.sol`) does not include it and not every
    /// ERC-20 implements it. Falls back to 18 when the call reverts, runs out of gas, or
    /// returns data that is not a single, cleanly-encoded `uint8` - so a hostile or
    /// non-conforming token can never make construction fail or return a garbage value.
    function _readDecimals(IERC20 token_) private view returns (uint8) {
        (bool ok, bytes memory data) = address(token_).staticcall(
            abi.encodeWithSignature("decimals()")
        );
        if (ok && data.length == 32) {
            uint256 value = abi.decode(data, (uint256));
            if (value <= type(uint8).max) {
                return uint8(value);
            }
        }
        return 18;
    }

    /// @notice Deposit `amount` underlying and receive shares.
    /// @dev Pulls from caller, approves strategy exactly, calls strategy.deposit(amount)
    /// and mints shares using conservative (floor) rounding. Returns minted shares.
    ///
    /// Three guards make the floor rounding safe to keep:
    /// - the vault must be able to PRICE the deposit: an empty vault (`totalSupply == 0`)
    ///   bootstraps 1:1, but a vault with shares outstanding and `strategy.totalAssets()`
    ///   at 0 - a total loss, an emergency unwind that ended empty, a strategy drained
    ///   from outside - has no honest exchange rate and must refuse rather than mint 1:1
    ///   against dead shares (see `_convertToShares`);
    /// - the share amount is computed BEFORE any token moves and must be non-zero, so a
    ///   depositor can never hand over assets and be minted nothing (the classic ERC-4626
    ///   first-depositor / donation inflation loss: donate to the strategy, and a later
    ///   deposit rounds down to 0 shares);
    /// - the strategy must have pulled exactly `amount` out of this vault by the time
    ///   `deposit()` returns, which is the pull-based custody rule in
    ///   `src/interfaces/IStrategy.sol` stated as an assertion instead of a comment.
    ///
    /// The call is also single-entry (`nonReentrant`): none of the three guards above survives
    /// a nested call, and a callback during `strategy.deposit()` would price against a state
    /// this call has already half-moved.
    function deposit(uint256 amount) external nonReentrant returns (uint256 shares) {
        require(amount > 0, "MinimalVault: zero-assets");

        uint256 totalAssetsBefore = strategy.totalAssets();
        require(totalSupply == 0 || totalAssetsBefore > 0, "MinimalVault: no-price");

        // Price the deposit against pre-deposit state, before any token moves.
        shares = _convertToShares(amount, totalAssetsBefore);
        require(shares > 0, "MinimalVault: zero-shares");

        // Pull tokens from caller into the vault
        uint256 vaultBefore = tokenBalanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), amount);

        // Approve strategy for exactly amount and let it pull
        token.safeApprove(address(strategy), amount);
        strategy.deposit(amount);
        _assertStrategyPulled(vaultBefore);

        // Mint shares
        totalSupply += shares;
        balanceOf[msg.sender] += shares;

        // Emit standard ERC-4626 Deposit and ERC20 Transfer (mint) logs
        emit Deposit(msg.sender, msg.sender, amount, shares);
        emit Transfer(address(0), msg.sender, shares);

        return shares;
    }

    /// @notice Mint `shares` by supplying the required underlying.
    /// @dev Computes required assets, pulls them, approves the strategy and deposits.
    /// Mirrors the guards in `deposit()`: the vault must be able to price the mint, no
    /// zero-share or zero-asset mint, and the strategy must take custody of everything
    /// this call pulled in.
    function mint(uint256 shares) external nonReentrant returns (uint256 assets) {
        require(shares > 0, "MinimalVault: zero-shares");

        uint256 totalAssetsBefore = strategy.totalAssets();
        require(totalSupply == 0 || totalAssetsBefore > 0, "MinimalVault: no-price");

        assets = _convertToAssetsForMint(shares, totalAssetsBefore);
        require(assets > 0, "MinimalVault: zero-assets");

        uint256 vaultBefore = tokenBalanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), assets);
        token.safeApprove(address(strategy), assets);
        strategy.deposit(assets);
        _assertStrategyPulled(vaultBefore);

        totalSupply += shares;
        balanceOf[msg.sender] += shares;

        // Emit standard ERC-4626 Deposit and ERC20 Transfer (mint) logs
        emit Deposit(msg.sender, msg.sender, assets, shares);
        emit Transfer(address(0), msg.sender, shares);

        return assets;
    }

    /// @notice Withdraw up to `assets` by burning proportional shares from caller.
    /// @dev Calls strategy.withdraw(assets) and burns shares proportional to the
    /// actual amount returned (ceil), then forwards tokens to caller.
    ///
    /// Single-entry (`nonReentrant`): shares are burned AFTER `strategy.withdraw()` returns, so
    /// a callback fired while the assets are in transit would see a low `totalAssets()` against
    /// an unchanged `totalSupply` and mint against it.
    function withdraw(uint256 assets) external nonReentrant returns (uint256 withdrawn) {
        uint256 totalAssetsBefore = strategy.totalAssets();
        require(totalAssetsBefore > 0 && totalSupply > 0, "no-liquidity");

        uint256 before = tokenBalanceOf(address(this));
        uint256 got = strategy.withdraw(assets);
        uint256 balanceAfter = tokenBalanceOf(address(this));
        withdrawn = balanceAfter - before;
        require(got == withdrawn, "MinimalVault: strategy returned mismatch");

        // Burn shares proportional to withdrawn amount (ceil)
        uint256 sharesToBurn = _mulDivCeil(withdrawn, totalSupply, totalAssetsBefore);
        require(balanceOf[msg.sender] >= sharesToBurn, "insufficient shares");
        balanceOf[msg.sender] -= sharesToBurn;
        totalSupply -= sharesToBurn;

        // Emit standard ERC-4626 Withdraw and ERC20 Transfer (burn) logs
        emit Withdraw(msg.sender, msg.sender, withdrawn, sharesToBurn);
        emit Transfer(msg.sender, address(0), sharesToBurn);

        if (withdrawn > 0) {
            token.safeTransfer(msg.sender, withdrawn);
        }
        return withdrawn;
    }

    /// @notice Redeem `shares` for underlying.
    /// @dev Rounding runs in the VAULT's favour, which is the only direction an
    /// ERC-4626-style redemption may round:
    /// - the assets asked of the strategy are priced with FLOOR
    ///   (`shares * totalAssets / totalSupply`), so a redeemer can never be paid more
    ///   than the burned shares are worth;
    /// - when the strategy serves the request in full, exactly `shares` are burned;
    /// - on a shortfall only the shares the payout actually covers are burned, rounded
    ///   UP (`ceil(withdrawn * totalSupply / totalAssets)`), so the shortfall costs the
    ///   redeemer nothing extra but never leaves shares un-burned.
    ///
    /// The old code asked for a rounded-UP amount and then CAPPED the burn at `shares`.
    /// That cap was conservative for the caller, not for the vault: a dust redeem against
    /// an inflated share price (deposit 3, donate 7 to the strategy, redeem 1) was paid
    /// 4 assets for a share worth 3.33 and the remaining holders paid the difference.
    /// With floor pricing the cap can no longer bind, so it is kept as an assertion.
    ///
    /// Single-entry (`nonReentrant`) for the same reason as `withdraw()`: the burn happens after
    /// the strategy has pushed, and a nested `deposit()` in that window mints at a price the
    /// in-transit assets have temporarily depressed.
    function redeem(uint256 shares) external nonReentrant returns (uint256 withdrawn) {
        require(shares > 0, "MinimalVault: zero-shares");
        require(balanceOf[msg.sender] >= shares, "insufficient shares");

        uint256 totalAssetsBefore = strategy.totalAssets();
        uint256 totalSupplyBefore = totalSupply;
        require(totalSupplyBefore > 0 && totalAssetsBefore > 0, "no-liquidity");

        // FLOOR: never ask the strategy for more than the shares are worth.
        uint256 assetsRequested = (shares * totalAssetsBefore) / totalSupplyBefore;
        require(assetsRequested > 0, "MinimalVault: zero-assets");

        uint256 before = tokenBalanceOf(address(this));
        uint256 got = strategy.withdraw(assetsRequested);
        uint256 balanceAfter = tokenBalanceOf(address(this));
        withdrawn = balanceAfter - before;
        require(got == withdrawn, "MinimalVault: strategy returned mismatch");
        require(withdrawn <= assetsRequested, "MinimalVault: strategy overpaid");

        uint256 sharesToBurn;
        if (withdrawn == assetsRequested) {
            // Served in full: the caller pays with every share offered.
            sharesToBurn = shares;
        } else {
            // Shortfall: burn only what the payout covers, rounded up.
            sharesToBurn = _mulDivCeil(withdrawn, totalSupplyBefore, totalAssetsBefore);
            // withdrawn < floor(shares * totalAssets / totalSupply) makes this strictly
            // smaller than `shares`; the old cap is an assertion now, not a discount.
            require(sharesToBurn <= shares, "MinimalVault: burn exceeds shares offered");
        }

        balanceOf[msg.sender] -= sharesToBurn;
        totalSupply -= sharesToBurn;

        // Emit standard ERC-4626 Withdraw and ERC20 Transfer (burn) logs
        emit Withdraw(msg.sender, msg.sender, withdrawn, sharesToBurn);
        emit Transfer(msg.sender, address(0), sharesToBurn);

        if (withdrawn > 0) {
            token.safeTransfer(msg.sender, withdrawn);
        }
        return withdrawn;
    }

    /// @notice Approve `spender` to move up to `value` of the caller's shares.
    /// @dev Overwrites any existing allowance (the standard ERC-20 `approve` semantics,
    /// including its known front-running caveat, which this vault does not attempt to fix).
    function approve(address spender, uint256 value) external returns (bool) {
        allowance[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }

    /// @notice Increase the caller's allowance for `spender` by `addedValue`.
    /// @dev Convenience helper matching common ERC-20 patterns. Emits Approval(owner, spender, newValue).
    function increaseAllowance(address spender, uint256 addedValue) external returns (bool) {
        allowance[msg.sender][spender] = allowance[msg.sender][spender] + addedValue;
        emit Approval(msg.sender, spender, allowance[msg.sender][spender]);
        return true;
    }

    /// @notice Decrease the caller's allowance for `spender` by `subtractedValue`.
    /// @dev Reverts when the subtraction would underflow. Emits Approval(owner, spender, newValue).
    function decreaseAllowance(address spender, uint256 subtractedValue) external returns (bool) {
        uint256 current = allowance[msg.sender][spender];
        require(current >= subtractedValue, "MinimalVault: decreased allowance below zero");
        unchecked {
            uint256 newAllowance = current - subtractedValue;
            allowance[msg.sender][spender] = newAllowance;
            emit Approval(msg.sender, spender, newAllowance);
        }
        return true;
    }

    /// @notice Move `value` of the caller's shares to `to`.
    /// @dev Pure ledger update: no strategy interaction, so no reentrancy exposure and no
    /// `nonReentrant` guard is needed. Rejects transfers to the zero address.
    function transfer(address to, uint256 value) external returns (bool) {
        require(to != address(0), "MinimalVault: transfer to zero address");
        uint256 fromBalance = balanceOf[msg.sender];
        require(fromBalance >= value, "MinimalVault: transfer exceeds balance");
        unchecked {
            balanceOf[msg.sender] = fromBalance - value;
        }
        balanceOf[to] += value;
        emit Transfer(msg.sender, to, value);
        return true;
    }

    /// @notice Move `value` of `from`'s shares to `to`, spending `msg.sender`'s allowance.
    /// @dev A `type(uint256).max` allowance is treated as infinite and left unchanged, matching
    /// the common ERC-20 convention.
    function transferFrom(address from, address to, uint256 value) external returns (bool) {
        require(to != address(0), "MinimalVault: transfer to zero address");
        uint256 currentAllowance = allowance[from][msg.sender];
        if (currentAllowance != type(uint256).max) {
            require(currentAllowance >= value, "MinimalVault: insufficient allowance");
            unchecked {
                uint256 newAllowance = currentAllowance - value;
                allowance[from][msg.sender] = newAllowance;
                // Emit Approval so off-chain indexers and wallets observe the allowance change
                emit Approval(from, msg.sender, newAllowance);
            }
        }
        uint256 fromBalance = balanceOf[from];
        require(fromBalance >= value, "MinimalVault: transfer exceeds balance");
        unchecked {
            balanceOf[from] = fromBalance - value;
        }
        balanceOf[to] += value;
        emit Transfer(from, to, value);
        return true;
    }

    /// @notice Forwarded view of the strategy's totalAssets().
    function totalAssets() external view returns (uint256) {
        return strategy.totalAssets();
    }

    /// @notice ERC-4626 asset() view: the underlying token address.
    /// @dev Additive, read-only: returns the vault's configured asset token.
    function asset() external view returns (address) {
        return address(token);
    }

    /// @notice Forwarded view of the strategy's maxWithdraw().
    function maxWithdraw() external view returns (uint256) {
        return strategy.maxWithdraw();
    }

    /// @notice Forwarded per-owner max withdraw: the lesser of the owner's floor-priced claim
    /// and the strategy's reported liquidity. Uses a single `strategy.totalAssets()` read.
    function maxWithdraw(address owner) external view returns (uint256) {
        uint256 totalAssetsBefore = strategy.totalAssets();
        // If the strategy reports zero while shares exist, the vault has no price and owners' claims are zero.
        if (totalSupply > 0 && totalAssetsBefore == 0) return 0;
        uint256 ownerClaim = _convertToAssets(balanceOf[owner], totalAssetsBefore);
        uint256 strategyCap = strategy.maxWithdraw();
        return ownerClaim <= strategyCap ? ownerClaim : strategyCap;
    }

    /// @notice Per-owner max redeem: the largest share count whose floor-priced assets fit
    /// within the owner's withdraw cap. Computed from a single `strategy.totalAssets()` read.
    function maxRedeem(address owner) external view returns (uint256) {
        uint256 totalAssetsBefore = strategy.totalAssets();
        if (totalSupply == 0 || totalAssetsBefore == 0) return 0;
        uint256 ownerClaim = _convertToAssets(balanceOf[owner], totalAssetsBefore);
        uint256 strategyCap = strategy.maxWithdraw();
        uint256 cap = ownerClaim <= strategyCap ? ownerClaim : strategyCap;
        // Solve for shares: floor(shares * totalAssetsBefore / totalSupply) <= cap
        uint256 shares = _mulDivFloor(cap, totalSupply, totalAssetsBefore);
        if (shares > balanceOf[owner]) return balanceOf[owner];
        return shares;
    }

    /// @notice Max deposit allowed by the vault. When the vault has shares but the strategy
    /// reports zero assets (a wiped-out vault) the vault refuses new deposits off-chain.
    function maxDeposit(address) external view returns (uint256) {
        uint256 totalAssetsBefore = strategy.totalAssets();
        if (totalSupply > 0 && totalAssetsBefore == 0) return 0;
        return type(uint256).max;
    }

    /// @notice Max mint allowed by the vault. When the vault has shares but the strategy
    /// reports zero assets (a wiped-out vault) the vault refuses new mints off-chain.
    function maxMint(address) external view returns (uint256) {
        uint256 totalAssetsBefore = strategy.totalAssets();
        if (totalSupply > 0 && totalAssetsBefore == 0) return 0;
        return type(uint256).max;
    }

    /// @notice Preview how many shares a deposit of `amount` would mint (floor).
    function previewDeposit(uint256 amount) external view returns (uint256) {
        return _convertToShares(amount, strategy.totalAssets());
    }

    /// @notice Preview how many assets a mint of `shares` would cost (ceil).
    /// Returns 0 when the vault has shares but the strategy reports zero assets (wiped-out).
    function previewMint(uint256 shares) external view returns (uint256) {
        uint256 totalAssetsBefore = strategy.totalAssets();
        if (totalSupply > 0 && totalAssetsBefore == 0) return 0;
        return _convertToAssetsForMint(shares, totalAssetsBefore);
    }

    /// @notice Preview how many shares would be burned to withdraw `assets` (ceil).
    function previewWithdraw(uint256 assets) external view returns (uint256) {
        uint256 totalAssetsBefore = strategy.totalAssets();
        if (totalSupply == 0 || totalAssetsBefore == 0) return 0;
        return _mulDivCeil(assets, totalSupply, totalAssetsBefore);
    }

    /// @notice Preview how many assets redeeming `shares` would return (floor).
    function previewRedeem(uint256 shares) external view returns (uint256) {
        return _convertToAssets(shares, strategy.totalAssets());
    }

    /// @notice Convert `amount` assets to shares using conservative floor rounding.
    function convertToShares(uint256 amount) external view returns (uint256) {
        return _convertToShares(amount, strategy.totalAssets());
    }

    /// @notice Convert `shares` to assets using floor rounding.
    function convertToAssets(uint256 shares) external view returns (uint256) {
        return _convertToAssets(shares, strategy.totalAssets());
    }

    /// @notice Convenience wrapper: forward a harvest call to the strategy and return the harvested amount.
    /// @dev Marked nonReentrant to avoid nested state-moving vault calls during strategy harvest.
    event Harvest(address indexed caller, uint256 harvested);
    event Panic(address indexed caller);

    function harvest() external nonReentrant returns (uint256) {
        uint256 harvested = strategy.harvest();
        emit Harvest(msg.sender, harvested);
        return harvested;
    }

    /// @notice Convenience wrapper: forward an emergency panic call to the strategy.
    /// @dev Marked nonReentrant to avoid nested state-moving vault calls during strategy panic.
    function panic() external nonReentrant {
        strategy.panic();
        emit Panic(msg.sender);
    }

    // --- Internals ---

    /// @dev Asserts the strategy took custody of everything the vault just pulled in, and
    /// clears any allowance the strategy left behind.
    ///
    /// The check reads the VAULT's own token balance, not `strategy.totalAssets()`, so a
    /// strategy that charges a deposit fee or reports assets in its own way is unaffected:
    /// all that is required is that no underlying is left stranded here. Stranded tokens
    /// would be invisible to `totalAssets()` and unreachable through `withdraw()`, which
    /// measures only its own balance delta.
    function _assertStrategyPulled(uint256 vaultBefore) internal {
        require(tokenBalanceOf(address(this)) == vaultBefore, "MinimalVault: strategy did not pull");
        // A conforming strategy consumes the whole allowance; clear any residue either way.
        if (token.allowance(address(this), address(strategy)) != 0) {
            token.safeApprove(address(strategy), 0);
        }
    }

    /// @dev An EMPTY vault (no shares outstanding) bootstraps 1:1. A WIPED-OUT vault
    /// (shares outstanding, no assets) is a different state entirely and must not be
    /// priced 1:1: doing so mints new money at the same rate as the dead shares and hands
    /// the newcomer's assets straight to them. There is no exchange rate to quote, so the
    /// quote is 0 and `deposit()` / `mint()` refuse the call outright ("no-price").
    function _convertToShares(uint256 amount, uint256 totalAssetsBefore) internal view returns (uint256) {
        if (totalSupply == 0) {
            // Bootstrap: 1:1 initial share for asset to keep it simple and deterministic.
            return amount;
        }
        if (totalAssetsBefore == 0) {
            // Shares outstanding, nothing behind them: no price, and no division by zero.
            return 0;
        }
        return _mulDivFloor(amount, totalSupply, totalAssetsBefore); // floor => conservative
    }

    /// @dev With shares outstanding and no assets this returns 0 - shares backed by
    /// nothing are worth nothing, and the view says so instead of quoting 1:1.
    function _convertToAssets(uint256 shares, uint256 totalAssetsBefore) internal view returns (uint256) {
        if (totalSupply == 0) {
            return shares;
        }
        return _mulDivFloor(shares, totalAssetsBefore, totalSupply); // floor
    }

    function _convertToAssetsForMint(uint256 shares, uint256 totalAssetsBefore) internal view returns (uint256) {
        // When minting, require the caller to send enough assets to cover shares.
        if (totalSupply == 0) {
            return shares;
        }
        // Ceil so we collect enough assets to back the minted shares.
        return _mulDivCeil(shares, totalAssetsBefore, totalSupply);
    }

    function _mulDivFloor(uint256 x, uint256 y, uint256 denominator) internal pure returns (uint256 result) {
        unchecked {
            uint256 prod0;
            uint256 prod1;
            assembly {
                let mm := mulmod(x, y, not(0))
                prod0 := mul(x, y)
                prod1 := sub(sub(mm, prod0), lt(mm, prod0))
            }
            if (prod1 == 0) {
                return prod0 / denominator;
            }
            require(denominator > prod1, "MinimalVault: mulDiv overflow");

            uint256 remainder;
            assembly { remainder := mulmod(x, y, denominator) }
            assembly {
                prod1 := sub(prod1, gt(remainder, prod0))
                prod0 := sub(prod0, remainder)
            }

            uint256 twos = denominator & (~denominator + 1);
            assembly {
                denominator := div(denominator, twos)
                prod0 := div(prod0, twos)
                twos := add(div(sub(0, twos), twos), 1)
            }

            prod0 |= prod1 * twos;

            // Invert denominator mod 2^256
            uint256 inv = (3 * denominator) ^ 2;
            inv *= 2 - denominator * inv; // inverse mod 2^8
            inv *= 2 - denominator * inv; // mod 2^16
            inv *= 2 - denominator * inv; // mod 2^32
            inv *= 2 - denominator * inv; // mod 2^64
            inv *= 2 - denominator * inv; // mod 2^128
            inv *= 2 - denominator * inv; // mod 2^256

            result = prod0 * inv;
            return result;
        }
    }

    function _mulDivCeil(uint256 x, uint256 y, uint256 denominator) internal pure returns (uint256) {
        uint256 floor = _mulDivFloor(x, y, denominator);
        if (mulmod(x, y, denominator) == 0) return floor;
        unchecked {
            return floor + 1;
        }
    }

    function tokenBalanceOf(address who) internal view returns (uint256) {
        return IERC20(token).balanceOf(who);
    }
}
