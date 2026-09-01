// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IEligibleIncomeAccounting} from "../interfaces/IEligibleIncomeAccounting.sol";

library StakedUSDatEligibleIncomeStorage {
    // keccak256(abi.encode(uint256(keccak256("saturn.storage.StakedUSDatEligibleIncome")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 internal constant LOCATION = 0xdba54d44c2a871cf13cf62eb227db5a5c7a6c3cd2ca45e904263d8462d4faf00;

    struct Layout {
        IEligibleIncomeAccounting.IncomeState state;
        address adapter;
        address asset;
        uint16 maxUnreviewedGrowthBps;
        uint64 lastSettlementBlock;
        bool configMediationActive;
        uint256 lastAcceptedRawIndex;
        uint256 lastEligibleUnitIndexWad;
        uint256 cumulativeStructuralAdjustmentFactorWad;
        uint256 eligibleUnitsPerSUSDatShareWad;
        uint256 lastRoundingRemainder;
        // Affine lifecycle transform: live units = a*x+b; crystallized value = c*x+d.
        uint256 liveUnitScaleWad;
        uint256 liveUnitsOffsetWad;
        uint256 crystallizedValueScaleWad;
        uint256 crystallizedValueOffsetWad;
        uint256 crystallizationNonce;
        bytes32 lastResolutionEvidence;
        uint256 fundedUSDat;
        uint256 pendingFundedUSDat;
        uint256 recognizedUSDat;
        uint256 recognizedUSDatPerSUSDatShareWad;
        uint256 lastUSDatRoundingRemainder;
    }

    function layout() internal pure returns (Layout storage $) {
        assembly ("memory-safe") {
            $.slot := LOCATION
        }
    }
}
