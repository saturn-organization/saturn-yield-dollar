// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IPriceOracle} from "../../interfaces/IPriceOracle.sol";
import {ISyntheticSharesOracle} from "../../interfaces/ISyntheticSharesOracle.sol";

/**
 * @title STRConPriceOracle
 * @author Saturn
 * @notice Validated STRCon/USD price: a wrapper over two Chainlink feeds (§2.3).
 * Primary — STRCon/USD (Ondo API), the recognized mark. Cross-check — STRCon/USD
 * (Calculated), exchange prints, regular market hours only.
 * @dev Fail-closed: getPrice() reverts when the price cannot be trusted — stale or
 * non-positive primary answer, sValue-adjusted price out of bounds, or contemporaneous
 * cross-feed disagreement. Access control resolves against the vault's role registry;
 * the oracle defines no roles of its own.
 */
contract STRConPriceOracle {
    error InvalidZeroAddress();
    error FeedDecimalsMismatch();
    error Unauthorized();
    error InvalidOraclePrice();
    error FeedDeviation();
    error InvalidPriceBounds();
    error InvalidStaleness();
    error InvalidSyncWindow();
    error InvalidDeviation();
    error AssetPaused();

    /// @dev Emitted when the primary feed is re-pointed.
    event PrimaryFeedUpdated(address oldFeed, address newFeed);
    /// @dev Emitted when the secondary feed is re-pointed.
    event SecondaryFeedUpdated(address oldFeed, address newFeed);
    event PriceBoundsUpdated(uint256 newMinPrice, uint256 newMaxPrice);
    event MaxPriceStalenessUpdated(uint256 newStaleness);
    event SyncWindowUpdated(uint256 newSyncWindow);
    event DeviationBpsUpdated(uint256 newDeviationBps);

    /// @notice Vault admin role id (AccessControl DEFAULT_ADMIN_ROLE)
    bytes32 public constant DEFAULT_ADMIN_ROLE = 0x00;

    /// @notice Role id on the vault authorized to tune oracle parameters
    bytes32 public constant PARAMETER_MANAGER_ROLE = keccak256("PARAMETER_MANAGER_ROLE");

    /// @notice Basis points denominator
    uint256 public constant BPS_DENOMINATOR = 10000;

    /// @notice Maximum allowed staleness setting (36 hours)
    uint256 public constant MAX_STALENESS = 36 hours;

    /// @notice Maximum allowed sync window setting (24 hours)
    uint256 public constant MAX_SYNC_WINDOW = 24 hours;

    /// @notice The StakedUSDat vault whose role registry gates setters
    address public immutable VAULT;

    /// @notice Ondo's SyntheticSharesOracle (sValue multiplier + per-asset pause flag)
    ISyntheticSharesOracle public immutable SVALUE_ORACLE;

    /// @notice The STRCon token (key into SVALUE_ORACLE)
    address public immutable STRCON;

    /// @notice Primary feed — STRCon/USD (Ondo API), the recognized mark, ~24h heartbeat
    IPriceOracle public primaryFeed;

    /// @notice Secondary feed — STRCon/USD (Calculated), cross-check only, prints
    /// regular market hours
    IPriceOracle public secondaryFeed;

    /// @notice The current maximum primary feed staleness setting. The primary
    /// heartbeats ~24h through market closures, so beyond this it is an outage.
    uint256 public maxPriceStaleness;

    /// @notice Maximum primary-vs-secondary deviation, in bps of the secondary print
    uint256 public deviationBps;

    /// @notice Maximum timestamp gap for two prints to count as contemporaneous.
    /// The deviation check only arms on contemporaneous prints; sized to price
    /// velocity (legit movement over the window ≪ deviationBps), never to the
    /// secondary's closure gaps.
    uint256 public syncWindow;

    /// @notice Minimum acceptable sValue-adjusted price (underlying STRC-equivalent,
    /// primary feed decimals)
    uint256 public minPrice;

    /// @notice Maximum acceptable sValue-adjusted price (underlying STRC-equivalent,
    /// primary feed decimals)
    uint256 public maxPrice;

    modifier onlyVaultRole(bytes32 role) {
        _requireVaultRole(role);
        _;
    }

    function _requireVaultRole(bytes32 role) internal view {
        require(IAccessControl(VAULT).hasRole(role, msg.sender), Unauthorized());
    }

    constructor(
        address vault,
        IPriceOracle primaryFeed_,
        IPriceOracle secondaryFeed_,
        ISyntheticSharesOracle sValueOracle,
        address strcon
    ) {
        require(
            vault != address(0) && address(sValueOracle) != address(0) && strcon != address(0), InvalidZeroAddress()
        );
        VAULT = vault;
        SVALUE_ORACLE = sValueOracle;
        STRCON = strcon;

        _setPrimaryFeed(primaryFeed_);
        _setSecondaryFeed(secondaryFeed_);

        maxPriceStaleness = 26 hours; // spans the primary's 24h weekend heartbeat
        deviationBps = 200; // 2% — both-fresh agreement measured ~0.15% (Appendix B)
        syncWindow = 1 hours;
        minPrice = 20e8; // $20 underlying, 8 decimals (v1 StrcPriceOracle bounds)
        maxPrice = 150e8; // $150 underlying, 8 decimals
    }

    /// @notice Re-points the primary feed (the recognized mark).
    /// @dev Caller must hold DEFAULT_ADMIN_ROLE on the vault — swapping the price
    /// source moves NAV.
    function setPrimaryFeed(IPriceOracle newFeed) external onlyVaultRole(DEFAULT_ADMIN_ROLE) {
        _setPrimaryFeed(newFeed);
    }

    /// @notice Re-points the secondary feed (the cross-check).
    /// @dev Caller must hold DEFAULT_ADMIN_ROLE on the vault.
    function setSecondaryFeed(IPriceOracle newFeed) external onlyVaultRole(DEFAULT_ADMIN_ROLE) {
        _setSecondaryFeed(newFeed);
    }

    function _setPrimaryFeed(IPriceOracle newFeed) internal {
        require(address(newFeed) != address(0), InvalidZeroAddress());
        // The tripwire compares the two answers raw — they must share decimals.
        if (address(secondaryFeed) != address(0)) {
            require(newFeed.decimals() == secondaryFeed.decimals(), FeedDecimalsMismatch());
        }

        address oldFeed = address(primaryFeed);
        primaryFeed = newFeed;

        emit PrimaryFeedUpdated(oldFeed, address(newFeed));
    }

    function _setSecondaryFeed(IPriceOracle newFeed) internal {
        require(address(newFeed) != address(0), InvalidZeroAddress());
        require(newFeed.decimals() == primaryFeed.decimals(), FeedDecimalsMismatch());

        address oldFeed = address(secondaryFeed);
        secondaryFeed = newFeed;

        emit SecondaryFeedUpdated(oldFeed, address(newFeed));
    }

    /// @notice Returns the validated STRCon/USD price (price, decimals).
    /// @dev Reverts when the price cannot be trusted: stale or non-positive primary
    /// answer, Ondo pause flag set, sValue-adjusted price out of bounds, or
    /// contemporaneous cross-feed disagreement.
    function getPrice() external view returns (uint256 price, uint8 oracleDecimals) {
        (, int256 answer,, uint256 updatedAt,) = primaryFeed.latestRoundData();

        require(block.timestamp - updatedAt <= maxPriceStaleness, InvalidOraclePrice());
        require(answer > 0, InvalidOraclePrice());

        // forge-lint: disable-next-line(unsafe-typecast)
        price = uint256(answer);

        _checkPriceBounds(price);
        _checkDeviation(price, updatedAt);

        oracleDecimals = primaryFeed.decimals();
    }

    /// @dev Requires the sValue-adjusted primary price — the underlying
    /// STRC-equivalent, price / sValue — to be within [minPrice, maxPrice].
    /// Dividing out the shares multiplier keeps the bounds meaningful as dividends
    /// compound into the mark (~1%/mo): they bound the underlying, not the drift.
    /// Also reverts while Ondo's per-asset pause flag is set (scheduled corporate
    /// actions — the mark is not trustworthy through them).
    function _checkPriceBounds(uint256 primaryPrice) internal view {
        (uint256 sValue, bool paused) = SVALUE_ORACLE.getSValue(STRCON);
        require(!paused, AssetPaused());
        require(sValue > 0, InvalidOraclePrice());

        // price (feed decimals) × 1e18 / sValue (18 decimals) → feed decimals
        uint256 underlyingPrice = Math.mulDiv(primaryPrice, 1e18, sValue);
        require(underlyingPrice >= minPrice && underlyingPrice <= maxPrice, InvalidOraclePrice());
    }

    /// @dev Requires contemporaneous prints (timestamps within syncWindow) to agree
    /// within deviationBps — two live prints disagreeing is a pricing fault. A silent
    /// secondary (nights/weekends/holidays — it prints market hours only) has no
    /// current opinion: the check disarms and the primary-only checks carry the
    /// weekend, the accepted risk (§5).
    function _checkDeviation(uint256 primaryPrice, uint256 primaryUpdatedAt) internal view {
        (, int256 answer,, uint256 updatedAt,) = secondaryFeed.latestRoundData();

        uint256 gap = primaryUpdatedAt > updatedAt ? primaryUpdatedAt - updatedAt : updatedAt - primaryUpdatedAt;
        if (gap > syncWindow) return;

        // A contemporaneous garbage print is a pricing fault, not clock skew.
        require(answer > 0, InvalidOraclePrice());

        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 secondaryPrice = uint256(answer);

        uint256 deviation =
            primaryPrice > secondaryPrice ? primaryPrice - secondaryPrice : secondaryPrice - primaryPrice;
        require(deviation <= Math.mulDiv(secondaryPrice, deviationBps, BPS_DENOMINATOR), FeedDeviation());
    }

    /// @notice Updates the acceptable underlying price bounds.
    /// @dev Caller must hold PARAMETER_MANAGER_ROLE on the vault. Bounds are
    /// sValue-adjusted (underlying STRC-equivalent), so routine dividend compounding
    /// never requires touching them.
    function setPriceBounds(uint256 newMinPrice, uint256 newMaxPrice) external onlyVaultRole(PARAMETER_MANAGER_ROLE) {
        require(newMinPrice > 0 && newMinPrice < newMaxPrice, InvalidPriceBounds());

        minPrice = newMinPrice;
        maxPrice = newMaxPrice;

        emit PriceBoundsUpdated(newMinPrice, newMaxPrice);
    }

    /// @notice Updates the maximum primary feed staleness.
    /// @dev Caller must hold PARAMETER_MANAGER_ROLE on the vault. Capped at
    /// MAX_STALENESS; must stay above the primary's 24h heartbeat or every quiet
    /// weekend reverts pricing.
    function setMaxPriceStaleness(uint256 newStaleness) external onlyVaultRole(PARAMETER_MANAGER_ROLE) {
        require(newStaleness > 0 && newStaleness <= MAX_STALENESS, InvalidStaleness());

        maxPriceStaleness = newStaleness;

        emit MaxPriceStalenessUpdated(newStaleness);
    }

    /// @notice Updates the contemporaneity window for the deviation check.
    /// @dev Caller must hold PARAMETER_MANAGER_ROLE on the vault. Sized to price
    /// velocity: legitimate movement over the window must stay well below
    /// deviationBps, or real drift reads as a fault.
    function setSyncWindow(uint256 newSyncWindow) external onlyVaultRole(PARAMETER_MANAGER_ROLE) {
        require(newSyncWindow > 0 && newSyncWindow <= MAX_SYNC_WINDOW, InvalidSyncWindow());

        syncWindow = newSyncWindow;

        emit SyncWindowUpdated(newSyncWindow);
    }

    /// @notice Updates the maximum cross-feed deviation (bps of the secondary print).
    /// @dev Caller must hold PARAMETER_MANAGER_ROLE on the vault.
    function setDeviationBps(uint256 newDeviationBps) external onlyVaultRole(PARAMETER_MANAGER_ROLE) {
        require(newDeviationBps > 0 && newDeviationBps <= BPS_DENOMINATOR, InvalidDeviation());

        deviationBps = newDeviationBps;

        emit DeviationBpsUpdated(newDeviationBps);
    }
}
