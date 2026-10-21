// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {MockERC20} from "./mocks/MockERC20.sol";
import {MockStrategy} from "./mocks/MockStrategy.sol";
import {MinimalVault} from "../src/vault/MinimalVault.sol";
import {IStrategy} from "../src/interfaces/IStrategy.sol";
import {IERC20} from "../src/utils/SafeERC20.sol";

interface Vm {
    function startPrank(address) external;
    function stopPrank() external;
    function expectRevert(bytes calldata) external;
}

Vm constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

/// @title MinimalVaultRounding
/// @notice ERC-4626 rounding direction and limit honesty for `MinimalVault`, stated as properties:
/// every preview rounds in the vault's favour (deposit and redeem floor, mint and withdraw ceil),
/// every action pays or charges exactly what its preview said, no round trip hands value out, and
/// `maxWithdraw(owner)` / `maxRedeem(owner)` are exactly what `withdraw()` / `redeem()` will serve
/// in full while the strategy holds (and partly locks) the funds.
contract MinimalVaultRoundingTest {
    MockERC20 token;
    MockStrategy mock;
    MinimalVault vault;

    address constant OTHER = address(0x0DD);

    function setUp() public {
        token = new MockERC20();
        mock = new MockStrategy(token);
        vault = new MinimalVault(IERC20(address(token)), IStrategy(address(mock)), address(this));
    }

    function _depositAs(address who, uint256 amount) internal returns (uint256 shares) {
        token.mint(who, amount);
        vm.startPrank(who);
        token.approve(address(vault), amount);
        shares = vault.deposit(amount);
        vm.stopPrank();
    }

    function _seed(uint256 first, uint256 yieldAmount) internal {
        require(_depositAs(address(this), first) == first, "bootstrap not 1:1");
        if (yieldAmount > 0) {
            token.mint(address(mock), yieldAmount);
        }
    }

    // --- rounding direction -------------------------------------------------------------

    /// @notice Each preview is the exact floor or ceil of the virtual-pair price, cross-multiplied
    /// so the check needs no division, and the four ERC-4626 round trips never profit the caller.
    function testFuzz_PreviewsRoundTowardsTheVault(uint96 firstRaw, uint96 yieldRaw, uint96 probeRaw) public {
        _seed((uint256(firstRaw) % 1e24) + 1, uint256(yieldRaw) % 1e24);
        uint256 probe = (uint256(probeRaw) % 1e24) + 1;
        uint256 assets = vault.totalAssets();
        uint256 supply = vault.totalSupply();

        uint256 pd = vault.previewDeposit(probe);
        require(pd * (assets + 1) <= probe * (supply + 1), "previewDeposit rounds up");
        require((pd + 1) * (assets + 1) > probe * (supply + 1), "previewDeposit floors too low");

        uint256 pm = vault.previewMint(probe);
        require(pm * (supply + 1) >= probe * (assets + 1), "previewMint rounds down");
        require(pm > 0 && (pm - 1) * (supply + 1) < probe * (assets + 1), "previewMint ceils too high");

        uint256 pw = vault.previewWithdraw(probe);
        require(pw * (assets + 1) >= probe * (supply + 1), "previewWithdraw rounds down");
        require(pw > 0 && (pw - 1) * (assets + 1) < probe * (supply + 1), "previewWithdraw ceils too high");

        uint256 pr = vault.previewRedeem(probe);
        require(pr * (supply + 1) <= probe * (assets + 1), "previewRedeem rounds up");
        require((pr + 1) * (supply + 1) > probe * (assets + 1), "previewRedeem floors too low");

        require(vault.previewRedeem(pd) <= probe, "deposit then redeem round trip profits");
        require(vault.previewMint(pw) >= probe, "withdraw then mint round trip profits");
        require(vault.previewWithdraw(pr) <= probe, "redeem then withdraw round trip profits");
        require(vault.previewDeposit(pm) >= probe, "mint then deposit round trip profits");

        require(vault.convertToShares(probe) == pd, "convertToShares disagrees with previewDeposit");
        require(vault.convertToAssets(probe) == pr, "convertToAssets disagrees with previewRedeem");
    }

    /// @notice Each action settles at exactly its preview and in the vault's favour, and the
    /// virtual-pair price never falls across it.
    function testFuzz_ActionsSettleAtTheirPreviews(uint96 firstRaw, uint96 yieldRaw, uint96 amountRaw, uint8 kind)
        public
    {
        _seed((uint256(firstRaw) % 1e24) + 1, uint256(yieldRaw) % 1e24);
        uint256 amount = (uint256(amountRaw) % 1e24) + 1;
        uint256 assets = vault.totalAssets();
        uint256 supply = vault.totalSupply();
        uint256 sharesBefore = vault.balanceOf(address(this));

        if (kind % 4 == 0) {
            uint256 preview = vault.previewDeposit(amount);
            token.mint(address(this), amount);
            token.approve(address(vault), amount);
            if (preview == 0) {
                vm.expectRevert(bytes("MinimalVault: zero-shares"));
                vault.deposit(amount);
                return;
            }
            uint256 minted = vault.deposit(amount);
            require(minted == preview, "deposit minted other than previewDeposit");
            require(minted * (assets + 1) <= amount * (supply + 1), "deposit minted more than was paid for");
            require(vault.convertToAssets(minted) <= amount, "deposited shares are worth more than the assets");
        } else if (kind % 4 == 1) {
            uint256 preview = vault.previewMint(amount);
            token.mint(address(this), preview);
            token.approve(address(vault), preview);
            uint256 charged = vault.mint(amount);
            require(charged == preview, "mint charged other than previewMint");
            require(charged * (supply + 1) >= amount * (assets + 1), "mint charged less than the shares are worth");
            require(vault.previewRedeem(amount) <= charged, "minted shares redeem for more than they cost");
        } else if (kind % 4 == 2) {
            uint256 claim = vault.convertToAssets(sharesBefore);
            uint256 want = (amount % claim) + 1;
            uint256 preview = vault.previewWithdraw(want);
            uint256 got = vault.withdraw(want);
            uint256 burned = sharesBefore - vault.balanceOf(address(this));
            require(got == want, "a liquid strategy did not serve the withdrawal in full");
            require(burned == preview, "withdraw burned other than previewWithdraw");
            require(burned * (assets + 1) >= want * (supply + 1), "withdraw burned fewer shares than the payout is worth");
        } else {
            uint256 shares = (amount % sharesBefore) + 1;
            uint256 preview = vault.previewRedeem(shares);
            if (preview == 0) {
                vm.expectRevert(bytes("MinimalVault: zero-assets"));
                vault.redeem(shares);
                return;
            }
            uint256 got = vault.redeem(shares);
            require(got == preview, "redeem paid other than previewRedeem");
            require(got * (supply + 1) <= shares * (assets + 1), "redeem paid more than the shares are worth");
            require(sharesBefore - vault.balanceOf(address(this)) == shares, "redeem burned other than the shares offered");
        }

        uint256 supplyAfter = vault.totalSupply();
        if (supplyAfter > 0) {
            require(
                (vault.totalAssets() + 1) * (supply + 1) >= (assets + 1) * (supplyAfter + 1),
                "assets per share fell"
            );
        }
    }

    // --- limit honesty ------------------------------------------------------------------

    /// @notice 3 shares over 10 assets, one of them held by OTHER. That share is worth
    /// floor(1 * 11 / 4) == 2 assets and `redeem(1)` pays it, so `maxRedeem(OTHER)` must say 1.
    /// The earlier `floor(cap * supply / assets)` said 0.
    function test_MaxRedeemReportsTheShareRedeemWillServe() public {
        require(_depositAs(address(this), 2) == 2, "bootstrap not 1:1");
        require(_depositAs(OTHER, 1) == 1, "second deposit not 1:1");
        token.mint(address(mock), 7);
        require(vault.totalSupply() == 3 && vault.totalAssets() == 10, "setup: 3 shares over 10 assets");

        uint256 maxShares = vault.maxRedeem(OTHER);
        require(maxShares == 1, "maxRedeem under-reports a share redeem() serves");
        require(vault.maxWithdraw(OTHER) == 2, "maxWithdraw is not the share's floor value");

        vm.startPrank(OTHER);
        uint256 paid = vault.redeem(maxShares);
        vm.stopPrank();
        require(paid == 2, "redeem(maxRedeem) did not pay the floor value");
        require(vault.balanceOf(OTHER) == 0, "redeem(maxRedeem) did not burn the share");
    }

    /// @notice With two holders, yield and an arbitrary lock on the strategy, `maxWithdraw(owner)`
    /// is min(claim, liquidity), `withdraw(maxWithdraw)` is served in full, `maxRedeem(owner)` is
    /// the LARGEST share count `redeem()` serves in full - one more would hit the lock - and
    /// `redeem(maxRedeem)` burns exactly that many.
    function testFuzz_OwnerLimitsAreExactUnderALockedStrategy(
        uint96 firstRaw,
        uint96 otherRaw,
        uint96 yieldRaw,
        uint96 lockRaw
    ) public {
        // Both holders enter at 1:1, then yield lands and part of the position is locked.
        _seed((uint256(firstRaw) % 1e24) + 1, 0);
        _depositAs(OTHER, (uint256(otherRaw) % 1e24) + 1);
        uint256 yieldAmount = uint256(yieldRaw) % 1e24;
        if (yieldAmount > 0) {
            token.mint(address(mock), yieldAmount);
        }
        mock.setIlliquid(uint256(lockRaw) % (vault.totalAssets() + 1e24));

        uint256 liquidity = mock.maxWithdraw();
        uint256 balance = vault.balanceOf(address(this));
        uint256 claim = vault.convertToAssets(balance);

        uint256 maxAssets = vault.maxWithdraw(address(this));
        require(maxAssets == (claim <= liquidity ? claim : liquidity), "maxWithdraw is not min(claim, liquidity)");

        uint256 maxShares = vault.maxRedeem(address(this));
        require(maxShares <= balance, "maxRedeem above the balance");
        uint256 maxSharesValue = vault.previewRedeem(maxShares);
        require(maxSharesValue <= liquidity, "maxRedeem is not serviceable by the strategy");
        require(maxShares == 0 || maxSharesValue > 0, "maxRedeem quotes a zero-asset redeem");
        if (maxShares < balance) {
            uint256 oneMore = vault.previewRedeem(maxShares + 1);
            require(oneMore > liquidity || oneMore == 0, "maxRedeem under-reports: one more share is still served");
        }

        if (maxAssets > 0) {
            uint256 got = vault.withdraw(maxAssets);
            require(got == maxAssets, "withdraw(maxWithdraw) was not served in full");
        }

        // The limits are recomputed on the new state and redeem(maxRedeem) is served in full.
        maxShares = vault.maxRedeem(address(this));
        if (maxShares > 0) {
            uint256 sharesBefore = vault.balanceOf(address(this));
            uint256 preview = vault.previewRedeem(maxShares);
            uint256 paid = vault.redeem(maxShares);
            require(paid == preview, "redeem(maxRedeem) paid other than its preview");
            require(sharesBefore - vault.balanceOf(address(this)) == maxShares, "redeem(maxRedeem) was not served in full");
        }
    }
}
