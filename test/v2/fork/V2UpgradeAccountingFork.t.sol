// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {Test} from "forge-std/Test.sol";

import {BuildV2UpgradeBatch} from "../../../script/v2/upgrade/BuildV2UpgradeBatch.s.sol";
import {UpgradeConfig} from "../../../script/v2/configs/UpgradeConfig.sol";

/// @dev Executes the configured upgrade only on a fork of the latest RPC state.
/// Run: RUN_V2_UPGRADE_ACCOUNTING_FORK=true forge test --match-path test/v2/fork/V2UpgradeAccountingFork.t.sol -vv
contract V2UpgradeAccountingForkTest is Test, UpgradeConfig {
    function test_latestUpgrade_PrintsAccountingChanges() public {
        if (!vm.envOr("RUN_V2_UPGRADE_ACCOUNTING_FORK", false)) {
            vm.skip(true, "set RUN_V2_UPGRADE_ACCOUNTING_FORK=true to run the latest-state upgrade rehearsal");
            return;
        }

        vm.createSelectFork(vm.envString("RPC_URL"));
        assertEq(block.chainid, EXPECTED_CHAIN_ID);

        IERC4626 vault = IERC4626(STAKED_USDAT_PROXY);
        uint256 assetsBefore = vault.totalAssets();
        uint256 priceBefore = vault.convertToAssets(1e18);

        BuildV2UpgradeBatch.UpgradeBatch memory batch = new BuildV2UpgradeBatch().buildBatch();
        TimelockController(payable(TIMELOCK))
            .executeBatch(batch.targets, batch.values, batch.payloads, UPGRADE_PREDECESSOR, BATCH_SALT);

        emit log_named_decimal_int("Total assets change (USDat)", int256(vault.totalAssets()) - int256(assetsBefore), 6);
        emit log_named_decimal_int(
            "Share price change (USDat per sUSDat)", int256(vault.convertToAssets(1e18)) - int256(priceBefore), 6
        );
    }
}
