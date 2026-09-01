// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {Script, console} from "forge-std/Script.sol";

import {IEligibleIncomeAccounting} from "../../src/v3/interfaces/IEligibleIncomeAccounting.sol";
import {IEligibleIncomeAdapter} from "../../src/v3/interfaces/IEligibleIncomeAdapter.sol";
import {IStakedUSDatEligibleIncomeModule} from "../../src/v3/interfaces/IStakedUSDatEligibleIncomeModule.sol";
import {STRConEligibleIncomeAdapter} from "../../src/v3/STRConEligibleIncomeAdapter.sol";
import {StakedUSDatEligibleIncomeModule} from "../../src/v3/StakedUSDatEligibleIncomeModule.sol";
import {StakedUSDat} from "../../src/v3/StakedUSDat.sol";

interface IUUPSV3 {
    function upgradeToAndCall(address implementation, bytes calldata data) external payable;
}

/**
 *  @notice Builds, but never submits, the atomic V2-to-V3 timelock batch.
 */
contract BuildV3UpgradeBatch is Script {
    // =========================================================================
    // Configuration
    // =========================================================================

    error InvalidConfiguration(string field);
    error WrongChain(uint256 chainId);

    uint256 public constant EXPECTED_CHAIN_ID = 1;
    uint256 public constant TIMELOCK_DELAY = 5 days;
    address public constant TIMELOCK = 0xfD5782E3BFF366601da3973aE30C583dE4F08A67;
    address public constant PROPOSER = 0x610182581C93687Ca03F4a8E7f124f8cEC616820;
    address public constant STAKED_USDAT_PROXY = 0xD166337499E176bbC38a1FBd113Ab144e5bd2Df7;
    address public constant WITHDRAWAL_QUEUE_PROXY = 0x4Bc9FEC04F0F95e9b42a3EF18F3C96fB57923D2e;
    address public constant STRCON = 0xECABE1Ff8a9e1dC55899cf58dac8497ecE5Ae84c;
    address public constant SYNTHETIC_SHARES_ORACLE = 0x9BC39DB6fbB44B91a48b8D5A6C208B82B1741bE6;
    bytes32 public constant PARAMETER_MANAGER_ROLE = keccak256("PARAMETER_MANAGER_ROLE");
    bytes32 public constant PREDECESSOR = bytes32(0);

    // Deliberately unset until deployment outputs and governance inputs are approved.
    address public constant V3_IMPLEMENTATION = address(0);
    address public constant ELIGIBLE_INCOME_MODULE = address(0);
    address public constant ELIGIBLE_INCOME_ADAPTER = address(0);
    address public constant CONFIG_MANAGER = address(0);
    uint16 public constant MAX_UNREVIEWED_GROWTH_BPS = 0;
    bytes32 public constant BATCH_SALT = bytes32(0);
    bool public constant CONFIGURATION_APPROVED = false;

    // =========================================================================
    // Batch Types
    // =========================================================================

    struct UpgradeInput {
        address implementation;
        IStakedUSDatEligibleIncomeModule module;
        IEligibleIncomeAdapter adapter;
        address configManager;
        uint16 maxUnreviewedGrowthBps;
        bytes32 salt;
    }

    struct UpgradeBatch {
        address[] targets;
        uint256[] values;
        bytes[] payloads;
        bytes initializer;
        bytes scheduleCalldata;
        bytes executeCalldata;
        bytes32 operationId;
    }

    // =========================================================================
    // Production Entry Point
    // =========================================================================

    function run() external view returns (UpgradeBatch memory batch) {
        if (block.chainid != EXPECTED_CHAIN_ID) revert WrongChain(block.chainid);
        if (!CONFIGURATION_APPROVED) revert InvalidConfiguration("CONFIGURATION_APPROVED");
        UpgradeInput memory input = productionInput();
        validateInput(input);
        batch = buildBatch(input);
        _validateProductionBindings(input, batch);
        _logBatch(batch);
    }

    // =========================================================================
    // Batch Construction
    // =========================================================================

    function productionInput() public pure returns (UpgradeInput memory input) {
        input = UpgradeInput({
            implementation: V3_IMPLEMENTATION,
            module: IStakedUSDatEligibleIncomeModule(ELIGIBLE_INCOME_MODULE),
            adapter: IEligibleIncomeAdapter(ELIGIBLE_INCOME_ADAPTER),
            configManager: CONFIG_MANAGER,
            maxUnreviewedGrowthBps: MAX_UNREVIEWED_GROWTH_BPS,
            salt: BATCH_SALT
        });
    }

    function validateInput(UpgradeInput memory input) public pure {
        if (input.implementation == address(0)) revert InvalidConfiguration("implementation");
        if (address(input.module) == address(0)) revert InvalidConfiguration("module");
        if (address(input.adapter) == address(0)) revert InvalidConfiguration("adapter");
        if (input.configManager == address(0)) revert InvalidConfiguration("configManager");
        if (input.maxUnreviewedGrowthBps == 0 || input.maxUnreviewedGrowthBps > 10_000) {
            revert InvalidConfiguration("maxUnreviewedGrowthBps");
        }
        if (input.salt == bytes32(0)) revert InvalidConfiguration("salt");
    }

    function buildBatch(UpgradeInput memory input) public pure returns (UpgradeBatch memory batch) {
        validateInput(input);
        IEligibleIncomeAccounting.EligibleIncomeConfig memory config = IEligibleIncomeAccounting.EligibleIncomeConfig({
            adapter: input.adapter,
            configManager: input.configManager,
            maxUnreviewedGrowthBps: input.maxUnreviewedGrowthBps
        });
        batch.initializer = abi.encodeCall(StakedUSDat.initializeV3, (input.module, config));
        batch.targets = new address[](2);
        batch.targets[0] = STAKED_USDAT_PROXY;
        batch.targets[1] = STAKED_USDAT_PROXY;
        batch.values = new uint256[](2);
        batch.payloads = new bytes[](2);
        batch.payloads[0] = abi.encodeCall(IAccessControl.grantRole, (PARAMETER_MANAGER_ROLE, address(input.module)));
        batch.payloads[1] = abi.encodeCall(IUUPSV3.upgradeToAndCall, (input.implementation, batch.initializer));
        batch.operationId = keccak256(abi.encode(batch.targets, batch.values, batch.payloads, PREDECESSOR, input.salt));
        batch.scheduleCalldata = abi.encodeCall(
            TimelockController.scheduleBatch,
            (batch.targets, batch.values, batch.payloads, PREDECESSOR, input.salt, TIMELOCK_DELAY)
        );
        batch.executeCalldata = abi.encodeCall(
            TimelockController.executeBatch, (batch.targets, batch.values, batch.payloads, PREDECESSOR, input.salt)
        );
    }

    // =========================================================================
    // Production Validation
    // =========================================================================

    function _validateProductionBindings(UpgradeInput memory input, UpgradeBatch memory batch) private view {
        if (TIMELOCK.code.length == 0 || STAKED_USDAT_PROXY.code.length == 0 || input.implementation.code.length == 0) {
            revert InvalidConfiguration("missing code");
        }
        if (address(input.module).code.length == 0 || address(input.adapter).code.length == 0) {
            revert InvalidConfiguration("dependency code");
        }
        if (input.module.VAULT() != STAKED_USDAT_PROXY) revert InvalidConfiguration("module vault");
        if (StakedUSDatEligibleIncomeModule(address(input.module)).configManager() != input.configManager) {
            revert InvalidConfiguration("module configManager");
        }
        if (input.module.isActive()) revert InvalidConfiguration("module already active");
        if (input.adapter.asset() != STRCON) revert InvalidConfiguration("adapter asset");
        if (address(STRConEligibleIncomeAdapter(address(input.adapter)).SHARES_ORACLE()) != SYNTHETIC_SHARES_ORACLE) {
            revert InvalidConfiguration("adapter oracle");
        }
        if (StakedUSDat(input.implementation).getWithdrawalQueue() != WITHDRAWAL_QUEUE_PROXY) {
            revert InvalidConfiguration("implementation queue");
        }
        TimelockController timelock = TimelockController(payable(TIMELOCK));
        if (timelock.getMinDelay() != TIMELOCK_DELAY) revert InvalidConfiguration("timelock delay");
        if (!timelock.hasRole(timelock.PROPOSER_ROLE(), PROPOSER)) revert InvalidConfiguration("proposer");
        if (!timelock.hasRole(timelock.EXECUTOR_ROLE(), address(0))) revert InvalidConfiguration("executor");
        if (!IAccessControl(STAKED_USDAT_PROXY).hasRole(bytes32(0), TIMELOCK)) {
            revert InvalidConfiguration("vault admin");
        }
        if (
            timelock.hashOperationBatch(batch.targets, batch.values, batch.payloads, PREDECESSOR, input.salt)
                != batch.operationId
        ) revert InvalidConfiguration("operation id");
    }

    // =========================================================================
    // Logging
    // =========================================================================

    function _logBatch(UpgradeBatch memory batch) private pure {
        console.log("V3 operation id");
        console.logBytes32(batch.operationId);
        console.log(
            "V3 batch grants the module role, then upgrades and initializes; it does not deploy or activate tranches"
        );
        console.logBytes(batch.scheduleCalldata);
        console.logBytes(batch.executeCalldata);
    }
}
