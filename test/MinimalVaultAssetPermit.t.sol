// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {MockERC2612} from "./mocks/MockERC2612.sol";
import {MockGenericStrategy} from "./mocks/MockGenericStrategy.sol";
import {MinimalVault} from "../src/vault/MinimalVault.sol";
import {IStrategy} from "../src/interfaces/IStrategy.sol";
import {IERC20} from "../src/utils/SafeERC20.sol";

interface Vm {
    function sign(uint256, bytes32) external returns (uint8, bytes32, bytes32);
    function addr(uint256) external returns (address);
    function prank(address) external;
    function expectRevert(bytes calldata) external;
    function warp(uint256) external;
}

Vm constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

/// @title MinimalVaultAssetPermit
/// @notice `depositWithPermit` / `mintWithPermit` against a REAL EIP-2612 asset
/// (`test/mocks/MockERC2612.sol`): the signature is used, consumed once, refused when replayed,
/// expired or forged, and - the finding - the deposit still goes through when a third party has
/// already submitted the same signature to the token, which used to turn every permit deposit
/// into a griefable transaction.
contract MinimalVaultAssetPermitTest {
    MockERC2612 token;
    MockGenericStrategy mock;
    MinimalVault vault;

    uint256 constant OWNER_PK = 0xA11CE;
    uint256 constant OTHER_PK = 0xBADBEEF;
    address owner;
    address constant FRONT_RUNNER = address(0xF00);

    function setUp() public {
        token = new MockERC2612();
        mock = new MockGenericStrategy(IERC20(address(token)));
        vault = new MinimalVault(IERC20(address(token)), IStrategy(address(mock)), address(this));
        owner = vm.addr(OWNER_PK);
        vm.warp(1_000_000);
    }

    function _sign(uint256 pk, address signer, uint256 value, uint256 nonce, uint256 deadline)
        internal
        returns (uint8 v, bytes32 r, bytes32 s)
    {
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                token.DOMAIN_SEPARATOR(),
                keccak256(abi.encode(token.PERMIT_TYPEHASH(), signer, address(vault), value, nonce, deadline))
            )
        );
        return vm.sign(pk, digest);
    }

    function test_DepositWithPermitUsesTheSignatureOnce() public {
        uint256 amount = 1_000e18;
        token.mint(owner, amount);
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _sign(OWNER_PK, owner, amount, 0, deadline);

        vm.prank(owner);
        uint256 shares = vault.depositWithPermit(amount, deadline, v, r, s);

        require(shares == amount, "bootstrap deposit not 1:1");
        require(vault.balanceOf(owner) == amount, "shares not credited to the signer");
        require(token.nonces(owner) == 1, "permit nonce not consumed");
        require(token.allowance(owner, address(vault)) == 0, "permit allowance not consumed by the pull");
        require(mock.totalAssets() == amount, "strategy custody missing");
    }

    function test_DepositWithPermitRejectsAReplayedSignature() public {
        uint256 amount = 1_000e18;
        token.mint(owner, 2 * amount);
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _sign(OWNER_PK, owner, amount, 0, deadline);

        vm.prank(owner);
        vault.depositWithPermit(amount, deadline, v, r, s);
        require(token.nonces(owner) == 1, "setup: first permit not consumed");

        // Same signature again: the nonce has moved on, the permit fails, and with no allowance
        // left the pull fails too. Nothing moves.
        vm.prank(owner);
        vm.expectRevert(bytes("MockERC20: insufficient allowance"));
        vault.depositWithPermit(amount, deadline, v, r, s);

        require(token.nonces(owner) == 1, "a replayed permit consumed a nonce");
        require(vault.balanceOf(owner) == amount, "a replayed permit minted shares");
        require(token.balanceOf(owner) == amount, "a replayed permit moved assets");
        require(mock.totalAssets() == amount, "strategy custody changed on a replay");
    }

    function test_DepositWithPermitRejectsAnExpiredDeadline() public {
        uint256 amount = 1_000e18;
        token.mint(owner, amount);
        uint256 deadline = block.timestamp - 1;
        (uint8 v, bytes32 r, bytes32 s) = _sign(OWNER_PK, owner, amount, 0, deadline);

        vm.prank(owner);
        vm.expectRevert(bytes("MockERC20: insufficient allowance"));
        vault.depositWithPermit(amount, deadline, v, r, s);

        require(token.nonces(owner) == 0, "an expired permit consumed a nonce");
        require(token.allowance(owner, address(vault)) == 0, "an expired permit set an allowance");
        require(vault.totalSupply() == 0, "an expired permit minted shares");
        require(token.balanceOf(owner) == amount, "an expired permit moved assets");
    }

    function test_DepositWithPermitRejectsAForgedSignature() public {
        uint256 amount = 1_000e18;
        token.mint(owner, amount);
        uint256 deadline = block.timestamp + 1 hours;
        // Signed by somebody else, presented as the owner's.
        (uint8 v, bytes32 r, bytes32 s) = _sign(OTHER_PK, owner, amount, 0, deadline);

        vm.prank(owner);
        vm.expectRevert(bytes("MockERC20: insufficient allowance"));
        vault.depositWithPermit(amount, deadline, v, r, s);

        require(token.nonces(owner) == 0, "a forged permit consumed a nonce");
        require(vault.totalSupply() == 0, "a forged permit minted shares");
        require(token.balanceOf(owner) == amount, "a forged permit moved assets");
    }

    /// @notice The finding. A signature in the mempool can be submitted to `token.permit()` by
    /// anyone; that consumes the nonce, and a vault that called `permit()` unconditionally then
    /// reverted the owner's own deposit with the allowance already sitting there. The deposit must
    /// go through on the allowance the front-run permit created.
    function test_DepositWithPermitSurvivesAFrontRunPermit() public {
        uint256 amount = 1_000e18;
        token.mint(owner, amount);
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _sign(OWNER_PK, owner, amount, 0, deadline);

        vm.prank(FRONT_RUNNER);
        token.permit(owner, address(vault), amount, deadline, v, r, s);
        require(token.nonces(owner) == 1, "setup: front-run permit not applied");
        require(token.allowance(owner, address(vault)) == amount, "setup: front-run allowance missing");

        vm.prank(owner);
        uint256 shares = vault.depositWithPermit(amount, deadline, v, r, s);

        require(shares == amount, "deposit after a front-run permit did not go through");
        require(vault.balanceOf(owner) == amount, "shares not credited after a front-run permit");
        require(token.nonces(owner) == 1, "the front-run signature was consumed twice");
        require(token.allowance(owner, address(vault)) == 0, "allowance not consumed by the pull");
        require(mock.totalAssets() == amount, "strategy custody missing");
    }

    function test_MintWithPermitUsesTheSignatureOverThePreviewedAssets() public {
        // Bootstrap at 1:1, then yield lifts the price to 1.5 assets per share.
        token.mint(address(this), 1_000e18);
        token.approve(address(vault), 1_000e18);
        vault.deposit(1_000e18);
        token.mint(address(mock), 500e18);

        uint256 shares = 100e18;
        uint256 assets = vault.previewMint(shares);
        require(assets > shares, "setup: price did not rise");
        token.mint(owner, assets);
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _sign(OWNER_PK, owner, assets, 0, deadline);

        vm.prank(owner);
        uint256 charged = vault.mintWithPermit(shares, deadline, v, r, s);

        require(charged == assets, "mintWithPermit charged other than previewMint");
        require(vault.balanceOf(owner) == shares, "shares not credited to the signer");
        require(token.nonces(owner) == 1, "permit nonce not consumed");
        require(token.balanceOf(owner) == 0, "assets not pulled from the signer");
    }

    /// @notice Documented fragility: the permit is bound to the exact assets of the mint. When
    /// the price moves between signing and execution the signature covers the wrong value, and the
    /// mint fails closed with nothing moved. `depositWithPermit` is the robust gasless path.
    function test_MintWithPermitFailsClosedWhenThePriceMovedSinceSigning() public {
        token.mint(address(this), 1_000e18);
        token.approve(address(vault), 1_000e18);
        vault.deposit(1_000e18);

        uint256 shares = 100e18;
        uint256 signedAssets = vault.previewMint(shares);
        token.mint(owner, 2 * signedAssets);
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _sign(OWNER_PK, owner, signedAssets, 0, deadline);

        // Yield arrives: the same shares now cost more than the signature covers.
        token.mint(address(mock), 500e18);
        require(vault.previewMint(shares) > signedAssets, "setup: price did not move");

        vm.prank(owner);
        vm.expectRevert(bytes("MockERC20: insufficient allowance"));
        vault.mintWithPermit(shares, deadline, v, r, s);

        require(token.nonces(owner) == 0, "a mismatched permit consumed a nonce");
        require(vault.balanceOf(owner) == 0, "a mismatched permit minted shares");
        require(token.balanceOf(owner) == 2 * signedAssets, "a mismatched permit moved assets");
    }
}
