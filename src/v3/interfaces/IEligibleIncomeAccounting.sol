// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IEligibleIncomeAdapter} from "./IEligibleIncomeAdapter.sol";

/**
 * @title IEligibleIncomeAccounting
 * @notice V3 sUSDat accounting for capitalized, unit-based STRCon income.
 */
interface IEligibleIncomeAccounting {
    // ============ Enums ============

    enum IncomeState {
        Uninitialized,
        Active,
        Review
    }

    // ============ Structs ============

    struct EligibleIncomeConfig {
        IEligibleIncomeAdapter adapter;
        address configManager;
        uint16 maxUnreviewedGrowthBps;
    }

    struct EligibleIncomeState {
        IncomeState state;
        address adapter;
        address asset;
        uint16 maxUnreviewedGrowthBps;
        uint64 lastSettlementBlock;
        uint256 lastAcceptedRawIndex;
        uint256 lastEligibleUnitIndexWad;
        uint256 cumulativeStructuralAdjustmentFactorWad;
        uint256 eligibleUnitsPerSUSDatShareWad;
        // Numerator remainder from the latest materialization. It is never carried across supply changes.
        uint256 lastRoundingRemainder;
        // Affine lifecycle transform: live units = a*x+b; crystallized value = c*x+d.
        // Consumers checkpoint (a,b,c,d) and derive the relative transform since that checkpoint.
        uint256 liveUnitScaleWad;
        uint256 liveUnitsOffsetWad;
        uint256 crystallizedValueScaleWad;
        uint256 crystallizedValueOffsetWad;
        uint256 crystallizationNonce;
        bytes32 lastResolutionEvidence;
        bool configMediationActive;
        uint256 fundedUSDat;
        uint256 pendingFundedUSDat;
        uint256 recognizedUSDat;
        uint256 recognizedUSDatPerSUSDatShareWad;
        uint256 lastUSDatRoundingRemainder;
    }

    // ============ Errors ============

    error EligibleIncomeNotActive();
    error EligibleIncomeNotInReview();
    error InvalidEligibleIncomeAdapter();
    error InvalidEligibleIncomeIndex();
    error EligibleIncomeCustodyShortfall();
    error EligibleIncomeGrowthTooLarge();
    error InvalidStructuralAdjustment();
    error FullSTRConExitRequiresReview();
    error FundedUSDatSurplusExceeded();

    // ============ Events ============

    event EligibleIncomeInitialized(address indexed adapter, address indexed asset, address indexed configManager);
    event EligibleIncomeConfigManagerUpdated(address indexed oldManager, address indexed newManager);
    event EligibleIncomeMaterialized(
        uint256 indexed rawIndex,
        uint256 normalizedIndex,
        uint256 exposure,
        uint256 supply,
        uint256 unitsPerShareIncrease
    );
    event EligibleIncomeReviewEntered(bytes32 indexed evidence);
    event EligibleIncomeResumed(bytes32 indexed evidence);
    event NeutralStructuralAdjustmentResolved(
        uint256 oldFactorWad, uint256 newFactorWad, uint256 rawIndex, bytes32 indexed evidence
    );
    event STRConIncomeCrystallized(
        uint256 indexed nonce, uint256 assetDelivered, uint256 usdatReceived, uint256 remainingExposure
    );
    event MaxUnreviewedGrowthUpdated(uint16 oldBps, uint16 newBps);
    event EligibleIncomeDependencyConfigured(address indexed target, bytes4 indexed selector);
    event USDatSurplusFunded(uint256 amount, uint256 pendingFundedUSDat);
    event USDatSurplusRecognized(
        uint256 amount, uint256 supply, uint256 valuePerShareIncreaseWad, uint256 pendingFundedUSDat
    );

    // ============ Accounting Functions ============

    function initializeEligibleIncomeV3(EligibleIncomeConfig calldata config) external;
    function materializeSTRConEligibleIncome() external returns (uint256 unitsPerShareIncrease);
    function previewSTRConEligibleUnitsPerShareWad() external view returns (uint256);
    function eligibleIncomeState() external view returns (EligibleIncomeState memory);
    function enterSTRConIncomeReview(bytes32 evidence) external;
    function resumeSTRConIncome(bytes32 evidence) external;
    function resolveNeutralSTRConStructuralAdjustment(uint256 newFactorWad, bytes32 evidence) external;
    function setSTRConMaxUnreviewedGrowthBps(uint16 newBps) external;
    function configureEligibleIncomeDependency(address target, bytes calldata data) external;
}
