// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IWithdrawalQueueERC721 {
    function addRequest(address owner, uint256 shares, uint256 minUsdatReceived) external returns (uint256 tokenId);

    function claimAllFor(address user) external returns (uint256 totalAmount);

    function claimBatchFor(address user, uint256[] calldata tokenIds) external returns (uint256 totalAmount);
}
