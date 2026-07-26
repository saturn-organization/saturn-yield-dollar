// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title ISTRConPriceOracle
 * @author Saturn
 * @notice Scalar 8-decimal STRCon/USD price interface.
 */
interface ISTRConPriceOracle {
    function decimals() external view returns (uint8);

    function getPrice() external view returns (uint256);
}
