// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {ISTRConModule} from "../../../src/v2/interfaces/modules/ISTRConModule.sol";
import {ISTRConPriceOracle} from "../../../src/v2/interfaces/oracles/ISTRConPriceOracle.sol";
import {STRConModule} from "../../../src/v2/modules/STRCon/STRConModule.sol";

contract STRConModuleVaultMock {
    mapping(bytes32 role => mapping(address account => bool enabled)) private _roles;

    function buy(ISTRConModule module, uint256 assetReceived) external {
        module.buy(assetReceived);
    }

    function sell(ISTRConModule module, uint256 assetDelivered) external {
        module.sell(assetDelivered);
    }

    function setRole(bytes32 role, address account, bool enabled) external {
        _roles[role][account] = enabled;
    }

    function hasRole(bytes32 role, address account) external view returns (bool) {
        return _roles[role][account];
    }
}

contract STRConModuleOracleMock is ISTRConPriceOracle {
    error DecimalsReadFailed();
    error PriceReadFailed();

    uint8 private _decimals;
    uint256 private _price;
    bool private _decimalsReadFails;
    bool private _priceReadFails;

    constructor(uint8 initialDecimals, uint256 initialPrice) {
        _decimals = initialDecimals;
        _price = initialPrice;
    }

    function setDecimals(uint8 newDecimals) external {
        _decimals = newDecimals;
    }

    function setPrice(uint256 newPrice) external {
        _price = newPrice;
    }

    function setDecimalsReadFails(bool shouldFail) external {
        _decimalsReadFails = shouldFail;
    }

    function setPriceReadFails(bool shouldFail) external {
        _priceReadFails = shouldFail;
    }

    function decimals() external view returns (uint8) {
        if (_decimalsReadFails) revert DecimalsReadFailed();
        return _decimals;
    }

    function getPrice() external view returns (uint256) {
        if (_priceReadFails) revert PriceReadFailed();
        return _price;
    }
}

contract STRConModuleMissingDecimalsMock {
    function getPrice() external pure returns (uint256) {
        return 100e8;
    }
}

contract STRConModuleMalformedDecimalsMock {
    fallback() external {
        assembly ("memory-safe") {
            mstore(0, 8)
            return(31, 1)
        }
    }
}

contract STRConModuleDirtyDecimalsMock {
    fallback() external {
        assembly ("memory-safe") {
            mstore(0, 0x108)
            return(0, 32)
        }
    }
}

contract STRConModuleTest is Test {
    event OracleUpdated(address indexed oldOracle, address indexed newOracle);

    address private constant ASSET_ADDRESS = address(0x2222);
    uint256 private constant INITIAL_PRICE = 100e8;

    STRConModuleVaultMock private vault;
    STRConModuleOracleMock private initialOracle;
    STRConModule private module;

    function setUp() public {
        vault = new STRConModuleVaultMock();
        initialOracle = new STRConModuleOracleMock(8, INITIAL_PRICE);
        module = new STRConModule(address(vault), ASSET_ADDRESS, initialOracle);

        vault.setRole(module.PARAMETER_MANAGER_ROLE(), address(this), true);
    }

    function test_constructorBindsVaultAssetAndInitialOracle() public view {
        ISTRConModule moduleInterface = ISTRConModule(address(module));

        assertEq(module.VAULT(), address(vault));
        assertEq(module.ASSET(), ASSET_ADDRESS);
        assertEq(module.asset(), ASSET_ADDRESS);
        assertEq(address(moduleInterface.oracle()), address(initialOracle));
        assertEq(module.ORACLE_DECIMALS(), 8);
        assertEq(module.getPrice(), INITIAL_PRICE);
    }

    function test_balanceInitializesToZero() public view {
        assertEq(module.balance(), 0);
    }

    function test_buyRequiresVaultCaller() public {
        vm.expectRevert(STRConModule.NotVault.selector);
        module.buy(1);

        assertEq(module.balance(), 0);
    }

    function test_buyAddsToBalanceWithoutReadingOracle() public {
        initialOracle.setPriceReadFails(true);

        vault.buy(module, 2e18);
        vault.buy(module, 3e18);

        assertEq(module.balance(), 5e18);
    }

    function test_sellRequiresVaultCaller() public {
        vault.buy(module, 5e18);

        vm.expectRevert(STRConModule.NotVault.selector);
        module.sell(1e18);

        assertEq(module.balance(), 5e18);
    }

    function test_sellSubtractsFromBalanceWithoutReadingOracle() public {
        vault.buy(module, 5e18);
        initialOracle.setPriceReadFails(true);

        vault.sell(module, 2e18);
        assertEq(module.balance(), 3e18);

        vault.sell(module, 3e18);
        assertEq(module.balance(), 0);
    }

    function test_sellCannotExceedBalance() public {
        vault.buy(module, 5e18);

        vm.expectRevert(STRConModule.InsufficientBalance.selector);
        vault.sell(module, 5e18 + 1);

        assertEq(module.balance(), 5e18);
    }

    function test_recognizedValueReturnsZeroWithoutReadingOracle() public {
        initialOracle.setPriceReadFails(true);

        assertEq(module.recognizedValue(), 0);
    }

    function test_recognizedValueConvertsToSixDecimals() public {
        vault.buy(module, 1e18);

        assertEq(module.recognizedValue(), 100e6);
    }

    function test_recognizedValueFloorsNonDivisibleConversion() public {
        uint256 recognizedBalance = 1e18 + 7;
        uint256 price = 100e8 + 3;
        vault.buy(module, recognizedBalance);
        initialOracle.setPrice(price);

        uint256 expected = Math.mulDiv(recognizedBalance, price, 1e20, Math.Rounding.Floor);
        assertEq(module.recognizedValue(), expected);
    }

    function test_recognizedValuePropagatesOracleFailureForNonzeroBalance() public {
        vault.buy(module, 1);
        initialOracle.setPriceReadFails(true);

        vm.expectRevert(STRConModuleOracleMock.PriceReadFailed.selector);
        module.recognizedValue();
    }

    function test_recognizedValueUsesRotatedOracleWithoutChangingBalance() public {
        vault.buy(module, 1e18);
        assertEq(module.recognizedValue(), 100e6);

        STRConModuleOracleMock replacement = new STRConModuleOracleMock(8, 102e8);
        module.setOracle(address(replacement));

        assertEq(module.balance(), 1e18);
        assertEq(module.recognizedValue(), 102e6);
    }

    function testFuzz_recognizedValueMatchesFullPrecisionFloor(uint128 rawBalance, uint128 rawPrice) public {
        uint256 recognizedBalance = bound(uint256(rawBalance), 1, type(uint128).max);
        uint256 price = bound(uint256(rawPrice), 1, type(uint128).max);
        vault.buy(module, recognizedBalance);
        initialOracle.setPrice(price);

        uint256 expected = Math.mulDiv(recognizedBalance, price, 1e20, Math.Rounding.Floor);
        assertEq(module.recognizedValue(), expected);
    }

    function test_constructorRejectsZeroVault() public {
        vm.expectRevert(STRConModule.InvalidZeroAddress.selector);
        new STRConModule(address(0), ASSET_ADDRESS, initialOracle);
    }

    function test_constructorRejectsZeroAsset() public {
        vm.expectRevert(STRConModule.InvalidZeroAddress.selector);
        new STRConModule(address(vault), address(0), initialOracle);
    }

    function test_constructorRejectsZeroAndCodelessOracle() public {
        vm.expectRevert(STRConModule.InvalidOracle.selector);
        new STRConModule(address(vault), ASSET_ADDRESS, ISTRConPriceOracle(address(0)));

        vm.expectRevert(STRConModule.InvalidOracle.selector);
        new STRConModule(address(vault), ASSET_ADDRESS, ISTRConPriceOracle(makeAddr("codelessOracle")));
    }

    function test_constructorRejectsEveryNonEightDecimalOracle() public {
        STRConModuleOracleMock sixDecimalOracle = new STRConModuleOracleMock(6, INITIAL_PRICE);
        vm.expectRevert(STRConModule.InvalidOracle.selector);
        new STRConModule(address(vault), ASSET_ADDRESS, sixDecimalOracle);

        STRConModuleOracleMock eighteenDecimalOracle = new STRConModuleOracleMock(18, INITIAL_PRICE);
        vm.expectRevert(STRConModule.InvalidOracle.selector);
        new STRConModule(address(vault), ASSET_ADDRESS, eighteenDecimalOracle);
    }

    function test_constructorRejectsMissingRevertingMalformedAndDirtyDecimals() public {
        STRConModuleMissingDecimalsMock missingDecimals = new STRConModuleMissingDecimalsMock();
        vm.expectRevert();
        new STRConModule(address(vault), ASSET_ADDRESS, ISTRConPriceOracle(address(missingDecimals)));

        STRConModuleOracleMock revertingDecimals = new STRConModuleOracleMock(8, INITIAL_PRICE);
        revertingDecimals.setDecimalsReadFails(true);
        vm.expectRevert(STRConModuleOracleMock.DecimalsReadFailed.selector);
        new STRConModule(address(vault), ASSET_ADDRESS, revertingDecimals);

        STRConModuleMalformedDecimalsMock malformedDecimals = new STRConModuleMalformedDecimalsMock();
        vm.expectRevert();
        new STRConModule(address(vault), ASSET_ADDRESS, ISTRConPriceOracle(address(malformedDecimals)));

        STRConModuleDirtyDecimalsMock dirtyDecimals = new STRConModuleDirtyDecimalsMock();
        vm.expectRevert();
        new STRConModule(address(vault), ASSET_ADDRESS, ISTRConPriceOracle(address(dirtyDecimals)));
    }

    function test_constructorValidatesDecimalsWithoutReadingPrice() public {
        initialOracle.setPriceReadFails(true);

        STRConModule freshModule = new STRConModule(address(vault), ASSET_ADDRESS, initialOracle);
        assertEq(address(freshModule.oracle()), address(initialOracle));

        vm.expectRevert(STRConModuleOracleMock.PriceReadFailed.selector);
        freshModule.getPrice();
    }

    function test_getPriceForwardsCurrentOracleAndPropagatesFailure() public {
        initialOracle.setPrice(101e8);
        assertEq(module.getPrice(), 101e8);

        initialOracle.setPriceReadFails(true);
        vm.expectRevert(STRConModuleOracleMock.PriceReadFailed.selector);
        module.getPrice();

        initialOracle.setPriceReadFails(false);
        assertEq(module.getPrice(), 101e8);
    }

    function test_setOracleRequiresVaultParameterManagerBeforeReadingCandidate() public {
        STRConModuleOracleMock replacement = new STRConModuleOracleMock(8, 102e8);
        replacement.setDecimalsReadFails(true);

        vm.expectRevert(STRConModule.Unauthorized.selector);
        vm.prank(makeAddr("unauthorized"));
        module.setOracle(address(replacement));

        assertEq(address(module.oracle()), address(initialOracle));
    }

    function test_setOracleUpdatesBindingEmitsAndSwitchesPriceSource() public {
        STRConModuleOracleMock replacement = new STRConModuleOracleMock(8, 102e8);

        vm.expectEmit(true, true, false, false, address(module));
        emit OracleUpdated(address(initialOracle), address(replacement));
        module.setOracle(address(replacement));

        assertEq(address(module.oracle()), address(replacement));
        assertEq(module.getPrice(), 102e8);
        assertEq(module.VAULT(), address(vault));
        assertEq(module.ASSET(), ASSET_ADDRESS);
        assertEq(module.asset(), ASSET_ADDRESS);
        assertEq(module.balance(), 0);
    }

    function test_setOracleDoesNotRequireCandidatePriceAvailability() public {
        STRConModuleOracleMock replacement = new STRConModuleOracleMock(8, 102e8);
        replacement.setPriceReadFails(true);

        module.setOracle(address(replacement));
        assertEq(address(module.oracle()), address(replacement));

        vm.expectRevert(STRConModuleOracleMock.PriceReadFailed.selector);
        module.getPrice();
    }

    function test_setOracleRejectsInvalidCandidatesWithoutChangingBinding() public {
        _expectInvalidRotation(address(0));
        _expectInvalidRotation(makeAddr("codelessReplacement"));

        STRConModuleOracleMock wrongDecimals = new STRConModuleOracleMock(18, 102e8);
        _expectInvalidRotation(address(wrongDecimals));

        STRConModuleOracleMock revertingDecimals = new STRConModuleOracleMock(8, 102e8);
        revertingDecimals.setDecimalsReadFails(true);
        _expectInvalidRotation(address(revertingDecimals));

        _expectInvalidRotation(address(new STRConModuleMissingDecimalsMock()));
        _expectInvalidRotation(address(new STRConModuleMalformedDecimalsMock()));
        _expectInvalidRotation(address(new STRConModuleDirtyDecimalsMock()));
    }

    function _expectInvalidRotation(address candidate) private {
        vm.expectRevert();
        module.setOracle(candidate);

        assertEq(address(module.oracle()), address(initialOracle));
        assertEq(module.getPrice(), INITIAL_PRICE);
    }
}
