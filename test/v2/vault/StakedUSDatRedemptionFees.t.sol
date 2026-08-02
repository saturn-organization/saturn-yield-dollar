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
import {STRConExecutionPolicy} from "../../../src/v2/STRConExecutionPolicy.sol";
import {IStakedUSDat} from "../../../src/v2/interfaces/IStakedUSDat.sol";
import {ISTRConExecutionPolicy} from "../../../src/v2/interfaces/ISTRConExecutionPolicy.sol";
import {IWithdrawalQueueERC721} from "../../../src/v2/interfaces/IWithdrawalQueueERC721.sol";
import {ISTRConModule} from "../../../src/v2/interfaces/modules/ISTRConModule.sol";
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
        ISTRConExecutionPolicy unauthorizedPolicy = _newPolicy();
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, unauthorized, vault.DEFAULT_ADMIN_ROLE()
            )
        );
        vm.prank(unauthorized);
        _initializeWithPolicy(5, 10, unauthorizedPolicy);

        _initialize(5, 10);

        ISTRConExecutionPolicy replacementPolicy = _newPolicy();
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        _initializeWithPolicy(5, 10, replacementPolicy);
    }

    function test_initializeV2_InvalidFeesDoNotConsumeReinitializer() public {
        ISTRConExecutionPolicy policy = _newPolicy();
        vm.expectRevert(IStakedUSDat.InvalidFee.selector);
        _initializeWithPolicy(11, 10, policy);

        _initializeWithPolicy(5, 10, policy);

        assertEq(vault.baseRedemptionFeeBps(), 5);
        assertEq(vault.elevatedRedemptionFeeBps(), 10);
    }

    function test_redemptionFeeBps_SelectsTierFromMarketMode() public {
        _initialize(5, 10);

        assertEq(vault.redemptionFeeBps(), 5);

        vault.setMarketMode(IStakedUSDat.MarketMode.Elevated);
        assertEq(vault.redemptionFeeBps(), 10);

        vault.setMarketMode(IStakedUSDat.MarketMode.Restricted);
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

    function test_previewRedeem_DeductsCeilRoundedFeeAndMatchesQueuedPayout() public {
        _initializeAndDeposit(5, 10);
        uint256 shares = 10_000_001e12;
        uint256 gross = vault.convertToAssets(shares);
        uint256 fee = Math.mulDiv(gross, 5, vault.BPS_DENOMINATOR(), Math.Rounding.Ceil);
        uint256 preview = vault.previewRedeem(shares);

        (IStakedUSDat.RedemptionResult result, uint256 payout) = queue.redeemQueuedShares(vault, shares, 0);

        assertEq(preview, gross - fee);
        assertEq(uint256(result), uint256(IStakedUSDat.RedemptionResult.Settled));
        assertEq(payout, preview);
    }

    function test_previewRedeem_UsesFeeSelectedByMarketMode() public {
        _initializeAndDeposit(5, 500);
        uint256 shares = 40e18;
        uint256 gross = vault.convertToAssets(shares);
        uint256 baseFee = Math.mulDiv(gross, 5, vault.BPS_DENOMINATOR(), Math.Rounding.Ceil);
        uint256 elevatedFee = Math.mulDiv(gross, 500, vault.BPS_DENOMINATOR(), Math.Rounding.Ceil);

        assertEq(vault.previewRedeem(shares), gross - baseFee);

        vault.setMarketMode(IStakedUSDat.MarketMode.Elevated);
        assertEq(vault.previewRedeem(shares), gross - elevatedFee);

        vault.setMarketMode(IStakedUSDat.MarketMode.Restricted);
        assertEq(vault.previewRedeem(shares), gross - elevatedFee);
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

    function test_redeemQueuedShares_ExactNetSharePriceSettles() public {
        _initializeAndDeposit(5, 10);
        uint256 shares = 40e18;
        uint256 gross = vault.convertToAssets(shares);
        uint256 fee = Math.mulDiv(gross, 5, vault.BPS_DENOMINATOR(), Math.Rounding.Ceil);
        uint256 expectedPayout = gross - fee;
        uint256 netSharePrice = Math.mulDiv(expectedPayout, 1e18, shares, Math.Rounding.Floor);

        (IStakedUSDat.RedemptionResult result, uint256 payout) = queue.redeemQueuedShares(vault, shares, netSharePrice);

        assertEq(uint256(result), uint256(IStakedUSDat.RedemptionResult.Settled));
        assertEq(payout, expectedPayout);
        assertEq(Math.mulDiv(payout, 1e18, shares, Math.Rounding.Floor), netSharePrice);
    }

    function test_redeemQueuedShares_OneUnitAboveNetSharePriceSkipsWithoutMutation() public {
        _initializeAndDeposit(5, 10);
        uint256 shares = 40e18;
        uint256 gross = vault.convertToAssets(shares);
        uint256 fee = Math.mulDiv(gross, 5, vault.BPS_DENOMINATOR(), Math.Rounding.Ceil);
        uint256 netSharePrice = Math.mulDiv(gross - fee, 1e18, shares, Math.Rounding.Floor);
        uint256 queueSharesBefore = vault.balanceOf(address(queue));
        uint256 totalSupplyBefore = vault.totalSupply();
        uint256 usdatBalanceBefore = vault.usdatBalance();
        uint256 vaultAssetsBefore = usdat.balanceOf(address(vault));
        uint256 queueAssetsBefore = usdat.balanceOf(address(queue));

        (IStakedUSDat.RedemptionResult result, uint256 payout) =
            queue.redeemQueuedShares(vault, shares, netSharePrice + 1);

        assertEq(uint256(result), uint256(IStakedUSDat.RedemptionResult.BelowLimit));
        assertEq(payout, 0);
        assertEq(vault.balanceOf(address(queue)), queueSharesBefore);
        assertEq(vault.totalSupply(), totalSupplyBefore);
        assertEq(vault.usdatBalance(), usdatBalanceBefore);
        assertEq(usdat.balanceOf(address(vault)), vaultAssetsBefore);
        assertEq(usdat.balanceOf(address(queue)), queueAssetsBefore);
    }

    function test_redeemQueuedShares_ElevatedFeeCanMoveNetPriceBelowOtherwiseAcceptableLimit() public {
        _initializeAndDeposit(5, 500);
        uint256 shares = 40e18;
        uint256 gross = vault.convertToAssets(shares);
        uint256 baseFee = Math.mulDiv(gross, 5, vault.BPS_DENOMINATOR(), Math.Rounding.Ceil);
        uint256 minSharePrice = Math.mulDiv(gross - baseFee, 1e18, shares, Math.Rounding.Floor);

        vault.setMarketMode(IStakedUSDat.MarketMode.Elevated);
        uint256 elevatedFee = Math.mulDiv(gross, 500, vault.BPS_DENOMINATOR(), Math.Rounding.Ceil);
        uint256 elevatedNetSharePrice = Math.mulDiv(gross - elevatedFee, 1e18, shares, Math.Rounding.Floor);

        assertLe(minSharePrice, Math.mulDiv(gross, 1e18, shares));
        assertGt(minSharePrice, elevatedNetSharePrice);

        (IStakedUSDat.RedemptionResult result, uint256 payout) = queue.redeemQueuedShares(vault, shares, minSharePrice);

        assertEq(uint256(result), uint256(IStakedUSDat.RedemptionResult.BelowLimit));
        assertEq(payout, 0);
        assertEq(vault.balanceOf(address(queue)), DEPOSIT * 1e12);
        assertEq(vault.totalSupply(), DEPOSIT * 1e12);
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
        vault.setMarketMode(IStakedUSDat.MarketMode.Restricted);

        vm.expectRevert(IStakedUSDat.MarketRestricted.selector);
        queue.redeemQueuedShares(vault, 40e18, 0);

        assertEq(vault.balanceOf(address(queue)), 100e18);
        assertEq(vault.totalSupply(), 100e18);
        assertEq(vault.usdatBalance(), DEPOSIT);
        assertEq(usdat.balanceOf(address(vault)), DEPOSIT);
        assertEq(usdat.balanceOf(address(queue)), 0);
    }

    function _initialize(uint16 baseBps, uint16 elevatedBps) private {
        _initializeWithPolicy(baseBps, elevatedBps, _newPolicy());
    }

    function _newPolicy() private returns (ISTRConExecutionPolicy) {
        return new STRConExecutionPolicy(address(vault), ISTRConModule(address(strconModule)));
    }

    function _initializeWithPolicy(uint16 baseBps, uint16 elevatedBps, ISTRConExecutionPolicy policy) private {
        V2InitializationHelper.initializeWithPolicy(
            vault,
            address(strcMirrorModule),
            ISTRConModule(address(strconModule)),
            policy,
            baseBps,
            elevatedBps,
            25,
            uint64(block.timestamp + 8 hours),
            type(uint128).max,
            0
        );
    }

    function _initializeAndDeposit(uint16 baseBps, uint16 elevatedBps) private {
        _initialize(baseBps, elevatedBps);
        vault.depositWithMinShares(DEPOSIT, address(queue), 0);
    }
}
