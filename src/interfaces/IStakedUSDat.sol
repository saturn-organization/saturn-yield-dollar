// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IStakedUSDat {
    function isBlacklisted(address account) external view returns (bool);
}
