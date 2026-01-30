// SPDX-License-Identifier: MIT
// Compatible with OpenZeppelin Contracts ^5.4.0
pragma solidity ^0.8.27;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {ITokenizedSTRC} from "./interfaces/ITokenizedSTRC.sol";
import {IPriceOracle} from "./interfaces/IPriceOracle.sol";

/**
 * @title TokenizedSTRC
 * @author Saturn
 * @notice Implementation of the ITokenizedSTRC interface.
 * @dev See {ITokenizedSTRC} for full documentation.
 */
contract TokenizedSTRC is ERC20, ERC20Burnable, ReentrancyGuard, AccessControl, ITokenizedSTRC {
    using SafeERC20 for IERC20;

    /// @notice Maximum allowed staleness setting (6 hours)
    uint256 public constant MAX_STALENESS = 6 hours;

    /// @notice Role identifier for the StakedUSDat contract
    bytes32 public constant STAKED_USDAT_ROLE = keccak256("STAKED_USDAT_ROLE");

    /// @notice The current maximum price staleness setting.
    uint256 public maxPriceStaleness;

    /// @notice The minimum acceptable price from the oracle.
    uint256 public minPrice;

    /// @notice The maximum acceptable price from the oracle.
    uint256 public maxPrice;

    /// @dev The price oracle contract
    IPriceOracle private oracle;

    constructor(address defaultAdmin, address oracleAddress) ERC20("TokenizedSTRC", "tSTRC") {
        _grantRole(DEFAULT_ADMIN_ROLE, defaultAdmin);

        oracle = IPriceOracle(oracleAddress);
        maxPriceStaleness = 2 hours; // Oracle heartbeat is 1 hr
        minPrice = 20e8; // $20 with 8 decimals
        maxPrice = 150e8; // $150 with 8 decimals
    }

    /// @inheritdoc ITokenizedSTRC
    function mint(address to, uint256 amount) public onlyRole(STAKED_USDAT_ROLE) {
        _mint(to, amount);
    }

    /// @inheritdoc ITokenizedSTRC
    function rescueTokens(address token, uint256 amount, address to)
        external
        nonReentrant
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        IERC20(token).safeTransfer(to, amount);
    }

    /// @inheritdoc ITokenizedSTRC
    function updateOracle(address newOracle) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newOracle != address(0), InvalidZeroAddress());
        address oldOracle = address(oracle);
        oracle = IPriceOracle(newOracle);
        emit OracleUpdated(oldOracle, newOracle);
    }

    /// @inheritdoc ITokenizedSTRC
    function setMaxPriceStaleness(uint256 newStaleness) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newStaleness <= MAX_STALENESS, InvalidStaleness());
        maxPriceStaleness = newStaleness;
        emit MaxPriceStalenessUpdated(newStaleness);
    }

    /// @inheritdoc ITokenizedSTRC
    function setPriceBounds(uint256 newMinPrice, uint256 newMaxPrice) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newMinPrice > 0 && newMinPrice < newMaxPrice, InvalidPriceBounds());
        minPrice = newMinPrice;
        maxPrice = newMaxPrice;
        emit PriceBoundsUpdated(newMinPrice, newMaxPrice);
    }

    /// @inheritdoc ITokenizedSTRC
    function getOracle() external view returns (address) {
        return address(oracle);
    }

    /// @inheritdoc ITokenizedSTRC
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
