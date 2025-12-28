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

/// @notice Interface for price oracle
interface IPriceOracle {
    function latestAnswer() external view returns (int256);

    function decimals() external view returns (uint8);
}

/// @title tSTRC
/// @notice The tSTRC token is used to track the amount of STRC that is held in the off chain entity.
/// This token is minted and directly transferred to sUSDat during the mint process. The mint
/// process starts with the user calling deposit on the sUSDat contract. At the same time the
/// sUSDat entity purchases STRC from the market, tSTRC is deposited into the sUSDat contract.

contract tokenizedSTRC is ERC20, ERC20Burnable, ReentrancyGuard, AccessControl, ERC20Permit {
    using SafeERC20 for IERC20;

    // sUSDat contract is the only entity that can mint tSTRC
    // need to set after deploying sUSDat
    bytes32 public constant STAKED_USDAT_ROLE = keccak256("STAKED_USDAT_ROLE");

    IPriceOracle private oracle;

    event OracleUpdated(address indexed oldOracle, address indexed newOracle);

    constructor(address defaultAdmin, address oracleAddress)
        ERC20("tokenizedSTRC", "tSTRC")
        ERC20Permit("tokenizedSTRC")
    {
        _grantRole(DEFAULT_ADMIN_ROLE, defaultAdmin);

        oracle = IPriceOracle(oracleAddress);
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
        require(newOracle != address(0), "Invalid oracle address");
        address oldOracle = address(oracle);
        oracle = IPriceOracle(newOracle);
        emit OracleUpdated(oldOracle, newOracle);
    }

    function getOracle() external view returns (address) {
        return address(oracle);
    }

    /// @notice Fetches the latest STRC price from the oracle
    /// @return price The latest price from the oracle (scaled by oracle decimals)
    /// @return decimals The number of decimals in the price
    function getPrice() external view returns (uint256 price, uint8 decimals) {
        require(address(oracle) != address(0), "Oracle not set");

        int256 answer = oracle.latestAnswer();

        require(answer > 0, "Invalid price from oracle");

        // forge-lint: disable-next-line(unsafe-typecast)
        price = uint256(answer);
        decimals = oracle.decimals();
    }
}
