// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {IPriceOracle} from "../../src/v2/interfaces/IPriceOracle.sol";
import {ISTRConPriceOracle} from "../../src/v2/interfaces/ISTRConPriceOracle.sol";
import {ISyntheticSharesOracle} from "../../src/v2/interfaces/ISyntheticSharesOracle.sol";
import {STRConPriceOracle} from "../../src/v2/modules/STRCon/STRConPriceOracle.sol";

contract STRConChainlinkFeedMock is IPriceOracle {
    error FeedReadFailed();
    error DecimalsReadFailed();

    uint8 private _decimals;
    uint80 private _roundId;
    int256 private _answer;
    uint256 private _startedAt;
    uint256 private _updatedAt;
    uint80 private _answeredInRound;
    bool private _feedReadFails;
    bool private _decimalsReadFails;

    constructor(uint8 initialDecimals) {
        _decimals = initialDecimals;
    }

    function setDecimals(uint8 newDecimals) external {
        _decimals = newDecimals;
    }

    function setRound(
        uint80 newRoundId,
        int256 newAnswer,
        uint256 newStartedAt,
        uint256 newUpdatedAt,
        uint80 newAnsweredInRound
    ) external {
        _roundId = newRoundId;
        _answer = newAnswer;
        _startedAt = newStartedAt;
        _updatedAt = newUpdatedAt;
        _answeredInRound = newAnsweredInRound;
    }

    function setFeedReadFails(bool shouldFail) external {
        _feedReadFails = shouldFail;
    }

    function setDecimalsReadFails(bool shouldFail) external {
        _decimalsReadFails = shouldFail;
    }

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        if (_feedReadFails) revert FeedReadFailed();
        return (_roundId, _answer, _startedAt, _updatedAt, _answeredInRound);
    }

    function decimals() external view returns (uint8) {
        if (_decimalsReadFails) revert DecimalsReadFailed();
        return _decimals;
    }
}

contract STRConSyntheticSharesOracleMock is ISyntheticSharesOracle {
    error SValueReadFailed();
    error WrongAsset();

    address private immutable _EXPECTED_ASSET;
    uint256 private _sValue;
    bool private _paused;
    bool private _readFails;

    constructor(address expectedAsset) {
        _EXPECTED_ASSET = expectedAsset;
    }

    function setSValue(uint256 newSValue, bool paused_) external {
        _sValue = newSValue;
        _paused = paused_;
    }

    function setReadFails(bool shouldFail) external {
        _readFails = shouldFail;
    }

    function getSValue(address asset) external view returns (uint256 sValue, bool paused) {
        if (_readFails) revert SValueReadFailed();
        if (asset != _EXPECTED_ASSET) revert WrongAsset();
        return (_sValue, _paused);
    }
}

contract STRConOracleVaultMock {
    mapping(bytes32 role => mapping(address account => bool enabled)) private _roles;
    bool public paused;

    function setRole(bytes32 role, address account, bool enabled) external {
        _roles[role][account] = enabled;
    }

    function setPaused(bool newPaused) external {
        paused = newPaused;
    }

    function hasRole(bytes32 role, address account) external view returns (bool) {
        return _roles[role][account];
    }
}

contract STRConPriceOracleTest is Test {
    event PriceBoundsUpdated(uint256 newMinPrice, uint256 newMaxPrice);
    event MaxApiStalenessUpdated(uint256 newStaleness);
    event DeviationBpsUpdated(uint256 newDeviationBps);

    uint256 private constant START = 100 days;
    uint256 private constant PRIMARY_PRICE = 100e8 + 1;
    uint256 private constant INITIAL_DEVIATION_BPS = 50;
    uint256 private constant MAX_DEVIATION_BPS = 500;
    address private constant STRCON = address(0x1234);

    STRConOracleVaultMock private vault;
    STRConChainlinkFeedMock private primary;
    STRConChainlinkFeedMock private referenceFeedMock;
    STRConSyntheticSharesOracleMock private sharesOracle;
    STRConPriceOracle private oracle;

    function setUp() public {
        vm.warp(START);

        vault = new STRConOracleVaultMock();
        primary = new STRConChainlinkFeedMock(8);
        referenceFeedMock = new STRConChainlinkFeedMock(8);
        sharesOracle = new STRConSyntheticSharesOracleMock(STRCON);

        _setPrices(PRIMARY_PRICE, PRIMARY_PRICE);
        sharesOracle.setSValue(1e18, false);

        oracle = _deployOracle(
            address(vault), STRCON, sharesOracle, primary, referenceFeedMock, INITIAL_DEVIATION_BPS, MAX_DEVIATION_BPS
        );
        vault.setRole(oracle.PARAMETER_MANAGER_ROLE(), address(this), true);
    }

    function test_constructorBindsFeedsAndSpecDefaults() public view {
        assertEq(oracle.VAULT(), address(vault));
        assertEq(oracle.STRCON(), STRCON);
        assertEq(address(oracle.syntheticSharesOracle()), address(sharesOracle));
        assertEq(address(oracle.primaryFeed()), address(primary));
        assertEq(address(oracle.referenceFeed()), address(referenceFeedMock));
        assertEq(oracle.decimals(), 8);
        assertEq(oracle.MAX_DEVIATION_BPS(), MAX_DEVIATION_BPS);
        assertEq(oracle.maxApiStaleness(), 26 hours);
        assertEq(oracle.deviationBps(), INITIAL_DEVIATION_BPS);
        assertEq(oracle.minPrice(), 20e8);
        assertEq(oracle.maxPrice(), 150e8);
    }

    function test_constructorRejectsEveryZeroBinding() public {
        vm.expectRevert(STRConPriceOracle.InvalidZeroAddress.selector);
        _deployOracle(
            address(0), STRCON, sharesOracle, primary, referenceFeedMock, INITIAL_DEVIATION_BPS, MAX_DEVIATION_BPS
        );

        vm.expectRevert(STRConPriceOracle.InvalidZeroAddress.selector);
        _deployOracle(
            address(vault),
            address(0),
            sharesOracle,
            primary,
            referenceFeedMock,
            INITIAL_DEVIATION_BPS,
            MAX_DEVIATION_BPS
        );

        vm.expectRevert(STRConPriceOracle.InvalidZeroAddress.selector);
        _deployOracle(
            address(vault),
            STRCON,
            ISyntheticSharesOracle(address(0)),
            primary,
            referenceFeedMock,
            INITIAL_DEVIATION_BPS,
            MAX_DEVIATION_BPS
        );

        vm.expectRevert(STRConPriceOracle.InvalidZeroAddress.selector);
        _deployOracle(
            address(vault),
            STRCON,
            sharesOracle,
            IPriceOracle(address(0)),
            referenceFeedMock,
            INITIAL_DEVIATION_BPS,
            MAX_DEVIATION_BPS
        );

        vm.expectRevert(STRConPriceOracle.InvalidZeroAddress.selector);
        _deployOracle(
            address(vault),
            STRCON,
            sharesOracle,
            primary,
            IPriceOracle(address(0)),
            INITIAL_DEVIATION_BPS,
            MAX_DEVIATION_BPS
        );
    }

    function test_constructorRejectsEitherNonEightDecimalFeed() public {
        primary.setDecimals(7);
        vm.expectRevert(STRConPriceOracle.InvalidFeedDecimals.selector);
        _deployOracle(
            address(vault), STRCON, sharesOracle, primary, referenceFeedMock, INITIAL_DEVIATION_BPS, MAX_DEVIATION_BPS
        );

        primary.setDecimals(8);
        referenceFeedMock.setDecimals(9);
        vm.expectRevert(STRConPriceOracle.InvalidFeedDecimals.selector);
        _deployOracle(
            address(vault), STRCON, sharesOracle, primary, referenceFeedMock, INITIAL_DEVIATION_BPS, MAX_DEVIATION_BPS
        );
    }

    function test_constructorFailsClosedWhenFeedDecimalsCannotBeRead() public {
        primary.setDecimalsReadFails(true);

        vm.expectRevert(STRConChainlinkFeedMock.DecimalsReadFailed.selector);
        _deployOracle(
            address(vault), STRCON, sharesOracle, primary, referenceFeedMock, INITIAL_DEVIATION_BPS, MAX_DEVIATION_BPS
        );
    }

    function test_constructorRejectsInitialDeviationAboveImmutableCap() public {
        vm.expectRevert(STRConPriceOracle.InvalidDeviation.selector);
        _deployOracle(address(vault), STRCON, sharesOracle, primary, referenceFeedMock, 501, 500);

        STRConPriceOracle exactCap =
            _deployOracle(address(vault), STRCON, sharesOracle, primary, referenceFeedMock, 500, 500);
        assertEq(exactCap.deviationBps(), 500);
        assertEq(exactCap.MAX_DEVIATION_BPS(), 500);
    }

    function test_getPriceReturnsOnlyPrimaryAndRecomputesLatestRounds() public {
        uint256 firstReferencePrice = PRIMARY_PRICE + 40_000_000;
        _setPrices(PRIMARY_PRICE, firstReferencePrice);

        ISTRConPriceOracle scalarOracle = ISTRConPriceOracle(address(oracle));
        assertEq(scalarOracle.decimals(), 8);
        assertEq(scalarOracle.getPrice(), PRIMARY_PRICE);
        assertTrue(PRIMARY_PRICE != firstReferencePrice);

        uint256 nextPrimaryPrice = 101e8;
        uint256 nextReferencePrice = nextPrimaryPrice - 25_000_000;
        _setPrices(nextPrimaryPrice, nextReferencePrice);

        assertEq(oracle.getPrice(), nextPrimaryPrice);
        assertTrue(nextPrimaryPrice != nextReferencePrice);
    }

    function test_primaryRejectsEveryInvalidRoundFieldAndRecovers() public {
        _assertEveryInvalidRound(primary);
    }

    function test_referenceRejectsEveryInvalidRoundFieldAndRecovers() public {
        _assertEveryInvalidRound(referenceFeedMock);
    }

    function test_roundTemporalBoundariesAndIgnoredStartedAtAreAccepted() public {
        primary.setRound(10, _asInt(PRIMARY_PRICE), 0, START, 10);
        referenceFeedMock.setRound(10, _asInt(PRIMARY_PRICE), 0, START, 10);

        assertEq(oracle.getPrice(), PRIMARY_PRICE);
    }

    function test_referenceStalenessAcceptsBoundaryAndRejectsFirstSecondAfter() public {
        primary.setRound(10, _asInt(PRIMARY_PRICE), 0, 1, 10);
        referenceFeedMock.setRound(10, _asInt(PRIMARY_PRICE), 0, START - 26 hours, 10);

        assertEq(oracle.getPrice(), PRIMARY_PRICE);

        referenceFeedMock.setRound(10, _asInt(PRIMARY_PRICE), 0, START - 26 hours - 1, 10);
        vm.expectRevert(STRConPriceOracle.StaleReferencePrice.selector);
        oracle.getPrice();
    }

    function test_primaryHasNoWallClockStalenessLimit() public {
        primary.setRound(10, _asInt(PRIMARY_PRICE), 0, 1, 10);
        referenceFeedMock.setRound(10, _asInt(PRIMARY_PRICE), 0, START, 10);

        assertEq(oracle.getPrice(), PRIMARY_PRICE);
    }

    function test_sValueFailuresPauseAndZeroFailClosedThenRecover() public {
        sharesOracle.setReadFails(true);
        vm.expectRevert(STRConSyntheticSharesOracleMock.SValueReadFailed.selector);
        oracle.getPrice();

        sharesOracle.setReadFails(false);
        sharesOracle.setSValue(1e18, true);
        vm.expectRevert(STRConPriceOracle.AssetPaused.selector);
        oracle.getPrice();

        sharesOracle.setSValue(0, false);
        vm.expectRevert(STRConPriceOracle.InvalidSValue.selector);
        oracle.getPrice();

        sharesOracle.setSValue(1e18, false);
        assertEq(oracle.getPrice(), PRIMARY_PRICE);
    }

    function test_underlyingPriceBoundsAreInclusiveAndRejectFirstOutsideUnit() public {
        _setPrices(20e8, 20e8);
        assertEq(oracle.getPrice(), 20e8);

        _setPrices(150e8, 150e8);
        assertEq(oracle.getPrice(), 150e8);

        _setPrices(20e8 - 1, 20e8 - 1);
        vm.expectRevert(STRConPriceOracle.UnderlyingPriceOutOfBounds.selector);
        oracle.getPrice();

        _setPrices(150e8 + 1, 150e8 + 1);
        vm.expectRevert(STRConPriceOracle.UnderlyingPriceOutOfBounds.selector);
        oracle.getPrice();
    }

    function test_underlyingPriceUsesFloorRounding() public {
        sharesOracle.setSValue(3e18, false);

        _setPrices(3 * 20e8 - 1, 3 * 20e8 - 1);
        vm.expectRevert(STRConPriceOracle.UnderlyingPriceOutOfBounds.selector);
        oracle.getPrice();

        _setPrices(3 * 20e8, 3 * 20e8);
        assertEq(oracle.getPrice(), 3 * 20e8);

        _setPrices(3 * 150e8 + 2, 3 * 150e8 + 2);
        assertEq(oracle.getPrice(), 3 * 150e8 + 2);

        _setPrices(3 * 150e8 + 3, 3 * 150e8 + 3);
        vm.expectRevert(STRConPriceOracle.UnderlyingPriceOutOfBounds.selector);
        oracle.getPrice();
    }

    function test_underlyingPriceUsesFullPrecisionMulDiv() public {
        uint256 largePrice = 1e60;
        sharesOracle.setSValue(1e68, false);
        _setPrices(largePrice, largePrice);

        assertEq(oracle.getPrice(), largePrice);
    }

    function test_deviationCeilBoundaryAndFirstFailureReferenceAbovePrimary() public {
        uint256 maximumDifference = Math.mulDiv(PRIMARY_PRICE, INITIAL_DEVIATION_BPS, 10_000);

        _setPrices(PRIMARY_PRICE, PRIMARY_PRICE + maximumDifference);
        assertEq(oracle.getPrice(), PRIMARY_PRICE);

        _setPrices(PRIMARY_PRICE, PRIMARY_PRICE + maximumDifference + 1);
        vm.expectRevert(STRConPriceOracle.FeedDeviation.selector);
        oracle.getPrice();
    }

    function test_deviationCeilBoundaryAndFirstFailureReferenceBelowPrimary() public {
        uint256 maximumDifference = Math.mulDiv(PRIMARY_PRICE, INITIAL_DEVIATION_BPS, 10_000);

        _setPrices(PRIMARY_PRICE, PRIMARY_PRICE - maximumDifference);
        assertEq(oracle.getPrice(), PRIMARY_PRICE);

        _setPrices(PRIMARY_PRICE, PRIMARY_PRICE - maximumDifference - 1);
        vm.expectRevert(STRConPriceOracle.FeedDeviation.selector);
        oracle.getPrice();
    }

    function test_zeroDeviationRequiresExactAgreementAndOneBpsAcceptsOneUnit() public {
        oracle.setDeviationBps(0);
        _setPrices(PRIMARY_PRICE, PRIMARY_PRICE);
        assertEq(oracle.getPrice(), PRIMARY_PRICE);

        _setPrices(PRIMARY_PRICE, PRIMARY_PRICE + 1);
        vm.expectRevert(STRConPriceOracle.FeedDeviation.selector);
        oracle.getPrice();

        oracle.setDeviationBps(1);
        assertEq(oracle.getPrice(), PRIMARY_PRICE);
    }

    function test_configurationSettersRequireVaultParameterManagerRole() public {
        address outsider = makeAddr("outsider");

        vm.expectRevert(STRConPriceOracle.Unauthorized.selector);
        vm.prank(outsider);
        oracle.setPriceBounds(10e8, 200e8);

        vm.expectRevert(STRConPriceOracle.Unauthorized.selector);
        vm.prank(outsider);
        oracle.setMaxApiStaleness(1 hours);

        vm.expectRevert(STRConPriceOracle.Unauthorized.selector);
        vm.prank(outsider);
        oracle.setDeviationBps(1);
    }

    function test_setPriceBoundsValidatesStoresAndEmits() public {
        vm.expectRevert(STRConPriceOracle.InvalidPriceBounds.selector);
        oracle.setPriceBounds(0, 1);

        vm.expectRevert(STRConPriceOracle.InvalidPriceBounds.selector);
        oracle.setPriceBounds(100e8, 100e8);

        vm.expectRevert(STRConPriceOracle.InvalidPriceBounds.selector);
        oracle.setPriceBounds(101e8, 100e8);

        vm.expectEmit(false, false, false, true, address(oracle));
        emit PriceBoundsUpdated(10e8, 200e8);
        oracle.setPriceBounds(10e8, 200e8);

        assertEq(oracle.minPrice(), 10e8);
        assertEq(oracle.maxPrice(), 200e8);
    }

    function test_setMaxApiStalenessAllowsZeroAndHardCapThenRejectsFirstSecondAbove() public {
        vm.expectRevert(STRConPriceOracle.InvalidStaleness.selector);
        oracle.setMaxApiStaleness(36 hours + 1);

        vm.expectEmit(false, false, false, true, address(oracle));
        emit MaxApiStalenessUpdated(36 hours);
        oracle.setMaxApiStaleness(36 hours);
        assertEq(oracle.maxApiStaleness(), 36 hours);

        vm.expectEmit(false, false, false, true, address(oracle));
        emit MaxApiStalenessUpdated(0);
        oracle.setMaxApiStaleness(0);
        assertEq(oracle.maxApiStaleness(), 0);
    }

    function test_setDeviationBpsAllowsZeroAndImmutableCapThenRejectsFirstUnitAbove() public {
        vm.expectRevert(STRConPriceOracle.InvalidDeviation.selector);
        oracle.setDeviationBps(MAX_DEVIATION_BPS + 1);

        vm.expectEmit(false, false, false, true, address(oracle));
        emit DeviationBpsUpdated(MAX_DEVIATION_BPS);
        oracle.setDeviationBps(MAX_DEVIATION_BPS);
        assertEq(oracle.deviationBps(), MAX_DEVIATION_BPS);

        vm.expectEmit(false, false, false, true, address(oracle));
        emit DeviationBpsUpdated(0);
        oracle.setDeviationBps(0);
        assertEq(oracle.deviationBps(), 0);
    }

    function test_configurationSettersRemainAvailableWhileVaultPaused() public {
        vault.setPaused(true);

        oracle.setPriceBounds(10e8, 200e8);
        oracle.setMaxApiStaleness(1 hours);
        oracle.setDeviationBps(25);

        assertEq(oracle.minPrice(), 10e8);
        assertEq(oracle.maxPrice(), 200e8);
        assertEq(oracle.maxApiStaleness(), 1 hours);
        assertEq(oracle.deviationBps(), 25);
    }

    function test_currentReadsRecoverImmediatelyAfterValidReconfiguration() public {
        _setPrices(PRIMARY_PRICE, PRIMARY_PRICE + 40_000_000);
        referenceFeedMock.setRound(10, _asInt(PRIMARY_PRICE + 40_000_000), 0, START - 2 hours, 10);

        oracle.setMaxApiStaleness(1 hours);
        vm.expectRevert(STRConPriceOracle.StaleReferencePrice.selector);
        oracle.getPrice();

        oracle.setMaxApiStaleness(2 hours);
        assertEq(oracle.getPrice(), PRIMARY_PRICE);

        oracle.setDeviationBps(30);
        vm.expectRevert(STRConPriceOracle.FeedDeviation.selector);
        oracle.getPrice();

        oracle.setDeviationBps(40);
        assertEq(oracle.getPrice(), PRIMARY_PRICE);

        oracle.setPriceBounds(101e8, 150e8);
        vm.expectRevert(STRConPriceOracle.UnderlyingPriceOutOfBounds.selector);
        oracle.getPrice();

        oracle.setPriceBounds(20e8, 150e8);
        assertEq(oracle.getPrice(), PRIMARY_PRICE);
    }

    function test_ABIHasNoFeedRotationSyncWindowCacheOrLocalACL() public {
        bytes[] memory removedCalls = new bytes[](12);
        removedCalls[0] = abi.encodeWithSignature("setPrimaryFeed(address)", address(referenceFeedMock));
        removedCalls[1] = abi.encodeWithSignature("setReferenceFeed(address)", address(primary));
        removedCalls[2] = abi.encodeWithSignature("setCalculatedFeed(address)", address(referenceFeedMock));
        removedCalls[3] = abi.encodeWithSignature("setApiFeed(address)", address(primary));
        removedCalls[4] = abi.encodeWithSignature("setSyncWindow(uint256)", 1);
        removedCalls[5] = abi.encodeWithSignature("syncWindow()");
        removedCalls[6] = abi.encodeWithSignature("lastGoodPrice()");
        removedCalls[7] = abi.encodeWithSignature("hasRole(bytes32,address)", bytes32(0), address(this));
        removedCalls[8] = abi.encodeWithSignature("grantRole(bytes32,address)", bytes32(0), address(this));
        removedCalls[9] = abi.encodeWithSignature("revokeRole(bytes32,address)", bytes32(0), address(this));
        removedCalls[10] = abi.encodeWithSignature("renounceRole(bytes32,address)", bytes32(0), address(this));
        removedCalls[11] = abi.encodeWithSignature("getRoleAdmin(bytes32)", bytes32(0));

        for (uint256 i = 0; i < removedCalls.length; ++i) {
            (bool success,) = address(oracle).call(removedCalls[i]);
            assertFalse(success);
        }

        assertEq(address(oracle.primaryFeed()), address(primary));
        assertEq(address(oracle.referenceFeed()), address(referenceFeedMock));
    }

    function testFuzz_deviationUsesPrimaryDenominatorAndCeilBoundary(
        uint96 rawPrimaryPrice,
        uint16 rawDeviationBps,
        bool referenceAbove
    ) public {
        uint256 primaryPrice = bound(uint256(rawPrimaryPrice), 20e8, 150e8);
        uint256 configuredDeviation = bound(uint256(rawDeviationBps), 0, MAX_DEVIATION_BPS);
        uint256 maximumDifference = Math.mulDiv(primaryPrice, configuredDeviation, 10_000);

        oracle.setDeviationBps(configuredDeviation);

        uint256 boundaryReference = referenceAbove ? primaryPrice + maximumDifference : primaryPrice - maximumDifference;
        _setPrices(primaryPrice, boundaryReference);
        assertEq(oracle.getPrice(), primaryPrice);

        uint256 firstFailingReference =
            referenceAbove ? primaryPrice + maximumDifference + 1 : primaryPrice - maximumDifference - 1;
        _setPrices(primaryPrice, firstFailingReference);
        vm.expectRevert(STRConPriceOracle.FeedDeviation.selector);
        oracle.getPrice();
    }

    function testFuzz_underlyingBoundsMatchFullPrecisionFloor(uint128 rawPrimaryPrice, uint128 rawSValue) public {
        uint256 primaryPrice = bound(uint256(rawPrimaryPrice), 1, type(uint128).max);
        uint256 sValue = bound(uint256(rawSValue), 1, type(uint128).max);
        uint256 expectedUnderlying = Math.mulDiv(primaryPrice, 1e18, sValue, Math.Rounding.Floor);

        sharesOracle.setSValue(sValue, false);
        _setPrices(primaryPrice, primaryPrice);

        if (expectedUnderlying >= oracle.minPrice() && expectedUnderlying <= oracle.maxPrice()) {
            assertEq(oracle.getPrice(), primaryPrice);
        } else {
            vm.expectRevert(STRConPriceOracle.UnderlyingPriceOutOfBounds.selector);
            oracle.getPrice();
        }
    }

    function _assertEveryInvalidRound(STRConChainlinkFeedMock target) private {
        target.setFeedReadFails(true);
        vm.expectRevert(STRConChainlinkFeedMock.FeedReadFailed.selector);
        oracle.getPrice();
        target.setFeedReadFails(false);

        target.setRound(0, _asInt(PRIMARY_PRICE), 0, START, 10);
        _expectInvalidRound();

        target.setRound(10, 0, 0, START, 10);
        _expectInvalidRound();

        target.setRound(10, -1, 0, START, 10);
        _expectInvalidRound();

        target.setRound(10, _asInt(PRIMARY_PRICE), 0, 0, 10);
        _expectInvalidRound();

        target.setRound(10, _asInt(PRIMARY_PRICE), 0, START + 1, 10);
        _expectInvalidRound();

        target.setRound(10, _asInt(PRIMARY_PRICE), 0, START, 9);
        _expectInvalidRound();

        target.setRound(10, _asInt(PRIMARY_PRICE), 0, START, 10);
        assertEq(oracle.getPrice(), PRIMARY_PRICE);
    }

    function _expectInvalidRound() private {
        vm.expectRevert(STRConPriceOracle.InvalidOracleRound.selector);
        oracle.getPrice();
    }

    function _setPrices(uint256 primaryPrice, uint256 referencePrice) private {
        primary.setRound(10, _asInt(primaryPrice), 0, block.timestamp, 10);
        referenceFeedMock.setRound(10, _asInt(referencePrice), 0, block.timestamp, 10);
    }

    function _asInt(uint256 value) private pure returns (int256) {
        return SafeCast.toInt256(value);
    }

    function _deployOracle(
        address vault_,
        address strcon_,
        ISyntheticSharesOracle sharesOracle_,
        IPriceOracle primary_,
        IPriceOracle reference_,
        uint256 initialDeviationBps,
        uint256 maxDeviationBps
    ) private returns (STRConPriceOracle) {
        return new STRConPriceOracle(
            vault_, strcon_, sharesOracle_, primary_, reference_, initialDeviationBps, maxDeviationBps
        );
    }
}
