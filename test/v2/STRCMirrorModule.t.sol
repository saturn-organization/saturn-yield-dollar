// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IStrcPriceOracle} from "../../src/v2/interfaces/IStrcPriceOracle.sol";
import {STRCMirrorModule} from "../../src/v2/modules/MirrorSTRC/STRCMirrorModule.sol";

contract STRCMirrorOracleMock {
    error PricingFailed();

    uint256 private _price;
    uint8 private _decimals;
    bool private _pricingFails;

    constructor(uint256 initialPrice, uint8 initialDecimals) {
        _price = initialPrice;
        _decimals = initialDecimals;
    }

    function setPrice(uint256 newPrice, uint8 newDecimals) external {
        _price = newPrice;
        _decimals = newDecimals;
    }

    function setPricingFails(bool pricingFails) external {
        _pricingFails = pricingFails;
    }

    function getPrice() external view returns (uint256, uint8) {
        if (_pricingFails) revert PricingFailed();
        return (_price, _decimals);
    }
}

contract STRCMirrorVaultMock {
    mapping(bytes32 role => mapping(address account => bool hasRole_)) private _roles;
    uint256 private _totalAssets;

    function setRole(bytes32 role, address account, bool enabled) external {
        _roles[role][account] = enabled;
    }

    function hasRole(bytes32 role, address account) external view returns (bool) {
        return _roles[role][account];
    }

    function setTotalAssets(uint256 newTotalAssets) external {
        _totalAssets = newTotalAssets;
    }

    function totalAssets() external view returns (uint256) {
        return _totalAssets;
    }

    function seed(
        STRCMirrorModule module,
        uint256 initialBalance,
        uint256 initialVestingAmount,
        uint256 initialLastDistributionTimestamp,
        uint256 initialVestingPeriod,
        uint256 initialMaxRewardsBps
    ) external {
        module.seed(
            initialBalance,
            initialVestingAmount,
            initialLastDistributionTimestamp,
            initialVestingPeriod,
            initialMaxRewardsBps
        );
    }

    function retire(STRCMirrorModule module) external {
        module.retire();
    }
}

contract STRCMirrorModuleTest is Test {
    event Seeded(
        uint256 balance,
        uint256 vestingAmount,
        uint256 lastDistributionTimestamp,
        uint256 vestingPeriod,
        uint256 maxRewardsBps
    );
    event RewardsReceived(uint256 amount, uint256 newVestingAmount);
    event VestingPeriodUpdated(uint256 oldPeriod, uint256 newPeriod);
    event MaxRewardsBpsUpdated(uint256 newMaxBps);
    event Retired();

    uint256 private constant START = 100 days;
    uint256 private constant DEFAULT_PRICE = 50e8;
    uint256 private constant DEFAULT_PERIOD = 30 days;
    uint256 private constant DEFAULT_MAX_REWARDS_BPS = 250;

    STRCMirrorOracleMock private oracle;
    STRCMirrorVaultMock private vault;
    STRCMirrorModule private module;

    function setUp() public {
        vm.warp(START);

        oracle = new STRCMirrorOracleMock(DEFAULT_PRICE, 8);
        vault = new STRCMirrorVaultMock();
        module = _newModule();

        vault.setRole(module.OPERATOR_ROLE(), address(this), true);
        vault.setRole(module.PARAMETER_MANAGER_ROLE(), address(this), true);
        vault.setTotalAssets(1_000_000e6);
    }

    function test_constructorBindsVaultAndDeployedOracle() public view {
        assertEq(module.VAULT(), address(vault));
        assertEq(address(module.ORACLE()), address(oracle));
    }

    function test_constructorRejectsZeroBindings() public {
        vm.expectRevert(STRCMirrorModule.InvalidZeroAddress.selector);
        new STRCMirrorModule(address(0), IStrcPriceOracle(address(oracle)));

        vm.expectRevert(STRCMirrorModule.InvalidZeroAddress.selector);
        new STRCMirrorModule(address(vault), IStrcPriceOracle(address(0)));
    }

    function test_preSeedViewsReturnZeroWithoutReadingOracle() public {
        oracle.setPricingFails(true);

        assertEq(module.balance(), 0);
        assertEq(module.getUnvestedAmount(), 0);
        assertEq(module.recognizedValue(), 0);
    }

    function test_seedStoresAllFiveV1FieldsExactly() public {
        uint256 initialBalance = 123_456_789;
        uint256 initialVestingAmount = 11;
        uint256 initialTimestamp = START - 9;
        uint256 initialPeriod = 10;

        vm.expectEmit(false, false, false, true, address(module));
        emit Seeded(initialBalance, initialVestingAmount, initialTimestamp, initialPeriod, DEFAULT_MAX_REWARDS_BPS);
        _seed(module, initialBalance, initialVestingAmount, initialTimestamp, initialPeriod, DEFAULT_MAX_REWARDS_BPS);

        assertTrue(module.seeded());
        assertFalse(module.retired());
        assertEq(module.balance(), initialBalance);
        assertEq(module.vestingAmount(), initialVestingAmount);
        assertEq(module.lastDistributionTimestamp(), initialTimestamp);
        assertEq(module.vestingPeriod(), initialPeriod);
        assertEq(module.maxRewardsBps(), DEFAULT_MAX_REWARDS_BPS);
    }

    function test_seedRejectsUnauthorizedCallerAndSecondSeed() public {
        vm.expectRevert(STRCMirrorModule.NotVault.selector);
        module.seed(0, 0, START, DEFAULT_PERIOD, DEFAULT_MAX_REWARDS_BPS);

        _seed(module, 0, 0, START, DEFAULT_PERIOD, DEFAULT_MAX_REWARDS_BPS);

        vm.expectRevert(STRCMirrorModule.AlreadySeeded.selector);
        _seed(module, 0, 0, START, DEFAULT_PERIOD, DEFAULT_MAX_REWARDS_BPS);
    }

    function test_seedEnforcesVestingPeriodBounds() public {
        vm.expectRevert(STRCMirrorModule.InvalidVestingPeriod.selector);
        _seed(module, 0, 0, START, 0, DEFAULT_MAX_REWARDS_BPS);

        vm.expectRevert(STRCMirrorModule.InvalidVestingPeriod.selector);
        _seed(module, 0, 0, START, 90 days + 1, DEFAULT_MAX_REWARDS_BPS);

        _seed(module, 0, 0, START, 90 days, DEFAULT_MAX_REWARDS_BPS);
        assertEq(module.vestingPeriod(), 90 days);
    }

    function test_seedRequiresNonzeroMaxRewardsWithoutUpperBound() public {
        vm.expectRevert(STRCMirrorModule.InvalidMaxRewardsBps.selector);
        _seed(module, 0, 0, START, DEFAULT_PERIOD, 0);

        _seed(module, 0, 0, START, DEFAULT_PERIOD, 10_001);
        assertEq(module.maxRewardsBps(), 10_001);
    }

    function test_seedChecksComputedUnvestedRatherThanRawVestingAmount() public {
        STRCMirrorModule invalidModule = _newModule();

        vm.expectRevert(STRCMirrorModule.UnvestedExceedsBalance.selector);
        _seed(invalidModule, 1, 11, START - 9, 10, DEFAULT_MAX_REWARDS_BPS);

        _seed(module, 2, 11, START - 9, 10, DEFAULT_MAX_REWARDS_BPS);
        assertEq(module.getUnvestedAmount(), 2);

        STRCMirrorModule fullyVestedModule = _newModule();
        _seed(fullyVestedModule, 0, 11, START - 10, 10, DEFAULT_MAX_REWARDS_BPS);
        assertEq(fullyVestedModule.getUnvestedAmount(), 0);
    }

    function test_getUnvestedAmountPreservesV1CeilRoundingAndBoundaries() public {
        _seed(module, 20, 11, START, 10, DEFAULT_MAX_REWARDS_BPS);

        uint256[6] memory elapsed = [uint256(0), 1, 5, 9, 10, 11];
        uint256[6] memory expected = [uint256(11), 10, 6, 2, 0, 0];

        for (uint256 i = 0; i < elapsed.length; ++i) {
            vm.warp(START + elapsed[i]);
            assertEq(module.getUnvestedAmount(), expected[i]);
        }
    }

    function test_recognizedValuePreservesV1CeilThenFloorRounding() public {
        oracle.setPrice(20e8 + 1, 8);
        _seed(module, 20, 11, START, 10, DEFAULT_MAX_REWARDS_BPS);

        uint256[5] memory elapsed = [uint256(0), 1, 5, 9, 10];
        uint256[5] memory expected = [uint256(180), 200, 280, 360, 400];

        for (uint256 i = 0; i < elapsed.length; ++i) {
            vm.warp(START + elapsed[i]);
            assertEq(module.recognizedValue(), expected[i]);
        }
    }

    function test_recognizedValueFloorsOracleConversion() public {
        oracle.setPrice(20e8 + 1, 8);
        _seed(module, 1, 0, START, DEFAULT_PERIOD, DEFAULT_MAX_REWARDS_BPS);

        assertEq(module.recognizedValue(), 20);
    }

    function test_zeroActiveBalanceReturnsZeroWithoutReadingOracle() public {
        _seed(module, 0, 0, START, DEFAULT_PERIOD, DEFAULT_MAX_REWARDS_BPS);
        oracle.setPricingFails(true);

        assertEq(module.recognizedValue(), 0);
    }

    function test_nonzeroBalanceFailsClosedWhenOracleCannotPrice() public {
        _seed(module, 1, 0, START, DEFAULT_PERIOD, DEFAULT_MAX_REWARDS_BPS);
        oracle.setPricingFails(true);

        vm.expectRevert(STRCMirrorOracleMock.PricingFailed.selector);
        module.recognizedValue();
    }

    function test_fullyUnvestedNonzeroBalanceStillReadsOracle() public {
        _seed(module, 1, 1, START, DEFAULT_PERIOD, DEFAULT_MAX_REWARDS_BPS);
        oracle.setPricingFails(true);

        vm.expectRevert(STRCMirrorOracleMock.PricingFailed.selector);
        module.recognizedValue();
    }

    function test_transferInRewardsRejectsInactiveUnauthorizedZeroAndOverlap() public {
        vm.expectRevert(STRCMirrorModule.STRCMirrorInactive.selector);
        module.transferInRewards(1);

        _seed(module, 10, 10, START, 10, DEFAULT_MAX_REWARDS_BPS);

        address outsider = makeAddr("outsider");
        vm.expectRevert(STRCMirrorModule.Unauthorized.selector);
        vm.prank(outsider);
        module.transferInRewards(1);

        vm.warp(START + 9);
        vm.expectRevert(STRCMirrorModule.StillVesting.selector);
        module.transferInRewards(1);

        vm.warp(START + 10);
        vm.expectRevert(STRCMirrorModule.ZeroAmount.selector);
        module.transferInRewards(0);
    }

    function test_transferInRewardsAcceptsCapEqualityAndRejectsFirstFailingAtom() public {
        oracle.setPrice(20e8 + 1, 8);
        vault.setTotalAssets(800e6);
        _seed(module, 0, 0, START, DEFAULT_PERIOD, DEFAULT_MAX_REWARDS_BPS);

        vm.expectRevert(STRCMirrorModule.RewardsExceedMax.selector);
        module.transferInRewards(1e6 + 1);

        module.transferInRewards(1e6);
        assertEq(module.balance(), 1e6);
    }

    function test_transferInRewardsAddsBalanceAndStartsV1Tranche() public {
        uint256 reward = 1e6;
        _seed(module, 7e6, 0, START - DEFAULT_PERIOD, DEFAULT_PERIOD, DEFAULT_MAX_REWARDS_BPS);

        vm.expectEmit(false, false, false, true, address(module));
        emit RewardsReceived(reward, reward);
        module.transferInRewards(reward);

        assertEq(module.balance(), 8e6);
        assertEq(module.vestingAmount(), reward);
        assertEq(module.lastDistributionTimestamp(), START);
        assertEq(module.getUnvestedAmount(), reward);
    }

    function test_transferInRewardsAllowsNewTrancheAtExactVestingEnd() public {
        _seed(module, 11, 11, START, 10, DEFAULT_MAX_REWARDS_BPS);

        vm.warp(START + 9);
        vm.expectRevert(STRCMirrorModule.StillVesting.selector);
        module.transferInRewards(1);

        vm.warp(START + 10);
        module.transferInRewards(1);

        assertEq(module.balance(), 12);
        assertEq(module.vestingAmount(), 1);
        assertEq(module.lastDistributionTimestamp(), START + 10);
    }

    function test_setVestingPeriodRequiresActiveParameterManager() public {
        vm.expectRevert(STRCMirrorModule.STRCMirrorInactive.selector);
        module.setVestingPeriod(1 days);

        _seed(module, 0, 0, START, DEFAULT_PERIOD, DEFAULT_MAX_REWARDS_BPS);
        vault.setRole(module.PARAMETER_MANAGER_ROLE(), address(this), false);

        vm.expectRevert(STRCMirrorModule.Unauthorized.selector);
        module.setVestingPeriod(1 days);
    }

    function test_setVestingPeriodEnforcesBoundsAndNoUnvestedRewards() public {
        _seed(module, 11, 11, START, 10, DEFAULT_MAX_REWARDS_BPS);

        vm.expectRevert(STRCMirrorModule.InvalidVestingPeriod.selector);
        module.setVestingPeriod(0);

        vm.expectRevert(STRCMirrorModule.InvalidVestingPeriod.selector);
        module.setVestingPeriod(90 days + 1);

        vm.expectRevert(STRCMirrorModule.StillVesting.selector);
        module.setVestingPeriod(1 days);
    }

    function test_setVestingPeriodUpdatesPeriodAndClearsStaleTranche() public {
        _seed(module, 1, 11, START - 10, 10, DEFAULT_MAX_REWARDS_BPS);

        vm.expectEmit(false, false, false, true, address(module));
        emit VestingPeriodUpdated(10, 90 days);
        module.setVestingPeriod(90 days);

        assertEq(module.vestingPeriod(), 90 days);
        assertEq(module.vestingAmount(), 0);
        assertEq(module.lastDistributionTimestamp(), START - 10);
    }

    function test_setMaxRewardsBpsRequiresActiveParameterManagerAndNonzeroValue() public {
        vm.expectRevert(STRCMirrorModule.STRCMirrorInactive.selector);
        module.setMaxRewardsBps(1);

        _seed(module, 0, 0, START, DEFAULT_PERIOD, DEFAULT_MAX_REWARDS_BPS);
        vault.setRole(module.PARAMETER_MANAGER_ROLE(), address(this), false);

        vm.expectRevert(STRCMirrorModule.Unauthorized.selector);
        module.setMaxRewardsBps(1);

        vault.setRole(module.PARAMETER_MANAGER_ROLE(), address(this), true);
        vm.expectRevert(STRCMirrorModule.InvalidMaxRewardsBps.selector);
        module.setMaxRewardsBps(0);
    }

    function test_setMaxRewardsBpsHasNoUpperBoundAndWorksDuringVesting() public {
        _seed(module, 11, 11, START, DEFAULT_PERIOD, DEFAULT_MAX_REWARDS_BPS);

        vm.expectEmit(false, false, false, true, address(module));
        emit MaxRewardsBpsUpdated(10_001);
        module.setMaxRewardsBps(10_001);

        assertEq(module.maxRewardsBps(), 10_001);
        assertEq(module.getUnvestedAmount(), 11);
    }

    function test_retireRequiresVaultActiveStateAndCompletedVesting() public {
        vm.expectRevert(STRCMirrorModule.NotVault.selector);
        module.retire();

        vm.expectRevert(STRCMirrorModule.STRCMirrorInactive.selector);
        vault.retire(module);

        _seed(module, 11, 11, START, 10, DEFAULT_MAX_REWARDS_BPS);

        vm.warp(START + 9);
        vm.expectRevert(STRCMirrorModule.StillVesting.selector);
        vault.retire(module);

        vm.warp(START + 10);
        vm.expectEmit(false, false, false, true, address(module));
        emit Retired();
        vault.retire(module);

        assertTrue(module.retired());
        assertEq(module.balance(), 0);
    }

    function test_retiredViewsReturnZeroWithoutOracleAndConfigRemainsReadable() public {
        _seed(module, 7, 0, START, DEFAULT_PERIOD, DEFAULT_MAX_REWARDS_BPS);
        vault.retire(module);
        oracle.setPricingFails(true);

        assertEq(module.balance(), 0);
        assertEq(module.getUnvestedAmount(), 0);
        assertEq(module.recognizedValue(), 0);
        assertEq(module.vestingPeriod(), DEFAULT_PERIOD);
        assertEq(module.maxRewardsBps(), DEFAULT_MAX_REWARDS_BPS);
        assertEq(module.lastDistributionTimestamp(), START);
    }

    function test_retirementPermanentlyDisablesEveryMutator() public {
        _seed(module, 7, 0, START, DEFAULT_PERIOD, DEFAULT_MAX_REWARDS_BPS);
        vault.retire(module);

        vm.expectRevert(STRCMirrorModule.STRCMirrorInactive.selector);
        module.transferInRewards(1);

        vm.expectRevert(STRCMirrorModule.STRCMirrorInactive.selector);
        module.setVestingPeriod(1 days);

        vm.expectRevert(STRCMirrorModule.STRCMirrorInactive.selector);
        module.setMaxRewardsBps(1);

        vm.expectRevert(STRCMirrorModule.STRCMirrorInactive.selector);
        vault.retire(module);

        vm.expectRevert(STRCMirrorModule.AlreadySeeded.selector);
        _seed(module, 0, 0, START, DEFAULT_PERIOD, DEFAULT_MAX_REWARDS_BPS);
    }

    function test_ABIHasNoTradingToleranceTokenOrLocalACLSelectors() public {
        bytes[] memory removedCalls = new bytes[](14);
        removedCalls[0] = abi.encodeWithSignature("asset()");
        removedCalls[1] = abi.encodeWithSignature("getPrice()");
        removedCalls[2] = abi.encodeWithSignature("buy(uint256)", 1);
        removedCalls[3] = abi.encodeWithSignature("buy(uint256,uint256,bytes)", 1, 1, "");
        removedCalls[4] = abi.encodeWithSignature("sell(uint256)", 1);
        removedCalls[5] = abi.encodeWithSignature("sell(uint256,uint256,bytes)", 1, 1, "");
        removedCalls[6] = abi.encodeWithSignature("setBalance(uint256)", 1);
        removedCalls[7] = abi.encodeWithSignature("setTolerance(uint256)", 1);
        removedCalls[8] = abi.encodeWithSignature("toleranceBps()");
        removedCalls[9] = abi.encodeWithSignature("USDAT()");
        removedCalls[10] = abi.encodeWithSignature("hasRole(bytes32,address)", bytes32(0), address(this));
        removedCalls[11] = abi.encodeWithSignature("grantRole(bytes32,address)", bytes32(0), address(this));
        removedCalls[12] = abi.encodeWithSignature("revokeRole(bytes32,address)", bytes32(0), address(this));
        removedCalls[13] = abi.encodeWithSignature("getRoleAdmin(bytes32)", bytes32(0));

        for (uint256 i = 0; i < removedCalls.length; ++i) {
            (bool success,) = address(module).call(removedCalls[i]);
            assertFalse(success);
        }
    }

    function testFuzz_vestingAndValuationPreserveV1Rounding(
        uint96 rawVestingAmount,
        uint96 rawBalance,
        uint32 rawPeriod,
        uint32 rawElapsed,
        uint64 rawPrice
    ) public {
        uint256 period = bound(uint256(rawPeriod), 1, 90 days);
        uint256 elapsed = bound(uint256(rawElapsed), 0, period + 1);
        uint256 initialVestingAmount = uint256(rawVestingAmount);
        uint256 initialBalance = bound(uint256(rawBalance), initialVestingAmount, type(uint96).max);
        uint256 price = bound(uint256(rawPrice), 20e8, 150e8);

        oracle.setPrice(price, 8);
        _seed(module, initialBalance, initialVestingAmount, START, period, DEFAULT_MAX_REWARDS_BPS);
        vm.warp(START + elapsed);

        uint256 expectedUnvested =
            elapsed >= period ? 0 : Math.mulDiv(period - elapsed, initialVestingAmount, period, Math.Rounding.Ceil);
        uint256 expectedValue = Math.mulDiv(initialBalance - expectedUnvested, price, 1e8, Math.Rounding.Floor);

        assertEq(module.getUnvestedAmount(), expectedUnvested);
        assertEq(module.recognizedValue(), expectedValue);
    }

    function _newModule() private returns (STRCMirrorModule) {
        return new STRCMirrorModule(address(vault), IStrcPriceOracle(address(oracle)));
    }

    function _seed(
        STRCMirrorModule target,
        uint256 initialBalance,
        uint256 initialVestingAmount,
        uint256 initialLastDistributionTimestamp,
        uint256 initialVestingPeriod,
        uint256 initialMaxRewardsBps
    ) private {
        vault.seed(
            target,
            initialBalance,
            initialVestingAmount,
            initialLastDistributionTimestamp,
            initialVestingPeriod,
            initialMaxRewardsBps
        );
    }
}
