// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IEligibleIncomeAccounting} from "./IEligibleIncomeAccounting.sol";

interface IStakedUSDatEligibleIncomeModule is IEligibleIncomeAccounting {
    function VAULT() external view returns (address);
    function isActive() external view returns (bool);
    function canAccount() external view returns (bool);
    function beforeSupplyOrExposureChange() external returns (uint256 unitsPerShareIncrease);
    function afterSTRConSale(uint256 delivered, uint256 usdatReceived) external;
    function registerFundedUSDatSurplus(uint256 amount) external;
    function recognizeFundedUSDatSurplus(uint256 amount) external returns (uint256 valuePerShareIncreaseWad);
}
