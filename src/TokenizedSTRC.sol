// SPDX-License-Identifier: MIT
// Compatible with OpenZeppelin Contracts ^5.4.0
pragma solidity ^0.8.27;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @notice Interface for price oracle (Chainlink-compatible)
interface IPriceOracle {
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);

    function decimals() external view returns (uint8);
}

/// @title tSTRC
/// @notice The tSTRC token is used to track the amount of STRC that is held in the off chain entity.
/// This token is minted and directly transferred to sUSDat during the mint process. The mint
/// process starts with the user calling deposit on the sUSDat contract. At the same time the
/// sUSDat entity purchases STRC from the market, tSTRC is deposited into the sUSDat contract.

contract TokenizedSTRC is ERC20, ERC20Burnable, ReentrancyGuard, AccessControl, ERC20Permit {
    using SafeERC20 for IERC20;

    error InvalidOraclePrice();
    error InvalidZeroAddress();
    error InvalidStaleness();
    error InvalidPriceBounds();

    uint256 public maxPriceStaleness;

    /// @notice Maximum allowed staleness setting
    uint256 public constant MAX_STALENESS = 6 hours;

    /// @notice Minimum acceptable price from oracle (default $20 with 8 decimals)
    uint256 public minPrice;
    /// @notice Maximum acceptable price from oracle (default $150 with 8 decimals)
    uint256 public maxPrice;

    event MaxPriceStalenessUpdated(uint256 newStaleness);
    event PriceBoundsUpdated(uint256 newMinPrice, uint256 newMaxPrice);

    // sUSDat contract is the only entity that can mint tSTRC
    // need to set after deploying sUSDat
    bytes32 public constant STAKED_USDAT_ROLE = keccak256("STAKED_USDAT_ROLE");

    IPriceOracle private oracle;

    event OracleUpdated(address indexed oldOracle, address indexed newOracle);

    constructor(address defaultAdmin, address oracleAddress)
        ERC20("TokenizedSTRC", "tSTRC")
        ERC20Permit("TokenizedSTRC")
    {
        _grantRole(DEFAULT_ADMIN_ROLE, defaultAdmin);

        oracle = IPriceOracle(oracleAddress);
        maxPriceStaleness = 2 hours; //Oracle heartbeat is 1 hr
        minPrice = 20e8; // $20 with 8 decimals
        maxPrice = 150e8; // $150 with 8 decimals
    }

    function mint(address to, uint256 amount) public onlyRole(STAKED_USDAT_ROLE) {
        _mint(to, amount);
    }

    function rescueTokens(address token, uint256 amount, address to)
        external
        nonReentrant
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        IERC20(token).safeTransfer(to, amount);
    }

    function updateOracle(address newOracle) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newOracle != address(0), InvalidZeroAddress());
        address oldOracle = address(oracle);
        oracle = IPriceOracle(newOracle);
        emit OracleUpdated(oldOracle, newOracle);
    }

    /// @notice Updates the maximum allowed price staleness
    /// @param newStaleness The new staleness value in seconds
    function setMaxPriceStaleness(uint256 newStaleness) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newStaleness <= MAX_STALENESS, InvalidStaleness());
        maxPriceStaleness = newStaleness;
        emit MaxPriceStalenessUpdated(newStaleness);
    }

    /// @notice Updates the acceptable price bounds
    /// @param newMinPrice The new minimum acceptable price
    /// @param newMaxPrice The new maximum acceptable price
    function setPriceBounds(uint256 newMinPrice, uint256 newMaxPrice) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newMinPrice > 0 && newMinPrice < newMaxPrice, InvalidPriceBounds());
        minPrice = newMinPrice;
        maxPrice = newMaxPrice;
        emit PriceBoundsUpdated(newMinPrice, newMaxPrice);
    }

    function getOracle() external view returns (address) {
        return address(oracle);
    }

    /// @notice Fetches the latest STRC price from the oracle
    /// @dev Uses latestRoundData for staleness checks (Chainlink recommended)
    /// @return price The latest price from the oracle (scaled by oracle decimals)
    /// @return oracleDecimals The number of decimals in the price
    function getPrice() external view returns (uint256 price, uint8 oracleDecimals) {
        require(address(oracle) != address(0), InvalidZeroAddress());

        (, int256 answer,, uint256 updatedAt,) = oracle.latestRoundData();

        // Staleness check
        require(block.timestamp - updatedAt <= maxPriceStaleness, InvalidOraclePrice());
        require(answer > 0, InvalidOraclePrice());

        // forge-lint: disable-next-line(unsafe-typecast)
        price = uint256(answer);

        // Bounds check
        require(price >= minPrice && price <= maxPrice, InvalidOraclePrice());

        oracleDecimals = oracle.decimals();
    }
}
