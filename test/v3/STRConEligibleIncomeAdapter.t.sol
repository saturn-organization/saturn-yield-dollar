// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";

import {ISyntheticSharesOracle} from "../../src/v2/interfaces/oracles/ISyntheticSharesOracle.sol";
import {STRConEligibleIncomeAdapter} from "../../src/v3/STRConEligibleIncomeAdapter.sol";

contract SharesOracleMock is ISyntheticSharesOracle {
    uint256 public value;
    bool public paused;

    function set(uint256 value_, bool paused_) external {
        value = value_;
        paused = paused_;
    }

    function getSValue(address) external view returns (uint256, bool) {
        return (value, paused);
    }
}

contract STRConEligibleIncomeAdapterTest is Test {
    address private asset = makeAddr("STRCon");
    SharesOracleMock private oracle;

    function setUp() public {
        oracle = new SharesOracleMock();
        oracle.set(1e18, false);
    }

    function test_bindsAssetAndReadsHealthyRawIndex() public {
        STRConEligibleIncomeAdapter adapter = new STRConEligibleIncomeAdapter(asset, oracle);
        assertEq(adapter.asset(), asset);
        assertEq(address(adapter.SHARES_ORACLE()), address(oracle));
        assertEq(adapter.rawIndex(), 1e18);
    }

    function test_constructorAndReadsFailClosedOnZeroOrPausedSource() public {
        oracle.set(0, false);
        vm.expectRevert(STRConEligibleIncomeAdapter.InvalidSourceState.selector);
        new STRConEligibleIncomeAdapter(asset, oracle);

        oracle.set(1e18, false);
        STRConEligibleIncomeAdapter adapter = new STRConEligibleIncomeAdapter(asset, oracle);
        oracle.set(1.1e18, true);
        vm.expectRevert(STRConEligibleIncomeAdapter.InvalidSourceState.selector);
        adapter.rawIndex();
    }

    function test_constructorRejectsZeroBindings() public {
        vm.expectRevert(STRConEligibleIncomeAdapter.InvalidZeroAddress.selector);
        new STRConEligibleIncomeAdapter(address(0), oracle);
        vm.expectRevert(STRConEligibleIncomeAdapter.InvalidZeroAddress.selector);
        new STRConEligibleIncomeAdapter(asset, ISyntheticSharesOracle(address(0)));
    }
}
