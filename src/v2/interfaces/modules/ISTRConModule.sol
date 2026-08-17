// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {ISTRConPriceOracle} from "../oracles/ISTRConPriceOracle.sol";
import {ITradableModule} from "./ITradableModule.sol";

/**
 * @title ISTRConModule
 * @author Saturn
 * @notice STRCon-specific tradable-module interface with a rotatable price oracle.
 */
interface ISTRConModule is ITradableModule {
    /**
     * @notice Returns the vault permanently bound to this module.
     */
    function VAULT() external view returns (address);

    /**
     * @notice Returns the STRCon asset permanently bound to this module.
     */
    function ASSET() external view returns (address);

    /**
     * @notice Returns the active 8-decimal STRCon price oracle.
     */
    function oracle() external view returns (ISTRConPriceOracle);

    /**
     * @notice Replaces the active oracle after module-level compatibility checks.
     */
    function setOracle(address newOracle) external;
}
