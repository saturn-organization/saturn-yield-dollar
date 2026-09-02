// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/**
 * @title STRCReferenceMetadata
 * @author Saturn
 * @notice Metadata-only descriptor for Pendle's offchain STRC accounting asset.
 * @dev This contract is not STRC, is not a claim on STRC, has no supply,
 *      balances, custody, or recovery functionality, and is non-transferable.
 *      Assets sent directly to this address may be irrecoverable.
 *      Pendle's stock oracle SY uses only `decimals()` onchain; the remaining
 *      ERC-20 metadata surface makes the reference semantics explicit to
 *      indexers. Its 18-decimal accounting convention matches the base-unit
 *      scale returned by the exchange-rate adapter and inherited by PT/YT.
 */
contract STRCReferenceMetadata is IERC20Metadata {
    error NonTransferableReference();

    function name() external pure returns (string memory) {
        return "STRC Accounting Reference";
    }

    function symbol() external pure returns (string memory) {
        return "STRC";
    }

    function decimals() external pure returns (uint8) {
        return 18;
    }

    function totalSupply() external pure returns (uint256) {
        return 0;
    }

    function balanceOf(address) external pure returns (uint256) {
        return 0;
    }

    function allowance(address, address) external pure returns (uint256) {
        return 0;
    }

    function transfer(address, uint256) external pure returns (bool) {
        revert NonTransferableReference();
    }

    function approve(address, uint256) external pure returns (bool) {
        revert NonTransferableReference();
    }

    function transferFrom(address, address, uint256) external pure returns (bool) {
        revert NonTransferableReference();
    }
}
