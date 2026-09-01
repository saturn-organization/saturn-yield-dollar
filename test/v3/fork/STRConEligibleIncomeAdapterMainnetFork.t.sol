// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";

import {ISyntheticSharesOracle} from "../../../src/v2/interfaces/oracles/ISyntheticSharesOracle.sol";
import {STRConEligibleIncomeAdapter} from "../../../src/v3/STRConEligibleIncomeAdapter.sol";

/**
 * @notice Read-only pinned-fork check of the concrete STRCon multiplier binding.
 * @dev Run with RUN_V3_STRCON_FORK=true and RPC_URL set.
 */
contract STRConEligibleIncomeAdapterMainnetForkTest is Test {
    uint256 private constant PINNED_MAINNET_BLOCK = 25_627_322;
    address private constant STRCON = 0xECABE1Ff8a9e1dC55899cf58dac8497ecE5Ae84c;
    address private constant SYNTHETIC_SHARES_ORACLE = 0x9BC39DB6fbB44B91a48b8D5A6C208B82B1741bE6;

    function test_pinnedMainnetBindingReadsExactlyAndFailsClosedWhenPaused() public {
        if (!vm.envOr("RUN_V3_STRCON_FORK", false)) {
            vm.skip(true, "set RUN_V3_STRCON_FORK=true to run the pinned adapter check");
            return;
        }
        require(vm.envExists("RPC_URL"), "RPC_URL is required");
        vm.createSelectFork(vm.envString("RPC_URL"), PINNED_MAINNET_BLOCK);

        ISyntheticSharesOracle oracle = ISyntheticSharesOracle(SYNTHETIC_SHARES_ORACLE);
        (uint256 expected, bool paused) = oracle.getSValue(STRCON);
        assertGt(expected, 0);

        if (paused) {
            vm.expectRevert(STRConEligibleIncomeAdapter.InvalidSourceState.selector);
            new STRConEligibleIncomeAdapter(STRCON, oracle);
            return;
        }

        STRConEligibleIncomeAdapter adapter = new STRConEligibleIncomeAdapter(STRCON, oracle);
        assertEq(adapter.rawIndex(), expected);

        vm.mockCall(
            SYNTHETIC_SHARES_ORACLE,
            abi.encodeCall(ISyntheticSharesOracle.getSValue, (STRCON)),
            abi.encode(expected, true)
        );
        vm.expectRevert(STRConEligibleIncomeAdapter.InvalidSourceState.selector);
        adapter.rawIndex();
    }
}
