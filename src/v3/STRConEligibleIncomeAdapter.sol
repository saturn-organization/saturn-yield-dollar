// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {ISyntheticSharesOracle} from "../v2/interfaces/oracles/ISyntheticSharesOracle.sol";
import {IEligibleIncomeAdapter} from "./interfaces/IEligibleIncomeAdapter.sol";

/**
 * @title STRConEligibleIncomeAdapter
 * @notice Reads STRCon's cumulative shares multiplier as the raw unit-income index.
 * @dev Structural changes are normalized by the vault, not by this immutable adapter.
 */
contract STRConEligibleIncomeAdapter is IEligibleIncomeAdapter {
    error InvalidZeroAddress();
    error InvalidSourceState();

    address public immutable override asset;
    ISyntheticSharesOracle public immutable SHARES_ORACLE;

    constructor(address asset_, ISyntheticSharesOracle sharesOracle_) {
        if (asset_ == address(0) || address(sharesOracle_) == address(0)) revert InvalidZeroAddress();
        asset = asset_;
        SHARES_ORACLE = sharesOracle_;
        rawIndex();
    }

    function rawIndex() public view override returns (uint256 index) {
        bool paused;
        (index, paused) = SHARES_ORACLE.getSValue(asset);
        if (paused || index == 0) revert InvalidSourceState();
    }
}
