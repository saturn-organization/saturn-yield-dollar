// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IAccountingModule} from "./IAccountingModule.sol";

/**
 * @title ISTRCMirrorModule
 * @author Saturn
 * @notice Migration interface for the fixed tokenless STRC accounting module.
 */
interface ISTRCMirrorModule is IAccountingModule {
    function VAULT() external view returns (address);

    function seeded() external view returns (bool);

    function retired() external view returns (bool);

    function getUnvestedAmount() external view returns (uint256);

    function seed(
        uint256 initialBalance,
        uint256 initialVestingAmount,
        uint256 initialLastDistributionTimestamp,
        uint256 initialVestingPeriod,
        uint256 initialMaxRewardsBps
    ) external;

    function retire() external;
}
