// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IStrategy} from "../src/interfaces/IStrategy.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockStrategy} from "./mocks/MockStrategy.sol";

/// @title IStrategyConformance
/// @notice Executable form of the custody rule documented in `src/interfaces/IStrategy.sol`,
/// README.md and SECURITY.md. Until now those three documents only agreed with each other;
/// these tests make an implementation prove the rule.
///
/// @dev Deliberately DEPENDENCY-FREE: no `forge-std`, no cheatcodes, no submodule. Assertions are
/// plain `require` (a failing require reverts, and `forge test` reports a reverting test as failed)
/// and the revert case is checked with `try/catch` on a real external call. `setUp()` is still
/// honoured by Foundry, and a test function taking arguments is still fuzzed.
///
/// Any future strategy can be checked against these rules by pointing `strategy` at it: everything
/// below is written against the `IStrategy` type, and only `setUp()` knows about MockStrategy.
contract IStrategyConformanceTest {
    MockERC20 internal token;
    MockStrategy internal mock;
    IStrategy internal strategy;

    /// Redeployed by Foundry before every test case, including every fuzz run.
    function setUp() public {
        token = new MockERC20();
        mock = new MockStrategy(token);
        strategy = IStrategy(address(mock));
    }

    // --- assertions (no forge-std) -------------------------------------------------

    function _assertEq(uint256 a, uint256 b, string memory reason) internal pure {
        require(a == b, reason);
    }

    function _assertLe(uint256 a, uint256 b, string memory reason) internal pure {
        require(a <= b, reason);
    }

    // --- rule 1: deposits are pull-based -------------------------------------------

    /// The strategy must pull with transferFrom, so with no allowance the call MUST revert.
    /// A strategy that credited an un-pulled balance instead would let this pass.
    function test_DepositRevertsWithoutApproval() public {
        token.mint(address(this), 1_000e18);
        _assertEq(token.allowance(address(this), address(strategy)), 0, "fixture: expected no allowance");

        try strategy.deposit(1_000e18) {
            revert("deposit() must revert when the caller has not approved the strategy");
        } catch {
            // expected: the pull failed
        }

        _assertEq(strategy.totalAssets(), 0, "deposit() must not credit assets it did not pull");
        _assertEq(token.balanceOf(address(this)), 1_000e18, "caller balance must be untouched");
    }

    /// Approving exactly `amount` and depositing `amount` must consume the allowance exactly:
    /// no leftover (the strategy pulled less than it credited) and no revert (it pulled more).
    function test_DepositPullsExactlyAmountAndLeavesNoAllowance() public {
        uint256 amount = 500e18;
        token.mint(address(this), amount);
        token.approve(address(strategy), amount);

        strategy.deposit(amount);

        _assertEq(token.allowance(address(this), address(strategy)), 0, "deposit() must pull exactly `amount`");
        _assertEq(token.balanceOf(address(this)), 0, "caller must have paid exactly `amount`");
        _assertEq(token.balanceOf(address(strategy)), amount, "strategy must hold custody after deposit()");
        _assertEq(strategy.totalAssets(), amount, "totalAssets() must report the pulled amount");
    }

    // --- rule 2: maxWithdraw() is an honest upper bound ------------------------------

    function test_MaxWithdrawNeverExceedsTotalAssets() public {
        _assertLe(strategy.maxWithdraw(), strategy.totalAssets(), "empty: maxWithdraw() > totalAssets()");

        _depositAs(1_000e18);
        _assertLe(strategy.maxWithdraw(), strategy.totalAssets(), "funded: maxWithdraw() > totalAssets()");

        mock.setIlliquid(400e18);
        _assertEq(strategy.maxWithdraw(), 600e18, "illiquid portion must be excluded from maxWithdraw()");
        _assertLe(strategy.maxWithdraw(), strategy.totalAssets(), "partly locked: maxWithdraw() > totalAssets()");

        // An implementation that reported a bound above its own position would fail here.
        mock.setIlliquid(5_000e18);
        _assertEq(strategy.maxWithdraw(), 0, "fully locked position must report 0");
        _assertLe(strategy.maxWithdraw(), strategy.totalAssets(), "over-locked: maxWithdraw() > totalAssets()");
    }

    // --- rule 3: withdrawals are push-based, and the return value is the truth --------

    /// withdraw() must return EXACTLY the balance delta of msg.sender: no push-later,
    /// no over-reporting that a Vault would then book as assets it never received.
    function test_WithdrawReturnValueEqualsCallerBalanceDelta() public {
        _depositAs(1_000e18);
        mock.setIlliquid(250e18);

        uint256 before = token.balanceOf(address(this));
        uint256 withdrawn = strategy.withdraw(400e18);
        uint256 delta = token.balanceOf(address(this)) - before;

        _assertEq(withdrawn, delta, "withdraw() return value must equal the caller's balance delta");
        _assertEq(withdrawn, 400e18, "a request under maxWithdraw() must be paid in full");
        _assertEq(strategy.totalAssets(), 600e18, "strategy custody must fall by exactly the amount pushed");
    }

    /// withdraw(x) must never return more than maxWithdraw() read BEFORE the call.
    function test_WithdrawNeverExceedsMaxWithdrawReadBefore() public {
        _depositAs(1_000e18);
        mock.setIlliquid(700e18);

        uint256 cap = strategy.maxWithdraw();
        uint256 before = token.balanceOf(address(this));
        uint256 withdrawn = strategy.withdraw(1_000e18);

        _assertLe(withdrawn, cap, "withdraw() paid out more than the maxWithdraw() bound it advertised");
        _assertEq(withdrawn, cap, "the liquid part of the position must be payable");
        _assertEq(token.balanceOf(address(this)) - before, withdrawn, "return value must equal the push");
    }

    /// Documented in IStrategy: unwound assets stay in custody and leave through withdraw().
    function test_PanicKeepsCustodyAndReopensMaxWithdraw() public {
        _depositAs(1_000e18);
        mock.setIlliquid(1_000e18);
        _assertEq(strategy.maxWithdraw(), 0, "fixture: position should start fully locked");

        strategy.panic();

        _assertEq(strategy.totalAssets(), 1_000e18, "panic() must not push assets to the caller");
        _assertEq(strategy.maxWithdraw(), 1_000e18, "after panic() the recovered balance must be redeemable");
        _assertEq(strategy.withdraw(1_000e18), 1_000e18, "recovered assets must leave through withdraw()");
    }

    // --- fuzz: the whole rule, over arbitrary amounts ---------------------------------

    /// Fuzzes (deposit, illiquid, requested) and re-checks every rule at once. uint96 keeps the
    /// amounts inside a realistic token supply while still covering 0 and the extremes.
    function testFuzz_CustodyRuleHolds(uint96 depositAmount, uint96 illiquidAmount, uint96 requested) public {
        uint256 deposited = uint256(depositAmount);

        if (deposited > 0) {
            token.mint(address(this), deposited);
            token.approve(address(strategy), deposited);
            strategy.deposit(deposited);
            _assertEq(token.allowance(address(this), address(strategy)), 0, "fuzz: leftover allowance after deposit()");
        }
        _assertEq(strategy.totalAssets(), deposited, "fuzz: custody must equal what was pulled");

        mock.setIlliquid(uint256(illiquidAmount));

        uint256 cap = strategy.maxWithdraw();
        _assertLe(cap, strategy.totalAssets(), "fuzz: maxWithdraw() > totalAssets()");

        uint256 before = token.balanceOf(address(this));
        uint256 withdrawn = strategy.withdraw(uint256(requested));
        uint256 delta = token.balanceOf(address(this)) - before;

        _assertEq(withdrawn, delta, "fuzz: return value must equal the caller's balance delta");
        _assertLe(withdrawn, cap, "fuzz: withdraw() exceeded the maxWithdraw() bound read before the call");
        _assertLe(withdrawn, uint256(requested), "fuzz: withdraw() paid out more than was requested");
        _assertEq(strategy.totalAssets(), deposited - withdrawn, "fuzz: custody must fall by exactly the push");
        _assertLe(strategy.maxWithdraw(), strategy.totalAssets(), "fuzz: bound broken after withdraw()");
    }

    // --- helpers ----------------------------------------------------------------------

    function _depositAs(uint256 amount) internal {
        token.mint(address(this), amount);
        token.approve(address(strategy), amount);
        strategy.deposit(amount);
    }
}
