// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IStrategy} from "../interfaces/IStrategy.sol";
import {SafeERC20, IERC20} from "../utils/SafeERC20.sol";
import {IERC4626} from "../interfaces/IERC4626.sol";
import {IERC20Permit} from "../interfaces/IERC20Permit.sol";

/// @title MinimalVault
/// @notice A small, auditable example vault that demonstrates an ERC-4626-like surface
/// and the exact custody boundary with an IStrategy. It is intentionally minimal: no
/// fees, no pausing, an immutable strategy and a single immutable `guardian` that alone may
/// trigger the strategy's emergency `panic()`. The state-changing entry points are
/// single-entry (`nonReentrant`); the views are not. Uses SafeERC20 for token ops.
///
/// Share pricing uses one virtual share and one virtual asset (the ERC-4626 "decimals
/// offset" scheme with an offset of 0): `shares = assets * (totalSupply + 1) / (totalAssets + 1)`
/// and `assets = shares * (totalAssets + 1) / (totalSupply + 1)`, floored or ceiled so that every
/// rounding step favours the vault. An empty vault (`totalSupply == 0`) still bootstraps 1:1.
/// See `_convertToShares` for why the virtual pair exists.
contract MinimalVault is IERC4626 {
    using SafeERC20 for IERC20;

    IERC20 public immutable token;
    IStrategy public immutable strategy;

    /// @notice The only address allowed to call `panic()`. `IStrategy.panic()` is an emergency
    /// unwind that may realise slippage or loss, and real strategies restrict it; a vault that
    /// forwarded it for anyone would be an open relay around that restriction. Immutable: this
    /// vault has no ownership and no rotation path, by design.
    address public immutable guardian;

    mapping(address => uint256) public balanceOf;
    uint256 public totalSupply;

    /// @dev ERC-20 allowances for vault shares. Spender-approved amounts are consumed by
    /// `transferFrom`; a max (`type(uint256).max`) approval is left untouched, matching the
    /// common infinite-approval convention.
    mapping(address => mapping(address => uint256)) public allowance;

    /// @dev EIP-2612-style permit state for gasless approvals of vault shares.
    /// nonces[owner] increments for every successful permit to prevent signature replay.
    mapping(address => uint256) public nonces;

    /// @dev EIP-712 domain separator inputs and permit typehash for constructing the signed digest.
    /// The separator is cached for the chain the vault was deployed on and rebuilt on any other
    /// chain id (see `DOMAIN_SEPARATOR()`), so a share permit signed before a chain fork cannot be
    /// replayed on the other side of the fork.
    bytes32 private constant _EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant _HASHED_NAME = keccak256("MinimalVault Share");
    bytes32 private constant _HASHED_VERSION = keccak256("1");
    uint256 private immutable _CACHED_CHAIN_ID;
    bytes32 private immutable _CACHED_DOMAIN_SEPARATOR;
    bytes32 public constant PERMIT_TYPEHASH = keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

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

    /// @dev ERC20 Transfer/Approval for shares. The ERC-4626 Deposit and Withdraw events are
    /// inherited from IERC4626; redeclaring them here is a compile error.
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    /// @notice Observational events emitted by the vault when callers ask the strategy to
    /// realise gains or unwind in an emergency. They are purely informational and do not
    /// alter custody or accounting beyond recording who asked for the action.
    event Harvest(address indexed caller, uint256 harvested);
    event Panic(address indexed caller);

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

    /// @dev Restricts a call to the `guardian` set at construction.
    modifier onlyGuardian() {
        require(msg.sender == guardian, "MinimalVault: not guardian");
        _;
    }

    constructor(IERC20 token_, IStrategy strategy_, address guardian_) {
        require(address(token_) != address(0), "MinimalVault: zero-token");
        require(address(strategy_) != address(0), "MinimalVault: zero-strategy");
        require(guardian_ != address(0), "MinimalVault: zero-guardian");
        token = token_;
        strategy = strategy_;
        guardian = guardian_;
        decimals = _readDecimals(token_);

        // EIP-712 domain separator as per EIP-2612: name, version "1", chainId and address.
        // `_HASHED_NAME` must stay keccak256 of `name`; both are constants so the compiler holds
        // them, and the test suite asserts the pair agree.
        _CACHED_CHAIN_ID = block.chainid;
        _CACHED_DOMAIN_SEPARATOR = _buildDomainSeparator(block.chainid);
    }

    /// @notice EIP-712 domain separator for share permits. Cached for the deployment chain and
    /// recomputed for any other `block.chainid`, so a signature is bound to the chain it was
    /// made for even after a fork.
    function DOMAIN_SEPARATOR() public view returns (bytes32) {
        if (block.chainid == _CACHED_CHAIN_ID) {
            return _CACHED_DOMAIN_SEPARATOR;
        }
        return _buildDomainSeparator(block.chainid);
    }

    function _buildDomainSeparator(uint256 chainId) private view returns (bytes32) {
        return keccak256(
            abi.encode(_EIP712_DOMAIN_TYPEHASH, _HASHED_NAME, _HASHED_VERSION, chainId, address(this))
        );
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
    // Slither: deliberate exact comparisons / guarded post-call writes; see SECURITY.md, "Slither triage".
    // slither-disable-next-line incorrect-equality,reentrancy-benign,reentrancy-no-eth
    function deposit(uint256 amount) external nonReentrant returns (uint256 shares) {
        require(amount > 0, "MinimalVault: zero-assets");

        uint256 totalAssetsBefore = strategy.totalAssets();
        require(totalSupply == 0 || totalAssetsBefore > 0, "MinimalVault: no-price");

        // Price the deposit against pre-deposit state, before any token moves.
        shares = _convertToShares(amount, totalAssetsBefore);
        require(shares > 0, "MinimalVault: zero-shares");

        _pullIntoStrategy(amount);
        _mintShares(amount, shares);
        return shares;
    }

    /// @notice Deposit `amount` using EIP-2612 permit (owner signs an approval off-chain).
    /// @dev Applies the permit (see `_tryPermit` for why a failed permit does not revert on its
    /// own) and then follows exactly the same guarded path as `deposit()`.
    // Slither: deliberate exact comparisons / guarded post-call writes; see SECURITY.md, "Slither triage".
    // slither-disable-next-line incorrect-equality,reentrancy-benign,reentrancy-no-eth
    function depositWithPermit(
        uint256 amount,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external nonReentrant returns (uint256 shares) {
        require(amount > 0, "MinimalVault: zero-assets");

        _tryPermit(amount, deadline, v, r, s);

        uint256 totalAssetsBefore = strategy.totalAssets();
        require(totalSupply == 0 || totalAssetsBefore > 0, "MinimalVault: no-price");

        // Price the deposit against pre-deposit state, before any token moves.
        shares = _convertToShares(amount, totalAssetsBefore);
        require(shares > 0, "MinimalVault: zero-shares");

        _pullIntoStrategy(amount);
        _mintShares(amount, shares);
        return shares;
    }

    /// @notice Mint `shares` by supplying the required underlying.
    /// @dev Computes required assets, pulls them, approves the strategy and deposits.
    /// Mirrors the guards in `deposit()`: the vault must be able to price the mint, no
    /// zero-share or zero-asset mint, and the strategy must take custody of everything
    /// this call pulled in.
    // Slither: deliberate exact comparisons / guarded post-call writes; see SECURITY.md, "Slither triage".
    // slither-disable-next-line incorrect-equality,reentrancy-benign,reentrancy-no-eth
    function mint(uint256 shares) external nonReentrant returns (uint256 assets) {
        require(shares > 0, "MinimalVault: zero-shares");

        uint256 totalAssetsBefore = strategy.totalAssets();
        require(totalSupply == 0 || totalAssetsBefore > 0, "MinimalVault: no-price");

        assets = _convertToAssetsForMint(shares, totalAssetsBefore);
        require(assets > 0, "MinimalVault: zero-assets");

        _pullIntoStrategy(assets);
        _mintShares(assets, shares);
        return assets;
    }

    /// @notice Mint `shares` using EIP-2612 permit (owner signs an approval off-chain).
    /// @dev The permit must be signed over exactly the assets `previewMint(shares)` reports at
    /// execution time; a price move between signing and execution leaves the signature for the
    /// wrong value and the mint reverts at `safeTransferFrom` unless an allowance already covers
    /// it. `depositWithPermit` is the robust gasless path. Otherwise identical to `mint()`.
    // Slither: deliberate exact comparisons / guarded post-call writes; see SECURITY.md, "Slither triage".
    // slither-disable-next-line incorrect-equality,reentrancy-benign,reentrancy-no-eth
    function mintWithPermit(
        uint256 shares,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external nonReentrant returns (uint256 assets) {
        require(shares > 0, "MinimalVault: zero-shares");

        // Compute assets required before token moves
        uint256 totalAssetsBefore = strategy.totalAssets();
        require(totalSupply == 0 || totalAssetsBefore > 0, "MinimalVault: no-price");

        assets = _convertToAssetsForMint(shares, totalAssetsBefore);
        require(assets > 0, "MinimalVault: zero-assets");

        _tryPermit(assets, deadline, v, r, s);

        _pullIntoStrategy(assets);
        _mintShares(assets, shares);
        return assets;
    }

    /// @dev Applies an EIP-2612 permit from `msg.sender` to this vault for `value`, and
    /// deliberately tolerates its failure.
    ///
    /// A permit signature is public the moment it is in the mempool. Anyone can submit it to
    /// `token.permit()` directly, which consumes the owner's nonce; the owner's own
    /// `depositWithPermit` / `mintWithPermit` would then revert inside `permit()` with the
    /// allowance already in place, and the griefer could do this to every retry. So the permit's
    /// result is not what gates the deposit: `safeTransferFrom` in `_pullIntoStrategy` is, and it
    /// reverts unless `msg.sender` really has approved this vault for `value` - by this permit, by
    /// the front-run copy of it, or by an ordinary `approve()`. A replayed or expired permit
    /// therefore cannot move anything either: it fails, and without an allowance the pull fails.
    function _tryPermit(uint256 value, uint256 deadline, uint8 v, bytes32 r, bytes32 s) private {
        try IERC20Permit(address(token)).permit(msg.sender, address(this), value, deadline, v, r, s) {} catch {}
    }

    /// @dev Pulls exactly `amount` of the underlying from `msg.sender` and hands it to the
    /// strategy, asserting both halves of the custody rule in `src/interfaces/IStrategy.sol`:
    /// - the vault's balance must rise by exactly `amount` on the pull. A fee-on-transfer asset
    ///   delivers less, and minting shares priced on `amount` against a smaller delivery would
    ///   dilute every other holder, so such assets are refused outright ("fee-on-transfer");
    /// - the strategy must then pull everything the vault received (`_assertStrategyPulled`).
    // Slither: deliberate exact comparisons / guarded post-call writes; see SECURITY.md, "Slither triage".
    // slither-disable-next-line incorrect-equality,reentrancy-balance
    function _pullIntoStrategy(uint256 amount) private {
        uint256 vaultBefore = tokenBalanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), amount);
        require(tokenBalanceOf(address(this)) == vaultBefore + amount, "MinimalVault: fee-on-transfer");

        // Approve strategy for exactly amount and let it pull
        token.safeApprove(address(strategy), amount);
        strategy.deposit(amount);
        _assertStrategyPulled(vaultBefore);
    }

    /// @dev Credits `shares` to `msg.sender` for `assets` already in the strategy's custody and
    /// emits the ERC-4626 Deposit and ERC-20 Transfer (mint) logs.
    function _mintShares(uint256 assets, uint256 shares) private {
        totalSupply += shares;
        balanceOf[msg.sender] += shares;
        emit Deposit(msg.sender, msg.sender, assets, shares);
        emit Transfer(address(0), msg.sender, shares);
    }

    /// @notice Withdraw up to `assets` by burning proportional shares from caller.
    /// @dev Calls strategy.withdraw(assets) and burns shares proportional to the
    /// actual amount returned (ceil), then forwards tokens to caller.
    ///
    /// Single-entry (`nonReentrant`): shares are burned AFTER `strategy.withdraw()` returns, so
    /// a callback fired while the assets are in transit would see a low `totalAssets()` against
    /// an unchanged `totalSupply` and mint against it.
    // Slither: deliberate exact comparisons / guarded post-call writes; see SECURITY.md, "Slither triage".
    // slither-disable-next-line incorrect-equality,reentrancy-balance,reentrancy-no-eth,reentrancy-benign
    function withdraw(uint256 assets) external nonReentrant returns (uint256 withdrawn) {
        uint256 totalAssetsBefore = strategy.totalAssets();
        require(totalAssetsBefore > 0 && totalSupply > 0, "no-liquidity");

        uint256 before = tokenBalanceOf(address(this));
        uint256 got = strategy.withdraw(assets);
        uint256 balanceAfter = tokenBalanceOf(address(this));
        withdrawn = balanceAfter - before;
        require(got == withdrawn, "MinimalVault: strategy returned mismatch");
        require(withdrawn <= assets, "MinimalVault: strategy overpaid");

        // Burn shares proportional to withdrawn amount (ceil, virtual pair included)
        uint256 sharesToBurn = _convertToSharesCeil(withdrawn, totalAssetsBefore);
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
    // Slither: deliberate exact comparisons / guarded post-call writes; see SECURITY.md, "Slither triage".
    // slither-disable-next-line incorrect-equality,reentrancy-balance,reentrancy-no-eth
    function redeem(uint256 shares) external nonReentrant returns (uint256 withdrawn) {
        require(shares > 0, "MinimalVault: zero-shares");
        require(balanceOf[msg.sender] >= shares, "insufficient shares");

        uint256 totalAssetsBefore = strategy.totalAssets();
        uint256 totalSupplyBefore = totalSupply;
        require(totalSupplyBefore > 0 && totalAssetsBefore > 0, "no-liquidity");

        // FLOOR: never ask the strategy for more than the shares are worth.
        uint256 assetsRequested = _convertToAssets(shares, totalAssetsBefore);
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
            sharesToBurn = _convertToSharesCeil(withdrawn, totalAssetsBefore);
            // withdrawn < floor(shares * (totalAssets + 1) / (totalSupply + 1)) makes this at
            // most `shares`; the old cap is an assertion now, not a discount.
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

    /// @notice EIP-2612 style permit for gasless approvals of vault shares.
    /// @dev Verifies an EIP-712 signature and sets allowance[owner][spender] = value.
    function permit(
        address owner,
        address spender,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external {
        require(block.timestamp <= deadline, "MinimalVault: permit expired");

        uint256 ownerNonce = nonces[owner];
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                DOMAIN_SEPARATOR(),
                keccak256(abi.encode(PERMIT_TYPEHASH, owner, spender, value, ownerNonce, deadline))
            )
        );

        address recovered = ecrecover(digest, v, r, s);
        require(recovered != address(0) && recovered == owner, "MinimalVault: invalid permit");

        // consume the nonce
        nonces[owner] = ownerNonce + 1;

        allowance[owner][spender] = value;
        emit Approval(owner, spender, value);
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

    /// @notice Price per share, scaled to 1e18 for a fixed-decimal UI-friendly value.
    /// @dev When the vault is empty (totalSupply == 0) we return 1e18 (bootstrap = 1).
    /// Otherwise return floor(strategy.totalAssets() * 1e18 / totalSupply).
    // Slither: deliberate exact comparisons / guarded post-call writes; see SECURITY.md, "Slither triage".
    // slither-disable-next-line incorrect-equality
    function pricePerShare() external view returns (uint256) {
        if (totalSupply == 0) return 1e18;
        return _mulDivFloor(strategy.totalAssets(), 1e18, totalSupply);
    }

    /// @notice ERC-4626 asset() view: the underlying token address.
    /// @dev Additive, read-only: returns the vault's configured asset token.
    function asset() external view returns (address) {
        return address(token);
    }

    /// @notice Forwarded view of the strategy's maxWithdraw().
    /// @dev Defensive: cap what the strategy reports to the strategy.totalAssets() value so
    ///      frontends do not see an advertised liquidity larger than the strategy actually holds.
    function maxWithdraw() external view returns (uint256) {
        uint256 totalAssetsBefore = strategy.totalAssets();
        uint256 strategyCap = strategy.maxWithdraw();
        if (strategyCap > totalAssetsBefore) strategyCap = totalAssetsBefore;
        return strategyCap;
    }

    /// @notice Forwarded per-owner max withdraw: the lesser of the owner's floor-priced claim
    /// and the strategy's reported liquidity. Uses a single `strategy.totalAssets()` read.
    function maxWithdraw(address owner) external view returns (uint256) {
        uint256 totalAssetsBefore = strategy.totalAssets();
        // If the strategy reports zero while shares exist, the vault has no price and owners' claims are zero.
        if (totalSupply > 0 && totalAssetsBefore == 0) return 0;
        uint256 ownerClaim = _convertToAssets(balanceOf[owner], totalAssetsBefore);
        uint256 strategyCap = strategy.maxWithdraw();
        if (strategyCap > totalAssetsBefore) strategyCap = totalAssetsBefore;
        return ownerClaim <= strategyCap ? ownerClaim : strategyCap;
    }

    /// @notice Per-owner max redeem: the LARGEST share count `redeem()` would serve in full right
    /// now - the owner's balance, or fewer when the strategy's liquidity binds. Computed from a
    /// single `strategy.totalAssets()` read.
    /// @dev `redeem(s)` asks the strategy for `floor(s * (A + 1) / (S + 1))`, so the answer is the
    /// largest `s` with that floor `<= cap`, i.e. `ceil((cap + 1) * (S + 1) / (A + 1)) - 1`. The
    /// earlier `floor(cap * S / A)` under-reported: with 3 shares over 10 assets a holder of one
    /// share was told 0 although `redeem(1)` pays out. A cap of 0 answers 0 outright, since any
    /// share count the formula allowed would floor to a zero-asset request `redeem()` refuses.
    // Slither: deliberate exact comparisons / guarded post-call writes; see SECURITY.md, "Slither triage".
    // slither-disable-next-line incorrect-equality
    function maxRedeem(address owner) external view returns (uint256) {
        uint256 totalAssetsBefore = strategy.totalAssets();
        if (totalSupply == 0 || totalAssetsBefore == 0) return 0;
        uint256 ownerClaim = _convertToAssets(balanceOf[owner], totalAssetsBefore);
        uint256 strategyCap = strategy.maxWithdraw();
        if (strategyCap > totalAssetsBefore) strategyCap = totalAssetsBefore;
        uint256 cap = ownerClaim <= strategyCap ? ownerClaim : strategyCap;
        if (cap == 0) return 0;
        uint256 shares = _mulDivCeil(cap + 1, totalSupply + 1, totalAssetsBefore + 1) - 1;
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
    // Slither: deliberate exact comparisons / guarded post-call writes; see SECURITY.md, "Slither triage".
    // slither-disable-next-line incorrect-equality
    function previewWithdraw(uint256 assets) external view returns (uint256) {
        uint256 totalAssetsBefore = strategy.totalAssets();
        if (totalSupply == 0 || totalAssetsBefore == 0) return 0;
        return _convertToSharesCeil(assets, totalAssetsBefore);
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
    function harvest() external nonReentrant returns (uint256) {
        uint256 harvested = strategy.harvest();
        emit Harvest(msg.sender, harvested);
        return harvested;
    }

    /// @notice Emergency wrapper: forward a panic call to the strategy. Guardian only.
    /// @dev `IStrategy.panic()` unwinds positions "accepting that some slippage or loss may
    /// occur", and real strategies restrict it. An unrestricted wrapper would let anyone force
    /// that loss on every holder at will, and would relay around a strategy that only trusts the
    /// vault's address. Marked nonReentrant to avoid nested state-moving vault calls during the
    /// unwind. `harvest()` stays permissionless: the interface lets it realise gains only, and
    /// keeps the assets in custody.
    function panic() external nonReentrant onlyGuardian {
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
    // Slither: deliberate exact comparisons / guarded post-call writes; see SECURITY.md, "Slither triage".
    // slither-disable-next-line incorrect-equality
    function _assertStrategyPulled(uint256 vaultBefore) internal {
        require(tokenBalanceOf(address(this)) == vaultBefore, "MinimalVault: strategy did not pull");
        // A conforming strategy consumes the whole allowance; clear any residue either way.
        if (token.allowance(address(this), address(strategy)) != 0) {
            token.safeApprove(address(strategy), 0);
        }
    }

    /// @dev Shares for `amount` assets, FLOOR, priced with one virtual share and one virtual
    /// asset: `amount * (totalSupply + 1) / (totalAssetsBefore + 1)`.
    ///
    /// Why the virtual pair: with plain proportional pricing the zero-share guard in `deposit()`
    /// only stops the TOTAL loss of the first-depositor inflation attack, not the attack. An
    /// attacker deposits 1 wei (1 share), donates D straight to the strategy, and a victim who
    /// then deposits 2D + 1 is floored to a single share worth 1.5D: the attacker's share is now
    /// worth 1.5D as well, a profit of 0.5D taken from the victim. With the virtual pair the vault
    /// itself holds one share of the pot, so the shares an inflated price mints go partly to that
    /// unredeemable share rather than to the attacker: in the same scenario the victim gets 3
    /// shares, the attacker's share is worth 0.6D and the attacker LOSES 0.4D. The attack is
    /// never profitable; the residual griefing (an attacker can still make a victim lose, at a
    /// cost at least as large to themselves) is documented in SECURITY.md. This is the ERC-4626
    /// "decimals offset" scheme with an offset of 0, so an EMPTY vault still bootstraps 1:1.
    ///
    /// A WIPED-OUT vault (shares outstanding, no assets) is a different state entirely and must
    /// not be priced: doing so mints new money alongside dead shares and hands part of the
    /// newcomer's assets to them. There is no exchange rate to quote, so the quote is 0 and
    /// `deposit()` / `mint()` refuse the call outright ("no-price").
    // Slither: deliberate exact comparisons / guarded post-call writes; see SECURITY.md, "Slither triage".
    // slither-disable-next-line incorrect-equality
    function _convertToShares(uint256 amount, uint256 totalAssetsBefore) internal view returns (uint256) {
        uint256 supply = totalSupply;
        if (supply == 0) {
            // Bootstrap: 1:1 initial share for asset to keep it simple and deterministic.
            return amount;
        }
        if (totalAssetsBefore == 0) {
            // Shares outstanding, nothing behind them: no price.
            return 0;
        }
        return _mulDivFloor(amount, supply + 1, totalAssetsBefore + 1); // floor => conservative
    }

    /// @dev Shares for `assets`, CEIL - the shares `withdraw()` burns for a payout, and what
    /// `previewWithdraw` quotes. Callers guarantee `totalSupply > 0`.
    function _convertToSharesCeil(uint256 assets, uint256 totalAssetsBefore) internal view returns (uint256) {
        return _mulDivCeil(assets, totalSupply + 1, totalAssetsBefore + 1);
    }

    /// @dev Assets for `shares`, FLOOR: `shares * (totalAssetsBefore + 1) / (totalSupply + 1)`.
    /// With shares outstanding and no assets this returns 0 - shares backed by nothing are
    /// worth nothing, and the view says so instead of quoting 1:1.
    // Slither: deliberate exact comparisons / guarded post-call writes; see SECURITY.md, "Slither triage".
    // slither-disable-next-line incorrect-equality
    function _convertToAssets(uint256 shares, uint256 totalAssetsBefore) internal view returns (uint256) {
        uint256 supply = totalSupply;
        if (supply == 0) {
            return shares;
        }
        if (totalAssetsBefore == 0) {
            return 0;
        }
        return _mulDivFloor(shares, totalAssetsBefore + 1, supply + 1); // floor
    }

    /// @dev Assets a mint of `shares` must collect, CEIL, so the minted shares are fully backed.
    // Slither: deliberate exact comparisons / guarded post-call writes; see SECURITY.md, "Slither triage".
    // slither-disable-next-line incorrect-equality
    function _convertToAssetsForMint(uint256 shares, uint256 totalAssetsBefore) internal view returns (uint256) {
        uint256 supply = totalSupply;
        if (supply == 0) {
            return shares;
        }
        return _mulDivCeil(shares, totalAssetsBefore + 1, supply + 1);
    }

    // Slither: deliberate exact comparisons / guarded post-call writes; see SECURITY.md, "Slither triage".
    // slither-disable-next-line incorrect-equality,incorrect-exp,divide-before-multiply
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

    // Slither: deliberate exact comparisons / guarded post-call writes; see SECURITY.md, "Slither triage".
    // slither-disable-next-line incorrect-equality
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
