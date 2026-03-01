// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IPriceOracle} from "../../src/interfaces/IPriceOracle.sol";

/**
 * @title MockChainlinkOracle
 * @notice A mock Chainlink-compatible oracle for testing on testnets
 * @dev Returns a fixed price of $100 (100e8 with 8 decimals)
 *      Call `heartbeat()` to refresh the timestamp and prevent staleness
 */
contract MockChainlinkOracle is IPriceOracle {
    /// @notice Fixed price of $100 with 8 decimals
    int256 public constant PRICE = 100e8;

    /// @notice Oracle decimals (matches Chainlink standard)
    uint8 public constant DECIMALS = 8;

    /// @notice Timestamp of the last heartbeat
    uint256 public updatedAt;

    /// @notice Emitted when heartbeat is called
    event Heartbeat(uint256 timestamp);

    constructor() {
        updatedAt = block.timestamp;
    }

    /**
     * @notice Updates the timestamp to current block time
     * @dev Call this periodically to keep the oracle fresh
     */
    function heartbeat() external {
        updatedAt = block.timestamp;
        emit Heartbeat(block.timestamp);
    }

    /**
     * @inheritdoc IPriceOracle
     */
    function latestRoundData()
        external
        view
        override
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt_,
            uint80 answeredInRound
        )
    {
        return (1, PRICE, updatedAt, updatedAt, 1);
    }

    /**
     * @inheritdoc IPriceOracle
     */
    function decimals() external pure override returns (uint8) {
        return DECIMALS;
    }
}
