// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {ISTRConModule} from "../interfaces/modules/ISTRConModule.sol";

/**
 * @title STRConRotationLogic
 * @author Saturn
 * @notice Stateless helpers for StakedUSDat STRCon buy and sell execution.
 */
library STRConRotationLogic {
    using SafeERC20 for IERC20;

    error CustodyShortfall();
    error ExecutionPriceMismatch();
    error InvalidAssetDelta();

    uint256 private constant BPS_DENOMINATOR = 10_000;

    /**
     * @notice Pulls STRCon into the vault and validates a USDat-for-STRCon execution price.
     * @param strconModule The STRCon accounting module providing the oracle price.
     * @param executionVehicle The counterparty delivering STRCon.
     * @param usdatPaid The exact USDat amount paid by the vault.
     * @param assetReceived The exact STRCon amount received by the vault.
     * @param executionToleranceBps The maximum adverse execution-price deviation.
     * @return oraclePrice The STRCon oracle price used to validate execution.
     */
    function prepareBuy(
        ISTRConModule strconModule,
        address executionVehicle,
        uint256 usdatPaid,
        uint256 assetReceived,
        uint16 executionToleranceBps
    ) external returns (uint256 oraclePrice) {
        _pullExact(IERC20(strconModule.asset()), executionVehicle, assetReceived);
        oraclePrice = _validateBuyPrice(strconModule, usdatPaid, assetReceived, executionToleranceBps);
    }

    /**
     * @notice Transfers USDat out of the vault and enforces final custody floors.
     * @param usdat The vault's core USDat asset.
     * @param strconModule The vault's fixed STRCon accounting module.
     * @param executionVehicle The counterparty receiving USDat.
     * @param usdatPaid The exact USDat amount paid by the vault.
     * @param trackedUsdat The vault's post-trade tracked USDat balance.
     * @param unvestedSurplus The vault's unvested USDat surplus.
     */
    function completeBuy(
        IERC20 usdat,
        ISTRConModule strconModule,
        address executionVehicle,
        uint256 usdatPaid,
        uint256 trackedUsdat,
        uint256 unvestedSurplus
    ) external {
        uint256 usdatCustody = _transferExact(usdat, executionVehicle, usdatPaid);
        _requireCustodyFloors(
            strconModule,
            usdatCustody,
            IERC20(strconModule.asset()).balanceOf(address(this)),
            trackedUsdat,
            unvestedSurplus
        );
    }

    /**
     * @notice Pulls USDat into the vault and validates an STRCon-for-USDat execution price.
     * @param usdat The vault's core USDat asset.
     * @param strconModule The STRCon accounting module providing the oracle price.
     * @param executionVehicle The counterparty delivering USDat.
     * @param assetDelivered The exact STRCon amount delivered by the vault.
     * @param usdatReceived The exact USDat amount received by the vault.
     * @param executionToleranceBps The maximum adverse execution-price deviation.
     * @return oraclePrice The STRCon oracle price used to validate execution.
     */
    function prepareSell(
        IERC20 usdat,
        ISTRConModule strconModule,
        address executionVehicle,
        uint256 assetDelivered,
        uint256 usdatReceived,
        uint16 executionToleranceBps
    ) external returns (uint256 oraclePrice) {
        _pullExact(usdat, executionVehicle, usdatReceived);
        oraclePrice = _validateSellPrice(strconModule, assetDelivered, usdatReceived, executionToleranceBps);
    }

    /**
     * @notice Transfers STRCon out of the vault and enforces final custody floors.
     * @param usdat The vault's core USDat asset.
     * @param strconModule The vault's fixed STRCon accounting module.
     * @param executionVehicle The counterparty receiving STRCon.
     * @param assetDelivered The exact STRCon amount delivered by the vault.
     * @param trackedUsdat The vault's post-trade tracked USDat balance.
     * @param unvestedSurplus The vault's unvested USDat surplus.
     */
    function completeSell(
        IERC20 usdat,
        ISTRConModule strconModule,
        address executionVehicle,
        uint256 assetDelivered,
        uint256 trackedUsdat,
        uint256 unvestedSurplus
    ) external {
        IERC20 strcon = IERC20(strconModule.asset());
        uint256 strconCustody = _transferExact(strcon, executionVehicle, assetDelivered);
        _requireCustodyFloors(
            strconModule, usdat.balanceOf(address(this)), strconCustody, trackedUsdat, unvestedSurplus
        );
    }

    /**
     * @notice Pulls an exact token amount into the calling vault.
     * @return custodyAfter The vault's token custody after the transfer.
     */
    function pullExact(IERC20 token, address from, uint256 amount) external returns (uint256 custodyAfter) {
        return _pullExact(token, from, amount);
    }

    /// @dev Applies the adverse-only buy bound and returns the validated oracle price.
    function _validateBuyPrice(
        ISTRConModule strconModule,
        uint256 usdatPaid,
        uint256 assetReceived,
        uint16 executionToleranceBps
    ) private view returns (uint256 oraclePrice) {
        oraclePrice = strconModule.getPrice();
        uint256 buyPrice = Math.mulDiv(usdatPaid, 1e20, assetReceived, Math.Rounding.Ceil);
        uint256 maxBuyPrice = Math.mulDiv(
            oraclePrice, BPS_DENOMINATOR + uint256(executionToleranceBps), BPS_DENOMINATOR, Math.Rounding.Floor
        );

        require(buyPrice <= maxBuyPrice, ExecutionPriceMismatch());
    }

    /// @dev Applies the adverse-only sell bound and returns the validated oracle price.
    function _validateSellPrice(
        ISTRConModule strconModule,
        uint256 assetDelivered,
        uint256 usdatReceived,
        uint16 executionToleranceBps
    ) private view returns (uint256 oraclePrice) {
        oraclePrice = strconModule.getPrice();
        uint256 sellPrice = Math.mulDiv(usdatReceived, 1e20, assetDelivered, Math.Rounding.Floor);
        uint256 minSellPrice = Math.mulDiv(
            oraclePrice, BPS_DENOMINATOR - uint256(executionToleranceBps), BPS_DENOMINATOR, Math.Rounding.Ceil
        );

        require(sellPrice >= minSellPrice, ExecutionPriceMismatch());
    }

    /// @dev Pulls an exact token amount into the calling vault.
    function _pullExact(IERC20 token, address from, uint256 amount) private returns (uint256 custodyAfter) {
        uint256 custodyBefore = token.balanceOf(address(this));
        token.safeTransferFrom(from, address(this), amount);
        custodyAfter = token.balanceOf(address(this));

        require(custodyAfter >= custodyBefore, InvalidAssetDelta());
        require(custodyAfter - custodyBefore == amount, InvalidAssetDelta());
    }

    /// @dev Transfers an exact token amount out of the calling vault.
    function _transferExact(IERC20 token, address to, uint256 amount) private returns (uint256 custodyAfter) {
        uint256 custodyBefore = token.balanceOf(address(this));
        token.safeTransfer(to, amount);
        custodyAfter = token.balanceOf(address(this));

        require(custodyBefore >= custodyAfter, InvalidAssetDelta());
        require(custodyBefore - custodyAfter == amount, InvalidAssetDelta());
    }

    /// @dev Enforces the tracked USDat, unvested surplus, and STRCon custody floors.
    function _requireCustodyFloors(
        ISTRConModule strconModule,
        uint256 usdatCustody,
        uint256 strconCustody,
        uint256 trackedUsdat,
        uint256 unvestedSurplus
    ) private view {
        require(usdatCustody >= trackedUsdat, CustodyShortfall());
        require(usdatCustody - trackedUsdat >= unvestedSurplus, CustodyShortfall());
        require(strconCustody >= strconModule.balance(), CustodyShortfall());
    }
}
