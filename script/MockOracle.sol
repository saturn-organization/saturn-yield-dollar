// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title MockOracle
/// @notice A mock Chainlink oracle for testing purposes only
/// @dev Implements the same interface as Chainlink's AggregatorV3Interface
contract MockOracle {
    int256 private _price;
    uint8 private constant DECIMALS = 8;
    uint256 private _updatedAt;
    address public owner;

    error OnlyOwner();

    modifier onlyOwner() {
        if (msg.sender != owner) revert OnlyOwner();
        _;
    }

    constructor(int256 initialPrice) {
        _price = initialPrice;
        _updatedAt = block.timestamp;
        owner = msg.sender;
    }

    function decimals() external pure returns (uint8) {
        return DECIMALS;
    }

    function latestRoundData()
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        )
    {
        return (1, _price, _updatedAt, _updatedAt, 1);
    }

    /// @notice Update the mock price (only owner)
    function setPrice(int256 newPrice) external onlyOwner {
        _price = newPrice;
        _updatedAt = block.timestamp;
    }

    /// @notice Update the timestamp (for testing staleness)
    function setUpdatedAt(uint256 timestamp) external onlyOwner {
        _updatedAt = timestamp;
    }

    /// @notice Refresh the timestamp to current block time
    function refreshTimestamp() external onlyOwner {
        _updatedAt = block.timestamp;
    }
}
