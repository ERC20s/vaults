// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {MinimalVault} from "../../src/vault/MinimalVault.sol";
import {IStrategy} from "../../src/interfaces/IStrategy.sol";
import {IERC20} from "../../src/utils/SafeERC20.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockStrategy} from "../mocks/MockStrategy.sol";

/// @title VaultActor
/// @notice One share holder. Exists because `MinimalVault` credits `msg.sender`, and this suite
/// uses no cheatcodes: without a set of separate callers every share in the vault would belong to
/// the handler and "shares are fully attributed" would be a tautology.
/// @dev Only its owning `VaultHandler` may drive it, so the invariant fuzzer cannot reach the vault
/// through an actor and mint shares outside the handler's ledger.
contract VaultActor {
    address public immutable owner;
    MinimalVault public immutable vault;
    MockERC20 public immutable token;

    constructor(MinimalVault vault_, MockERC20 token_) {
        owner = msg.sender;
        vault = vault_;
        token = token_;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "VaultActor: only the handler");
        _;
    }

    /// @dev Approves exactly `amount`, the way a front end would, and lets the vault pull.
    function deposit(uint256 amount) external onlyOwner returns (uint256 shares) {
        token.approve(address(vault), amount);
        return vault.deposit(amount);
    }

    /// @dev `maxAssets` is what the handler pre-funded and approved for this mint.
    function mint(uint256 shares, uint256 maxAssets) external onlyOwner returns (uint256 assets) {
        token.approve(address(vault), maxAssets);
        return vault.mint(shares);
    }

    function withdraw(uint256 assets) external onlyOwner returns (uint256 withdrawn) {
        return vault.withdraw(assets);
    }

    function redeem(uint256 shares) external onlyOwner returns (uint256 withdrawn) {
        return vault.redeem(shares);
    }
}

/// @title VaultHandler
/// @notice The only actor the stateful vault suite lets loose on `src/vault/MinimalVault.sol`.
/// @dev Foundry's invariant runner calls the public functions of this contract in long random
/// sequences. It is the vault-side twin of `test/handlers/StrategyHandler.sol` and follows the same
/// three rules:
/// - every action BOUNDS its argument, so a run is a plausible sequence of vault-sized operations
///   rather than a wall of reverts on `uint256.max`;
/// - every action checks its OWN post-condition before it returns - the per-call half of the
///   guards merged into the vault (zero-share, no-price, strategy-pulled, floor-priced redeem);
/// - post-conditions are RECORDED, not reverted. `_check` bumps `failureCount` and stores the
///   reason, because a revert would be rolled back by the fuzzer and, under
///   `fail_on_revert = false`, silently swallowed. `invariant_HandlerPostconditionsHold` in
///   `test/MinimalVaultInvariants.t.sol` asserts on the counter, so nothing is hidden.
///
/// Vault calls are wrapped in `try/catch` and a revert is generally NOT a failure here: the vault is
/// allowed - required, even - to refuse a zero-share deposit, a deposit into a wiped-out vault
/// ("no-price") or a redemption it cannot price. What is recorded is a call that SUCCEEDED where the
/// merged guards say it must not have, or one that succeeded on the wrong terms.
///
/// Dependency-free on purpose, like the rest of the suite: no `forge-std`, no cheatcodes, no
/// submodule. The handler mints its own funds through the test token, so no action depends on a
/// fixture a previous action may have drained.
///
/// The reentrancy guard merged in cycle 8 is asserted indirectly: `_locked` is private, so the suite
/// cannot read it. What it can prove is that the flag is always released - a sequence in which the
/// vault stayed latched would show up as every later deposit, mint, withdraw and redeem reverting,
/// and the ledger totals below would stop moving.
contract VaultHandler {
    /// @notice Upper bound for a single action, in underlying token units.
    /// @dev Large enough for realistic vault flows, small enough that a long sequence of deposits
    /// and injected yield can never overflow the token's `totalSupply` or the cross-multiplied
    /// share-price comparison (assets * supply stays far below 2**256).
    uint256 public constant MAX_ACTION = 1_000_000e18;

    /// @notice How many independent share holders the suite models.
    uint256 public constant ACTOR_COUNT = 3;

    MockERC20 public immutable token;
    MockStrategy public immutable strategy;
    MinimalVault public immutable vault;

    VaultActor[] public actors;

    // --- ghost totals -----------------------------------------------------------------

    /// @notice Underlying that entered the vault through `deposit()` / `mint()`.
    uint256 public assetsIn;
    /// @notice Underlying that left the vault through `withdraw()` / `redeem()`.
    uint256 public assetsOut;
    /// @notice Tokens minted straight into the strategy to model an external yield source.
    uint256 public yieldInjected;
    /// @notice Sum of the gains `harvest()` has reported.
    uint256 public harvested;
    /// @notice Every token this handler has ever minted, wherever it went.
    uint256 public mintedTotal;

    // --- share-price snapshot ----------------------------------------------------------

    /// @notice `strategy.totalAssets()` as it stood when the most recent action STARTED.
    uint256 public prevAssets;
    /// @notice `vault.totalSupply()` as it stood when the most recent action STARTED.
    uint256 public prevSupply;

    // --- recorded post-condition failures ----------------------------------------------

    uint256 public failureCount;
    string public lastFailure;

    // --- call counters (visible in the invariant run summary) ---------------------------

    uint256 public depositCalls;
    uint256 public mintCalls;
    uint256 public withdrawCalls;
    uint256 public redeemCalls;
    uint256 public harvestCalls;
    uint256 public setIlliquidCalls;
    uint256 public injectYieldCalls;

    constructor() {
        MockERC20 token_ = new MockERC20();
        MockStrategy strategy_ = new MockStrategy(token_);
        MinimalVault vault_ = new MinimalVault(IERC20(address(token_)), IStrategy(address(strategy_)));

        token = token_;
        strategy = strategy_;
        vault = vault_;

        for (uint256 i = 0; i < ACTOR_COUNT; i++) {
            actors.push(new VaultActor(vault_, token_));
        }
    }

    // --- actions ------------------------------------------------------------------------

    /// @notice Funds an actor and deposits. Mirrors a user hitting "deposit" with `amount`.
    function deposit(uint256 actorSeed, uint256 amount) external {
        depositCalls++;
        VaultActor actor = _actor(actorSeed);
        amount = _bound(amount, 0, MAX_ACTION);

        (uint256 assetsBefore, uint256 supplyBefore) = _snapshot();

        token.mint(address(actor), amount);
        mintedTotal += amount;
        uint256 actorBefore = token.balanceOf(address(actor));

        try actor.deposit(amount) returns (uint256 shares) {
            _check(shares > 0, "deposit() minted zero shares");
            _check(
                !(supplyBefore > 0 && assetsBefore == 0),
                "deposit() priced a vault with shares and no assets instead of reverting no-price"
            );
            _check(
                token.balanceOf(address(actor)) + amount == actorBefore,
                "deposit() did not take exactly `amount` from the depositor"
            );
            if (supplyBefore > 0) {
                _check(
                    shares * assetsBefore <= amount * supplyBefore,
                    "deposit() minted more shares than the pre-deposit price allows"
                );
            }
            _check(
                token.balanceOf(address(vault)) == 0,
                "deposit() left underlying stranded in the vault"
            );
            assetsIn += amount;
        } catch {
            // A refusal is legitimate here (zero assets, "no-price", a share amount that rounds
            // down to zero under an inflated price). Nothing moved, so there is nothing to record.
        }

        _checkSharePrice(assetsBefore, supplyBefore, "deposit() lowered the price of a share");
    }

    /// @notice Pre-funds an actor with exactly the previewed assets and mints `shares`.
    function mint(uint256 actorSeed, uint256 shares) external {
        mintCalls++;
        VaultActor actor = _actor(actorSeed);
        shares = _bound(shares, 0, MAX_ACTION);

        (uint256 assetsBefore, uint256 supplyBefore) = _snapshot();

        uint256 needed = _previewMint(shares, assetsBefore, supplyBefore);
        // Cross-check: the handler's mirror must match the vault's own preview.
        uint256 vaultNeeded = vault.previewMint(shares);
        _check(needed == vaultNeeded, "_previewMint desynchronised from vault.previewMint");
        // Out of this fixture's range: skip rather than mint an implausible pile of tokens.
        if (needed == 0 || needed > MAX_ACTION) return;

        token.mint(address(actor), needed);
        mintedTotal += needed;
        uint256 actorBefore = token.balanceOf(address(actor));
        uint256 sharesBefore = vault.balanceOf(address(actor));

        try actor.mint(shares, needed) returns (uint256 assets) {
            _check(assets == needed, "mint() charged something other than the previewed assets");
            _check(
                !(supplyBefore > 0 && assetsBefore == 0),
                "mint() priced a vault with shares and no assets instead of reverting no-price"
            );
            _check(
                token.balanceOf(address(actor)) + assets == actorBefore,
                "mint() did not take exactly the previewed assets from the minter"
            );
            _check(
                vault.balanceOf(address(actor)) == sharesBefore + shares,
                "mint() credited something other than the shares asked for"
            );
            if (supplyBefore > 0) {
                _check(
                    assets * supplyBefore >= shares * assetsBefore,
                    "mint() collected less than the shares it minted are worth"
                );
            }
            _check(token.balanceOf(address(vault)) == 0, "mint() left underlying stranded in the vault");
            assetsIn += assets;
        } catch {
            // Same as deposit(): refusing is a valid outcome.
        }

        _checkSharePrice(assetsBefore, supplyBefore, "mint() lowered the price of a share");
    }

    /// @notice Asks the vault for assets, bounded by what the actor's shares are actually worth.
    function withdraw(uint256 actorSeed, uint256 assets) external {
        withdrawCalls++;
        VaultActor actor = _actor(actorSeed);

        (uint256 assetsBefore, uint256 supplyBefore) = _snapshot();

        uint256 sharesBefore = vault.balanceOf(address(actor));
        // Ceiling = what those shares are worth at the current price. Asking for more would burn
        // shares the actor does not hold, which the vault refuses anyway ("insufficient shares").
        uint256 ceiling = _previewRedeem(sharesBefore, assetsBefore, supplyBefore);
        if (ceiling == 0) return;
        assets = _bound(assets, 0, ceiling);

        uint256 actorBefore = token.balanceOf(address(actor));

        try actor.withdraw(assets) returns (uint256 withdrawn) {
            uint256 delta = token.balanceOf(address(actor)) - actorBefore;
            uint256 burned = sharesBefore - vault.balanceOf(address(actor));

            _check(withdrawn == delta, "withdraw() return value is not the caller's balance delta");
            _check(withdrawn <= assets, "withdraw() paid out more than was requested");
            _check(
                burned * assetsBefore >= withdrawn * supplyBefore,
                "withdraw() burned fewer shares than the payout was worth"
            );
            _check(
                token.balanceOf(address(vault)) == 0,
                "withdraw() left underlying stranded in the vault"
            );
            assetsOut += withdrawn;
        } catch {
            // "no-liquidity" and a locked position are legitimate refusals.
        }

        _checkSharePrice(assetsBefore, supplyBefore, "withdraw() lowered the price of a share");
    }

    /// @notice Burns shares the actor really holds and takes whatever the strategy can serve.
    function redeem(uint256 actorSeed, uint256 shares) external {
        redeemCalls++;
        VaultActor actor = _actor(actorSeed);

        (uint256 assetsBefore, uint256 supplyBefore) = _snapshot();

        uint256 sharesBefore = vault.balanceOf(address(actor));
        if (sharesBefore == 0) return;
        shares = _bound(shares, 0, sharesBefore);

        uint256 actorBefore = token.balanceOf(address(actor));

        try actor.redeem(shares) returns (uint256 withdrawn) {
            uint256 delta = token.balanceOf(address(actor)) - actorBefore;
            uint256 burned = sharesBefore - vault.balanceOf(address(actor));

            _check(withdrawn == delta, "redeem() return value is not the caller's balance delta");
            _check(burned <= shares, "redeem() burned more shares than were offered");
            // The floor-priced redeem merged in cycle 6: a redemption can never be paid more than
            // the shares it offers are worth at the pre-redeem price.
            _check(
                withdrawn * supplyBefore <= shares * assetsBefore,
                "redeem() paid out more than the burned shares were worth"
            );
            _check(token.balanceOf(address(vault)) == 0, "redeem() left underlying stranded in the vault");
            assetsOut += withdrawn;
        } catch {
            // "no-liquidity" / a request that floors to zero assets are legitimate refusals.
        }

        _checkSharePrice(assetsBefore, supplyBefore, "redeem() lowered the price of a share");
    }

    /// @notice Realises gains in the strategy. No token may move and no share may be created.
    function harvest() external {
        harvestCalls++;
        (uint256 assetsBefore, uint256 supplyBefore) = _snapshot();

        try strategy.harvest() returns (uint256 gain) {
            harvested += gain;
            _check(strategy.totalAssets() == assetsBefore, "harvest() moved assets out of custody");
            _check(vault.totalSupply() == supplyBefore, "harvest() changed the vault's share supply");
        } catch {
            _check(false, "harvest() reverted");
        }

        _checkSharePrice(assetsBefore, supplyBefore, "harvest() lowered the price of a share");
    }

    /// @notice Locks part of the position, as an epoch or a lockup would. Bounded ABOVE the
    /// position on purpose, so an over-locked strategy is exercised too.
    function setIlliquid(uint256 amount) external {
        setIlliquidCalls++;
        (uint256 assetsBefore, uint256 supplyBefore) = _snapshot();

        strategy.setIlliquid(_bound(amount, 0, assetsBefore + MAX_ACTION));

        _check(
            strategy.maxWithdraw() <= strategy.totalAssets(),
            "maxWithdraw() exceeded totalAssets() after the position was locked"
        );
        _checkSharePrice(assetsBefore, supplyBefore, "setIlliquid() lowered the price of a share");
    }

    /// @notice Simulates an external yield source paying the strategy directly - the same model
    /// `StrategyHandler.simulateYield` uses, and the only way the share price ever rises.
    function injectYield(uint256 amount) external {
        injectYieldCalls++;
        amount = _bound(amount, 0, MAX_ACTION);

        (uint256 assetsBefore, uint256 supplyBefore) = _snapshot();

        token.mint(address(strategy), amount);
        mintedTotal += amount;
        yieldInjected += amount;

        _check(
            strategy.totalAssets() == assetsBefore + amount,
            "injected yield did not reach the strategy's custody"
        );
        _checkSharePrice(assetsBefore, supplyBefore, "injected yield lowered the price of a share");
    }

    // --- views the invariants read ------------------------------------------------------

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    /// @notice Shares held by the modelled holders. Must equal `vault.totalSupply()`.
    function totalActorShares() external view returns (uint256 total) {
        for (uint256 i = 0; i < actors.length; i++) {
            total += vault.balanceOf(address(actors[i]));
        }
    }

    /// @notice Underlying sitting in the holders' own hands (deposited funds excluded).
    function totalActorTokens() external view returns (uint256 total) {
        for (uint256 i = 0; i < actors.length; i++) {
            total += token.balanceOf(address(actors[i]));
        }
    }

    // --- internals -----------------------------------------------------------------------

    function _actor(uint256 seed) internal view returns (VaultActor) {
        return actors[seed % actors.length];
    }

    /// @dev Reads the (assets, supply) pair the vault prices against and stores it, so
    /// `invariant_SharePriceNeverFalls` can compare the state AFTER an action with the state
    /// BEFORE it - the one comparison an invariant function, which may not write state, cannot
    /// make on its own.
    function _snapshot() internal returns (uint256 assetsBefore, uint256 supplyBefore) {
        assetsBefore = strategy.totalAssets();
        supplyBefore = vault.totalSupply();
        prevAssets = assetsBefore;
        prevSupply = supplyBefore;
    }

    /// @dev assets-per-share never falls, compared CROSS-MULTIPLIED so there is no division and no
    /// dust tolerance: `assetsAfter / supplyAfter >= assetsBefore / supplyBefore`.
    /// Skipped when either side has no shares outstanding: an empty vault has no price at all, and
    /// the 1:1 bootstrap of the first deposit into a vault that already holds donated assets is a
    /// price change from nothing, not a fall.
    function _checkSharePrice(uint256 assetsBefore, uint256 supplyBefore, string memory reason) internal {
        uint256 supplyAfter = vault.totalSupply();
        if (supplyBefore == 0 || supplyAfter == 0) return;
        _check(strategy.totalAssets() * supplyBefore >= assetsBefore * supplyAfter, reason);
    }

    /// @dev Mirrors `MinimalVault._convertToAssetsForMint` (ceil), so the handler can pre-fund the
    /// actor with exactly what the vault will ask for.
    function _previewMint(uint256 shares, uint256 assetsBefore, uint256 supplyBefore)
        internal
        pure
        returns (uint256)
    {
        if (shares == 0) return 0;
        if (supplyBefore == 0) return shares;
        return (shares * assetsBefore + supplyBefore - 1) / supplyBefore;
    }

    /// @dev Mirrors the FLOOR pricing of `MinimalVault.redeem`.
    function _previewRedeem(uint256 shares, uint256 assetsBefore, uint256 supplyBefore)
        internal
        pure
        returns (uint256)
    {
        if (shares == 0 || supplyBefore == 0) return 0;
        return (shares * assetsBefore) / supplyBefore;
    }

    /// @dev Mirrors `MinimalVault._convertToShares` (floor) for deposit previews.
    function _previewDeposit(uint256 amount, uint256 assetsBefore, uint256 supplyBefore)
        internal
        pure
        returns (uint256)
    {
        if (supplyBefore == 0) return amount;
        if (assetsBefore == 0) return 0;
        return (amount * supplyBefore) / assetsBefore;
    }

    /// @dev Mirrors the ceiling share burn computed by `MinimalVault.withdraw`.
    function _previewWithdraw(uint256 assets, uint256 assetsBefore, uint256 supplyBefore)
        internal
        pure
        returns (uint256)
    {
        if (supplyBefore == 0 || assetsBefore == 0) return 0;
        return (assets * supplyBefore + assetsBefore - 1) / assetsBefore;
    }

    /// @dev Records a broken post-condition instead of reverting. See the contract doc.
    function _check(bool ok, string memory reason) internal {
        if (!ok) {
            failureCount++;
            lastFailure = reason;
        }
    }

    /// @dev Plain modulo bounding - no `forge-std` `bound`, no cheatcodes. `min` is 0 everywhere,
    /// so any value already inside the range is passed through unchanged and a hand-driven
    /// sequence (the deterministic test) means exactly what it says.
    function _bound(uint256 x, uint256 min, uint256 max) internal pure returns (uint256) {
        if (max <= min) return min;
        return min + (x % (max - min + 1));
    }
}
