// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

interface ISTRConPriceOracleConfig {
    function setPriceBounds(uint256 newMinPrice, uint256 newMaxPrice) external;
    function setMaxApiStaleness(uint256 newStaleness) external;
    function setDeviationBps(uint256 newDeviationBps) external;
}
