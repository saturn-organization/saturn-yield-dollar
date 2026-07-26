// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title ISwapFacility
 * @dev Minimal interface for M0's SwapFacility
 * (Ethereum: 0xB6807116b3B1B321a390594e31ECD6e0076f6278). Zero-fee swaps between
 * supported tokens (e.g. USDC → USDat); paths are permissioned per swapper
 * (`canSwapViaPath`).
 */
interface ISwapFacility {
    function swap(address tokenIn, address tokenOut, uint256 amount, address recipient) external;
}
