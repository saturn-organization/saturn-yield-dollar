// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {Test} from "forge-std/Test.sol";

import {BuildV3UpgradeBatch, IUUPSV3} from "../../../script/v3/BuildV3UpgradeBatch.s.sol";
import {IEligibleIncomeAccounting} from "../../../src/v3/interfaces/IEligibleIncomeAccounting.sol";
import {IEligibleIncomeAdapter} from "../../../src/v3/interfaces/IEligibleIncomeAdapter.sol";
import {IStakedUSDatEligibleIncomeModule} from "../../../src/v3/interfaces/IStakedUSDatEligibleIncomeModule.sol";
import {StakedUSDat} from "../../../src/v3/StakedUSDat.sol";

contract V3UpgradeTargetMock {
    uint256 public sequence;
    uint256 public roleGrantSequence;
    uint256 public upgradeSequence;
    bytes32 public grantedRole;
    address public grantedMember;
    address public implementation;
    bytes32 public initializerHash;

    function grantRole(bytes32 role, address member) external {
        roleGrantSequence = ++sequence;
        grantedRole = role;
        grantedMember = member;
    }

    function upgradeToAndCall(address implementation_, bytes calldata data) external payable {
        upgradeSequence = ++sequence;
        implementation = implementation_;
        initializerHash = keccak256(data);
    }
}

contract BuildV3UpgradeBatchTest is Test {
    BuildV3UpgradeBatch private builder;
    BuildV3UpgradeBatch.UpgradeInput private input;

    function setUp() public {
        builder = new BuildV3UpgradeBatch();
        input = BuildV3UpgradeBatch.UpgradeInput({
            implementation: makeAddr("implementation"),
            module: IStakedUSDatEligibleIncomeModule(makeAddr("module")),
            adapter: IEligibleIncomeAdapter(makeAddr("adapter")),
            configManager: makeAddr("configManager"),
            maxUnreviewedGrowthBps: 2_000,
            salt: keccak256("reviewed-v3-batch")
        });
    }

    // ============ Batch Construction ============

    function test_buildBatch_IsDeterministicAndRoleGrantPrecedesUpgrade() public view {
        BuildV3UpgradeBatch.UpgradeBatch memory first = builder.buildBatch(input);
        BuildV3UpgradeBatch.UpgradeBatch memory second = builder.buildBatch(input);
        assertEq(first.targets.length, 2);
        assertEq(first.targets[0], builder.STAKED_USDAT_PROXY());
        assertEq(first.targets[1], builder.STAKED_USDAT_PROXY());
        assertEq(first.values[0], 0);
        assertEq(first.values[1], 0);
        assertEq(_selector(first.payloads[0]), IAccessControl.grantRole.selector);
        assertEq(_selector(first.payloads[1]), IUUPSV3.upgradeToAndCall.selector);
        assertEq(first.operationId, second.operationId);
        assertEq(
            first.operationId,
            keccak256(abi.encode(first.targets, first.values, first.payloads, builder.PREDECESSOR(), input.salt))
        );
        assertEq(first.scheduleCalldata, second.scheduleCalldata);
        assertEq(first.executeCalldata, second.executeCalldata);
    }

    function test_buildBatch_EncodesExactInitializerAndTimelockPayloads() public view {
        BuildV3UpgradeBatch.UpgradeBatch memory batch = builder.buildBatch(input);
        IEligibleIncomeAccounting.EligibleIncomeConfig memory config = IEligibleIncomeAccounting.EligibleIncomeConfig({
            adapter: input.adapter,
            configManager: input.configManager,
            maxUnreviewedGrowthBps: input.maxUnreviewedGrowthBps
        });
        bytes memory initializer = abi.encodeCall(StakedUSDat.initializeV3, (input.module, config));
        assertEq(batch.initializer, initializer);
        assertEq(
            batch.payloads[0],
            abi.encodeCall(IAccessControl.grantRole, (builder.PARAMETER_MANAGER_ROLE(), address(input.module)))
        );
        assertEq(batch.payloads[1], abi.encodeCall(IUUPSV3.upgradeToAndCall, (input.implementation, initializer)));
        assertEq(
            batch.scheduleCalldata,
            abi.encodeCall(
                TimelockController.scheduleBatch,
                (
                    batch.targets,
                    batch.values,
                    batch.payloads,
                    builder.PREDECESSOR(),
                    input.salt,
                    builder.TIMELOCK_DELAY()
                )
            )
        );
        assertEq(
            batch.executeCalldata,
            abi.encodeCall(
                TimelockController.executeBatch,
                (batch.targets, batch.values, batch.payloads, builder.PREDECESSOR(), input.salt)
            )
        );
    }

    function test_buildBatch_ExecutesThroughLocalTimelockOnlyAfterDelayAndCannotReplay() public {
        BuildV3UpgradeBatch.UpgradeBatch memory batch = builder.buildBatch(input);
        address proposer = builder.PROPOSER();
        bytes32 predecessor = builder.PREDECESSOR();
        uint256 delay = builder.TIMELOCK_DELAY();
        V3UpgradeTargetMock targetTemplate = new V3UpgradeTargetMock();
        vm.etch(builder.STAKED_USDAT_PROXY(), address(targetTemplate).code);
        V3UpgradeTargetMock target = V3UpgradeTargetMock(builder.STAKED_USDAT_PROXY());

        address[] memory proposers = new address[](1);
        proposers[0] = proposer;
        address[] memory executors = new address[](1);
        executors[0] = address(0);
        TimelockController timelock = new TimelockController(delay, proposers, executors, address(this));

        assertEq(
            timelock.hashOperationBatch(batch.targets, batch.values, batch.payloads, predecessor, input.salt),
            batch.operationId
        );

        vm.prank(proposer);
        timelock.scheduleBatch(batch.targets, batch.values, batch.payloads, predecessor, input.salt, delay);
        assertTrue(timelock.isOperationPending(batch.operationId));

        bytes32 readyState = bytes32(uint256(1) << uint8(TimelockController.OperationState.Ready));
        vm.expectRevert(
            abi.encodeWithSelector(
                TimelockController.TimelockUnexpectedOperationState.selector, batch.operationId, readyState
            )
        );
        timelock.executeBatch(batch.targets, batch.values, batch.payloads, predecessor, input.salt);
        assertEq(target.sequence(), 0);
        assertEq(target.implementation(), address(0));

        vm.warp(block.timestamp + delay);
        timelock.executeBatch(batch.targets, batch.values, batch.payloads, predecessor, input.salt);

        assertTrue(timelock.isOperationDone(batch.operationId));
        assertEq(target.roleGrantSequence(), 1);
        assertEq(target.upgradeSequence(), 2);
        assertEq(target.grantedRole(), builder.PARAMETER_MANAGER_ROLE());
        assertEq(target.grantedMember(), address(input.module));
        assertEq(target.implementation(), input.implementation);
        assertEq(target.initializerHash(), keccak256(batch.initializer));

        vm.expectRevert(
            abi.encodeWithSelector(
                TimelockController.TimelockUnexpectedOperationState.selector, batch.operationId, readyState
            )
        );
        timelock.executeBatch(batch.targets, batch.values, batch.payloads, predecessor, input.salt);
        assertEq(target.sequence(), 2);
    }

    // ============ Fail-Closed Validation ============

    function test_validateInput_FailsClosedOnEveryPlaceholderAndBound() public {
        BuildV3UpgradeBatch.UpgradeInput memory valid = input;
        input.implementation = address(0);
        _expectInvalid("implementation");
        input = valid;
        input.module = IStakedUSDatEligibleIncomeModule(address(0));
        _expectInvalid("module");
        input = valid;
        input.adapter = IEligibleIncomeAdapter(address(0));
        _expectInvalid("adapter");
        input = valid;
        input.configManager = address(0);
        _expectInvalid("configManager");
        input = valid;
        input.maxUnreviewedGrowthBps = 0;
        _expectInvalid("maxUnreviewedGrowthBps");
        input = valid;
        input.maxUnreviewedGrowthBps = 10_001;
        _expectInvalid("maxUnreviewedGrowthBps");
        input = valid;
        input.salt = bytes32(0);
        _expectInvalid("salt");
    }

    function test_productionManifest_RemainsUnapprovedAndUnset() public view {
        assertFalse(builder.CONFIGURATION_APPROVED());
        BuildV3UpgradeBatch.UpgradeInput memory production = builder.productionInput();
        assertEq(production.implementation, address(0));
        assertEq(address(production.module), address(0));
        assertEq(address(production.adapter), address(0));
        assertEq(production.configManager, address(0));
        assertEq(production.maxUnreviewedGrowthBps, 0);
        assertEq(production.salt, bytes32(0));
    }

    function test_runFailsClosedBeforeBuildingAnUnapprovedProductionBatch() public {
        vm.chainId(builder.EXPECTED_CHAIN_ID());
        vm.expectRevert(
            abi.encodeWithSelector(BuildV3UpgradeBatch.InvalidConfiguration.selector, "CONFIGURATION_APPROVED")
        );
        builder.run();
    }

    function test_runRejectsWrongChainFirst() public {
        vm.chainId(31337);
        vm.expectRevert(abi.encodeWithSelector(BuildV3UpgradeBatch.WrongChain.selector, 31337));
        builder.run();
    }

    // ============ Helpers ============

    function _selector(bytes memory data) private pure returns (bytes4 result) {
        assembly ("memory-safe") {
            result := mload(add(data, 0x20))
        }
    }

    function _expectInvalid(string memory field) private {
        vm.expectRevert(abi.encodeWithSelector(BuildV3UpgradeBatch.InvalidConfiguration.selector, field));
        builder.validateInput(input);
    }
}
