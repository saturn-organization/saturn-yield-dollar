// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Script, console} from "forge-std/Script.sol";

import {ISTRConExecutionPolicy} from "../../src/v2/interfaces/ISTRConExecutionPolicy.sol";
import {IStakedUSDat} from "../../src/v2/interfaces/IStakedUSDat.sol";
import {ISTRCMirrorModule} from "../../src/v2/interfaces/modules/ISTRCMirrorModule.sol";
import {ISTRConModule} from "../../src/v2/interfaces/modules/ISTRConModule.sol";

interface IPausableView {
    function paused() external view returns (bool);
}

/**
 * @title BuildV2Migration
 * @notice Builds the one-shot Step-2 migration timelock operation without broadcasting.
 * @dev Run after the Step-1 validation round trip and immediately before submitting
 * `scheduleCalldata` from PROPOSER to TIMELOCK through Fireblocks.
 *
 * Usage (build calldata only):
 *   forge script script/v2/BuildV2Migration.s.sol:BuildV2Migration --rpc-url $RPC_URL
 *
 * Submit the generated schedule calldata with Fireblocks:
 *   fireblocks-json-rpc --http -- cast send $TIMELOCK $SCHEDULE_CALLDATA \
 *     --from $ADMIN --unlocked --rpc-url {}
 *
 * Submit the generated execute calldata after the timelock delay:
 *   fireblocks-json-rpc --http -- cast send $TIMELOCK $EXECUTE_CALLDATA \
 *     --from $EXECUTOR --unlocked --rpc-url {}
 */
contract BuildV2Migration is Script {
    error InvalidConfiguration(string field);
    error MissingCode(address target);
    error WrongChain(uint256 actualChainId);

    // =========================================================================
    // REVIEWED PRODUCTION INFRASTRUCTURE
    // =========================================================================

    uint256 public constant EXPECTED_CHAIN_ID = 1;
    uint256 public constant TIMELOCK_DELAY = 5 days;
    uint16 public constant MAX_MIGRATION_TOLERANCE_BPS = 500;

    address public constant TIMELOCK = 0xfD5782E3BFF366601da3973aE30C583dE4F08A67;
    address public constant PROPOSER = 0x610182581C93687Ca03F4a8E7f124f8cEC616820;
    address public constant STAKED_USDAT_PROXY = 0xD166337499E176bbC38a1FBd113Ab144e5bd2Df7;
    address public constant STRCON = 0xECABE1Ff8a9e1dC55899cf58dac8497ecE5Ae84c;

    bytes32 public constant PREDECESSOR = bytes32(0);

    // =========================================================================
    // TODO: SET AFTER THE VALIDATION ROUND TRIP
    // =========================================================================

    uint256 public constant EXPECTED_STRCON = 0;
    address public constant EXPECTED_EXECUTION_VEHICLE = address(0);
    uint16 public constant EXPECTED_MIGRATION_TOLERANCE_BPS = 0;
    uint256 public constant MIGRATION_DEADLINE = 0;

    // Use a reviewed unique, nonzero salt for this exact Step-2 operation.
    bytes32 public constant MIGRATION_SALT = bytes32(0);

    // Flip only after every value above has been reviewed.
    bool public constant CONFIGURATION_APPROVED = false;

    struct MigrationOperation {
        address target;
        uint256 value;
        bytes payload;
        bytes scheduleCalldata;
        bytes executeCalldata;
        bytes32 operationId;
    }

    /**
     * @notice Validates live migration readiness and prints the exact Fireblocks
     * schedule transaction and matching open-executor transaction.
     */
    function run() external view returns (MigrationOperation memory operation) {
        _validateConfiguration();
        operation = buildOperation();
        _validateProductionState(operation);
        _logOperation(operation);
    }

    /**
     * @notice Deterministically builds the migrate call and its timelock wrapper.
     */
    function buildOperation() public pure returns (MigrationOperation memory operation) {
        return buildOperation(EXPECTED_STRCON, MIGRATION_DEADLINE, MIGRATION_SALT);
    }

    /**
     * @notice Builds the same production operation with caller-supplied migration terms.
     * @dev Used by the mock-fork rehearsal; production validation remains in `run`.
     */
    function buildOperation(uint256 expectedStrcon, uint256 deadline, bytes32 salt)
        public
        pure
        returns (MigrationOperation memory operation)
    {
        operation.target = STAKED_USDAT_PROXY;
        operation.payload = abi.encodeCall(IStakedUSDat.migrate, (expectedStrcon, deadline));
        operation.operationId =
            keccak256(abi.encode(operation.target, operation.value, operation.payload, PREDECESSOR, salt));
        operation.scheduleCalldata = abi.encodeCall(
            TimelockController.schedule,
            (operation.target, operation.value, operation.payload, PREDECESSOR, salt, TIMELOCK_DELAY)
        );
        operation.executeCalldata = abi.encodeCall(
            TimelockController.execute, (operation.target, operation.value, operation.payload, PREDECESSOR, salt)
        );
    }

    function _validateConfiguration() private view {
        require(block.chainid == EXPECTED_CHAIN_ID, WrongChain(block.chainid));
        require(CONFIGURATION_APPROVED, InvalidConfiguration("CONFIGURATION_APPROVED"));
        require(EXPECTED_STRCON != 0, InvalidConfiguration("EXPECTED_STRCON"));
        require(EXPECTED_EXECUTION_VEHICLE != address(0), InvalidConfiguration("EXPECTED_EXECUTION_VEHICLE"));
        require(
            EXPECTED_MIGRATION_TOLERANCE_BPS <= MAX_MIGRATION_TOLERANCE_BPS,
            InvalidConfiguration("EXPECTED_MIGRATION_TOLERANCE_BPS")
        );
        require(MIGRATION_SALT != bytes32(0), InvalidConfiguration("MIGRATION_SALT"));
        require(MIGRATION_DEADLINE > block.timestamp + TIMELOCK_DELAY, InvalidConfiguration("MIGRATION_DEADLINE"));
    }

    function _validateProductionState(MigrationOperation memory operation) private view {
        _requireCode(TIMELOCK);
        _requireCode(STAKED_USDAT_PROXY);
        _requireCode(STRCON);

        TimelockController timelock = TimelockController(payable(TIMELOCK));
        require(timelock.getMinDelay() == TIMELOCK_DELAY, InvalidConfiguration("TIMELOCK_DELAY"));
        require(timelock.hasRole(timelock.PROPOSER_ROLE(), PROPOSER), InvalidConfiguration("PROPOSER_ROLE"));
        require(timelock.hasRole(timelock.EXECUTOR_ROLE(), address(0)), InvalidConfiguration("open EXECUTOR_ROLE"));
        require(
            IAccessControl(STAKED_USDAT_PROXY).hasRole(bytes32(0), TIMELOCK),
            InvalidConfiguration("vault DEFAULT_ADMIN_ROLE")
        );
        require(
            timelock.hashOperation(operation.target, operation.value, operation.payload, PREDECESSOR, MIGRATION_SALT)
                == operation.operationId,
            InvalidConfiguration("operation id")
        );

        IStakedUSDat vault = IStakedUSDat(STAKED_USDAT_PROXY);
        require(!IPausableView(STAKED_USDAT_PROXY).paused(), InvalidConfiguration("vault paused"));
        require(
            vault.migrationToleranceBps() == EXPECTED_MIGRATION_TOLERANCE_BPS,
            InvalidConfiguration("migration tolerance")
        );

        ISTRCMirrorModule mirror = vault.strcMirrorModule();
        ISTRConModule module = vault.strconModule();
        ISTRConExecutionPolicy policy = vault.executionPolicy();
        _requireCode(address(mirror));
        _requireCode(address(module));
        _requireCode(address(policy));

        require(mirror.VAULT() == STAKED_USDAT_PROXY, InvalidConfiguration("mirror vault binding"));
        require(mirror.seeded() && !mirror.retired(), InvalidConfiguration("mirror state"));
        require(mirror.getUnvestedAmount() == 0, InvalidConfiguration("mirror vesting"));
        require(module.VAULT() == STAKED_USDAT_PROXY, InvalidConfiguration("module vault binding"));
        require(module.ASSET() == STRCON, InvalidConfiguration("module asset binding"));
        require(module.balance() == 0, InvalidConfiguration("module balance"));
        require(policy.VAULT() == STAKED_USDAT_PROXY, InvalidConfiguration("policy vault binding"));
        require(address(policy.STRCON_MODULE()) == address(module), InvalidConfiguration("policy module binding"));
        require(policy.executionVehicle() == EXPECTED_EXECUTION_VEHICLE, InvalidConfiguration("execution vehicle"));

        IERC20 strcon = IERC20(STRCON);
        require(
            strcon.balanceOf(EXPECTED_EXECUTION_VEHICLE) >= EXPECTED_STRCON,
            InvalidConfiguration("vehicle STRCon balance")
        );
        require(
            strcon.allowance(EXPECTED_EXECUTION_VEHICLE, STAKED_USDAT_PROXY) >= EXPECTED_STRCON,
            InvalidConfiguration("vehicle STRCon allowance")
        );

        uint256 navBefore = vault.totalAssets();
        uint256 mirrorValue = mirror.recognizedValue();
        require(navBefore != 0 && mirrorValue != 0 && navBefore >= mirrorValue, InvalidConfiguration("migration NAV"));

        uint256 strconValue = Math.mulDiv(EXPECTED_STRCON, module.getPrice(), 1e20);
        uint256 navAfter = navBefore - mirrorValue + strconValue;
        uint256 delta = navAfter >= navBefore ? navAfter - navBefore : navBefore - navAfter;
        require(
            delta <= Math.mulDiv(navBefore, EXPECTED_MIGRATION_TOLERANCE_BPS, 10_000),
            InvalidConfiguration("projected migration NAV")
        );
    }

    function _requireCode(address target) private view {
        require(target.code.length != 0, MissingCode(target));
    }

    function _logOperation(MigrationOperation memory operation) private pure {
        console.log("=== Saturn V2 Migration Operation ===");
        console.log("Operation ID:");
        console.logBytes32(operation.operationId);
        console.log("Expected STRCon:", EXPECTED_STRCON);
        console.log("Expected execution vehicle:", EXPECTED_EXECUTION_VEHICLE);
        console.log("Expected migration tolerance bps:", EXPECTED_MIGRATION_TOLERANCE_BPS);
        console.log("Migration deadline:", MIGRATION_DEADLINE);
        console.log("Vault migrate payload:");
        console.logBytes(operation.payload);

        console.log("=== Fireblocks Schedule Transaction ===");
        console.log("From:", PROPOSER);
        console.log("To:", TIMELOCK);
        console.log("Value: 0");
        console.log("Calldata:");
        console.logBytes(operation.scheduleCalldata);

        console.log("=== Open-Executor Transaction After Delay ===");
        console.log("To:", TIMELOCK);
        console.log("Value: 0");
        console.log("Calldata:");
        console.logBytes(operation.executeCalldata);
    }
}
