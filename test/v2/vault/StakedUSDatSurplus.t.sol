// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {StakedUSDat} from "../../../src/v2/StakedUSDat.sol";
import {IAccountingModule} from "../../../src/v2/interfaces/modules/IAccountingModule.sol";
import {IStakedUSDat} from "../../../src/v2/interfaces/IStakedUSDat.sol";
import {IWithdrawalQueueERC721} from "../../../src/v2/interfaces/IWithdrawalQueueERC721.sol";
import {ZeroTradableModuleMock} from "../helpers/FixedModuleMocks.sol";
import {BoundMirrorModuleMock, V2InitializationHelper} from "../helpers/V2InitializationHelper.sol";

contract SurplusUSDatMock is ERC20 {
    mapping(address account => bool frozen) private _frozen;

    constructor() ERC20("USDat", "USDat") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setFrozen(address account, bool frozen) external {
        _frozen[account] = frozen;
    }

    function isFrozen(address account) external view returns (bool) {
        return _frozen[account];
    }
}

contract SurplusUnrelatedTokenMock is ERC20 {
    constructor() ERC20("Unrelated", "UNRELATED") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract SurplusAccountingModuleMock is IAccountingModule, BoundMirrorModuleMock {
    error PricingFailed();

    bool private _pricingFails;

    constructor(address vault) BoundMirrorModuleMock(vault) {}

    function setPricingFails(bool pricingFails) external {
        _pricingFails = pricingFails;
    }

    function recognizedValue() external view returns (uint256) {
        if (_pricingFails) revert PricingFailed();
        return 0;
    }

    function balance() external pure returns (uint256) {
        return 0;
    }
}

contract SurplusQueueHarness {
    function redeemQueuedShares(StakedUSDat vault, uint256 shares)
        external
        returns (IStakedUSDat.RedemptionResult result, uint256 usdat)
    {
        return vault.redeemQueuedShares(shares, 0);
    }
}

contract StakedUSDatSurplusTest is Test {
    uint256 private constant INITIAL_CASH = 1_000e6;
    uint256 private constant MAX_SURPLUS = 50e6;
    uint256 private constant SMALL_SURPLUS = 1e6;
    uint256 private constant DEFAULT_VESTING_PERIOD = 3 days;

    SurplusUSDatMock private usdat;
    SurplusAccountingModuleMock private strcMirrorModule;
    ZeroTradableModuleMock private strconModule;
    SurplusQueueHarness private queue;
    StakedUSDat private vault;

    address private unauthorized = makeAddr("unauthorized");
    address private permissionlessCaller = makeAddr("permissionlessCaller");

    event SurplusReceived(uint256 amount);
    event SurplusSwept(uint256 amount);
    event SurplusSourceUpdated(address indexed oldSource, address indexed newSource);
    event SurplusVestingPeriodUpdated(uint256 oldPeriod, uint256 newPeriod);

    function setUp() public {
        vm.warp(1_000_000);

        usdat = new SurplusUSDatMock();
        queue = new SurplusQueueHarness();
        vault = _deployVault();
        strcMirrorModule = new SurplusAccountingModuleMock(address(vault));
        strconModule = new ZeroTradableModuleMock(address(vault));

        V2InitializationHelper.initialize(vault, address(strcMirrorModule), address(strconModule), 5, 10, 25);
        vault.grantRole(vault.SURPLUS_MANAGER_ROLE(), address(this));
        vault.grantRole(vault.PARAMETER_MANAGER_ROLE(), address(this));
        vault.grantRole(vault.PAUSER_ROLE(), address(this));

        usdat.mint(address(this), 2_000e6);
        usdat.approve(address(vault), type(uint256).max);
        vault.deposit(INITIAL_CASH, address(this));
    }

    function test_FixedFivePercentCapAndInitializeV2SetsThreeDayVestingPeriod() public view {
        assertEq(vault.MAX_SURPLUS_BPS(), 500);
        assertEq(vault.surplusVestingPeriod(), DEFAULT_VESTING_PERIOD);
        assertEq(vault.MAX_SURPLUS_VESTING_PERIOD(), 7 days);
        assertEq(vault.surplusVestingAmount(), 0);
        assertEq(vault.surplusVestingStartTimestamp(), 0);
        assertEq(vault.surplusSource(), address(this));
    }

    function test_transferInSurplus_PullsUSDatAndStartsFullyUnvested() public {
        SurplusUnrelatedTokenMock unrelatedToken = new SurplusUnrelatedTokenMock();
        unrelatedToken.mint(address(this), MAX_SURPLUS);
        unrelatedToken.approve(address(vault), MAX_SURPLUS);
        uint256 custodyBefore = usdat.balanceOf(address(vault));

        vm.expectEmit(false, false, false, true, address(vault));
        emit SurplusReceived(MAX_SURPLUS);
        vault.transferInSurplus(MAX_SURPLUS);

        assertEq(usdat.balanceOf(address(vault)), custodyBefore + MAX_SURPLUS);
        assertEq(unrelatedToken.balanceOf(address(vault)), 0);
        assertEq(unrelatedToken.balanceOf(address(this)), MAX_SURPLUS);
        assertEq(vault.usdatBalance(), INITIAL_CASH);
        assertEq(vault.surplusVestingAmount(), MAX_SURPLUS);
        assertEq(vault.surplusVestingStartTimestamp(), block.timestamp);
        assertEq(vault.getUnvestedSurplus(), MAX_SURPLUS);
        assertEq(vault.totalAssets(), INITIAL_CASH);
    }

    function test_setSurplusSource_RequiresParameterManagerAndRejectsInvalidSources() public {
        address candidate = makeAddr("candidate");

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, unauthorized, vault.PARAMETER_MANAGER_ROLE()
            )
        );
        vm.prank(unauthorized);
        vault.setSurplusSource(candidate);

        vm.expectRevert(IStakedUSDat.InvalidZeroAddress.selector);
        vault.setSurplusSource(address(0));

        vm.expectRevert(IStakedUSDat.InvalidSurplusSource.selector);
        vault.setSurplusSource(address(vault));

        vm.expectRevert(IStakedUSDat.InvalidSurplusSource.selector);
        vault.setSurplusSource(address(queue));

        address blacklisted = makeAddr("blacklisted");
        vault.addToBlacklist(blacklisted);
        vm.expectRevert(IStakedUSDat.AddressBlacklisted.selector);
        vault.setSurplusSource(blacklisted);

        address frozen = makeAddr("frozen");
        usdat.setFrozen(frozen, true);
        vm.expectRevert(IStakedUSDat.AddressBlacklisted.selector);
        vault.setSurplusSource(frozen);

        assertEq(vault.surplusSource(), address(this));
    }

    function test_setSurplusSource_UpdatesEmitsAndWorksWhilePaused() public {
        address firstSource = makeAddr("firstSource");
        vm.expectEmit(true, true, false, true, address(vault));
        emit SurplusSourceUpdated(address(this), firstSource);
        vault.setSurplusSource(firstSource);

        assertEq(vault.surplusSource(), firstSource);

        vault.pause();
        address secondSource = makeAddr("secondSource");
        vm.expectEmit(true, true, false, true, address(vault));
        emit SurplusSourceUpdated(firstSource, secondSource);
        vault.setSurplusSource(secondSource);

        assertTrue(vault.paused());
        assertEq(vault.surplusSource(), secondSource);
    }

    function test_transferInSurplus_PullsFromConfiguredSourceNotManager() public {
        address manager = makeAddr("manager");
        vault.grantRole(vault.SURPLUS_MANAGER_ROLE(), manager);

        usdat.mint(manager, SMALL_SURPLUS);
        vm.prank(manager);
        usdat.approve(address(vault), SMALL_SURPLUS);

        uint256 sourceBalanceBefore = usdat.balanceOf(address(this));
        uint256 managerBalanceBefore = usdat.balanceOf(manager);

        vm.prank(manager);
        vault.transferInSurplus(SMALL_SURPLUS);

        assertEq(usdat.balanceOf(address(this)), sourceBalanceBefore - SMALL_SURPLUS);
        assertEq(usdat.balanceOf(manager), managerBalanceBefore);
        assertEq(vault.surplusVestingAmount(), SMALL_SURPLUS);
    }

    function test_transferInSurplus_RequiresSurplusManagerNonzeroAndUnpaused() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, unauthorized, vault.SURPLUS_MANAGER_ROLE()
            )
        );
        vm.prank(unauthorized);
        vault.transferInSurplus(SMALL_SURPLUS);

        address operator = makeAddr("operator");
        vault.grantRole(vault.OPERATOR_ROLE(), operator);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, operator, vault.SURPLUS_MANAGER_ROLE()
            )
        );
        vm.prank(operator);
        vault.transferInSurplus(SMALL_SURPLUS);

        vm.expectRevert(IStakedUSDat.ZeroAmount.selector);
        vault.transferInSurplus(0);

        vault.pause();
        vm.expectRevert();
        vault.transferInSurplus(SMALL_SURPLUS);
    }

    function test_transferInSurplus_AcceptsExactFivePercentCap() public {
        vault.transferInSurplus(MAX_SURPLUS);

        assertEq(vault.surplusVestingAmount(), MAX_SURPLUS);
    }

    function test_transferInSurplus_RejectsAmountAboveFivePercentCap() public {
        vm.expectRevert(IStakedUSDat.SurplusExceedsMax.selector);
        vault.transferInSurplus(MAX_SURPLUS + 1);

        assertEq(vault.surplusVestingAmount(), 0);
        assertEq(usdat.balanceOf(address(vault)), INITIAL_CASH);
    }

    function test_transferInSurplus_FloorsNonDivisibleNavCap() public {
        vault.deposit(1, address(this));

        vm.expectRevert(IStakedUSDat.SurplusExceedsMax.selector);
        vault.transferInSurplus(MAX_SURPLUS + 1);

        vault.transferInSurplus(MAX_SURPLUS);
        assertEq(vault.surplusVestingAmount(), MAX_SURPLUS);
    }

    function test_transferInSurplus_FailsClosedWhenNavCannotBePriced() public {
        strcMirrorModule.setPricingFails(true);

        vm.expectRevert(SurplusAccountingModuleMock.PricingFailed.selector);
        vault.transferInSurplus(SMALL_SURPLUS);

        assertEq(vault.surplusVestingAmount(), 0);
        assertEq(usdat.balanceOf(address(vault)), INITIAL_CASH);
    }

    function test_getUnvestedSurplus_UsesCeilRoundedLinearVesting() public {
        vault.transferInSurplus(MAX_SURPLUS);
        uint256 startedAt = block.timestamp;

        assertEq(vault.getUnvestedSurplus(), MAX_SURPLUS);

        vm.warp(startedAt + DEFAULT_VESTING_PERIOD / 2);
        uint256 halfUnvested =
            Math.mulDiv(DEFAULT_VESTING_PERIOD / 2, MAX_SURPLUS, DEFAULT_VESTING_PERIOD, Math.Rounding.Ceil);
        assertEq(vault.getUnvestedSurplus(), halfUnvested);
        assertEq(vault.totalAssets(), INITIAL_CASH + MAX_SURPLUS - halfUnvested);

        vm.warp(startedAt + DEFAULT_VESTING_PERIOD - 1);
        uint256 finalUnvested = Math.mulDiv(1, MAX_SURPLUS, DEFAULT_VESTING_PERIOD, Math.Rounding.Ceil);
        assertEq(vault.getUnvestedSurplus(), finalUnvested);
        assertEq(vault.totalAssets(), INITIAL_CASH + MAX_SURPLUS - finalUnvested);

        vm.warp(startedAt + DEFAULT_VESTING_PERIOD);
        assertEq(vault.getUnvestedSurplus(), 0);
        assertEq(vault.totalAssets(), INITIAL_CASH + MAX_SURPLUS);
    }

    function test_transferInSurplus_RejectsSecondActiveTranche() public {
        vault.transferInSurplus(MAX_SURPLUS);

        vm.expectRevert(IStakedUSDat.StillVesting.selector);
        vault.transferInSurplus(SMALL_SURPLUS);

        assertEq(vault.surplusVestingAmount(), MAX_SURPLUS);
    }

    function test_transferInSurplus_SweepsMatureTrancheBeforeStartingNext() public {
        vault.transferInSurplus(MAX_SURPLUS);
        vm.warp(block.timestamp + DEFAULT_VESTING_PERIOD);

        vault.transferInSurplus(SMALL_SURPLUS);

        assertEq(vault.usdatBalance(), INITIAL_CASH + MAX_SURPLUS);
        assertEq(vault.surplusVestingAmount(), SMALL_SURPLUS);
        assertEq(vault.getUnvestedSurplus(), SMALL_SURPLUS);
        assertEq(vault.totalAssets(), INITIAL_CASH + MAX_SURPLUS);
    }

    function test_sweep_IsPermissionlessNavNeutralAndCallableWhilePaused() public {
        vault.transferInSurplus(MAX_SURPLUS);

        vm.prank(permissionlessCaller);
        vault.sweep();
        assertEq(vault.usdatBalance(), INITIAL_CASH);
        assertEq(vault.surplusVestingAmount(), MAX_SURPLUS);

        vm.warp(block.timestamp + DEFAULT_VESTING_PERIOD);
        uint256 navBefore = vault.totalAssets();
        vault.pause();

        vm.expectEmit(false, false, false, true, address(vault));
        emit SurplusSwept(MAX_SURPLUS);
        vm.prank(permissionlessCaller);
        vault.sweep();

        assertTrue(vault.paused());
        assertEq(vault.usdatBalance(), INITIAL_CASH + MAX_SURPLUS);
        assertEq(vault.surplusVestingAmount(), 0);
        assertEq(vault.totalAssets(), navBefore);
    }

    function test_sweep_DoesNotRequireModulePricing() public {
        vault.transferInSurplus(MAX_SURPLUS);
        vm.warp(block.timestamp + DEFAULT_VESTING_PERIOD);
        strcMirrorModule.setPricingFails(true);

        vm.prank(permissionlessCaller);
        vault.sweep();

        assertEq(vault.usdatBalance(), INITIAL_CASH + MAX_SURPLUS);
        assertEq(vault.surplusVestingAmount(), 0);
    }

    function test_setSurplusVestingPeriod_RequiresParameterManagerAndValidatesBounds() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, unauthorized, vault.PARAMETER_MANAGER_ROLE()
            )
        );
        vm.prank(unauthorized);
        vault.setSurplusVestingPeriod(2 days);

        vm.expectRevert(IStakedUSDat.InvalidVestingPeriod.selector);
        vault.setSurplusVestingPeriod(0);
        vm.expectRevert(IStakedUSDat.InvalidVestingPeriod.selector);
        vault.setSurplusVestingPeriod(7 days + 1);
    }

    function test_setSurplusVestingPeriod_UpdatesAndRemainsCallableWhilePaused() public {
        vault.pause();

        vm.expectEmit(false, false, false, true, address(vault));
        emit SurplusVestingPeriodUpdated(DEFAULT_VESTING_PERIOD, 2 days);
        vault.setSurplusVestingPeriod(2 days);

        assertEq(vault.surplusVestingPeriod(), 2 days);
        assertEq(vault.MAX_SURPLUS_BPS(), 500);
    }

    function test_NoMutableMaxSurplusBpsSetter() public {
        (bool success,) = address(vault).call(abi.encodeWithSignature("setMaxSurplusBps(uint256)", 250));

        assertFalse(success);
        assertEq(vault.MAX_SURPLUS_BPS(), 500);
    }

    function test_setSurplusVestingPeriod_RejectsActiveAndSweepsMatureTranche() public {
        vault.transferInSurplus(MAX_SURPLUS);

        vm.expectRevert(IStakedUSDat.StillVesting.selector);
        vault.setSurplusVestingPeriod(2 days);

        vm.warp(block.timestamp + DEFAULT_VESTING_PERIOD);
        vault.setSurplusVestingPeriod(2 days);

        assertEq(vault.surplusVestingPeriod(), 2 days);
        assertEq(vault.surplusVestingAmount(), 0);
        assertEq(vault.usdatBalance(), INITIAL_CASH + MAX_SURPLUS);
    }

    function test_deposit_SweepsMatureSurplusBeforeAddingCash() public {
        vault.transferInSurplus(MAX_SURPLUS);
        vm.warp(block.timestamp + DEFAULT_VESTING_PERIOD);

        vault.deposit(SMALL_SURPLUS, address(this));

        assertEq(vault.surplusVestingAmount(), 0);
        assertEq(vault.usdatBalance(), INITIAL_CASH + MAX_SURPLUS + SMALL_SURPLUS);
    }

    function test_redeemQueuedShares_SweepsMatureSurplusBeforeLiquidityCheck() public {
        vault.transferInSurplus(MAX_SURPLUS);
        uint256 shares = vault.balanceOf(address(this));
        assertTrue(vault.transfer(address(queue), shares));
        vm.warp(block.timestamp + DEFAULT_VESTING_PERIOD);
        vault.authorizeRegularMode(uint64(block.timestamp + 8 hours));

        uint256 gross = vault.convertToAssets(shares);
        uint256 fee = Math.mulDiv(gross, 5, 10_000, Math.Rounding.Ceil);
        uint256 expectedPayout = gross - fee;
        uint256 surplusSourceBalanceBefore = usdat.balanceOf(vault.surplusSource());
        assertGt(expectedPayout, INITIAL_CASH);

        (IStakedUSDat.RedemptionResult result, uint256 payout) = queue.redeemQueuedShares(vault, shares);

        assertEq(uint256(result), uint256(IStakedUSDat.RedemptionResult.Settled));
        assertEq(payout, expectedPayout);
        assertEq(usdat.balanceOf(address(queue)), expectedPayout);
        assertEq(usdat.balanceOf(vault.surplusSource()), surplusSourceBalanceBefore + fee);
        assertEq(vault.surplusVestingAmount(), 0);
        assertEq(vault.usdatBalance(), INITIAL_CASH + MAX_SURPLUS - gross);
    }

    function _deployVault() private returns (StakedUSDat deployedVault) {
        StakedUSDat implementation = new StakedUSDat(IWithdrawalQueueERC721(address(queue)));
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(implementation), abi.encodeCall(StakedUSDat.initialize, (address(this), IERC20(address(usdat))))
        );
        return StakedUSDat(address(proxy));
    }
}
