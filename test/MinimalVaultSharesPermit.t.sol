// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {MockERC20} from "./mocks/MockERC20.sol";
import {MockStrategy} from "./mocks/MockStrategy.sol";
import {MinimalVault} from "../src/vault/MinimalVault.sol";
import {IERC20} from "../src/utils/SafeERC20.sol";

// Minimal Vm cheat interface for Foundry's vm.* helpers used in tests.
interface Vm {
    function sign(uint256, bytes32) external returns (uint8, bytes32, bytes32);
    function addr(uint256) external returns (address);
    function startPrank(address) external;
    function stopPrank() external;
}

// Standard address used in many Foundry tests to access cheatcodes.
Vm constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

contract MinimalVaultSharesPermitTest {
    MockERC20 token;
    MockStrategy mock;
    MinimalVault vault;

    function setUp() public {
        token = new MockERC20();
        mock = new MockStrategy(token);
        vault = new MinimalVault(IERC20(address(token)), mock);
    }

    function test_permit_sets_allowance_and_prevents_replay() public {
        uint256 pk = 0xBEEF;
        address owner = vm.addr(pk);
        address spender = address(this);

        uint256 amount = 1_000e18;
        token.mint(owner, amount);

        // Owner approves and deposits to obtain shares
        vm.startPrank(owner);
        token.approve(address(vault), amount);
        vault.deposit(amount);
        vm.stopPrank();

        uint256 nonce = vault.nonces(owner);
        uint256 value = 200e18;
        uint256 deadline = block.timestamp + 1 days;

        bytes32 structHash = keccak256(abi.encode(vault.PERMIT_TYPEHASH(), owner, spender, value, nonce, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", vault.DOMAIN_SEPARATOR(), structHash));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);

        // Call permit and observe allowance and nonce change
        vault.permit(owner, spender, value, deadline, v, r, s);
        require(vault.allowance(owner, spender) == value, "permit did not set allowance");
        require(vault.nonces(owner) == nonce + 1, "nonce not incremented");

        // Re-using the same signature should fail (nonce consumed)
        (bool ok, ) = address(vault).call(abi.encodeWithSelector(vault.permit.selector, owner, spender, value, deadline, v, r, s));
        require(!ok, "replay was not prevented");
    }

    function test_permit_with_expired_deadline_reverts() public {
        uint256 pk = 0xCAFE;
        address owner = vm.addr(pk);
        address spender = address(this);

        uint256 amount = 500e18;
        token.mint(owner, amount);

        // Obtain some shares
        vm.startPrank(owner);
        token.approve(address(vault), amount);
        vault.deposit(amount);
        vm.stopPrank();

        uint256 nonce = vault.nonces(owner);
        uint256 value = 100e18;
        uint256 deadline = block.timestamp - 1; // already expired

        bytes32 structHash = keccak256(abi.encode(vault.PERMIT_TYPEHASH(), owner, spender, value, nonce, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", vault.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);

        // Expect call to revert due to expired deadline
        (bool ok, ) = address(vault).call(abi.encodeWithSelector(vault.permit.selector, owner, spender, value, deadline, v, r, s));
        require(!ok, "expired permit did not revert");
    }
}
