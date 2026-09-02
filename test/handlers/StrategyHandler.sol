// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {MockERC20} from "../mocks/MockERC20.sol";
import {MockStrategy} from "../mocks/MockStrategy.sol";

/// @title StrategyHandler
/// @notice The only actor the stateful invariant suite lets loose on an `IStrategy`.
/// @dev Foundry's invariant runner calls the public functions of this contract in long random
/// sequences. Every action here:
/// - bounds its argument, so a run is a plausible sequence of vault-sized operations rather than a
///   wall of reverts on `uint256.max`;
/// - checks its OWN post-condition (the per-call half of the custody rule in
///   `src/interfaces/IStrategy.sol`) before it returns;
/// - updates the ghost totals (`pulled`, `pushed`, `harvested`, `yieldInjected`, `mintedTotal`)
///   that `test/IStrategyInvariants.t.sol` asserts over after the whole sequence.
///
/// Post-conditions are RECORDED, not reverted: `_check` bumps `failureCount` and stores the reason
/// instead of calling `require`. A revert would be rolled back by the fuzzer and, under
/// `fail_on_revert = false`, silently swallowed - the failure would never reach the group. Recording
/// it makes `invariant_HandlerPostconditionsHold` fail loudly with the reason attached. For the same
/// reason every strategy call is wrapped in `try/catch`: a strategy that reverts where the interface
/// promises it must not is recorded as a failure instead of vanishing into the fuzzer's revert count.
///
/// Dependency-free on purpose, like `test/IStrategyConformance.t.sol`: no `forge-std`, no
/// cheatcodes, no submodule. The handler mints its own funds through the test token, so no action
/// depends on a fixture that a previous action may have drained.
contract StrategyHandler {
    /// @notice Upper bound for a single action, in underlying token units.
    /// @dev Large enough to cover realistic vault flows, small enough that a long sequence of
    /// deposits and simulated yield can never overflow the token's `totalSupply`.
    uint256 public constant MAX_ACTION = 1_000_000e18;

    MockERC20 public immutable token;
    MockStrategy public immutable strategy;

    // --- ghost totals ---------------------------------------------------------------

    /// @notice Everything this handler has deposited into the strategy.
    uint256 public pulled;
    /// @notice Everything `withdraw()` has actually pushed back to this handler.
    uint256 public pushed;
    /// @notice Sum of the gains `harvest()` has reported.
    uint256 public harvested;
    /// @notice Tokens minted straight into the strategy to simulate an external yield source.
    uint256 public yieldInjected;
    /// @notice Every token this handler has ever minted, wherever it went.
    uint256 public mintedTotal;

    // --- recorded post-condition failures --------------------------------------------

    uint256 public failureCount;
    string public lastFailure;

    // --- call counters (visible in the invariant run summary) --------------------------

    uint256 public depositCalls;
    uint256 public withdrawCalls;
    uint256 public harvestCalls;
    uint256 public setIlliquidCalls;
    uint256 public panicCalls;
    uint256 public simulateYieldCalls;

    constructor() {
        MockERC20 token_ = new MockERC20();
        token = token_;
        strategy = new MockStrategy(token_);
    }

    // --- actions ----------------------------------------------------------------------

    /// @notice Mints `amount`, approves it and deposits it. PULL side of the custody rule.
    function deposit(uint256 amount) external {
        depositCalls++;
        amount = _bound(amount, 0, MAX_ACTION);

        token.mint(address(this), amount);
        mintedTotal += amount;
        token.approve(address(strategy), amount);

        uint256 callerBefore = token.balanceOf(address(this));
        uint256 custodyBefore = strategy.totalAssets();

        try strategy.deposit(amount) {
            _check(
                token.balanceOf(address(this)) + amount == callerBefore,
                "deposit() did not take exactly `amount` from the caller"
            );
            _check(
                strategy.totalAssets() == custodyBefore + amount,
                "deposit() did not raise strategy custody by exactly the pulled amount"
            );
            _check(
                token.allowance(address(this), address(strategy)) == 0,
                "deposit() left allowance behind: it pulled less than it credited"
            );
            pulled += amount;
        } catch {
            _check(false, "deposit() reverted although the caller approved exactly `amount`");
        }
    }

    /// @notice Asks for `amount` back. PUSH side of the custody rule.
    /// @dev The bound is deliberately wider than the position so over-asking is exercised too.
    function withdraw(uint256 amount) external {
        withdrawCalls++;
        amount = _bound(amount, 0, MAX_ACTION);

        // The advertised bound, read BEFORE the call - exactly how a Vault would use it.
        uint256 cap = strategy.maxWithdraw();
        uint256 callerBefore = token.balanceOf(address(this));
        uint256 custodyBefore = strategy.totalAssets();

        try strategy.withdraw(amount) returns (uint256 withdrawn) {
            uint256 delta = token.balanceOf(address(this)) - callerBefore;

            _check(withdrawn == delta, "withdraw() return value is not the caller's balance delta");
            _check(withdrawn <= cap, "withdraw() paid out more than the maxWithdraw() it advertised");
            _check(withdrawn <= amount, "withdraw() paid out more than was requested");
            _check(
                custodyBefore >= delta && strategy.totalAssets() == custodyBefore - delta,
                "strategy custody did not fall by exactly what was pushed"
            );

            pushed += delta;
        } catch {
            _check(false, "withdraw() reverted: a request within maxWithdraw() must be payable");
        }
    }

    /// @notice Realises gains. Harvested assets must STAY in the strategy.
    function harvest() external {
        harvestCalls++;

        uint256 callerBefore = token.balanceOf(address(this));
        uint256 custodyBefore = strategy.totalAssets();

        try strategy.harvest() returns (uint256 gain) {
            _check(
                token.balanceOf(address(this)) == callerBefore,
                "harvest() pushed tokens to the caller: harvested assets must stay in custody"
            );
            _check(
                strategy.totalAssets() == custodyBefore,
                "harvest() moved assets out of the strategy"
            );
            _check(gain <= custodyBefore, "harvest() reported more gain than the strategy holds");

            harvested += gain;
        } catch {
            _check(false, "harvest() reverted");
        }
    }

    /// @notice Locks part of the position, as an epoch or a lockup would.
    function setIlliquid(uint256 amount) external {
        setIlliquidCalls++;
        // Bounded above the position on purpose: an over-locked strategy must still report a
        // maxWithdraw() of 0 rather than underflow.
        uint256 total = strategy.totalAssets();
        strategy.setIlliquid(_bound(amount, 0, total + MAX_ACTION));

        _check(
            strategy.maxWithdraw() <= strategy.totalAssets(),
            "maxWithdraw() exceeded totalAssets() after the position was locked"
        );
    }

    /// @notice Emergency unwind. Recovered assets stay in custody and leave via withdraw().
    function panic() external {
        panicCalls++;

        uint256 callerBefore = token.balanceOf(address(this));
        uint256 custodyBefore = strategy.totalAssets();

        try strategy.panic() {
            _check(
                token.balanceOf(address(this)) == callerBefore,
                "panic() pushed assets to the caller instead of keeping custody"
            );
            _check(strategy.totalAssets() == custodyBefore, "panic() lost assets held in custody");
            _check(
                strategy.maxWithdraw() == custodyBefore,
                "after panic() the whole recovered balance must be redeemable"
            );
        } catch {
            _check(false, "panic() reverted: the emergency unwind must always be callable");
        }
    }

    /// @notice Simulates an external yield source paying the strategy directly.
    /// @dev Uses the test token's unrestricted `mint`, which is why the ledger invariants are only
    /// asserted while `token.totalSupply() == mintedTotal()`: every token in play came from here.
    function simulateYield(uint256 amount) external {
        simulateYieldCalls++;
        amount = _bound(amount, 0, MAX_ACTION);

        uint256 custodyBefore = strategy.totalAssets();
        token.mint(address(strategy), amount);
        mintedTotal += amount;
        yieldInjected += amount;

        _check(
            strategy.totalAssets() == custodyBefore + amount,
            "totalAssets() did not follow the strategy's own token balance"
        );
    }

    // --- internals ---------------------------------------------------------------------

    /// @dev Records a broken post-condition instead of reverting. See the contract doc.
    function _check(bool ok, string memory reason) internal {
        if (!ok) {
            failureCount++;
            lastFailure = reason;
        }
    }

    /// @dev Plain modulo bounding - no `forge-std` `bound`, no cheatcodes.
    function _bound(uint256 x, uint256 min, uint256 max) internal pure returns (uint256) {
        if (max <= min) return min;
        return min + (x % (max - min + 1));
    }
}
