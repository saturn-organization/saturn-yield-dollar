// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

/**
 * @title IEligibleIncomeAdapter
 * @notice Asset-specific source for a cumulative eligible-income unit index.
 * @dev Implementations must fail closed while their source is unhealthy.
 */
interface IEligibleIncomeAdapter {
    function asset() external view returns (address);

    function rawIndex() external view returns (uint256);
}
