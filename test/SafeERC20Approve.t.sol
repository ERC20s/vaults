// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {SafeERC20, IERC20} from "../src/utils/SafeERC20.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockNonStandardERC20} from "./mocks/MockNonStandardERC20.sol";

/// @notice Calls the library the way a vault does: `SafeERC20` functions are `internal`,
/// so `address(this)` inside `safeApprove` is this contract — the same relationship
/// `MinimalVault` and `ReferenceVault` have with their own allowances.
contract ApproverHarness {
    using SafeERC20 for IERC20;

    function approveVia(IERC20 token, address spender, uint256 value) external {
        token.safeApprove(spender, value);
    }

    /// @dev A raw, unwrapped approve, used to show the fixture really does enforce the
    /// non-zero -> non-zero rule that `safeApprove` works around.
    function rawApprove(address token, address spender, uint256 value) external {
        (bool ok,) = token.call(abi.encodeWithSignature("approve(address,uint256)", spender, value));
        require(ok, "raw approve reverted");
    }
}

/// @title SafeERC20ApproveTest
/// @notice Proves `SafeERC20.safeApprove` sets an exact allowance on both a well-behaved
/// ERC-20 and a USDT-style token that forbids changing a non-zero allowance directly.
///
/// @dev Dependency-free in the style of the rest of this suite: no `forge-std`, no
/// cheatcodes. Assertions are plain `require` (a reverting test is reported as failed by
/// `forge test`) and the "must revert" case uses try/catch on a real external call.
contract SafeERC20ApproveTest {
    ApproverHarness internal harness;
    MockERC20 internal standard;
    MockNonStandardERC20 internal nonStandard;
    address internal constant SPENDER = address(0xBEEF);

    function setUp() public {
        harness = new ApproverHarness();
        standard = new MockERC20();
        nonStandard = new MockNonStandardERC20();
    }

    // --- the fixture really is hostile -------------------------------------------------

    /// A direct non-zero -> non-zero approve on the USDT-style token MUST revert.
    /// Without this, the test below would prove nothing.
    function test_RawApproveRevertsOnNonZeroToNonZero() public {
        harness.rawApprove(address(nonStandard), SPENDER, 100);
        require(nonStandard.allowance(address(harness), SPENDER) == 100, "fixture: first approve failed");

        try harness.rawApprove(address(nonStandard), SPENDER, 200) {
            revert("fixture must reject a non-zero -> non-zero approve");
        } catch {
            // expected
        }
        require(nonStandard.allowance(address(harness), SPENDER) == 100, "fixture: allowance changed");
    }

    // --- the behaviour this change adds ------------------------------------------------

    /// safeApprove writes the allowance down to zero first, so the same change succeeds.
    function test_SafeApproveResetsNonZeroAllowanceFirst() public {
        harness.approveVia(IERC20(address(nonStandard)), SPENDER, 100);
        require(nonStandard.allowance(address(harness), SPENDER) == 100, "first approve not set");
        require(nonStandard.approveCalls() == 1, "fresh approval must be a single call");

        harness.approveVia(IERC20(address(nonStandard)), SPENDER, 200);
        require(nonStandard.allowance(address(harness), SPENDER) == 200, "allowance not updated");
        require(nonStandard.approveCalls() == 3, "expected reset-to-zero then set");
    }

    /// Setting an allowance to zero, or from zero, stays a single approve call.
    function test_SafeApproveKeepsSingleCallWhenNoResetNeeded() public {
        harness.approveVia(IERC20(address(nonStandard)), SPENDER, 100);
        require(nonStandard.approveCalls() == 1, "from zero must be one call");

        harness.approveVia(IERC20(address(nonStandard)), SPENDER, 0);
        require(nonStandard.allowance(address(harness), SPENDER) == 0, "allowance not cleared");
        require(nonStandard.approveCalls() == 2, "to zero must be one call");
    }

    /// A well-behaved token is unaffected: the allowance always ends at the exact value.
    function test_StandardTokenUnchanged() public {
        harness.approveVia(IERC20(address(standard)), SPENDER, 1_000e18);
        require(standard.allowance(address(harness), SPENDER) == 1_000e18, "standard: not set");

        harness.approveVia(IERC20(address(standard)), SPENDER, 7e18);
        require(standard.allowance(address(harness), SPENDER) == 7e18, "standard: not overwritten");

        harness.approveVia(IERC20(address(standard)), SPENDER, 0);
        require(standard.allowance(address(harness), SPENDER) == 0, "standard: not cleared");
    }

    /// Any sequence of two allowances lands on the second one, on both token shapes.
    function testFuzz_SafeApproveAlwaysLandsOnExactValue(uint128 first, uint128 second) public {
        harness.approveVia(IERC20(address(nonStandard)), SPENDER, first);
        harness.approveVia(IERC20(address(nonStandard)), SPENDER, second);
        require(nonStandard.allowance(address(harness), SPENDER) == second, "fuzz: non-standard mismatch");

        harness.approveVia(IERC20(address(standard)), SPENDER, first);
        harness.approveVia(IERC20(address(standard)), SPENDER, second);
        require(standard.allowance(address(harness), SPENDER) == second, "fuzz: standard mismatch");
    }

    /// The reset path never moves tokens: only the allowance changes, and it ends exact,
    /// which is what a strategy then pulls with transferFrom.
    function test_ResetTouchesAllowanceOnly() public {
        nonStandard.mint(address(harness), 500);
        harness.approveVia(IERC20(address(nonStandard)), SPENDER, 100);
        harness.approveVia(IERC20(address(nonStandard)), SPENDER, 300);

        require(nonStandard.allowance(address(harness), SPENDER) == 300, "allowance not exactly 300");
        require(nonStandard.balanceOf(address(harness)) == 500, "balance must be untouched by approvals");
    }
}
