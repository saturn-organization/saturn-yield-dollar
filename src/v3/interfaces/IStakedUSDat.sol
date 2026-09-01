// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IStakedUSDat as IStakedUSDatV2} from "../../v2/interfaces/IStakedUSDat.sol";
import {IEligibleIncomeAccounting} from "./IEligibleIncomeAccounting.sol";
import {IStakedUSDatEligibleIncomeModule} from "./IStakedUSDatEligibleIncomeModule.sol";

interface IStakedUSDat is IStakedUSDatV2 {
    function initializeV3(
        IStakedUSDatEligibleIncomeModule module,
        IEligibleIncomeAccounting.EligibleIncomeConfig calldata config
    ) external;
    function eligibleIncomeModule() external view returns (IStakedUSDatEligibleIncomeModule);
}
