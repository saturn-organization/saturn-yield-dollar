// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface ITokenizedSTRC {
    function getPrice() external view returns (uint256 price, uint8 decimals);

    function balanceOf(address account) external view returns (uint256);

    function mint(address to, uint256 amount) external;
}
