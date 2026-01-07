// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IStakedUSDat {
    function isBlacklisted(address account) external view returns (bool);

    function burnQueuedShares(uint256 shares, uint256 strcAmount) external;

    function previewRedeem(uint256 shares) external view returns (uint256);
}
