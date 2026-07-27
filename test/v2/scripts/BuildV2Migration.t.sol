// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {Test} from "forge-std/Test.sol";

import {BuildV2Migration} from "../../../script/v2/BuildV2Migration.s.sol";
import {IStakedUSDat} from "../../../src/v2/interfaces/IStakedUSDat.sol";

contract BuildV2MigrationTest is Test {
    BuildV2Migration private builder;

    function setUp() public {
        builder = new BuildV2Migration();
    }

    function test_buildOperation_EncodesExactMigrationTimelockOperation() public view {
        BuildV2Migration.MigrationOperation memory operation = builder.buildOperation();
        bytes memory expectedPayload =
            abi.encodeCall(IStakedUSDat.migrate, (builder.EXPECTED_STRCON(), builder.MIGRATION_DEADLINE()));

        assertEq(builder.TIMELOCK(), 0xfD5782E3BFF366601da3973aE30C583dE4F08A67);
        assertEq(builder.PROPOSER(), 0x610182581C93687Ca03F4a8E7f124f8cEC616820);
        assertEq(operation.target, builder.STAKED_USDAT_PROXY());
        assertEq(operation.value, 0);
        assertEq(operation.payload, expectedPayload);

        bytes memory expectedScheduleCalldata = abi.encodeCall(
            TimelockController.schedule,
            (
                operation.target,
                operation.value,
                expectedPayload,
                builder.PREDECESSOR(),
                builder.MIGRATION_SALT(),
                builder.TIMELOCK_DELAY()
            )
        );
        bytes memory expectedExecuteCalldata = abi.encodeCall(
            TimelockController.execute,
            (operation.target, operation.value, expectedPayload, builder.PREDECESSOR(), builder.MIGRATION_SALT())
        );

        assertEq(operation.scheduleCalldata, expectedScheduleCalldata);
        assertEq(operation.executeCalldata, expectedExecuteCalldata);
        assertEq(
            operation.operationId,
            keccak256(
                abi.encode(
                    operation.target, operation.value, expectedPayload, builder.PREDECESSOR(), builder.MIGRATION_SALT()
                )
            )
        );
    }
}
