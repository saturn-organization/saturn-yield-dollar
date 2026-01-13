// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IStakedUSDat {
    function isBlacklisted(address account) external view returns (bool);

    function burnQueuedShares(uint256 shares, uint256 strcAmount) external;

    function totalAssets() external view returns (uint256);

    function asset() external view returns (address);

    function getUnvestedAmount() external view returns (uint256);

    function toleranceBps() external view returns (uint256);
}
