// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IWithdrawalQueueERC721 {
    function addRequest(address owner, uint256 strcAmount) external;

    function claimFor(address user) external returns (uint256 totalAmount);
}
