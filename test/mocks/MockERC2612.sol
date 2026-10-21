// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {MockERC20} from "./MockERC20.sol";

/// @title MockERC2612
/// @notice `MockERC20` plus a REAL EIP-2612 `permit`: EIP-712 domain, per-owner nonces, a deadline
/// check and `ecrecover`. TEST FIXTURE ONLY - it exists so the vault's permit-enabled deposit and
/// mint can be exercised against signatures that can actually be replayed, expired, forged or
/// front-run, which the signature-less stub in `MockERC20Permit.sol` cannot model.
contract MockERC2612 is MockERC20 {
    bytes32 public constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    mapping(address => uint256) public nonces;

    function DOMAIN_SEPARATOR() public view returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes(name)),
                keccak256("1"),
                block.chainid,
                address(this)
            )
        );
    }

    function permit(address owner, address spender, uint256 value, uint256 deadline, uint8 v, bytes32 r, bytes32 s)
        external
    {
        require(block.timestamp <= deadline, "MockERC2612: permit expired");
        uint256 nonce = nonces[owner];
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                DOMAIN_SEPARATOR(),
                keccak256(abi.encode(PERMIT_TYPEHASH, owner, spender, value, nonce, deadline))
            )
        );
        address recovered = ecrecover(digest, v, r, s);
        require(recovered != address(0) && recovered == owner, "MockERC2612: invalid signature");
        nonces[owner] = nonce + 1;
        allowance[owner][spender] = value;
        emit Approval(owner, spender, value);
    }
}
