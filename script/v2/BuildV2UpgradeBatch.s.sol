// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {Script, console} from "forge-std/Script.sol";

import {ISTRConExecutionPolicy} from "../../src/v2/interfaces/ISTRConExecutionPolicy.sol";
import {IStakedUSDat} from "../../src/v2/interfaces/IStakedUSDat.sol";
import {ISTRCMirrorModule} from "../../src/v2/interfaces/modules/ISTRCMirrorModule.sol";
import {ISTRConModule} from "../../src/v2/interfaces/modules/ISTRConModule.sol";

interface IUUPSUpgradeable {
    function upgradeToAndCall(address newImplementation, bytes calldata data) external payable;
}

interface IWithdrawalQueueV2Initializer {
    function initializeV2(address operator, address enforcer, address pauser, address unpauser) external;
}

interface IWithdrawalQueueImplementationBindings {
    function USDAT() external view returns (address);
    function STAKED_USDAT() external view returns (address);
}

/**
 * @title BuildV2UpgradeBatch
 * @notice Builds the exact atomic Step-1 schedule and execution calldata without broadcasting.
 * @dev Set every TODO constant below, review the resulting operation id and calldata, then
 * submit `scheduleCalldata` from PROPOSER to TIMELOCK through Fireblocks. After the delay,
 * submit the matching `executeCalldata` to TIMELOCK from any executor.
 *
 * Usage (build calldata only):
 *   forge script script/v2/BuildV2UpgradeBatch.s.sol:BuildV2UpgradeBatch --rpc-url $RPC_URL
 *
 * Submit the generated schedule calldata with Fireblocks:
 *   fireblocks-json-rpc --http -- cast send $TIMELOCK $SCHEDULE_CALLDATA \
 *     --from $ADMIN --unlocked --rpc-url {}
 *
 * Submit the generated execute calldata after the timelock delay:
 *   fireblocks-json-rpc --http -- cast send $TIMELOCK $EXECUTE_CALLDATA \
 *     --from $EXECUTOR --unlocked --rpc-url {}
 */
contract BuildV2UpgradeBatch is Script {
    error InvalidConfiguration(string field);
    error MissingCode(address target);
    error UnsetAddress(string field);
    error WrongChain(uint256 actualChainId);

    // =========================================================================
    // REVIEWED PRODUCTION INFRASTRUCTURE
    // =========================================================================

    uint256 public constant EXPECTED_CHAIN_ID = 1;
    uint256 public constant TIMELOCK_DELAY = 5 days;
    uint16 public constant MAX_FEE_BPS = 500;
    uint16 public constant MAX_EXECUTION_TOLERANCE_BPS = 500;
    uint16 public constant MAX_MIGRATION_TOLERANCE_BPS = 500;

    address public constant TIMELOCK = 0xfD5782E3BFF366601da3973aE30C583dE4F08A67;
    address public constant PROPOSER = 0x610182581C93687Ca03F4a8E7f124f8cEC616820;
    address public constant STAKED_USDAT_PROXY = 0xD166337499E176bbC38a1FBd113Ab144e5bd2Df7;
    address public constant WITHDRAWAL_QUEUE_PROXY = 0x4Bc9FEC04F0F95e9b42a3EF18F3C96fB57923D2e;
    address public constant USDAT = 0x23238f20b894f29041f48D88eE91131C395Aaa71;

    bytes32 public constant PREDECESSOR = bytes32(0);

    // =========================================================================
    // TODO: SET FROM DeployV2Dependencies.s.sol OUTPUT
    // =========================================================================

    address public constant STAKED_USDAT_IMPLEMENTATION = address(0);
    address public constant WITHDRAWAL_QUEUE_IMPLEMENTATION = address(0);
    address public constant STRC_MIRROR_MODULE = address(0);
    address public constant STRCON_MODULE = address(0);
    address public constant EXECUTION_POLICY = address(0);

    // =========================================================================
    // TODO: SET APPROVED VAULT CONFIGURATION
    // =========================================================================

    address public constant RECOVERY_ADDRESS = address(0);
    address public constant EXECUTION_VEHICLE = address(0);

    uint16 public constant BASE_REDEMPTION_FEE_BPS = 0;
    uint16 public constant ELEVATED_REDEMPTION_FEE_BPS = 0;
    uint16 public constant ELEVATED_DEPOSIT_FEE_BPS = 0;
    uint16 public constant EXECUTION_TOLERANCE_BPS = 0;
    uint16 public constant MIGRATION_TOLERANCE_BPS = 0;

    uint128 public constant INITIAL_EXECUTION_CAPACITY = 0;
    uint128 public constant INITIAL_EXECUTION_REFILL_PER_DAY = 0;

    // These are absolute Unix timestamps used to review the expected timelock window.
    uint64 public constant EXPECTED_SCHEDULE_TIMESTAMP = 0;
    uint64 public constant EXPECTED_UPGRADE_EXECUTION_TIMESTAMP = 0;

    // Use a reviewed unique, nonzero salt for this exact Step-1 batch.
    bytes32 public constant BATCH_SALT = bytes32(0);

    // =========================================================================
    // TODO: SET APPROVED VAULT ROLE HOLDERS
    // =========================================================================

    address public constant VAULT_PARAMETER_MANAGER = address(0);
    address public constant VAULT_MARKET_MODE_MANAGER = address(0);
    address public constant VAULT_OPERATOR = address(0);
    address public constant VAULT_BLACKLISTER = address(0);
    address public constant VAULT_ENFORCER = address(0);
    address public constant VAULT_PAUSER = address(0);
    address public constant VAULT_UNPAUSER = address(0);

    // =========================================================================
    // TODO: SET APPROVED WITHDRAWAL-QUEUE ROLE HOLDERS
    // These may equal the corresponding vault holders, but are explicit inputs.
    // =========================================================================

    address public constant QUEUE_OPERATOR = address(0);
    address public constant QUEUE_ENFORCER = address(0);
    address public constant QUEUE_PAUSER = address(0);
    address public constant QUEUE_UNPAUSER = address(0);

    // Flip only after every value above has been reviewed.
    bool public constant CONFIGURATION_APPROVED = false;

    struct QueueRoles {
        address operator;
        address enforcer;
        address pauser;
        address unpauser;
    }

    struct UpgradeBatchInput {
        address stakedUsdatImplementation;
        address withdrawalQueueImplementation;
        IStakedUSDat.V2Config vaultConfig;
        IStakedUSDat.V2Roles vaultRoles;
        QueueRoles queueRoles;
        bytes32 salt;
    }

    struct UpgradeBatch {
        address[] targets;
        uint256[] values;
        bytes[] payloads;
        bytes vaultInitializer;
        bytes queueInitializer;
        bytes scheduleCalldata;
        bytes executeCalldata;
        bytes32 operationId;
    }

    /**
     * @notice Validates production state and prints the exact Fireblocks and executor transactions.
     * @dev This function is read-only and contains no broadcast cheatcode.
     */
    function run() external view returns (UpgradeBatch memory batch) {
        _validateConfiguration();
        batch = buildBatch();
        _validateProductionBindings(batch);
        _logBatch(batch);
    }

    /**
     * @notice Deterministically builds both proxy upgrades and the outer timelock calls.
     */
    function buildBatch() public pure returns (UpgradeBatch memory batch) {
        return buildBatch(_productionInput());
    }

    /**
     * @notice Builds the same production operation with caller-supplied future deployments and configuration.
     * @dev Used by the mock-fork rehearsal; production validation remains in `run`.
     */
    function buildBatch(UpgradeBatchInput memory input) public pure returns (UpgradeBatch memory batch) {
        batch.vaultInitializer = abi.encodeCall(IStakedUSDat.initializeV2, (input.vaultConfig, input.vaultRoles));
        batch.queueInitializer = abi.encodeCall(
            IWithdrawalQueueV2Initializer.initializeV2,
            (input.queueRoles.operator, input.queueRoles.enforcer, input.queueRoles.pauser, input.queueRoles.unpauser)
        );

        batch.targets = new address[](2);
        batch.targets[0] = STAKED_USDAT_PROXY;
        batch.targets[1] = WITHDRAWAL_QUEUE_PROXY;

        batch.values = new uint256[](2);

        batch.payloads = new bytes[](2);
        batch.payloads[0] = abi.encodeCall(
            IUUPSUpgradeable.upgradeToAndCall, (input.stakedUsdatImplementation, batch.vaultInitializer)
        );
        batch.payloads[1] = abi.encodeCall(
            IUUPSUpgradeable.upgradeToAndCall, (input.withdrawalQueueImplementation, batch.queueInitializer)
        );

        batch.operationId = keccak256(abi.encode(batch.targets, batch.values, batch.payloads, PREDECESSOR, input.salt));
        batch.scheduleCalldata = abi.encodeCall(
            TimelockController.scheduleBatch,
            (batch.targets, batch.values, batch.payloads, PREDECESSOR, input.salt, TIMELOCK_DELAY)
        );
        batch.executeCalldata = abi.encodeCall(
            TimelockController.executeBatch, (batch.targets, batch.values, batch.payloads, PREDECESSOR, input.salt)
        );
    }

    function _productionInput() private pure returns (UpgradeBatchInput memory input) {
        input.stakedUsdatImplementation = STAKED_USDAT_IMPLEMENTATION;
        input.withdrawalQueueImplementation = WITHDRAWAL_QUEUE_IMPLEMENTATION;
        input.vaultConfig = IStakedUSDat.V2Config({
            strcMirrorModule: ISTRCMirrorModule(STRC_MIRROR_MODULE),
            strconModule: ISTRConModule(STRCON_MODULE),
            executionPolicy: ISTRConExecutionPolicy(EXECUTION_POLICY),
            recoveryAddress: RECOVERY_ADDRESS,
            executionVehicle: EXECUTION_VEHICLE,
            baseRedemptionFeeBps: BASE_REDEMPTION_FEE_BPS,
            elevatedRedemptionFeeBps: ELEVATED_REDEMPTION_FEE_BPS,
            elevatedDepositFeeBps: ELEVATED_DEPOSIT_FEE_BPS,
            executionToleranceBps: EXECUTION_TOLERANCE_BPS,
            migrationToleranceBps: MIGRATION_TOLERANCE_BPS,
            initialExecutionCapacity: INITIAL_EXECUTION_CAPACITY,
            initialExecutionRefillPerDay: INITIAL_EXECUTION_REFILL_PER_DAY
        });
        input.vaultRoles = IStakedUSDat.V2Roles({
            parameterManager: VAULT_PARAMETER_MANAGER,
            marketModeManager: VAULT_MARKET_MODE_MANAGER,
            operator: VAULT_OPERATOR,
            blacklister: VAULT_BLACKLISTER,
            enforcer: VAULT_ENFORCER,
            pauser: VAULT_PAUSER,
            unpauser: VAULT_UNPAUSER
        });
        input.queueRoles = QueueRoles({
            operator: QUEUE_OPERATOR, enforcer: QUEUE_ENFORCER, pauser: QUEUE_PAUSER, unpauser: QUEUE_UNPAUSER
        });
        input.salt = BATCH_SALT;
    }

    function _validateConfiguration() private view {
        require(block.chainid == EXPECTED_CHAIN_ID, WrongChain(block.chainid));
        require(CONFIGURATION_APPROVED, InvalidConfiguration("CONFIGURATION_APPROVED"));

        _requireSet(STAKED_USDAT_IMPLEMENTATION, "STAKED_USDAT_IMPLEMENTATION");
        _requireSet(WITHDRAWAL_QUEUE_IMPLEMENTATION, "WITHDRAWAL_QUEUE_IMPLEMENTATION");
        _requireSet(STRC_MIRROR_MODULE, "STRC_MIRROR_MODULE");
        _requireSet(STRCON_MODULE, "STRCON_MODULE");
        _requireSet(EXECUTION_POLICY, "EXECUTION_POLICY");
        _requireSet(RECOVERY_ADDRESS, "RECOVERY_ADDRESS");
        _requireSet(EXECUTION_VEHICLE, "EXECUTION_VEHICLE");

        _requireSet(VAULT_PARAMETER_MANAGER, "VAULT_PARAMETER_MANAGER");
        _requireSet(VAULT_MARKET_MODE_MANAGER, "VAULT_MARKET_MODE_MANAGER");
        _requireSet(VAULT_OPERATOR, "VAULT_OPERATOR");
        _requireSet(VAULT_BLACKLISTER, "VAULT_BLACKLISTER");
        _requireSet(VAULT_ENFORCER, "VAULT_ENFORCER");
        _requireSet(VAULT_PAUSER, "VAULT_PAUSER");
        _requireSet(VAULT_UNPAUSER, "VAULT_UNPAUSER");

        _requireSet(QUEUE_OPERATOR, "QUEUE_OPERATOR");
        _requireSet(QUEUE_ENFORCER, "QUEUE_ENFORCER");
        _requireSet(QUEUE_PAUSER, "QUEUE_PAUSER");
        _requireSet(QUEUE_UNPAUSER, "QUEUE_UNPAUSER");

        require(BATCH_SALT != bytes32(0), InvalidConfiguration("BATCH_SALT"));
        require(BASE_REDEMPTION_FEE_BPS <= ELEVATED_REDEMPTION_FEE_BPS, InvalidConfiguration("redemption fee ordering"));
        require(ELEVATED_REDEMPTION_FEE_BPS <= MAX_FEE_BPS, InvalidConfiguration("ELEVATED_REDEMPTION_FEE_BPS"));
        require(ELEVATED_DEPOSIT_FEE_BPS <= MAX_FEE_BPS, InvalidConfiguration("ELEVATED_DEPOSIT_FEE_BPS"));
        require(EXECUTION_TOLERANCE_BPS <= MAX_EXECUTION_TOLERANCE_BPS, InvalidConfiguration("EXECUTION_TOLERANCE_BPS"));
        require(MIGRATION_TOLERANCE_BPS <= MAX_MIGRATION_TOLERANCE_BPS, InvalidConfiguration("MIGRATION_TOLERANCE_BPS"));

        require(EXPECTED_SCHEDULE_TIMESTAMP != 0, InvalidConfiguration("EXPECTED_SCHEDULE_TIMESTAMP"));
        require(
            EXPECTED_UPGRADE_EXECUTION_TIMESTAMP >= uint256(EXPECTED_SCHEDULE_TIMESTAMP) + TIMELOCK_DELAY,
            InvalidConfiguration("EXPECTED_UPGRADE_EXECUTION_TIMESTAMP")
        );
    }

    function _validateProductionBindings(UpgradeBatch memory batch) private view {
        _requireCode(TIMELOCK);
        _requireCode(STAKED_USDAT_PROXY);
        _requireCode(WITHDRAWAL_QUEUE_PROXY);
        _requireCode(STAKED_USDAT_IMPLEMENTATION);
        _requireCode(WITHDRAWAL_QUEUE_IMPLEMENTATION);
        _requireCode(STRC_MIRROR_MODULE);
        _requireCode(STRCON_MODULE);
        _requireCode(EXECUTION_POLICY);

        TimelockController timelock = TimelockController(payable(TIMELOCK));
        require(timelock.getMinDelay() == TIMELOCK_DELAY, InvalidConfiguration("TIMELOCK_DELAY"));
        require(timelock.hasRole(timelock.PROPOSER_ROLE(), PROPOSER), InvalidConfiguration("PROPOSER_ROLE"));
        require(timelock.hasRole(timelock.EXECUTOR_ROLE(), address(0)), InvalidConfiguration("open EXECUTOR_ROLE"));
        require(
            IAccessControl(STAKED_USDAT_PROXY).hasRole(bytes32(0), TIMELOCK),
            InvalidConfiguration("vault DEFAULT_ADMIN_ROLE")
        );
        require(
            IAccessControl(WITHDRAWAL_QUEUE_PROXY).hasRole(bytes32(0), TIMELOCK),
            InvalidConfiguration("queue DEFAULT_ADMIN_ROLE")
        );

        require(
            ISTRCMirrorModule(STRC_MIRROR_MODULE).VAULT() == STAKED_USDAT_PROXY,
            InvalidConfiguration("STRC mirror vault binding")
        );
        require(!ISTRCMirrorModule(STRC_MIRROR_MODULE).seeded(), InvalidConfiguration("STRC mirror already seeded"));
        require(
            ISTRConModule(STRCON_MODULE).VAULT() == STAKED_USDAT_PROXY,
            InvalidConfiguration("STRCon module vault binding")
        );
        require(ISTRConModule(STRCON_MODULE).balance() == 0, InvalidConfiguration("STRCon module initial balance"));
        require(
            ISTRConExecutionPolicy(EXECUTION_POLICY).VAULT() == STAKED_USDAT_PROXY,
            InvalidConfiguration("execution policy vault binding")
        );
        require(
            address(ISTRConExecutionPolicy(EXECUTION_POLICY).STRCON_MODULE()) == STRCON_MODULE,
            InvalidConfiguration("execution policy module binding")
        );

        require(
            IStakedUSDat(STAKED_USDAT_IMPLEMENTATION).getWithdrawalQueue() == WITHDRAWAL_QUEUE_PROXY,
            InvalidConfiguration("vault implementation queue binding")
        );
        IWithdrawalQueueImplementationBindings queueImplementation =
            IWithdrawalQueueImplementationBindings(WITHDRAWAL_QUEUE_IMPLEMENTATION);
        require(queueImplementation.USDAT() == USDAT, InvalidConfiguration("queue implementation USDat binding"));
        require(
            queueImplementation.STAKED_USDAT() == STAKED_USDAT_PROXY,
            InvalidConfiguration("queue implementation vault binding")
        );

        require(
            timelock.hashOperationBatch(batch.targets, batch.values, batch.payloads, PREDECESSOR, BATCH_SALT)
                == batch.operationId,
            InvalidConfiguration("operation id")
        );
    }

    function _requireSet(address value, string memory field) private pure {
        require(value != address(0), UnsetAddress(field));
    }

    function _requireCode(address target) private view {
        require(target.code.length != 0, MissingCode(target));
    }

    function _logBatch(UpgradeBatch memory batch) private pure {
        console.log("=== Saturn V2 Atomic Upgrade Batch ===");
        console.log("Operation ID:");
        console.logBytes32(batch.operationId);
        console.log("Expected schedule timestamp:", EXPECTED_SCHEDULE_TIMESTAMP);
        console.log("Expected execution timestamp:", EXPECTED_UPGRADE_EXECUTION_TIMESTAMP);
        console.log("Initial market mode: Elevated");

        console.log("Vault upgradeToAndCall payload:");
        console.logBytes(batch.payloads[0]);
        console.log("Queue upgradeToAndCall payload:");
        console.logBytes(batch.payloads[1]);

        console.log("=== Fireblocks Schedule Transaction ===");
        console.log("From:", PROPOSER);
        console.log("To:", TIMELOCK);
        console.log("Value: 0");
        console.log("Calldata:");
        console.logBytes(batch.scheduleCalldata);

        console.log("=== Atomic Execute Transaction After Delay ===");
        console.log("To:", TIMELOCK);
        console.log("Value: 0");
        console.log("Calldata:");
        console.logBytes(batch.executeCalldata);
    }
}
