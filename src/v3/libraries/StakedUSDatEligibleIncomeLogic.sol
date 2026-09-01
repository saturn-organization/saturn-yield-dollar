// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {ISTRCMirrorModule} from "../../v2/interfaces/modules/ISTRCMirrorModule.sol";
import {ISTRConModule} from "../../v2/interfaces/modules/ISTRConModule.sol";
import {IEligibleIncomeAccounting} from "../interfaces/IEligibleIncomeAccounting.sol";
import {IEligibleIncomeAdapter} from "../interfaces/IEligibleIncomeAdapter.sol";
import {StakedUSDatEligibleIncomeStorage} from "./StakedUSDatEligibleIncomeStorage.sol";

/**
 * @title StakedUSDatEligibleIncomeLogic
 * @notice Linked library for V3 eligible-income accounting.
 * @dev Keeps the near-limit vault deployable while retaining atomic module storage.
 */
library StakedUSDatEligibleIncomeLogic {
    uint256 private constant WAD = 1e18;
    uint256 private constant BPS_DENOMINATOR = 10_000;

    // ============ Initialization ============

    function initialize(
        IEligibleIncomeAccounting.EligibleIncomeConfig calldata config,
        address vault,
        ISTRCMirrorModule mirror,
        ISTRConModule module
    ) external returns (address adapter, address asset) {
        StakedUSDatEligibleIncomeStorage.Layout storage $ = StakedUSDatEligibleIncomeStorage.layout();
        if ($.state != IEligibleIncomeAccounting.IncomeState.Uninitialized) {
            revert IEligibleIncomeAccounting.InvalidEligibleIncomeAdapter();
        }
        adapter = address(config.adapter);
        asset = module.asset();
        uint256 exposure = module.balance();
        if (
            adapter.code.length == 0 || config.configManager == address(0)
                || config.maxUnreviewedGrowthBps > BPS_DENOMINATOR || !mirror.retired() || exposure == 0
                || config.adapter.asset() != asset
        ) revert IEligibleIncomeAccounting.InvalidEligibleIncomeAdapter();
        if (IERC20(asset).balanceOf(vault) < exposure) {
            revert IEligibleIncomeAccounting.EligibleIncomeCustodyShortfall();
        }

        uint256 rawIndex = config.adapter.rawIndex();
        if (rawIndex == 0) revert IEligibleIncomeAccounting.InvalidEligibleIncomeIndex();

        $.state = IEligibleIncomeAccounting.IncomeState.Active;
        $.adapter = adapter;
        $.asset = asset;
        $.maxUnreviewedGrowthBps = config.maxUnreviewedGrowthBps;
        $.lastSettlementBlock = uint64(block.number);
        $.lastAcceptedRawIndex = rawIndex;
        $.lastEligibleUnitIndexWad = rawIndex;
        $.cumulativeStructuralAdjustmentFactorWad = WAD;
        $.liveUnitScaleWad = WAD;
        $.configMediationActive = true;
    }

    // ============ Views and Materialization ============

    function preview(ISTRConModule module, uint256 supply) external view returns (uint256 cumulative) {
        StakedUSDatEligibleIncomeStorage.Layout storage $ = StakedUSDatEligibleIncomeStorage.layout();
        if ($.state != IEligibleIncomeAccounting.IncomeState.Active) {
            revert IEligibleIncomeAccounting.EligibleIncomeNotActive();
        }
        (uint256 rawIndex, uint256 normalized) = _readNormalized($);
        rawIndex;
        uint256 last = $.lastEligibleUnitIndexWad;
        _validateGrowth(last, normalized, $.maxUnreviewedGrowthBps);
        cumulative = $.eligibleUnitsPerSUSDatShareWad;
        if (normalized != last && supply != 0) {
            cumulative += Math.mulDiv(module.balance(), normalized - last, supply, Math.Rounding.Floor);
        }
    }

    function materialize(ISTRConModule module, uint256 supply, bool allowReview)
        external
        returns (uint256 unitsPerShareIncrease)
    {
        return _materialize(module, supply, allowReview);
    }

    function state() external view returns (IEligibleIncomeAccounting.EligibleIncomeState memory result) {
        StakedUSDatEligibleIncomeStorage.Layout storage $ = StakedUSDatEligibleIncomeStorage.layout();
        result = IEligibleIncomeAccounting.EligibleIncomeState({
            state: $.state,
            adapter: $.adapter,
            asset: $.asset,
            maxUnreviewedGrowthBps: $.maxUnreviewedGrowthBps,
            lastSettlementBlock: $.lastSettlementBlock,
            lastAcceptedRawIndex: $.lastAcceptedRawIndex,
            lastEligibleUnitIndexWad: $.lastEligibleUnitIndexWad,
            cumulativeStructuralAdjustmentFactorWad: $.cumulativeStructuralAdjustmentFactorWad,
            eligibleUnitsPerSUSDatShareWad: $.eligibleUnitsPerSUSDatShareWad,
            lastRoundingRemainder: $.lastRoundingRemainder,
            liveUnitScaleWad: $.liveUnitScaleWad,
            liveUnitsOffsetWad: $.liveUnitsOffsetWad,
            crystallizedValueScaleWad: $.crystallizedValueScaleWad,
            crystallizedValueOffsetWad: $.crystallizedValueOffsetWad,
            crystallizationNonce: $.crystallizationNonce,
            lastResolutionEvidence: $.lastResolutionEvidence,
            configMediationActive: $.configMediationActive,
            fundedUSDat: $.fundedUSDat,
            pendingFundedUSDat: $.pendingFundedUSDat,
            recognizedUSDat: $.recognizedUSDat,
            recognizedUSDatPerSUSDatShareWad: $.recognizedUSDatPerSUSDatShareWad,
            lastUSDatRoundingRemainder: $.lastUSDatRoundingRemainder
        });
    }

    // ============ Funded USDat ============

    function registerFundedUSDat(uint256 amount) external {
        StakedUSDatEligibleIncomeStorage.Layout storage $ = StakedUSDatEligibleIncomeStorage.layout();
        if ($.state == IEligibleIncomeAccounting.IncomeState.Uninitialized) {
            revert IEligibleIncomeAccounting.EligibleIncomeNotActive();
        }
        $.fundedUSDat += amount;
        $.pendingFundedUSDat += amount;
        emit IEligibleIncomeAccounting.USDatSurplusFunded(amount, $.pendingFundedUSDat);
    }

    function recognizeFundedUSDat(uint256 amount, uint256 supply) external returns (uint256 valuePerShareIncreaseWad) {
        StakedUSDatEligibleIncomeStorage.Layout storage $ = StakedUSDatEligibleIncomeStorage.layout();
        if ($.state == IEligibleIncomeAccounting.IncomeState.Uninitialized) {
            revert IEligibleIncomeAccounting.EligibleIncomeNotActive();
        }
        if (amount > $.pendingFundedUSDat) revert IEligibleIncomeAccounting.FundedUSDatSurplusExceeded();

        $.pendingFundedUSDat -= amount;
        $.recognizedUSDat += amount;
        if (supply != 0) {
            valuePerShareIncreaseWad = Math.mulDiv(amount, 1e30, supply, Math.Rounding.Floor);
            $.recognizedUSDatPerSUSDatShareWad += valuePerShareIncreaseWad;
            $.crystallizedValueOffsetWad += valuePerShareIncreaseWad;
            $.lastUSDatRoundingRemainder = mulmod(amount, 1e30, supply);
        }
        $.lastSettlementBlock = uint64(block.number);
        emit IEligibleIncomeAccounting.USDatSurplusRecognized(
            amount, supply, valuePerShareIncreaseWad, $.pendingFundedUSDat
        );
    }

    // ============ Review Lifecycle ============

    function enterReview(ISTRConModule module, uint256 supply, bytes32 evidence, bool settleCurrent) external {
        StakedUSDatEligibleIncomeStorage.Layout storage $ = StakedUSDatEligibleIncomeStorage.layout();
        if ($.state != IEligibleIncomeAccounting.IncomeState.Active) {
            revert IEligibleIncomeAccounting.EligibleIncomeNotActive();
        }

        // Settle only a currently valid ordinary increment. Surprise/paused states still enter review safely.
        if (settleCurrent) {
            try IEligibleIncomeAdapter($.adapter).rawIndex() returns (uint256 rawIndex) {
                uint256 normalized = Math.mulDiv(rawIndex, WAD, $.cumulativeStructuralAdjustmentFactorWad);
                if (_growthIsValid($.lastEligibleUnitIndexWad, normalized, $.maxUnreviewedGrowthBps)) {
                    _materializeKnown($, module, supply, rawIndex, normalized);
                }
            } catch {}
        }

        $.state = IEligibleIncomeAccounting.IncomeState.Review;
        $.lastResolutionEvidence = evidence;
        emit IEligibleIncomeAccounting.EligibleIncomeReviewEntered(evidence);
    }

    function resume(ISTRConModule module, uint256 supply, bytes32 evidence) external {
        StakedUSDatEligibleIncomeStorage.Layout storage $ = StakedUSDatEligibleIncomeStorage.layout();
        if ($.state != IEligibleIncomeAccounting.IncomeState.Review) {
            revert IEligibleIncomeAccounting.EligibleIncomeNotInReview();
        }
        _materialize(module, supply, true);
        $.state = IEligibleIncomeAccounting.IncomeState.Active;
        $.lastResolutionEvidence = evidence;
        emit IEligibleIncomeAccounting.EligibleIncomeResumed(evidence);
    }

    function resolve(ISTRConModule module, uint256 supply, uint256 newFactorWad, bytes32 evidence) external {
        StakedUSDatEligibleIncomeStorage.Layout storage $ = StakedUSDatEligibleIncomeStorage.layout();
        if ($.state != IEligibleIncomeAccounting.IncomeState.Review) {
            revert IEligibleIncomeAccounting.EligibleIncomeNotInReview();
        }
        if (newFactorWad == 0) revert IEligibleIncomeAccounting.InvalidStructuralAdjustment();
        uint256 rawIndex = IEligibleIncomeAdapter($.adapter).rawIndex();
        uint256 normalized = Math.mulDiv(rawIndex, WAD, newFactorWad);
        if (normalized < $.lastEligibleUnitIndexWad) revert IEligibleIncomeAccounting.InvalidStructuralAdjustment();
        _validateGrowth($.lastEligibleUnitIndexWad, normalized, $.maxUnreviewedGrowthBps);

        uint256 oldFactor = $.cumulativeStructuralAdjustmentFactorWad;
        $.cumulativeStructuralAdjustmentFactorWad = newFactorWad;
        _materializeKnown($, module, supply, rawIndex, normalized);
        $.lastResolutionEvidence = evidence;
        $.state = IEligibleIncomeAccounting.IncomeState.Active;
        emit IEligibleIncomeAccounting.NeutralStructuralAdjustmentResolved(oldFactor, newFactorWad, rawIndex, evidence);
    }

    // ============ Configuration ============

    function setMaxGrowth(ISTRConModule module, uint256 supply, uint16 newBps) external {
        StakedUSDatEligibleIncomeStorage.Layout storage $ = StakedUSDatEligibleIncomeStorage.layout();
        if ($.state == IEligibleIncomeAccounting.IncomeState.Active) _materialize(module, supply, false);
        if (newBps > BPS_DENOMINATOR) revert IEligibleIncomeAccounting.EligibleIncomeGrowthTooLarge();
        uint16 oldBps = $.maxUnreviewedGrowthBps;
        $.maxUnreviewedGrowthBps = newBps;
        emit IEligibleIncomeAccounting.MaxUnreviewedGrowthUpdated(oldBps, newBps);
    }

    // ============ Crystallization ============

    function crystallize(uint256 preExposure, uint256 delivered, uint256 usdatReceived) external {
        StakedUSDatEligibleIncomeStorage.Layout storage $ = StakedUSDatEligibleIncomeStorage.layout();
        if ($.state == IEligibleIncomeAccounting.IncomeState.Uninitialized) return;
        if ($.state != IEligibleIncomeAccounting.IncomeState.Active) {
            revert IEligibleIncomeAccounting.EligibleIncomeNotActive();
        }

        uint256 q = Math.mulDiv(preExposure - delivered, WAD, preExposure);
        uint256 r = Math.mulDiv(usdatReceived, 1e30, preExposure);
        $.crystallizedValueScaleWad += Math.mulDiv(r, $.liveUnitScaleWad, WAD, Math.Rounding.Floor);
        $.crystallizedValueOffsetWad += Math.mulDiv(r, $.liveUnitsOffsetWad, WAD, Math.Rounding.Floor);
        $.liveUnitScaleWad = Math.mulDiv($.liveUnitScaleWad, q, WAD, Math.Rounding.Floor);
        $.liveUnitsOffsetWad = Math.mulDiv($.liveUnitsOffsetWad, q, WAD, Math.Rounding.Floor);
        unchecked {
            ++$.crystallizationNonce;
        }
        emit IEligibleIncomeAccounting.STRConIncomeCrystallized(
            $.crystallizationNonce, delivered, usdatReceived, preExposure - delivered
        );
    }

    // ============ Internal Accounting ============

    function _materialize(ISTRConModule module, uint256 supply, bool allowReview)
        private
        returns (uint256 unitsPerShareIncrease)
    {
        StakedUSDatEligibleIncomeStorage.Layout storage $ = StakedUSDatEligibleIncomeStorage.layout();
        if ($.state == IEligibleIncomeAccounting.IncomeState.Uninitialized) return 0;
        if (
            (!allowReview && $.state != IEligibleIncomeAccounting.IncomeState.Active)
                || (allowReview && $.state != IEligibleIncomeAccounting.IncomeState.Review)
        ) {
            if (allowReview) revert IEligibleIncomeAccounting.EligibleIncomeNotInReview();
            revert IEligibleIncomeAccounting.EligibleIncomeNotActive();
        }
        (uint256 rawIndex, uint256 normalized) = _readNormalized($);
        _validateGrowth($.lastEligibleUnitIndexWad, normalized, $.maxUnreviewedGrowthBps);
        return _materializeKnown($, module, supply, rawIndex, normalized);
    }

    function _materializeKnown(
        StakedUSDatEligibleIncomeStorage.Layout storage $,
        ISTRConModule module,
        uint256 supply,
        uint256 rawIndex,
        uint256 normalized
    ) private returns (uint256 unitsPerShareIncrease) {
        uint256 last = $.lastEligibleUnitIndexWad;
        uint256 exposure = module.balance();
        uint256 delta = normalized - last;
        if (delta != 0 && supply != 0) {
            unitsPerShareIncrease = Math.mulDiv(exposure, delta, supply, Math.Rounding.Floor);
            $.eligibleUnitsPerSUSDatShareWad += unitsPerShareIncrease;
            $.liveUnitsOffsetWad += unitsPerShareIncrease;
            $.lastRoundingRemainder = mulmod(exposure, delta, supply);
        }
        $.lastAcceptedRawIndex = rawIndex;
        $.lastEligibleUnitIndexWad = normalized;
        $.lastSettlementBlock = uint64(block.number);
        emit IEligibleIncomeAccounting.EligibleIncomeMaterialized(
            rawIndex, normalized, exposure, supply, unitsPerShareIncrease
        );
    }

    function _readNormalized(StakedUSDatEligibleIncomeStorage.Layout storage $)
        private
        view
        returns (uint256 rawIndex, uint256 normalized)
    {
        rawIndex = IEligibleIncomeAdapter($.adapter).rawIndex();
        normalized = Math.mulDiv(rawIndex, WAD, $.cumulativeStructuralAdjustmentFactorWad);
        if (normalized < $.lastEligibleUnitIndexWad) revert IEligibleIncomeAccounting.InvalidEligibleIncomeIndex();
    }

    function _validateGrowth(uint256 last, uint256 current, uint16 maxBps) private pure {
        if (!_growthIsValid(last, current, maxBps)) revert IEligibleIncomeAccounting.EligibleIncomeGrowthTooLarge();
    }

    function _growthIsValid(uint256 last, uint256 current, uint16 maxBps) private pure returns (bool) {
        if (current < last) return false;
        return current <= last + Math.mulDiv(last, maxBps, BPS_DENOMINATOR);
    }
}
