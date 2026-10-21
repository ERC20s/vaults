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
    function chainId(uint256) external;
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
        vault = new MinimalVault(IERC20(address(token)), mock, address(this));
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

    /// @notice The domain separator is built from the live `block.chainid`, so a share permit
    /// signed before a chain fork is bound to the chain it was signed on: on the other side of the
    /// fork the old signature is refused and a fresh one under the new separator is accepted.
    /// A separator frozen at construction would accept the old signature on both chains.
    function test_permit_signed_before_a_chain_fork_is_rejected_after_it() public {
        uint256 pk = 0xF0F0;
        address owner = vm.addr(pk);
        address spender = address(this);
        uint256 value = 1e18;
        uint256 deadline = block.timestamp + 1 days;

        bytes32 separatorBefore = vault.DOMAIN_SEPARATOR();
        bytes32 structHash = keccak256(abi.encode(vault.PERMIT_TYPEHASH(), owner, spender, value, 0, deadline));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, keccak256(abi.encodePacked("\x19\x01", separatorBefore, structHash)));

        vm.chainId(block.chainid + 1);
        bytes32 separatorAfter = vault.DOMAIN_SEPARATOR();
        require(separatorAfter != separatorBefore, "domain separator did not follow the chain id");

        (bool ok, bytes memory data) = address(vault).call(
            abi.encodeWithSelector(vault.permit.selector, owner, spender, value, deadline, v, r, s)
        );
        require(!ok, "a permit signed on the other chain was accepted");
        require(
            keccak256(data) == keccak256(abi.encodeWithSignature("Error(string)", "MinimalVault: invalid permit")),
            "unexpected revert reason"
        );
        require(vault.nonces(owner) == 0, "a rejected permit consumed a nonce");
        require(vault.allowance(owner, spender) == 0, "a rejected permit set an allowance");

        // A signature under the new separator works on the new chain.
        (v, r, s) = vm.sign(pk, keccak256(abi.encodePacked("\x19\x01", separatorAfter, structHash)));
        vault.permit(owner, spender, value, deadline, v, r, s);
        require(vault.allowance(owner, spender) == value, "permit under the new separator did not set the allowance");
        require(vault.nonces(owner) == 1, "nonce not incremented");
    }

    /// @notice The separator is the EIP-712 domain of the vault's own `name`, version "1", the
    /// live chain id and the vault's address - so a wallet building it from `name()` matches.
    function test_domain_separator_matches_the_vaults_name_and_chain() public {
        bytes32 expected = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes(vault.name())),
                keccak256("1"),
                block.chainid,
                address(vault)
            )
        );
        require(vault.DOMAIN_SEPARATOR() == expected, "domain separator does not match name/version/chain/address");
    }

    /// @notice A signature over the right digest but with a wrong `v` recovers a different (or no)
    /// address and is refused without touching the nonce.
    function test_permit_with_wrong_v_is_rejected() public {
        uint256 pk = 0xD00D;
        address owner = vm.addr(pk);
        address spender = address(this);
        uint256 value = 1e18;
        uint256 deadline = block.timestamp + 1 days;

        bytes32 structHash = keccak256(abi.encode(vault.PERMIT_TYPEHASH(), owner, spender, value, 0, deadline));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, keccak256(abi.encodePacked("\x19\x01", vault.DOMAIN_SEPARATOR(), structHash)));
        uint8 wrongV = v == 27 ? 28 : 27;

        (bool ok, bytes memory data) = address(vault).call(
            abi.encodeWithSelector(vault.permit.selector, owner, spender, value, deadline, wrongV, r, s)
        );
        require(!ok, "a permit with a wrong v was accepted");
        require(
            keccak256(data) == keccak256(abi.encodeWithSignature("Error(string)", "MinimalVault: invalid permit")),
            "unexpected revert reason"
        );
        require(vault.nonces(owner) == 0, "a rejected permit consumed a nonce");
    }
}
