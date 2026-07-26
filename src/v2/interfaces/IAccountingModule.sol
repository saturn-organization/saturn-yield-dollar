// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IAccountingModule
 * @author Saturn
 * @notice Accounting adapter for a backing position of the StakedUSDat vault.
 */
interface IAccountingModule {
    /**
     * @notice Returns the USD value currently recognized by the vault.
     * @dev Uses 6 decimals, reverts when a nonzero position cannot be reliably
     * priced, and returns zero without pricing when `balance()` is zero.
     */
    function recognizedValue() external view returns (uint256);

    /**
     * @notice Returns the recognized position quantity maintained by the module.
     */
    function balance() external view returns (uint256);
}
