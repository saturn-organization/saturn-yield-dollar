// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {ISTRConModule} from "../../interfaces/modules/ISTRConModule.sol";
import {ITradableModule} from "../../interfaces/modules/ITradableModule.sol";
import {ISTRConPriceOracle} from "../../interfaces/oracles/ISTRConPriceOracle.sol";

/**
 * @title STRConModule
 * @author Saturn
 * @notice Accounting module for the vault's STRCon position.
 */
contract STRConModule is ISTRConModule {
    error InvalidZeroAddress();
    error InvalidOracle();
    error InsufficientBalance();
    error NotVault();
    error Unauthorized();

    event OracleUpdated(address indexed oldOracle, address indexed newOracle);

    bytes32 public constant PARAMETER_MANAGER_ROLE = keccak256("PARAMETER_MANAGER_ROLE");
    uint8 public constant ORACLE_DECIMALS = 8;

    address public immutable VAULT;
    address public immutable ASSET;

    ISTRConPriceOracle public override oracle;
    uint256 public override balance;

    modifier onlyVault() {
        if (msg.sender != VAULT) revert NotVault();
        _;
    }

    modifier onlyVaultRole(bytes32 role) {
        if (!IAccessControl(VAULT).hasRole(role, msg.sender)) {
            revert Unauthorized();
        }
        _;
    }

    constructor(address vault, address asset_, ISTRConPriceOracle initialOracle) {
        if (vault == address(0) || asset_ == address(0)) {
            revert InvalidZeroAddress();
        }

        VAULT = vault;
        ASSET = asset_;

        _setOracle(address(initialOracle));
    }

    /// @notice Returns the recognized STRCon position value in 6-decimal USDat units.
    /// @dev STRCon balance (18 decimals) multiplied by oracle price (8 decimals) has
    /// 26 decimals; dividing by 1e20 leaves 6 decimals. The conversion rounds down.
    function recognizedValue() external view returns (uint256) {
        uint256 currentBalance = balance;
        if (currentBalance == 0) return 0;

        return Math.mulDiv(currentBalance, oracle.getPrice(), 1e20, Math.Rounding.Floor);
    }

    /// @inheritdoc ITradableModule
    function asset() external view returns (address) {
        return ASSET;
    }

    /// @inheritdoc ITradableModule
    function getPrice() external view returns (uint256) {
        return oracle.getPrice();
    }

    /// @inheritdoc ITradableModule
    function buy(uint256 assetReceived) external onlyVault {
        balance += assetReceived;
    }

    /// @inheritdoc ITradableModule
    function sell(uint256 assetDelivered) external onlyVault {
        if (assetDelivered > balance) revert InsufficientBalance();

        balance -= assetDelivered;
    }

    /// @inheritdoc ISTRConModule
    function setOracle(address newOracle) external onlyVaultRole(PARAMETER_MANAGER_ROLE) {
        address oldOracle = address(oracle);
        _setOracle(newOracle);
        emit OracleUpdated(oldOracle, newOracle);
    }

    function _setOracle(address newOracle) private {
        if (newOracle == address(0) || newOracle.code.length == 0) {
            revert InvalidOracle();
        }

        ISTRConPriceOracle newPriceOracle = ISTRConPriceOracle(newOracle);
        if (newPriceOracle.decimals() != ORACLE_DECIMALS) {
            revert InvalidOracle();
        }

        oracle = newPriceOracle;
    }
}
