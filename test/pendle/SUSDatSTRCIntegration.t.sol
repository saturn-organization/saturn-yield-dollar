// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {stdError} from "forge-std/StdError.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ERC1967Proxy} from "pendle-oz/proxy/ERC1967/ERC1967Proxy.sol";
import {PendleERC20WithOracleSY} from "pendle-sy/core/StandardizedYield/implementations/PendleERC20WithOracleSY.sol";
import {Errors as SYErrors} from "pendle-sy/core/libraries/Errors.sol";
import {IStandardizedYield} from "pendle-sy/interfaces/IStandardizedYield.sol";
import {IPMarket} from "pendle-core/interfaces/IPMarket.sol";
import {IPYieldToken} from "pendle-core/interfaces/IPYieldToken.sol";
import {IPPrincipalToken} from "pendle-core/interfaces/IPPrincipalToken.sol";

import {STRCReferenceMetadata} from "../../src/pendle/STRCReferenceMetadata.sol";
import {SUSDatSTRCExchangeRateOracle} from "../../src/pendle/SUSDatSTRCExchangeRateOracle.sol";
import {IPriceOracle} from "../../src/v2/interfaces/oracles/IPriceOracle.sol";
import {ISyntheticSharesOracle} from "../../src/v2/interfaces/oracles/ISyntheticSharesOracle.sol";
import {STRConPriceOracle} from "../../src/v2/modules/STRCon/STRConPriceOracle.sol";
import {STRConModule} from "../../src/v2/modules/STRCon/STRConModule.sol";

interface IPYieldContractFactoryHarness {
    function createYieldContract(address SY, uint32 expiry, bool doCacheIndexSameBlock)
        external
        returns (address PT, address YT);
}

interface IPYieldTokenHarness is IPYieldToken {
    function postExpiry() external view returns (uint128 firstPYIndex, uint128 totalSyInterestForTreasury);
}

interface IPMarketFactoryHarness {
    function createNewMarket(address PT, int256 scalarRoot, int256 initialAnchor, uint80 lnFeeRateRoot)
        external
        returns (address market);
}

contract TokenMock is ERC20 {
    uint8 private immutable _tokenDecimals;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _tokenDecimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _tokenDecimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract SUSDatMock is TokenMock {
    error ConversionReverted();

    address public immutable asset;
    address public strconModule;
    uint256 public assetsPerShare = 10_000_000;
    bool public conversionShouldRevert;

    constructor(address usdat) TokenMock("Staked USDat", "sUSDat", 18) {
        asset = usdat;
    }

    function setAssetsPerShare(uint256 value) external {
        assetsPerShare = value;
    }

    function setStrconModule(address value) external {
        strconModule = value;
    }

    function setConversionShouldRevert(bool value) external {
        conversionShouldRevert = value;
    }

    function convertToAssets(uint256 shares) external view returns (uint256) {
        if (conversionShouldRevert) revert ConversionReverted();
        return Math.mulDiv(shares, assetsPerShare, 1e18);
    }
}

contract SUSDatWrongDecimalsMock is TokenMock {
    address public immutable asset;

    constructor(address usdat) TokenMock("Staked USDat", "sUSDat", 17) {
        asset = usdat;
    }

    function convertToAssets(uint256) external pure returns (uint256) {
        return 10e6;
    }
}

contract MalformedDependency {
    fallback() external {
        assembly {
            mstore(0, 1)
            return(31, 1)
        }
    }
}

contract STRConOracleMock {
    address public immutable VAULT;
    address public immutable STRCON;
    ISyntheticSharesOracle public immutable syntheticSharesOracle;
    uint256 public price = 100e8;
    uint8 public priceDecimals = 8;
    bool public priceShouldRevert;
    bool public decimalsShouldRevert;

    constructor(address vault, address strcon, ISyntheticSharesOracle syntheticSharesOracle_) {
        (VAULT, STRCON) = (vault, strcon);
        syntheticSharesOracle = syntheticSharesOracle_;
    }

    function set(uint256 price_, uint8 decimals_, bool priceRevert_, bool decimalsRevert_) external {
        (price, priceDecimals, priceShouldRevert, decimalsShouldRevert) =
        (price_, decimals_, priceRevert_, decimalsRevert_);
    }

    function decimals() external view returns (uint8) {
        require(!decimalsShouldRevert, "decimals revert");
        return priceDecimals;
    }

    function getPrice() external view returns (uint256) {
        require(!priceShouldRevert, "price revert");
        return price;
    }
}

contract STRConModuleMock {
    address public immutable VAULT;
    address public immutable ASSET;
    address public asset;
    address public oracle;

    constructor(address vault, address asset_, address oracle_) {
        (VAULT, ASSET, asset, oracle) = (vault, asset_, asset_, oracle_);
    }

    function setAsset(address value) external {
        asset = value;
    }

    function setOracle(address value) external {
        oracle = value;
    }
}

contract CanonicalFeedMock is IPriceOracle {
    uint8 public immutable override decimals = 8;
    uint80 public roundId = 1;
    int256 public answer = 100e8;
    uint256 public updatedAt;
    uint80 public answeredInRound = 1;

    constructor() {
        updatedAt = block.timestamp;
    }

    function set(int256 answer_, uint256 updatedAt_, uint80 answeredInRound_) external {
        (answer, updatedAt, answeredInRound) = (answer_, updatedAt_, answeredInRound_);
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (roundId, answer, updatedAt, updatedAt, answeredInRound);
    }
}

contract CanonicalSyntheticSharesMock is ISyntheticSharesOracle {
    uint256 public sValue = 1e18;
    bool public paused;
    bool public shouldRevert;

    function set(uint256 value, bool paused_) external {
        (sValue, paused) = (value, paused_);
    }

    function setShouldRevert(bool value) external {
        shouldRevert = value;
    }

    function getSValue(address) external view returns (uint256, bool) {
        require(!shouldRevert, "sValue revert");
        return (sValue, paused);
    }
}

contract SUSDatSTRCIntegrationTest is Test {
    uint32 private constant EXPIRY = 1_799_884_800; // 2027-01-14 00:00:00 UTC
    uint256 private constant PINNED_MAINNET_BLOCK = 25_892_118;
    address private constant MAINNET_YIELD_FACTORY_V6 = 0x3E6EBa46AbC5ab18ED95F6667d8B2fd4020E4637;
    address private constant MAINNET_MARKET_FACTORY_V7 = 0x6d247b1c044fA1E22e6B04fA9F71Baf99EB29A9f;
    uint256 private constant ASSET_SCALE = 100;

    struct MarketSnapshot {
        bytes32 storageHash;
        uint256 marketSy;
        uint256 marketPt;
        uint256 marketLpSupply;
        uint256 userSy;
        uint256 userPt;
        uint256 userLp;
        uint256 ytSy;
        uint256 sySupply;
        uint256 ptSupply;
        uint256 ytSupply;
        uint256 pyIndexStored;
    }

    TokenMock private usdat;
    TokenMock private strcon;
    SUSDatMock private susdat;
    CanonicalSyntheticSharesMock private synthetic;
    STRConOracleMock private strconOracle;
    STRConModuleMock private strconModule;
    STRCReferenceMetadata private descriptor;
    SUSDatSTRCExchangeRateOracle private rateOracle;

    function setUp() public {
        usdat = new TokenMock("USDat", "USDat", 6);
        strcon = new TokenMock("STRCon", "STRCon", 18);
        susdat = new SUSDatMock(address(usdat));
        synthetic = new CanonicalSyntheticSharesMock();
        strconOracle = new STRConOracleMock(address(susdat), address(strcon), synthetic);
        strconModule = new STRConModuleMock(address(susdat), address(strcon), address(strconOracle));
        susdat.setStrconModule(address(strconModule));
        descriptor = new STRCReferenceMetadata();
        rateOracle = new SUSDatSTRCExchangeRateOracle(address(susdat), address(usdat), address(strcon));
    }

    function test_metadataDescriptorIsExplicitlyNonTransferableAndHasNoSupply() public {
        assertEq(descriptor.name(), "STRC Accounting Reference");
        assertEq(descriptor.symbol(), "STRC");
        assertEq(descriptor.decimals(), 18);
        assertEq(descriptor.totalSupply(), 0);
        assertEq(descriptor.balanceOf(address(this)), 0);
        assertEq(descriptor.allowance(address(this), address(1)), 0);

        vm.expectRevert(STRCReferenceMetadata.NonTransferableReference.selector);
        assertFalse(descriptor.transfer(address(1), 0));
        vm.expectRevert(STRCReferenceMetadata.NonTransferableReference.selector);
        descriptor.approve(address(1), 0);
        vm.expectRevert(STRCReferenceMetadata.NonTransferableReference.selector);
        assertFalse(descriptor.transferFrom(address(this), address(1), 0));
    }

    function test_constructorPinsEconomicIdentitiesAndStockSYMetadata() public {
        assertEq(address(rateOracle.SUSDat()), address(susdat));
        assertEq(rateOracle.USDAT(), address(usdat));
        assertEq(rateOracle.STRCON(), address(strcon));

        PendleERC20WithOracleSY sy = _deploySY();
        assertEq(sy.yieldToken(), address(susdat));
        assertEq(sy.underlyingAsset(), address(descriptor));
        assertEq(sy.exchangeRateOracle(), address(rateOracle));

        (IStandardizedYield.AssetType kind, address assetAddress, uint8 assetDecimals) = sy.assetInfo();
        assertEq(uint256(kind), uint256(IStandardizedYield.AssetType.TOKEN));
        assertEq(assetAddress, address(descriptor));
        assertEq(assetDecimals, 18);
    }

    function test_constructorRejectsEveryZeroAndCodelessEconomicIdentity() public {
        address[3] memory dependencies = [address(susdat), address(usdat), address(strcon)];

        for (uint256 i; i < dependencies.length; ++i) {
            address valid = dependencies[i];

            dependencies[i] = address(0);
            vm.expectRevert(SUSDatSTRCExchangeRateOracle.InvalidConfiguration.selector);
            _newOracle(dependencies);

            dependencies[i] = address(uint160(0xBEEF + i));
            vm.expectRevert(SUSDatSTRCExchangeRateOracle.InvalidConfiguration.selector);
            _newOracle(dependencies);

            dependencies[i] = valid;
        }
    }

    function test_constructorRejectsWrongDecimalsAndAssetBinding() public {
        SUSDatWrongDecimalsMock wrongSusdatDecimals = new SUSDatWrongDecimalsMock(address(usdat));
        vm.expectRevert(SUSDatSTRCExchangeRateOracle.InvalidConfiguration.selector);
        new SUSDatSTRCExchangeRateOracle(address(wrongSusdatDecimals), address(usdat), address(strcon));

        TokenMock wrongUsdatDecimals = new TokenMock("wrong", "wrong", 18);
        SUSDatMock wrongAssetSusdat = new SUSDatMock(address(wrongUsdatDecimals));
        STRConOracleMock wrongAssetOracle = new STRConOracleMock(address(wrongAssetSusdat), address(strcon), synthetic);
        STRConModuleMock wrongAssetModule =
            new STRConModuleMock(address(wrongAssetSusdat), address(strcon), address(wrongAssetOracle));
        wrongAssetSusdat.setStrconModule(address(wrongAssetModule));
        vm.expectRevert(SUSDatSTRCExchangeRateOracle.InvalidConfiguration.selector);
        new SUSDatSTRCExchangeRateOracle(address(wrongAssetSusdat), address(wrongUsdatDecimals), address(strcon));

        TokenMock wrongDecimals = new TokenMock("wrong", "wrong", 17);
        vm.expectRevert(SUSDatSTRCExchangeRateOracle.InvalidConfiguration.selector);
        new SUSDatSTRCExchangeRateOracle(address(susdat), address(usdat), address(wrongDecimals));
    }

    function test_constructorRejectsMalformedOrCrossSystemActiveGraph() public {
        TokenMock otherUsdat = new TokenMock("other", "other", 6);

        vm.expectRevert(SUSDatSTRCExchangeRateOracle.InvalidConfiguration.selector);
        new SUSDatSTRCExchangeRateOracle(address(susdat), address(otherUsdat), address(strcon));

        susdat.setStrconModule(address(0));
        vm.expectRevert(SUSDatSTRCExchangeRateOracle.InvalidConfiguration.selector);
        _newOracle();

        susdat.setStrconModule(address(0xBEEF));
        vm.expectRevert(SUSDatSTRCExchangeRateOracle.InvalidConfiguration.selector);
        _newOracle();

        STRConModuleMock wrongAssetModule =
            new STRConModuleMock(address(susdat), address(otherUsdat), address(strconOracle));
        susdat.setStrconModule(address(wrongAssetModule));
        vm.expectRevert(SUSDatSTRCExchangeRateOracle.InvalidConfiguration.selector);
        _newOracle();

        STRConModuleMock wrongVaultModule =
            new STRConModuleMock(address(otherUsdat), address(strcon), address(strconOracle));
        susdat.setStrconModule(address(wrongVaultModule));
        vm.expectRevert(SUSDatSTRCExchangeRateOracle.InvalidConfiguration.selector);
        _newOracle();

        STRConModuleMock inconsistentAssetModule =
            new STRConModuleMock(address(susdat), address(strcon), address(strconOracle));
        inconsistentAssetModule.setAsset(address(otherUsdat));
        susdat.setStrconModule(address(inconsistentAssetModule));
        vm.expectRevert(SUSDatSTRCExchangeRateOracle.InvalidConfiguration.selector);
        _newOracle();

        strconModule.setOracle(address(0));
        susdat.setStrconModule(address(strconModule));
        vm.expectRevert(SUSDatSTRCExchangeRateOracle.InvalidConfiguration.selector);
        _newOracle();

        strconModule.setOracle(address(0xBEEF));
        vm.expectRevert(SUSDatSTRCExchangeRateOracle.InvalidConfiguration.selector);
        _newOracle();

        STRConOracleMock wrongOracle = new STRConOracleMock(address(otherUsdat), address(strcon), synthetic);
        strconModule.setOracle(address(wrongOracle));
        vm.expectRevert(SUSDatSTRCExchangeRateOracle.InvalidConfiguration.selector);
        _newOracle();

        TokenMock otherStrcon = new TokenMock("other", "other", 18);
        STRConOracleMock wrongTokenOracle = new STRConOracleMock(address(susdat), address(otherStrcon), synthetic);
        strconModule.setOracle(address(wrongTokenOracle));
        vm.expectRevert(SUSDatSTRCExchangeRateOracle.InvalidConfiguration.selector);
        _newOracle();

        STRConOracleMock wrongDecimalsOracle = new STRConOracleMock(address(susdat), address(strcon), synthetic);
        wrongDecimalsOracle.set(100e8, 7, false, false);
        strconModule.setOracle(address(wrongDecimalsOracle));
        vm.expectRevert(SUSDatSTRCExchangeRateOracle.InvalidConfiguration.selector);
        _newOracle();

        STRConOracleMock noSharesOracle =
            new STRConOracleMock(address(susdat), address(strcon), ISyntheticSharesOracle(address(0)));
        strconModule.setOracle(address(noSharesOracle));
        vm.expectRevert(SUSDatSTRCExchangeRateOracle.InvalidConfiguration.selector);
        _newOracle();
    }

    function test_constructorRejectsMalformedStructureButAllowsTransientUpstreamFailure() public {
        strconOracle.set(100e8, 7, false, false);
        vm.expectRevert(SUSDatSTRCExchangeRateOracle.InvalidConfiguration.selector);
        _newOracle();

        strconOracle.set(0, 8, false, false);
        SUSDatSTRCExchangeRateOracle candidate = _newOracle();
        vm.expectRevert(SUSDatSTRCExchangeRateOracle.InvalidRate.selector);
        candidate.getExchangeRate();

        strconOracle.set(100e8, 8, true, false);
        candidate = _newOracle();
        vm.expectRevert(bytes("price revert"));
        candidate.getExchangeRate();

        strconOracle.set(100e8, 8, false, false);
        synthetic.set(0, false);
        candidate = _newOracle();
        vm.expectRevert(SUSDatSTRCExchangeRateOracle.InvalidRate.selector);
        candidate.getExchangeRate();

        synthetic.set(1e18, true);
        candidate = _newOracle();
        vm.expectRevert(SUSDatSTRCExchangeRateOracle.SyntheticAssetPaused.selector);
        candidate.getExchangeRate();

        synthetic.set(1e18, false);
        synthetic.setShouldRevert(true);
        candidate = _newOracle();
        vm.expectRevert(bytes("sValue revert"));
        candidate.getExchangeRate();

        MalformedDependency malformed = new MalformedDependency();
        vm.expectRevert();
        new SUSDatSTRCExchangeRateOracle(address(malformed), address(usdat), address(strcon));
    }

    function test_exactRateDirectionDecimalsAndWorkedExample() public {
        // STRCon = $102.50 and sValue = 1.025, so underlying STRC = $100.
        // 10.25 USDat per sUSDat / $100 per STRC = 0.1025 STRC per sUSDat.
        susdat.setAssetsPerShare(10_250_000);
        synthetic.set(1.025e18, false);
        strconOracle.set(10_250_000_000, 8, false, false);
        assertEq(rateOracle.getExchangeRate(), 0.1025e18);

        uint256 oneSyInAssetUnits = Math.mulDiv(1e18, rateOracle.getExchangeRate(), 1e18);
        assertEq(oneSyInAssetUnits, 0.1025e18);
    }

    function test_floorRoundingAndCeilingDifferenceAtSingleUnitBoundary() public {
        susdat.setAssetsPerShare(1);
        synthetic.set(1e18, false);
        strconOracle.set(3, 8, false, false);
        uint256 numerator = ASSET_SCALE * 1e18;
        assertEq(rateOracle.getExchangeRate(), numerator / 3);
        assertEq(Math.mulDiv(ASSET_SCALE, 1e18, 3, Math.Rounding.Ceil), rateOracle.getExchangeRate() + 1);
        assertEq(rateOracle.getExchangeRate() * 3, numerator - 1);
    }

    function testFuzz_fullPrecisionFormulaRoundsDown(uint256 assets, uint256 sValue, uint256 price) public {
        assets = bound(assets, 1, type(uint256).max / ASSET_SCALE);
        sValue = bound(sValue, 1, type(uint256).max);
        uint256 scaledAssets = assets * ASSET_SCALE;
        uint256 minimumNonOverflowingPrice =
            Math.max(1, Math.mulDiv(scaledAssets, sValue, type(uint256).max, Math.Rounding.Ceil));
        price = bound(price, minimumNonOverflowingPrice, type(uint256).max);
        susdat.setAssetsPerShare(assets);
        synthetic.set(sValue, false);
        strconOracle.set(price, 8, false, false);

        uint256 expected = Math.mulDiv(scaledAssets, sValue, price, Math.Rounding.Floor);
        if (expected == 0) {
            vm.expectRevert(SUSDatSTRCExchangeRateOracle.InvalidRate.selector);
            rateOracle.getExchangeRate();
        } else {
            assertEq(rateOracle.getExchangeRate(), expected);
        }
    }

    function test_fullPrecisionHandlesOverflowingIntermediate() public {
        uint256 assets = type(uint256).max / ASSET_SCALE;
        susdat.setAssetsPerShare(assets);
        synthetic.set(100, false);
        strconOracle.set(100, 8, false, false);

        assertGt(assets, type(uint256).max / (100 * ASSET_SCALE));
        assertEq(rateOracle.getExchangeRate(), assets * ASSET_SCALE);
    }

    function test_overflowBoundariesRevertExplicitly() public {
        susdat.setAssetsPerShare(type(uint256).max);
        vm.expectRevert(SUSDatSTRCExchangeRateOracle.RateOverflow.selector);
        rateOracle.getExchangeRate();

        uint256 assets = type(uint256).max / ASSET_SCALE;
        susdat.setAssetsPerShare(assets);
        synthetic.set(101, false);
        strconOracle.set(100, 8, false, false);
        vm.expectRevert(stdError.arithmeticError);
        rateOracle.getExchangeRate();
    }

    function test_runtimeFailuresRevertRatherThanReturnPlausibleRate() public {
        susdat.setAssetsPerShare(0);
        vm.expectRevert(SUSDatSTRCExchangeRateOracle.InvalidRate.selector);
        rateOracle.getExchangeRate();

        susdat.setAssetsPerShare(10e6);
        strconOracle.set(0, 8, false, false);
        vm.expectRevert(SUSDatSTRCExchangeRateOracle.InvalidRate.selector);
        rateOracle.getExchangeRate();

        strconOracle.set(100e8, 8, true, false);
        vm.expectRevert(bytes("price revert"));
        rateOracle.getExchangeRate();

        strconOracle.set(100e8, 8, false, false);
        susdat.setConversionShouldRevert(true);
        vm.expectRevert(SUSDatMock.ConversionReverted.selector);
        rateOracle.getExchangeRate();

        susdat.setConversionShouldRevert(false);
        synthetic.set(1e18, true);
        vm.expectRevert(SUSDatSTRCExchangeRateOracle.SyntheticAssetPaused.selector);
        rateOracle.getExchangeRate();

        synthetic.set(0, false);
        vm.expectRevert(SUSDatSTRCExchangeRateOracle.InvalidRate.selector);
        rateOracle.getExchangeRate();

        synthetic.set(1e18, false);
        synthetic.setShouldRevert(true);
        vm.expectRevert(bytes("sValue revert"));
        rateOracle.getExchangeRate();

        synthetic.setShouldRevert(false);
        synthetic.set(1e18, false);
        strconModule.setOracle(address(usdat));
        vm.expectRevert();
        rateOracle.getExchangeRate();

        strconModule.setOracle(address(strconOracle));
        STRConModuleMock wrongModule = new STRConModuleMock(address(usdat), address(strcon), address(strconOracle));
        susdat.setStrconModule(address(wrongModule));
        vm.expectRevert(SUSDatSTRCExchangeRateOracle.OracleBindingChanged.selector);
        rateOracle.getExchangeRate();
    }

    function test_compatibleOracleAndModuleRotationsRemainLiveAndCoherent() public {
        susdat.setAssetsPerShare(12e6);
        assertEq(rateOracle.getExchangeRate(), 0.12e18);

        CanonicalSyntheticSharesMock replacementSynthetic = new CanonicalSyntheticSharesMock();
        replacementSynthetic.set(1.2e18, false);
        STRConOracleMock replacementOracle =
            new STRConOracleMock(address(susdat), address(strcon), replacementSynthetic);
        replacementOracle.set(120e8, 8, false, false);
        strconModule.setOracle(address(replacementOracle));

        // A, P, and S are read from one active graph. The retired synthetic
        // oracle no longer affects the rate.
        assertEq(rateOracle.getExchangeRate(), 0.12e18);
        synthetic.set(2e18, false);
        assertEq(rateOracle.getExchangeRate(), 0.12e18);
        replacementSynthetic.set(1.3e18, false);
        assertEq(rateOracle.getExchangeRate(), 0.13e18);

        CanonicalSyntheticSharesMock nextSynthetic = new CanonicalSyntheticSharesMock();
        nextSynthetic.set(1.5e18, false);
        STRConOracleMock nextOracle = new STRConOracleMock(address(susdat), address(strcon), nextSynthetic);
        nextOracle.set(150e8, 8, false, false);
        STRConModuleMock replacementModule = new STRConModuleMock(address(susdat), address(strcon), address(nextOracle));
        susdat.setStrconModule(address(replacementModule));

        assertEq(rateOracle.getExchangeRate(), 0.12e18);
        replacementSynthetic.set(2e18, false);
        assertEq(rateOracle.getExchangeRate(), 0.12e18);
    }

    function test_incompatibleRuntimeGraphChangesFailClosed() public {
        TokenMock other = new TokenMock("other", "other", 18);
        STRConModuleMock wrongAssetModule = new STRConModuleMock(address(susdat), address(other), address(strconOracle));
        susdat.setStrconModule(address(wrongAssetModule));
        vm.expectRevert(SUSDatSTRCExchangeRateOracle.OracleBindingChanged.selector);
        rateOracle.getExchangeRate();

        strconModule.setAsset(address(other));
        susdat.setStrconModule(address(strconModule));
        vm.expectRevert(SUSDatSTRCExchangeRateOracle.OracleBindingChanged.selector);
        rateOracle.getExchangeRate();
        strconModule.setAsset(address(strcon));

        STRConOracleMock wrongVaultOracle = new STRConOracleMock(address(other), address(strcon), synthetic);
        strconModule.setOracle(address(wrongVaultOracle));
        susdat.setStrconModule(address(strconModule));
        vm.expectRevert(SUSDatSTRCExchangeRateOracle.OracleBindingChanged.selector);
        rateOracle.getExchangeRate();

        STRConOracleMock wrongAssetOracle = new STRConOracleMock(address(susdat), address(other), synthetic);
        strconModule.setOracle(address(wrongAssetOracle));
        vm.expectRevert(SUSDatSTRCExchangeRateOracle.OracleBindingChanged.selector);
        rateOracle.getExchangeRate();

        STRConOracleMock wrongDecimalsOracle = new STRConOracleMock(address(susdat), address(strcon), synthetic);
        wrongDecimalsOracle.set(100e8, 7, false, false);
        strconModule.setOracle(address(wrongDecimalsOracle));
        vm.expectRevert(SUSDatSTRCExchangeRateOracle.OracleBindingChanged.selector);
        rateOracle.getExchangeRate();

        STRConOracleMock noSharesOracle =
            new STRConOracleMock(address(susdat), address(strcon), ISyntheticSharesOracle(address(0)));
        strconModule.setOracle(address(noSharesOracle));
        vm.expectRevert(SUSDatSTRCExchangeRateOracle.OracleBindingChanged.selector);
        rateOracle.getExchangeRate();
    }

    function test_canonicalOracleInvalidPausedStaleFutureAndDivergentInputsPropagate() public {
        vm.warp(30 days);
        CanonicalFeedMock primary = new CanonicalFeedMock();
        CanonicalFeedMock referenceFeed = new CanonicalFeedMock();
        CanonicalSyntheticSharesMock canonicalSynthetic = new CanonicalSyntheticSharesMock();
        STRConPriceOracle canonical =
            new STRConPriceOracle(address(susdat), address(strcon), canonicalSynthetic, primary, referenceFeed, 500);
        STRConModule canonicalModule = new STRConModule(address(susdat), address(strcon), canonical);
        susdat.setStrconModule(address(canonicalModule));
        SUSDatSTRCExchangeRateOracle adapter =
            new SUSDatSTRCExchangeRateOracle(address(susdat), address(usdat), address(strcon));
        assertGt(adapter.getExchangeRate(), 0);

        // Primary-feed age is not independently bounded. A valid old primary
        // round is accepted while the reference is fresh and within deviation.
        primary.set(100e8, block.timestamp - 7 days, 1);
        referenceFeed.set(100e8, block.timestamp, 1);
        assertGt(adapter.getExchangeRate(), 0);

        primary.set(19e8, block.timestamp, 1);
        referenceFeed.set(19e8, block.timestamp, 1);
        vm.expectRevert(STRConPriceOracle.UnderlyingPriceOutOfBounds.selector);
        adapter.getExchangeRate();

        primary.set(151e8, block.timestamp, 1);
        referenceFeed.set(151e8, block.timestamp, 1);
        vm.expectRevert(STRConPriceOracle.UnderlyingPriceOutOfBounds.selector);
        adapter.getExchangeRate();

        primary.set(0, block.timestamp, 1);
        vm.expectRevert(STRConPriceOracle.InvalidOracleRound.selector);
        adapter.getExchangeRate();

        primary.set(-1, block.timestamp, 1);
        vm.expectRevert(STRConPriceOracle.InvalidOracleRound.selector);
        adapter.getExchangeRate();

        primary.set(100e8, block.timestamp + 1, 1);
        vm.expectRevert(STRConPriceOracle.InvalidOracleRound.selector);
        adapter.getExchangeRate();

        primary.set(100e8, block.timestamp, 0);
        vm.expectRevert(STRConPriceOracle.InvalidOracleRound.selector);
        adapter.getExchangeRate();

        primary.set(100e8, block.timestamp, 1);
        referenceFeed.set(100e8, block.timestamp - 26 hours - 1, 1);
        vm.expectRevert(STRConPriceOracle.StaleReferencePrice.selector);
        adapter.getExchangeRate();

        referenceFeed.set(100e8, block.timestamp, 1);
        canonicalSynthetic.set(1e18, true);
        vm.expectRevert(STRConPriceOracle.AssetPaused.selector);
        adapter.getExchangeRate();

        canonicalSynthetic.set(0, false);
        vm.expectRevert(STRConPriceOracle.InvalidSValue.selector);
        adapter.getExchangeRate();

        canonicalSynthetic.set(1e18, false);
        referenceFeed.set(90e8, block.timestamp, 1);
        vm.expectRevert(STRConPriceOracle.FeedDeviation.selector);
        adapter.getExchangeRate();
    }

    function test_STRCSpotMovementCancelsWhileSValueAndAdditionalBackingAreYield() public {
        susdat.setAssetsPerShare(10e6);
        strconOracle.set(100e8, 8, false, false);
        uint256 initialRate = rateOracle.getExchangeRate();

        // A pure 20% underlying STRC spot move raises STRCon/USD and STRCon-backed NAV equally.
        susdat.setAssetsPerShare(12e6);
        strconOracle.set(120e8, 8, false, false);
        assertEq(rateOracle.getExchangeRate(), initialRate);

        // A 1% dividend reinvestment raises sValue and the underlying-STRC rate by exactly 1%.
        synthetic.set(1.01e18, false);
        assertEq(rateOracle.getExchangeRate(), initialRate * 101 / 100);

        // Additional STRCon-backed value per share is also relative outperformance/yield.
        susdat.setAssetsPerShare(13_200_000);
        assertEq(rateOracle.getExchangeRate(), initialRate * 1111 / 1000);
    }

    function test_exDividendDropPreservesSTRConValueButProducesUnderlyingSTRCYield() public {
        susdat.setAssetsPerShare(100e6);
        strconOracle.set(100e8, 8, false, false);
        uint256 initialRate = rateOracle.getExchangeRate();

        // $1 dividend: STRC falls from $100 to $99 while sValue rises to 100/99.
        // STRCon and sUSDat total-return value remain $100, but one STRCon now
        // represents more underlying STRC shares, which is the intended YT yield.
        uint256 postDividendSValue = uint256(100e18) / 99;
        synthetic.set(postDividendSValue, false);
        assertEq(strconOracle.price(), 100e8);
        assertEq(susdat.assetsPerShare(), 100e6);
        assertGt(rateOracle.getExchangeRate(), initialRate);
        assertEq(
            rateOracle.getExchangeRate(),
            Math.mulDiv(100e6 * ASSET_SCALE, postDividendSValue, 100e8, Math.Rounding.Floor)
        );
    }

    function test_nonSTRConReserveCreatesResidualSTRCSpotBasis() public {
        susdat.setAssetsPerShare(100e6);
        strconOracle.set(100e8, 8, false, false);
        uint256 initialRate = rateOracle.getExchangeRate();

        // Model 90% STRCon backing and 10% USDat cash. A 20% STRC move changes
        // NAV by only 18%, so cancellation is intentionally imperfect.
        susdat.setAssetsPerShare(118e6);
        strconOracle.set(120e8, 8, false, false);
        assertLt(rateOracle.getExchangeRate(), initialRate);
    }

    function test_conversionValueIncreaseIsReportedAsYieldAndRemainsUpstreamRisk() public {
        susdat.setAssetsPerShare(10e6);
        uint256 initialRate = rateOracle.getExchangeRate();

        // The adapter intentionally cannot distinguish earned value from a donation or NAV defect.
        susdat.setAssetsPerShare(11e6);
        assertEq(rateOracle.getExchangeRate(), initialRate * 11 / 10);
    }

    function test_stockSYOnlyAcceptsAndRedeemsSUSDatWithExactCustody() public {
        PendleERC20WithOracleSY sy = _deploySY();
        TokenMock other = new TokenMock("other", "other", 18);

        address[] memory tokensIn = sy.getTokensIn();
        address[] memory tokensOut = sy.getTokensOut();
        assertEq(tokensIn.length, 1);
        assertEq(tokensOut.length, 1);
        assertEq(tokensIn[0], address(susdat));
        assertEq(tokensOut[0], address(susdat));
        assertTrue(sy.isValidTokenIn(address(susdat)));
        assertTrue(sy.isValidTokenOut(address(susdat)));
        assertFalse(sy.isValidTokenIn(address(other)));
        assertFalse(sy.isValidTokenOut(address(other)));
        assertEq(sy.previewDeposit(address(susdat), 7e18), 7e18);
        assertEq(sy.previewRedeem(address(susdat), 7e18), 7e18);

        susdat.mint(address(this), 10e18);
        susdat.approve(address(sy), 10e18);
        vm.expectRevert(abi.encodeWithSelector(SYErrors.SYInvalidTokenIn.selector, address(other)));
        sy.deposit(address(this), address(other), 1e18, 0);
        vm.expectRevert(abi.encodeWithSelector(SYErrors.SYInvalidTokenOut.selector, address(other)));
        sy.redeem(address(this), 1e18, address(other), 0, false);

        assertEq(sy.deposit(address(this), address(susdat), 10e18, 10e18), 10e18);
        assertEq(susdat.balanceOf(address(sy)), 10e18);
        assertEq(sy.totalSupply(), 10e18);
        assertEq(sy.redeem(address(this), 10e18, address(susdat), 10e18, false), 10e18);
        assertEq(susdat.balanceOf(address(sy)), 0);
        assertEq(sy.totalSupply(), 0);
        assertEq(susdat.balanceOf(address(this)), 10e18);
    }

    function test_pinnedForkExactPendlePostV2LifecycleAndNoRoundingExtraction() public {
        if (!vm.envOr("RUN_PENDLE_FORK", false)) {
            vm.skip(true, "set RUN_PENDLE_FORK=true to run pinned Pendle lifecycle");
            return;
        }
        require(vm.envExists("RPC_URL"), "RPC_URL is required");
        vm.createSelectFork(vm.envString("RPC_URL"), PINNED_MAINNET_BLOCK);
        setUp();

        PendleERC20WithOracleSY sy = _deploySY();
        (address ptAddress, address ytAddress) =
            IPYieldContractFactoryHarness(MAINNET_YIELD_FACTORY_V6).createYieldContract(address(sy), EXPIRY, false);
        IPPrincipalToken pt = IPPrincipalToken(ptAddress);
        IPYieldToken yt = IPYieldToken(ytAddress);

        assertEq(descriptor.decimals(), 18);
        assertEq(pt.decimals(), 18);
        assertEq(yt.decimals(), 18);

        susdat.mint(address(this), 100e18);
        susdat.approve(address(sy), type(uint256).max);
        sy.deposit(address(this), address(susdat), 60e18, 60e18);

        _assertRepeatedRoundTripsDoNotExtract(sy, pt, yt, ytAddress);

        assertTrue(sy.transfer(ytAddress, 20e18));
        yt.mintPY(address(this), address(this));
        _assertRateAndHighWaterEconomics(yt);

        uint256 paired = pt.balanceOf(address(this)) / 2;
        uint256 expectedSyBeforeExpiry = Math.mulDiv(paired, 1e18, yt.pyIndexCurrent(), Math.Rounding.Floor);
        assertTrue(pt.transfer(ytAddress, paired));
        assertTrue(yt.transfer(ytAddress, paired));
        assertEq(yt.redeemPY(address(this)), expectedSyBeforeExpiry);

        vm.warp(EXPIRY);
        vm.roll(block.number + 1);
        uint256 ptAtExpiry = pt.balanceOf(address(this));
        uint256 expectedSyAtExpiry = Math.mulDiv(ptAtExpiry, 1e18, yt.pyIndexCurrent(), Math.Rounding.Floor);
        assertTrue(pt.transfer(ytAddress, ptAtExpiry));
        uint256 redeemedSy = yt.redeemPY(address(this));
        assertEq(redeemedSy, expectedSyAtExpiry);

        uint256 sUSDatBefore = susdat.balanceOf(address(this));
        sy.redeem(address(this), redeemedSy, address(susdat), redeemedSy, false);
        assertEq(susdat.balanceOf(address(this)) - sUSDatBefore, redeemedSy);
    }

    function test_pinnedForkExactPTSYAndSUSDatBalanceEquationsAtMaturity() public {
        if (!vm.envOr("RUN_PENDLE_FORK", false)) {
            vm.skip(true, "set RUN_PENDLE_FORK=true to run pinned Pendle lifecycle");
            return;
        }
        require(vm.envExists("RPC_URL"), "RPC_URL is required");
        vm.createSelectFork(vm.envString("RPC_URL"), PINNED_MAINNET_BLOCK);
        setUp();

        PendleERC20WithOracleSY sy = _deploySY();
        (address ptAddress, address ytAddress) =
            IPYieldContractFactoryHarness(MAINNET_YIELD_FACTORY_V6).createYieldContract(address(sy), EXPIRY, false);
        IPPrincipalToken pt = IPPrincipalToken(ptAddress);
        IPYieldToken yt = IPYieldToken(ytAddress);

        assertEq(descriptor.decimals(), 18);
        assertEq(pt.decimals(), descriptor.decimals());
        assertEq(yt.decimals(), descriptor.decimals());

        susdat.mint(address(this), 20e18);
        susdat.approve(address(sy), 20e18);
        assertEq(sy.deposit(address(this), address(susdat), 20e18, 20e18), 20e18);
        assertEq(susdat.balanceOf(address(sy)), 20e18);
        assertEq(sy.balanceOf(address(this)), 20e18);

        {
            uint256 initialIndex = rateOracle.getExchangeRate();
            assertEq(initialIndex, 0.1e18);
            assertTrue(sy.transfer(ytAddress, 20e18));
            uint256 expectedPY = Math.mulDiv(20e18, initialIndex, 1e18, Math.Rounding.Floor);
            assertEq(yt.mintPY(address(this), address(this)), expectedPY);
            // 20 SY at 0.1 underlying STRC per SY produces exactly 2 STRC,
            // represented as 2e18 base units by the selected convention.
            assertEq(expectedPY, 2e18);
            assertEq(expectedPY / 10 ** pt.decimals(), 2);
            assertEq(pt.balanceOf(address(this)), expectedPY);
            assertEq(yt.balanceOf(address(this)), expectedPY);
        }
        assertEq(sy.balanceOf(ytAddress), 20e18);
        assertEq(sy.balanceOf(address(this)), 0);

        {
            uint256 index = rateOracle.getExchangeRate();
            uint256 expectedSy = Math.mulDiv(1e18, 1e18, index, Math.Rounding.Floor);
            assertEq(1e18 / 10 ** pt.decimals(), 1);
            assertTrue(pt.transfer(ytAddress, 1e18));
            assertTrue(yt.transfer(ytAddress, 1e18));
            assertEq(yt.redeemPY(address(this)), expectedSy);
            assertEq(expectedSy, 10e18);
        }
        assertEq(pt.balanceOf(address(this)), 1e18);
        assertEq(yt.balanceOf(address(this)), 1e18);
        assertEq(sy.balanceOf(address(this)), 10e18);
        assertEq(sy.balanceOf(ytAddress), 10e18);

        vm.warp(EXPIRY);
        vm.roll(block.number + 1);
        {
            uint256 expiryIndex = yt.pyIndexCurrent();
            uint256 expectedSy = Math.mulDiv(1e18, 1e18, expiryIndex, Math.Rounding.Floor);
            assertTrue(pt.transfer(ytAddress, 1e18));
            assertEq(yt.redeemPY(address(this)), expectedSy);
            assertEq(expectedSy, 10e18);
        }
        assertEq(pt.balanceOf(address(this)), 0);
        assertEq(pt.totalSupply(), 0);
        assertEq(yt.balanceOf(address(this)), 1e18);
        assertEq(yt.totalSupply(), 1e18);
        assertEq(sy.balanceOf(address(this)), 20e18);
        assertEq(sy.balanceOf(ytAddress), 0);

        uint256 totalSyOut = sy.balanceOf(address(this));
        assertEq(totalSyOut, 20e18);
        assertEq(sy.redeem(address(this), totalSyOut, address(susdat), totalSyOut, false), totalSyOut);
        assertEq(susdat.balanceOf(address(this)), 20e18);
        assertEq(susdat.balanceOf(address(sy)), 0);
        assertEq(sy.balanceOf(address(this)), 0);
        assertEq(sy.totalSupply(), 0);
    }

    function test_pinnedForkInitializedMarketMintFailsAtomicallyWhenAdapterReverts() public {
        if (!vm.envOr("RUN_PENDLE_FORK", false)) {
            vm.skip(true, "set RUN_PENDLE_FORK=true to run pinned Pendle lifecycle");
            return;
        }
        require(vm.envExists("RPC_URL"), "RPC_URL is required");
        vm.createSelectFork(vm.envString("RPC_URL"), PINNED_MAINNET_BLOCK);
        setUp();

        PendleERC20WithOracleSY sy = _deploySY();
        (address ptAddress, address ytAddress) =
            IPYieldContractFactoryHarness(MAINNET_YIELD_FACTORY_V6).createYieldContract(address(sy), EXPIRY, false);
        IPPrincipalToken pt = IPPrincipalToken(ptAddress);
        IPYieldToken yt = IPYieldToken(ytAddress);
        IPMarket market =
            IPMarket(IPMarketFactoryHarness(MAINNET_MARKET_FACTORY_V7).createNewMarket(ptAddress, 1e18, 1e18, 0));

        susdat.mint(address(this), 30e18);
        susdat.approve(address(sy), 30e18);
        sy.deposit(address(this), address(susdat), 30e18, 30e18);
        assertTrue(sy.transfer(ytAddress, 20e18));
        uint256 mintedPY = yt.mintPY(address(this), address(this));
        assertEq(mintedPY, 2e18);

        assertTrue(sy.transfer(address(market), 4e18));
        assertTrue(pt.transfer(address(market), 0.4e18));
        (uint256 initialLp,,) = market.mint(address(this), 4e18, 0.4e18);
        assertGt(initialLp, 0);
        assertGt(market.totalSupply(), 0);

        assertTrue(sy.transfer(address(market), 1e18));
        assertTrue(pt.transfer(address(market), 0.1e18));
        STRConOracleMock incompatibleOracle = new STRConOracleMock(address(usdat), address(strcon), synthetic);
        strconModule.setOracle(address(incompatibleOracle));
        MarketSnapshot memory beforeFailure = _snapshotMarket(market, sy, pt, yt);

        vm.expectRevert(SUSDatSTRCExchangeRateOracle.OracleBindingChanged.selector);
        market.mint(address(this), 1e18, 0.1e18);

        MarketSnapshot memory afterFailure = _snapshotMarket(market, sy, pt, yt);
        assertEq(keccak256(abi.encode(afterFailure)), keccak256(abi.encode(beforeFailure)));
    }

    function test_pinnedForkCompatibleRotationsPreserveExpiryRedemption() public {
        if (!vm.envOr("RUN_PENDLE_FORK", false)) {
            vm.skip(true, "set RUN_PENDLE_FORK=true to run pinned Pendle lifecycle");
            return;
        }
        require(vm.envExists("RPC_URL"), "RPC_URL is required");
        vm.createSelectFork(vm.envString("RPC_URL"), PINNED_MAINNET_BLOCK);
        setUp();

        PendleERC20WithOracleSY sy = _deploySY();
        (address ptAddress, address ytAddress) =
            IPYieldContractFactoryHarness(MAINNET_YIELD_FACTORY_V6).createYieldContract(address(sy), EXPIRY, false);
        IPPrincipalToken pt = IPPrincipalToken(ptAddress);
        IPYieldTokenHarness yt = IPYieldTokenHarness(ytAddress);

        susdat.mint(address(this), 20e18);
        susdat.approve(address(sy), 20e18);
        assertEq(sy.deposit(address(this), address(susdat), 20e18, 20e18), 20e18);
        assertTrue(sy.transfer(ytAddress, 20e18));
        assertEq(yt.mintPY(address(this), address(this)), 2e18);

        vm.warp(EXPIRY);
        vm.roll(block.number + 1);
        assertTrue(pt.transfer(ytAddress, 1e18));

        STRConOracleMock incompatibleOracle = new STRConOracleMock(address(usdat), address(strcon), synthetic);
        strconModule.setOracle(address(incompatibleOracle));
        bytes32 stateBeforeFailure = _snapshotRedemptionState(sy, pt, yt);

        vm.expectRevert(SUSDatSTRCExchangeRateOracle.OracleBindingChanged.selector);
        yt.redeemPY(address(this));
        assertEq(_snapshotRedemptionState(sy, pt, yt), stateBeforeFailure);

        CanonicalSyntheticSharesMock replacementSynthetic = new CanonicalSyntheticSharesMock();
        STRConOracleMock replacementOracle =
            new STRConOracleMock(address(susdat), address(strcon), replacementSynthetic);
        strconModule.setOracle(address(replacementOracle));

        (uint128 firstIndexBefore,) = yt.postExpiry();
        assertEq(firstIndexBefore, 0);
        assertEq(yt.redeemPY(address(this)), 10e18);
        (uint128 firstIndexAfterRotation,) = yt.postExpiry();
        assertEq(firstIndexAfterRotation, 0.1e18);
        assertEq(pt.totalSupply(), 1e18);
        assertEq(sy.balanceOf(address(this)), 10e18);

        // A compatible module plus oracle plus synthetic-oracle rotation also
        // remains live after Pendle has finalized its first post-expiry index.
        assertTrue(pt.transfer(ytAddress, 1e18));
        CanonicalSyntheticSharesMock nextSynthetic = new CanonicalSyntheticSharesMock();
        STRConOracleMock nextOracle = new STRConOracleMock(address(susdat), address(strcon), nextSynthetic);
        STRConModuleMock replacementModule = new STRConModuleMock(address(susdat), address(strcon), address(nextOracle));
        susdat.setStrconModule(address(replacementModule));

        assertEq(yt.redeemPY(address(this)), 10e18);
        assertEq(pt.totalSupply(), 0);
        assertEq(sy.balanceOf(address(this)), 20e18);
    }

    function test_pinnedForkUpwardRotationErrorPermanentlyRaisesPYHighWater() public {
        if (!vm.envOr("RUN_PENDLE_FORK", false)) {
            vm.skip(true, "set RUN_PENDLE_FORK=true to run pinned Pendle lifecycle");
            return;
        }
        require(vm.envExists("RPC_URL"), "RPC_URL is required");
        vm.createSelectFork(vm.envString("RPC_URL"), PINNED_MAINNET_BLOCK);
        setUp();

        PendleERC20WithOracleSY sy = _deploySY();
        (, address ytAddress) =
            IPYieldContractFactoryHarness(MAINNET_YIELD_FACTORY_V6).createYieldContract(address(sy), EXPIRY, false);
        IPYieldToken yt = IPYieldToken(ytAddress);

        uint256 initialIndex = yt.pyIndexCurrent();
        assertEq(initialIndex, 0.1e18);

        CanonicalSyntheticSharesMock replacementSynthetic = new CanonicalSyntheticSharesMock();
        STRConOracleMock erroneousOracle = new STRConOracleMock(address(susdat), address(strcon), replacementSynthetic);
        erroneousOracle.set(90e8, 8, false, false);
        strconModule.setOracle(address(erroneousOracle));
        uint256 erroneousRate = rateOracle.getExchangeRate();
        assertGt(erroneousRate, initialIndex);
        assertEq(yt.pyIndexCurrent(), erroneousRate);

        STRConOracleMock correctedOracle = new STRConOracleMock(address(susdat), address(strcon), replacementSynthetic);
        strconModule.setOracle(address(correctedOracle));
        assertEq(rateOracle.getExchangeRate(), initialIndex);
        assertEq(yt.pyIndexCurrent(), erroneousRate);
        assertEq(yt.pyIndexStored(), erroneousRate);
    }

    function _assertRepeatedRoundTripsDoNotExtract(
        PendleERC20WithOracleSY sy,
        IPPrincipalToken pt,
        IPYieldToken yt,
        address ytAddress
    ) private {
        uint256 walletBeforeLoops = susdat.balanceOf(address(this));
        for (uint256 i; i < 8; ++i) {
            sy.deposit(address(this), address(susdat), 1e18, 1e18);
            assertTrue(sy.transfer(ytAddress, 1e18));
            uint256 amountPy = yt.mintPY(address(this), address(this));
            assertTrue(pt.transfer(ytAddress, amountPy));
            assertTrue(yt.transfer(ytAddress, amountPy));
            uint256 syOut = yt.redeemPY(address(this));
            assertEq(syOut, 1e18);
            assertEq(sy.redeem(address(this), syOut, address(susdat), syOut, false), 1e18);
        }
        assertEq(susdat.balanceOf(address(this)), walletBeforeLoops);
        assertEq(sy.balanceOf(address(this)), 60e18);
    }

    function _assertRateAndHighWaterEconomics(IPYieldToken yt) private {
        uint256 initialIndex = yt.pyIndexCurrent();

        // Pure underlying STRC price movement changes NAV and denominator proportionally.
        susdat.setAssetsPerShare(12e6);
        strconOracle.set(120e8, 8, false, false);
        vm.roll(block.number + 1);
        assertEq(yt.pyIndexCurrent(), initialIndex);
        (uint256 priceMoveInterest,) = yt.redeemDueInterestAndRewards(address(this), true, false);
        assertEq(priceMoveInterest, 0);

        // Reinvested STRC dividends increase sValue and the underlying-STRC index.
        synthetic.set(1.01e18, false);
        vm.roll(block.number + 1);
        uint256 highIndex = yt.pyIndexCurrent();
        assertGt(highIndex, initialIndex);
        (uint256 yieldInterest,) = yt.redeemDueInterestAndRewards(address(this), true, false);
        assertGt(yieldInterest, 0);

        // A temporary NAV/rate decrease cannot lower Pendle's stored PY high-water mark.
        susdat.setAssetsPerShare(11_000_000);
        vm.roll(block.number + 1);
        assertLt(rateOracle.getExchangeRate(), highIndex);
        assertEq(yt.pyIndexCurrent(), highIndex);
        (uint256 declineInterest,) = yt.redeemDueInterestAndRewards(address(this), true, false);
        assertEq(declineInterest, 0);

        // Recovery below the high-water mark still creates no new interest.
        susdat.setAssetsPerShare(11_900_000);
        vm.roll(block.number + 1);
        assertLt(rateOracle.getExchangeRate(), highIndex);
        assertEq(yt.pyIndexCurrent(), highIndex);
        (uint256 recoveryInterest,) = yt.redeemDueInterestAndRewards(address(this), true, false);
        assertEq(recoveryInterest, 0);

        // Only a rate above the old high-water mark creates new YT interest.
        susdat.setAssetsPerShare(12_100_000);
        vm.roll(block.number + 1);
        assertGt(rateOracle.getExchangeRate(), highIndex);
        assertGt(yt.pyIndexCurrent(), highIndex);
        (uint256 newHighInterest,) = yt.redeemDueInterestAndRewards(address(this), true, false);
        assertGt(newHighInterest, 0);
    }

    function test_pinnedForkSameBlockIndexCaching() public {
        if (!vm.envOr("RUN_PENDLE_FORK", false)) {
            vm.skip(true, "set RUN_PENDLE_FORK=true to run pinned Pendle lifecycle");
            return;
        }
        require(vm.envExists("RPC_URL"), "RPC_URL is required");
        vm.createSelectFork(vm.envString("RPC_URL"), PINNED_MAINNET_BLOCK);
        setUp();

        PendleERC20WithOracleSY sy = _deploySY();
        (, address ytAddress) =
            IPYieldContractFactoryHarness(MAINNET_YIELD_FACTORY_V6).createYieldContract(address(sy), EXPIRY, true);
        IPYieldToken yt = IPYieldToken(ytAddress);

        uint256 initialIndex = yt.pyIndexCurrent();
        synthetic.set(1.01e18, false);
        assertGt(rateOracle.getExchangeRate(), initialIndex);
        assertEq(yt.pyIndexCurrent(), initialIndex);

        vm.roll(block.number + 1);
        assertGt(yt.pyIndexCurrent(), initialIndex);
    }

    function _deploySY() private returns (PendleERC20WithOracleSY sy) {
        PendleERC20WithOracleSY implementation =
            new PendleERC20WithOracleSY(address(susdat), address(descriptor), address(rateOracle), address(0));
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(implementation),
            abi.encodeWithSignature(
                "initialize(string,string,address)", "SY sUSDat-STRC", "SY-sUSDat-STRC", address(this)
            )
        );
        sy = PendleERC20WithOracleSY(payable(address(proxy)));
    }

    function _snapshotMarket(IPMarket market, PendleERC20WithOracleSY sy, IPPrincipalToken pt, IPYieldToken yt)
        private
        view
        returns (MarketSnapshot memory snapshot)
    {
        (
            int128 totalPt,
            int128 totalSy,
            uint96 lastLnImpliedRate,
            uint16 observationIndex,
            uint16 cardinality,
            uint16 next
        ) = market._storage();
        snapshot = MarketSnapshot({
            storageHash: keccak256(
                abi.encode(totalPt, totalSy, lastLnImpliedRate, observationIndex, cardinality, next)
            ),
            marketSy: sy.balanceOf(address(market)),
            marketPt: pt.balanceOf(address(market)),
            marketLpSupply: market.totalSupply(),
            userSy: sy.balanceOf(address(this)),
            userPt: pt.balanceOf(address(this)),
            userLp: market.balanceOf(address(this)),
            ytSy: sy.balanceOf(address(yt)),
            sySupply: sy.totalSupply(),
            ptSupply: pt.totalSupply(),
            ytSupply: yt.totalSupply(),
            pyIndexStored: yt.pyIndexStored()
        });
    }

    function _snapshotRedemptionState(PendleERC20WithOracleSY sy, IPPrincipalToken pt, IPYieldTokenHarness yt)
        private
        view
        returns (bytes32)
    {
        (uint128 firstPYIndex, uint128 treasuryInterest) = yt.postExpiry();
        return keccak256(
            abi.encode(
                pt.balanceOf(address(this)),
                pt.balanceOf(address(yt)),
                pt.totalSupply(),
                yt.balanceOf(address(this)),
                yt.balanceOf(address(yt)),
                yt.totalSupply(),
                sy.balanceOf(address(this)),
                sy.balanceOf(address(yt)),
                sy.totalSupply(),
                yt.pyIndexStored(),
                firstPYIndex,
                treasuryInterest
            )
        );
    }

    function _newOracle(address[3] memory dependencies) private returns (SUSDatSTRCExchangeRateOracle) {
        return new SUSDatSTRCExchangeRateOracle(dependencies[0], dependencies[1], dependencies[2]);
    }

    function _newOracle() private returns (SUSDatSTRCExchangeRateOracle) {
        return new SUSDatSTRCExchangeRateOracle(address(susdat), address(usdat), address(strcon));
    }
}

contract RateStateHandler {
    SUSDatMock public immutable susdat;
    TokenMock public immutable strcon;
    STRConModuleMock public module;
    STRConOracleMock public strconOracle;
    CanonicalSyntheticSharesMock public synthetic;

    constructor(
        SUSDatMock susdat_,
        TokenMock strcon_,
        STRConModuleMock module_,
        STRConOracleMock strconOracle_,
        CanonicalSyntheticSharesMock synthetic_
    ) {
        (susdat, strcon, module, strconOracle, synthetic) = (susdat_, strcon_, module_, strconOracle_, synthetic_);
    }

    function setAssets(uint256 value) external {
        susdat.setAssetsPerShare(bound(value, 1, 1_000_000e6));
    }

    function setPrice(uint256 value) external {
        strconOracle.set(bound(value, 20e8, 150e8), 8, false, false);
    }

    function setSValue(uint256 value) external {
        synthetic.set(bound(value, 0.5e18, 2e18), false);
    }

    function movePriceAndNAVTogether(uint256 factor) external {
        factor = bound(factor, 1, 1e6);
        uint256 price = bound(strconOracle.price(), 20e8, 150e8);
        uint256 assets = bound(susdat.assetsPerShare(), 1, 1_000_000e6);
        if (price <= type(uint256).max / factor && assets <= type(uint256).max / factor) {
            strconOracle.set(price * factor, 8, false, false);
            susdat.setAssetsPerShare(assets * factor);
        }
    }

    function rotateOracle(uint256 price, uint256 sValue) external {
        CanonicalSyntheticSharesMock replacementSynthetic = new CanonicalSyntheticSharesMock();
        replacementSynthetic.set(bound(sValue, 0.5e18, 2e18), false);
        STRConOracleMock replacementOracle =
            new STRConOracleMock(address(susdat), address(strcon), replacementSynthetic);
        replacementOracle.set(bound(price, 20e8, 150e8), 8, false, false);

        module.setOracle(address(replacementOracle));
        (strconOracle, synthetic) = (replacementOracle, replacementSynthetic);
    }

    function rotateModule(uint256 price, uint256 sValue) external {
        CanonicalSyntheticSharesMock replacementSynthetic = new CanonicalSyntheticSharesMock();
        replacementSynthetic.set(bound(sValue, 0.5e18, 2e18), false);
        STRConOracleMock replacementOracle =
            new STRConOracleMock(address(susdat), address(strcon), replacementSynthetic);
        replacementOracle.set(bound(price, 20e8, 150e8), 8, false, false);
        STRConModuleMock replacementModule =
            new STRConModuleMock(address(susdat), address(strcon), address(replacementOracle));

        susdat.setStrconModule(address(replacementModule));
        (module, strconOracle, synthetic) = (replacementModule, replacementOracle, replacementSynthetic);
    }

    function bound(uint256 value, uint256 min, uint256 max) private pure returns (uint256) {
        if (value < min) return min;
        if (value > max) return min + value % (max - min + 1);
        return value;
    }
}

contract SUSDatSTRCRateInvariantTest is Test {
    uint256 private constant ASSET_SCALE = 100;

    SUSDatMock private susdat;
    STRConOracleMock private strconOracle;
    CanonicalSyntheticSharesMock private synthetic;
    SUSDatSTRCExchangeRateOracle private rateOracle;
    STRCReferenceMetadata private descriptor;
    RateStateHandler private handler;

    function setUp() public {
        TokenMock usdat = new TokenMock("USDat", "USDat", 6);
        TokenMock strcon = new TokenMock("STRCon", "STRCon", 18);
        susdat = new SUSDatMock(address(usdat));
        synthetic = new CanonicalSyntheticSharesMock();
        strconOracle = new STRConOracleMock(address(susdat), address(strcon), synthetic);
        STRConModuleMock module = new STRConModuleMock(address(susdat), address(strcon), address(strconOracle));
        susdat.setStrconModule(address(module));
        rateOracle = new SUSDatSTRCExchangeRateOracle(address(susdat), address(usdat), address(strcon));
        descriptor = new STRCReferenceMetadata();
        handler = new RateStateHandler(susdat, strcon, module, strconOracle, synthetic);
        targetContract(address(handler));
    }

    function invariant_rateAlwaysEqualsTheDocumentedStatelessFormula() public view {
        STRConOracleMock activeOracle = handler.strconOracle();
        CanonicalSyntheticSharesMock activeSynthetic = handler.synthetic();
        STRConModuleMock activeModule = handler.module();
        assertEq(activeModule.ASSET(), address(handler.strcon()));
        assertEq(activeModule.asset(), address(handler.strcon()));
        assertEq(descriptor.decimals(), 18);
        uint256 expected = Math.mulDiv(
            susdat.assetsPerShare() * ASSET_SCALE, activeSynthetic.sValue(), activeOracle.price(), Math.Rounding.Floor
        );
        uint256 rate = rateOracle.getExchangeRate();
        assertEq(rate, expected);
        assertEq(Math.mulDiv(rate, 20e18, 1e18, Math.Rounding.Floor), expected * 20);
    }
}
