// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IERC20Burnable
 * @notice Interface for ERC20 tokens with burn functionality.
 */
interface IERC20Burnable {
    /**
     * @notice Burns a specific amount of tokens from the caller's balance.
     * @param amount The amount of tokens to burn.
     */
    function burn(uint256 amount) external;
}
