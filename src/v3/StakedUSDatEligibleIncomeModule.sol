// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IStakedUSDat} from "../v2/interfaces/IStakedUSDat.sol";
import {ISTRConExecutionPolicy} from "../v2/interfaces/ISTRConExecutionPolicy.sol";
import {ISTRConModule} from "../v2/interfaces/modules/ISTRConModule.sol";
import {ISTRConPriceOracleConfig} from "./interfaces/ISTRConPriceOracleConfig.sol";
import {IEligibleIncomeAccounting} from "./interfaces/IEligibleIncomeAccounting.sol";
import {IStakedUSDatEligibleIncomeModule} from "./interfaces/IStakedUSDatEligibleIncomeModule.sol";
import {StakedUSDatEligibleIncomeLogic} from "./libraries/StakedUSDatEligibleIncomeLogic.sol";

interface IStakedUSDatContext {
    function totalAssets() external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function strcMirrorModule() external view returns (address);
    function strconModule() external view returns (ISTRConModule);
    function executionPolicy() external view returns (ISTRConExecutionPolicy);
    function getUnvestedSurplus() external view returns (uint256);
}

/**
 * @title StakedUSDatEligibleIncomeModule
 * @notice Vault-bound unit-income ledger and sole post-V3 parameter mediator.
 */
contract StakedUSDatEligibleIncomeModule is IStakedUSDatEligibleIncomeModule {
    bytes32 private constant PARAMETER_MANAGER_ROLE = keccak256("PARAMETER_MANAGER_ROLE");

    error Unauthorized();
    error InvalidConfiguration();

    address public immutable override VAULT;
    address public configManager;

    // ============ Modifiers ============

    modifier onlyVault() {
        if (msg.sender != VAULT) revert Unauthorized();
        _;
    }

    modifier onlyConfigManager() {
        if (msg.sender != configManager) revert Unauthorized();
        _;
    }

    constructor(address vault, address configManager_) {
        if (vault == address(0) || configManager_ == address(0)) revert InvalidConfiguration();
        VAULT = vault;
        configManager = configManager_;
    }

    // ============ Initialization ============

    function initializeEligibleIncomeV3(EligibleIncomeConfig calldata config) external onlyVault {
        if (config.configManager != configManager) revert InvalidConfiguration();
        if (!IAccessControl(VAULT).hasRole(PARAMETER_MANAGER_ROLE, address(this))) {
            revert InvalidConfiguration();
        }
        IStakedUSDatContext vault = IStakedUSDatContext(VAULT);
        vault.totalAssets();
        StakedUSDatEligibleIncomeLogic.initialize(
            config, VAULT, IStakedUSDat(VAULT).strcMirrorModule(), vault.strconModule()
        );
        emit EligibleIncomeInitialized(address(config.adapter), config.adapter.asset(), configManager);
    }

    // ============ Status ============

    function isActive() public view returns (bool) {
        return StakedUSDatEligibleIncomeLogic.state().state == IncomeState.Active;
    }

    function canAccount() external view returns (bool) {
        if (!isActive()) return false;
        if (!_fundedUSDatIsCoherent()) return false;
        try this.previewSTRConEligibleUnitsPerShareWad() returns (uint256) {
            return true;
        } catch {
            return false;
        }
    }

    // ============ Vault Hooks ============

    function beforeSupplyOrExposureChange() external onlyVault returns (uint256 unitsPerShareIncrease) {
        if (!isActive()) revert EligibleIncomeNotActive();
        IStakedUSDatContext vault = IStakedUSDatContext(VAULT);
        _requireHealthyCustody(vault, vault.strconModule());
        return StakedUSDatEligibleIncomeLogic.materialize(vault.strconModule(), vault.totalSupply(), false);
    }

    function afterSTRConSale(uint256 delivered, uint256 usdatReceived) external onlyVault {
        uint256 preExposure = IStakedUSDatContext(VAULT).strconModule().balance() + delivered;
        if (delivered >= preExposure) revert FullSTRConExitRequiresReview();
        StakedUSDatEligibleIncomeLogic.crystallize(preExposure, delivered, usdatReceived);
    }

    // ============ Income Accounting ============

    function registerFundedUSDatSurplus(uint256 amount) external onlyVault {
        StakedUSDatEligibleIncomeLogic.registerFundedUSDat(amount);
        if (!_fundedUSDatIsCoherent()) revert InvalidConfiguration();
    }

    function recognizeFundedUSDatSurplus(uint256 amount) external onlyVault returns (uint256 valuePerShareIncreaseWad) {
        valuePerShareIncreaseWad =
            StakedUSDatEligibleIncomeLogic.recognizeFundedUSDat(amount, IStakedUSDatContext(VAULT).totalSupply());
        if (!_fundedUSDatIsCoherent()) revert InvalidConfiguration();
    }

    function previewSTRConEligibleUnitsPerShareWad() public view returns (uint256) {
        IStakedUSDatContext vault = IStakedUSDatContext(VAULT);
        _requireHealthyCustody(vault, vault.strconModule());
        return StakedUSDatEligibleIncomeLogic.preview(vault.strconModule(), vault.totalSupply());
    }

    function materializeSTRConEligibleIncome() external returns (uint256 unitsPerShareIncrease) {
        if (!isActive()) revert EligibleIncomeNotActive();
        IStakedUSDatContext vault = IStakedUSDatContext(VAULT);
        _requireHealthyCustody(vault, vault.strconModule());
        return StakedUSDatEligibleIncomeLogic.materialize(vault.strconModule(), vault.totalSupply(), false);
    }

    function eligibleIncomeState() external view returns (EligibleIncomeState memory) {
        return StakedUSDatEligibleIncomeLogic.state();
    }

    // ============ Review Controls ============

    function enterSTRConIncomeReview(bytes32 evidence) external onlyConfigManager {
        IStakedUSDatContext vault = IStakedUSDatContext(VAULT);
        ISTRConModule module = vault.strconModule();
        bool settleCurrent;
        try this.requireHealthyCustody() {
            settleCurrent = true;
        } catch {}
        StakedUSDatEligibleIncomeLogic.enterReview(module, vault.totalSupply(), evidence, settleCurrent);
    }

    function resumeSTRConIncome(bytes32 evidence) external onlyConfigManager {
        IStakedUSDatContext vault = IStakedUSDatContext(VAULT);
        _requireHealthyCustody(vault, vault.strconModule());
        StakedUSDatEligibleIncomeLogic.resume(vault.strconModule(), vault.totalSupply(), evidence);
    }

    function resolveNeutralSTRConStructuralAdjustment(uint256 newFactorWad, bytes32 evidence)
        external
        onlyConfigManager
    {
        IStakedUSDatContext vault = IStakedUSDatContext(VAULT);
        _requireHealthyCustody(vault, vault.strconModule());
        StakedUSDatEligibleIncomeLogic.resolve(vault.strconModule(), vault.totalSupply(), newFactorWad, evidence);
    }

    // ============ Configuration ============

    function setSTRConMaxUnreviewedGrowthBps(uint16 newBps) external onlyConfigManager {
        IStakedUSDatContext vault = IStakedUSDatContext(VAULT);
        if (isActive()) _requireHealthyCustody(vault, vault.strconModule());
        StakedUSDatEligibleIncomeLogic.setMaxGrowth(vault.strconModule(), vault.totalSupply(), newBps);
    }

    function configureEligibleIncomeDependency(address target, bytes calldata data) external onlyConfigManager {
        if (data.length < 4) revert InvalidConfiguration();
        IStakedUSDatContext vault = IStakedUSDatContext(VAULT);
        ISTRConModule module = vault.strconModule();
        ISTRConExecutionPolicy policy = vault.executionPolicy();
        bytes4 selector = bytes4(data[:4]);
        bool moduleConfig = target == address(module) && selector == ISTRConModule.setOracle.selector;
        address priceOracle = address(module.oracle());
        bool priceConfig = target == priceOracle
            && (selector == ISTRConPriceOracleConfig.setPriceBounds.selector
                || selector == ISTRConPriceOracleConfig.setMaxApiStaleness.selector
                || selector == ISTRConPriceOracleConfig.setDeviationBps.selector);
        bool executionConfig = target == address(policy)
            && (selector == ISTRConExecutionPolicy.setExecutionVehicle.selector
                || selector == ISTRConExecutionPolicy.setExecutionTolerance.selector
                || selector == ISTRConExecutionPolicy.setExecutionCapacity.selector);
        bool vaultConfig = target == VAULT && _isAllowedVaultSelector(selector);
        if (!(moduleConfig || priceConfig || executionConfig || vaultConfig)) revert InvalidConfiguration();

        if ((moduleConfig || priceConfig) && isActive()) {
            _requireHealthyCustody(vault, module);
            StakedUSDatEligibleIncomeLogic.materialize(module, vault.totalSupply(), false);
        }
        (bool success, bytes memory result) = target.call(data);
        if (!success) {
            assembly ("memory-safe") {
                revert(add(result, 0x20), mload(result))
            }
        }
        if (moduleConfig || priceConfig) vault.totalAssets();
        emit EligibleIncomeDependencyConfigured(target, selector);
    }

    function setConfigManager(address newManager) external onlyConfigManager {
        if (newManager == address(0)) revert InvalidConfiguration();
        address oldManager = configManager;
        configManager = newManager;
        emit EligibleIncomeConfigManagerUpdated(oldManager, newManager);
    }

    // ============ Internal Validation ============

    function requireHealthyCustody() external view {
        IStakedUSDatContext vault = IStakedUSDatContext(VAULT);
        _requireHealthyCustody(vault, vault.strconModule());
    }

    function _requireHealthyCustody(IStakedUSDatContext vault, ISTRConModule module) private view {
        vault.totalAssets();
        if (IERC20(module.asset()).balanceOf(VAULT) < module.balance()) revert EligibleIncomeCustodyShortfall();
    }

    function _fundedUSDatIsCoherent() private view returns (bool) {
        IEligibleIncomeAccounting.EligibleIncomeState memory current = StakedUSDatEligibleIncomeLogic.state();
        return current.fundedUSDat == current.pendingFundedUSDat + current.recognizedUSDat
            && current.pendingFundedUSDat >= IStakedUSDatContext(VAULT).getUnvestedSurplus();
    }

    function _isAllowedVaultSelector(bytes4 selector) private pure returns (bool) {
        return selector == IStakedUSDat.setRecoveryAddress.selector
            || selector == IStakedUSDat.setSurplusSource.selector
            || selector == IStakedUSDat.setMigrationTolerance.selector
            || selector == IStakedUSDat.setRedemptionFees.selector
            || selector == IStakedUSDat.setElevatedDepositFee.selector
            || selector == IStakedUSDat.setSurplusVestingPeriod.selector;
    }
}
