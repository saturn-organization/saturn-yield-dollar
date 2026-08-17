// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IPriceOracle} from "../../interfaces/oracles/IPriceOracle.sol";
import {ISTRConPriceOracle} from "../../interfaces/oracles/ISTRConPriceOracle.sol";
import {ISyntheticSharesOracle} from "../../interfaces/oracles/ISyntheticSharesOracle.sol";

/**
 * @title STRConPriceOracle
 * @author Saturn
 * @notice Fail-closed STRCon/USD price wrapper over immutable primary and reference feeds.
 * @dev The Calculated feed is the primary value-securing mark. The API feed is only a
 * fresh circuit-breaker reference and is never returned.
 */
contract STRConPriceOracle is ISTRConPriceOracle {
    // ============ Errors ============

    error InvalidZeroAddress();
    error InvalidFeedDecimals();
    error Unauthorized();
    error InvalidOracleRound();
    error StaleReferencePrice();
    error AssetPaused();
    error InvalidSValue();
    error UnderlyingPriceOutOfBounds();
    error FeedDeviation();
    error InvalidPriceBounds();
    error InvalidStaleness();
    error InvalidDeviation();

    // ============ Events ============

    event PriceBoundsUpdated(uint256 newMinPrice, uint256 newMaxPrice);
    event MaxApiStalenessUpdated(uint256 newStaleness);
    event DeviationBpsUpdated(uint256 newDeviationBps);

    // ============ Constants ============

    bytes32 public constant PARAMETER_MANAGER_ROLE = keccak256("PARAMETER_MANAGER_ROLE");
    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint256 public constant MAX_API_STALENESS = 36 hours;
    uint256 public constant MAX_DEVIATION_BPS = 1_000;
    uint8 private constant FEED_DECIMALS = 8;

    // ============ Immutables ============

    address public immutable VAULT;
    address public immutable STRCON;
    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    ISyntheticSharesOracle public immutable syntheticSharesOracle;
    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    IPriceOracle public immutable primaryFeed;
    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    IPriceOracle public immutable referenceFeed;

    // ============ Storage ============

    uint256 public maxApiStaleness;
    uint256 public deviationBps;
    uint256 public minPrice;
    uint256 public maxPrice;

    // ============ Modifiers ============

    modifier onlyVaultRole(bytes32 role) {
        if (!IAccessControl(VAULT).hasRole(role, msg.sender)) revert Unauthorized();
        _;
    }

    constructor(
        address vault,
        address strcon,
        ISyntheticSharesOracle syntheticSharesOracle_,
        IPriceOracle primaryFeed_,
        IPriceOracle referenceFeed_,
        uint256 initialDeviationBps
    ) {
        if (
            vault == address(0) || strcon == address(0) || address(syntheticSharesOracle_) == address(0)
                || address(primaryFeed_) == address(0) || address(referenceFeed_) == address(0)
        ) {
            revert InvalidZeroAddress();
        }
        if (primaryFeed_.decimals() != FEED_DECIMALS || referenceFeed_.decimals() != FEED_DECIMALS) {
            revert InvalidFeedDecimals();
        }
        if (initialDeviationBps == 0 || initialDeviationBps > MAX_DEVIATION_BPS) revert InvalidDeviation();

        VAULT = vault;
        STRCON = strcon;
        syntheticSharesOracle = syntheticSharesOracle_;
        primaryFeed = primaryFeed_;
        referenceFeed = referenceFeed_;

        maxApiStaleness = 26 hours;
        deviationBps = initialDeviationBps;
        minPrice = 20e8;
        maxPrice = 150e8;
    }

    // ============ Price ============

    /// @inheritdoc ISTRConPriceOracle
    function decimals() external pure returns (uint8) {
        return FEED_DECIMALS;
    }

    /// @inheritdoc ISTRConPriceOracle
    function getPrice() external view returns (uint256) {
        (uint256 primaryPrice,) = _readValidRound(primaryFeed);
        (uint256 referencePrice, uint256 referenceUpdatedAt) = _readValidRound(referenceFeed);

        if (block.timestamp - referenceUpdatedAt > maxApiStaleness) revert StaleReferencePrice();

        (uint256 sValue, bool paused) = syntheticSharesOracle.getSValue(STRCON);
        if (paused) revert AssetPaused();
        if (sValue == 0) revert InvalidSValue();

        uint256 underlyingPrice = Math.mulDiv(primaryPrice, 1e18, sValue, Math.Rounding.Floor);
        if (underlyingPrice < minPrice || underlyingPrice > maxPrice) revert UnderlyingPriceOutOfBounds();

        uint256 difference =
            primaryPrice > referencePrice ? primaryPrice - referencePrice : referencePrice - primaryPrice;
        uint256 deviation = Math.mulDiv(difference, BPS_DENOMINATOR, primaryPrice, Math.Rounding.Ceil);
        if (deviation > deviationBps) revert FeedDeviation();

        return primaryPrice;
    }

    // ============ Configuration ============

    function setPriceBounds(uint256 newMinPrice, uint256 newMaxPrice) external onlyVaultRole(PARAMETER_MANAGER_ROLE) {
        if (newMinPrice == 0 || newMinPrice >= newMaxPrice) revert InvalidPriceBounds();

        minPrice = newMinPrice;
        maxPrice = newMaxPrice;

        emit PriceBoundsUpdated(newMinPrice, newMaxPrice);
    }

    function setMaxApiStaleness(uint256 newStaleness) external onlyVaultRole(PARAMETER_MANAGER_ROLE) {
        if (newStaleness == 0 || newStaleness > MAX_API_STALENESS) revert InvalidStaleness();

        maxApiStaleness = newStaleness;

        emit MaxApiStalenessUpdated(newStaleness);
    }

    function setDeviationBps(uint256 newDeviationBps) external onlyVaultRole(PARAMETER_MANAGER_ROLE) {
        if (newDeviationBps == 0 || newDeviationBps > MAX_DEVIATION_BPS) revert InvalidDeviation();

        deviationBps = newDeviationBps;

        emit DeviationBpsUpdated(newDeviationBps);
    }

    // ============ Internal ============

    function _readValidRound(IPriceOracle feed) private view returns (uint256 price, uint256 updatedAt) {
        (uint80 roundId, int256 answer,, uint256 roundUpdatedAt, uint80 answeredInRound) = feed.latestRoundData();

        if (
            roundId == 0 || answer <= 0 || roundUpdatedAt == 0 || roundUpdatedAt > block.timestamp
                || answeredInRound < roundId
        ) {
            revert InvalidOracleRound();
        }

        // forge-lint: disable-next-line(unsafe-typecast)
        price = uint256(answer);
        updatedAt = roundUpdatedAt;
    }
}
