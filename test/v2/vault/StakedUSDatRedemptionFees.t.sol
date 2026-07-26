// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {StakedUSDat} from "../../../src/v2/StakedUSDat.sol";
import {IStakedUSDat} from "../../../src/v2/interfaces/IStakedUSDat.sol";
import {IWithdrawalQueueERC721} from "../../../src/v2/interfaces/IWithdrawalQueueERC721.sol";
import {ZeroAccountingModuleMock, ZeroTradableModuleMock} from "../helpers/FixedModuleMocks.sol";
import {V2InitializationHelper} from "../helpers/V2InitializationHelper.sol";

contract RedemptionFeeUSDatMock is ERC20 {
    constructor() ERC20("USDat", "USDat") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function isFrozen(address) external pure returns (bool) {
        return false;
    }
}

contract RedemptionFeeQueueHarness {
    function redeemQueuedShares(StakedUSDat vault, uint256 shares, uint256 minSharePrice)
        external
        returns (IStakedUSDat.RedemptionResult result, uint256 usdat)
    {
        return vault.redeemQueuedShares(shares, minSharePrice);
    }
}

contract StakedUSDatRedemptionFeeHarness is StakedUSDat {
    uint256 private _mockSharePrice;

    constructor(IWithdrawalQueueERC721 withdrawalQueue) StakedUSDat(withdrawalQueue) {}

    function setMockSharePrice(uint256 newSharePrice) external {
        _mockSharePrice = newSharePrice;
    }

    function _convertToAssets(uint256 shares, Math.Rounding rounding) internal view override returns (uint256) {
        if (_mockSharePrice == 0) return super._convertToAssets(shares, rounding);
        return Math.mulDiv(shares, _mockSharePrice, 1e18, rounding);
    }
}

contract StakedUSDatRedemptionFeesTest is Test {
    uint256 private constant DEPOSIT = 100e6;

    RedemptionFeeUSDatMock private usdat;
    RedemptionFeeQueueHarness private queue;
    StakedUSDatRedemptionFeeHarness private vault;
    ZeroAccountingModuleMock private strcMirrorModule;
    ZeroTradableModuleMock private strconModule;

    address private unauthorized = makeAddr("unauthorized");

    event RedemptionFeesUpdated(uint16 baseBps, uint16 elevatedBps);

    function setUp() public {
        usdat = new RedemptionFeeUSDatMock();
        queue = new RedemptionFeeQueueHarness();

        StakedUSDatRedemptionFeeHarness implementation =
            new StakedUSDatRedemptionFeeHarness(IWithdrawalQueueERC721(address(queue)));
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(implementation), abi.encodeCall(StakedUSDat.initialize, (address(this), IERC20(address(usdat))))
        );
        vault = StakedUSDatRedemptionFeeHarness(address(proxy));
        strcMirrorModule = new ZeroAccountingModuleMock(address(vault));
        strconModule = new ZeroTradableModuleMock(address(vault));

        vault.grantRole(vault.PARAMETER_MANAGER_ROLE(), address(this));
        vault.grantRole(vault.MARKET_MODE_MANAGER_ROLE(), address(this));

        usdat.mint(address(this), DEPOSIT);
        usdat.approve(address(vault), DEPOSIT);
    }

    function test_initializeV2_SetsRedemptionFeeTiers() public {
        vm.expectEmit(false, false, false, true, address(vault));
        emit RedemptionFeesUpdated(5, 10);

        _initialize(5, 10);

        assertEq(vault.baseRedemptionFeeBps(), 5);
        assertEq(vault.elevatedRedemptionFeeBps(), 10);
        assertEq(vault.elevatedDepositFeeBps(), 25);
        assertEq(vault.redemptionFeeBps(), 5);
    }

    function test_initializeV2_RequiresAdminAndRunsOnce() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, unauthorized, vault.DEFAULT_ADMIN_ROLE()
            )
        );
        vm.prank(unauthorized);
        _initialize(5, 10);

        _initialize(5, 10);

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        _initialize(5, 10);
    }

    function test_initializeV2_InvalidFeesDoNotConsumeReinitializer() public {
        vm.expectRevert(IStakedUSDat.InvalidFee.selector);
        _initialize(11, 10);

        _initialize(5, 10);

        assertEq(vault.baseRedemptionFeeBps(), 5);
        assertEq(vault.elevatedRedemptionFeeBps(), 10);
    }

    function test_redemptionFeeBps_SelectsTierFromMarketMode() public {
        _initialize(5, 10);

        assertEq(vault.redemptionFeeBps(), 5);

        vault.setMarketMode(IStakedUSDat.MarketMode.ELEVATED);
        assertEq(vault.redemptionFeeBps(), 10);

        vault.setMarketMode(IStakedUSDat.MarketMode.RESTRICTED);
        assertEq(vault.redemptionFeeBps(), 10);
    }

    function test_setRedemptionFees_RequiresParameterManagerRole() public {
        _initialize(5, 10);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, unauthorized, vault.PARAMETER_MANAGER_ROLE()
            )
        );
        vm.prank(unauthorized);
        vault.setRedemptionFees(6, 12);

        assertEq(vault.baseRedemptionFeeBps(), 5);
        assertEq(vault.elevatedRedemptionFeeBps(), 10);
    }

    function test_setRedemptionFees_UpdatesBothTiersAndEmits() public {
        _initialize(5, 10);

        vm.expectEmit(false, false, false, true, address(vault));
        emit RedemptionFeesUpdated(6, 12);
        vault.setRedemptionFees(6, 12);

        assertEq(vault.baseRedemptionFeeBps(), 6);
        assertEq(vault.elevatedRedemptionFeeBps(), 12);
    }

    function test_setRedemptionFees_RejectsInvalidOrderingAndCap() public {
        _initialize(5, 10);

        vm.expectRevert(IStakedUSDat.InvalidFee.selector);
        vault.setRedemptionFees(11, 10);

        vm.expectRevert(IStakedUSDat.InvalidFee.selector);
        vault.setRedemptionFees(500, 501);

        assertEq(vault.baseRedemptionFeeBps(), 5);
        assertEq(vault.elevatedRedemptionFeeBps(), 10);
    }

    function test_redeemQueuedShares_CeilRoundsAndRetainsFeeInVault() public {
        _initializeAndDeposit(5, 10);
        uint256 shares = 10_000_001e12;
        uint256 gross = vault.convertToAssets(shares);
        uint256 fee = Math.mulDiv(gross, 5, vault.BPS_DENOMINATOR(), Math.Rounding.Ceil);

        (IStakedUSDat.RedemptionResult result, uint256 payout) = queue.redeemQueuedShares(vault, shares, 0);

        assertEq(uint256(result), uint256(IStakedUSDat.RedemptionResult.Settled));
        assertEq(gross, 10_000_001);
        assertEq(fee, 5_001);
        assertEq(payout, gross - fee);
        assertEq(vault.usdatBalance(), DEPOSIT - payout);
        assertEq(usdat.balanceOf(address(vault)), DEPOSIT - payout);
        assertEq(usdat.balanceOf(address(queue)), payout);
    }

    function test_redeemQueuedShares_UsesElevatedTierAndChecksLimitBeforeFee() public {
        _initializeAndDeposit(5, 10);
        vault.setMarketMode(IStakedUSDat.MarketMode.ELEVATED);
        uint256 shares = 40e18;
        uint256 gross = vault.convertToAssets(shares);
        uint256 grossSharePrice = Math.mulDiv(gross, 1e18, shares);
        uint256 elevatedFee = Math.mulDiv(gross, 10, vault.BPS_DENOMINATOR(), Math.Rounding.Ceil);

        (IStakedUSDat.RedemptionResult result, uint256 payout) =
            queue.redeemQueuedShares(vault, shares, grossSharePrice);

        assertEq(uint256(result), uint256(IStakedUSDat.RedemptionResult.Settled));
        assertEq(payout, gross - elevatedFee);
        assertLt(Math.mulDiv(payout, 1e18, shares), grossSharePrice);
    }

    function test_redeemQueuedShares_SequentialFeeRetentionRaisesGrossSharePrice() public {
        _initializeAndDeposit(500, 500);
        uint256 shares = 40e18;
        uint256 firstGross = vault.convertToAssets(shares);

        (IStakedUSDat.RedemptionResult firstResult, uint256 firstPayout) = queue.redeemQueuedShares(vault, shares, 0);
        uint256 secondGross = vault.convertToAssets(shares);

        assertEq(uint256(firstResult), uint256(IStakedUSDat.RedemptionResult.Settled));
        assertEq(firstGross, 40e6);
        assertEq(firstPayout, 38e6);
        assertGt(secondGross, firstGross);
    }

    function test_redeemQueuedShares_InsufficientLiquiditySkipsWithoutMutation() public {
        _initializeAndDeposit(500, 500);
        vault.setMockSharePrice(2e6);
        uint256 shares = 60e18;

        (IStakedUSDat.RedemptionResult result, uint256 payout) = queue.redeemQueuedShares(vault, shares, 0);

        assertEq(uint256(result), uint256(IStakedUSDat.RedemptionResult.InsufficientLiquidity));
        assertEq(payout, 0);
        assertEq(vault.balanceOf(address(queue)), 100e18);
        assertEq(vault.totalSupply(), 100e18);
        assertEq(vault.usdatBalance(), DEPOSIT);
        assertEq(usdat.balanceOf(address(vault)), DEPOSIT);
        assertEq(usdat.balanceOf(address(queue)), 0);
    }

    function test_redeemQueuedShares_UsesNetAmountForLiquidityCheck() public {
        _initializeAndDeposit(500, 500);
        vault.setMockSharePrice(2_100_000);
        uint256 shares = 50e18;
        uint256 gross = vault.convertToAssets(shares);
        uint256 fee = Math.mulDiv(gross, 500, vault.BPS_DENOMINATOR(), Math.Rounding.Ceil);

        (IStakedUSDat.RedemptionResult result, uint256 payout) = queue.redeemQueuedShares(vault, shares, 0);

        assertEq(gross, 105e6);
        assertGt(gross, DEPOSIT);
        assertEq(payout, gross - fee);
        assertLe(payout, DEPOSIT);
        assertEq(uint256(result), uint256(IStakedUSDat.RedemptionResult.Settled));
    }

    function test_redeemQueuedShares_RestrictedModeRevertsWithoutMutation() public {
        _initializeAndDeposit(5, 10);
        vault.setMarketMode(IStakedUSDat.MarketMode.RESTRICTED);

        vm.expectRevert(IStakedUSDat.MarketRestricted.selector);
        queue.redeemQueuedShares(vault, 40e18, 0);

        assertEq(vault.balanceOf(address(queue)), 100e18);
        assertEq(vault.totalSupply(), 100e18);
        assertEq(vault.usdatBalance(), DEPOSIT);
        assertEq(usdat.balanceOf(address(vault)), DEPOSIT);
        assertEq(usdat.balanceOf(address(queue)), 0);
    }

    function _initialize(uint16 baseBps, uint16 elevatedBps) private {
        V2InitializationHelper.initialize(
            vault, address(strcMirrorModule), address(strconModule), baseBps, elevatedBps, 25
        );
    }

    function _initializeAndDeposit(uint16 baseBps, uint16 elevatedBps) private {
        _initialize(baseBps, elevatedBps);
        vault.depositWithMinShares(DEPOSIT, address(queue), 0);
    }
}
