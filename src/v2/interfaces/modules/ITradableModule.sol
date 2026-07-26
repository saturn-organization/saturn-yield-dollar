// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IAccountingModule} from "./IAccountingModule.sol";

/**
 * @title ITradableModule
 * @author Saturn
 * @notice Accounting adapter for an asset that the StakedUSDat vault can trade.
 */
interface ITradableModule is IAccountingModule {
    /**
     * @notice Returns the ERC20 asset fixed by the concrete module.
     */
    function asset() external view returns (address);

    /**
     * @notice Returns the validated USD price of one whole asset.
     * @dev Uses 8 decimals.
     */
    function getPrice() external view returns (uint256);

    /**
     * @notice Recognizes a completed inbound asset delivery.
     * @dev Callable only by the vault in concrete implementations.
     */
    function buy(uint256 assetReceived) external;

    /**
     * @notice Derecognizes an asset quantity before outbound delivery.
     * @dev Callable only by the vault in concrete implementations.
     */
    function sell(uint256 assetDelivered) external;
}
