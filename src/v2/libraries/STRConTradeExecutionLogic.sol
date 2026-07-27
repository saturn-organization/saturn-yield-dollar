// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {ISTRConExecutionPolicy} from "../interfaces/ISTRConExecutionPolicy.sol";
import {ISTRCMirrorModule} from "../interfaces/modules/ISTRCMirrorModule.sol";
import {ISTRConModule} from "../interfaces/modules/ISTRConModule.sol";

interface ITotalAssets {
    function totalAssets() external view returns (uint256);
}

/**
 * @title STRConTradeExecutionLogic
 * @author Saturn
 * @notice Complete STRCon settlement and migration workflows executed in the vault context.
 */
library STRConTradeExecutionLogic {
    using SafeERC20 for IERC20;

    error CustodyShortfall();
    error InvalidAssetDelta();
    error MigrationNAVMismatch();
    error ZeroNAV();

    event AssetBought(
        address indexed module, address indexed vehicle, uint256 usdatPaid, uint256 assetReceived, uint256 oraclePrice
    );
    event AssetSold(
        address indexed module,
        address indexed vehicle,
        uint256 assetDelivered,
        uint256 usdatReceived,
        uint256 oraclePrice
    );

    uint256 private constant BPS_DENOMINATOR = 10_000;

    /**
     * @notice Executes an exact USDat-for-STRCon rotation from the calling vault.
     */
    function executeBuy(
        ISTRConExecutionPolicy policy,
        IERC20 usdat,
        ISTRConModule strconModule,
        address expectedVehicle,
        uint256 usdatPaid,
        uint256 assetReceived,
        uint256 trackedUsdat,
        uint256 unvestedSurplus
    ) external {
        uint256 oraclePrice = policy.validateBuy(usdatPaid, assetReceived, expectedVehicle);

        IERC20 strcon = IERC20(strconModule.asset());
        _pullExact(strcon, expectedVehicle, assetReceived);
        strconModule.buy(assetReceived);

        uint256 usdatCustody = _transferExact(usdat, expectedVehicle, usdatPaid);
        _requireCustodyFloors(
            strconModule, usdatCustody, strcon.balanceOf(address(this)), trackedUsdat, unvestedSurplus
        );

        emit AssetBought(address(strconModule), expectedVehicle, usdatPaid, assetReceived, oraclePrice);
    }

    /**
     * @notice Executes an exact STRCon-for-USDat rotation from the calling vault.
     */
    function executeSell(
        ISTRConExecutionPolicy policy,
        IERC20 usdat,
        ISTRConModule strconModule,
        address expectedVehicle,
        uint256 assetDelivered,
        uint256 usdatReceived,
        uint256 trackedUsdat,
        uint256 unvestedSurplus
    ) external {
        uint256 oraclePrice = policy.validateSell(assetDelivered, usdatReceived, expectedVehicle);

        uint256 usdatCustody = _pullExact(usdat, expectedVehicle, usdatReceived);
        strconModule.sell(assetDelivered);

        IERC20 strcon = IERC20(strconModule.asset());
        uint256 strconCustody = _transferExact(strcon, expectedVehicle, assetDelivered);
        _requireCustodyFloors(strconModule, usdatCustody, strconCustody, trackedUsdat, unvestedSurplus);

        emit AssetSold(address(strconModule), expectedVehicle, assetDelivered, usdatReceived, oraclePrice);
    }

    /**
     * @notice Retires the legacy mirror and recognizes the delivered STRCon position.
     */
    function executeMigration(
        ISTRCMirrorModule mirrorModule,
        ISTRConModule strconModule,
        address executionVehicle,
        uint256 expectedStrcon,
        uint16 migrationToleranceBps
    ) external {
        uint256 navBefore = ITotalAssets(address(this)).totalAssets();
        require(navBefore != 0, ZeroNAV());

        IERC20 strcon = IERC20(strconModule.asset());
        uint256 strconCustody = _pullExact(strcon, executionVehicle, expectedStrcon);

        mirrorModule.retire();
        strconModule.buy(expectedStrcon);

        uint256 navAfter = ITotalAssets(address(this)).totalAssets();
        uint256 delta = navAfter >= navBefore ? navAfter - navBefore : navBefore - navAfter;
        require(delta <= Math.mulDiv(navBefore, migrationToleranceBps, BPS_DENOMINATOR), MigrationNAVMismatch());
        require(strconCustody >= strconModule.balance(), CustodyShortfall());
    }

    function _pullExact(IERC20 token, address from, uint256 amount) private returns (uint256 custodyAfter) {
        uint256 custodyBefore = token.balanceOf(address(this));
        token.safeTransferFrom(from, address(this), amount);
        custodyAfter = token.balanceOf(address(this));

        require(custodyAfter >= custodyBefore, InvalidAssetDelta());
        require(custodyAfter - custodyBefore == amount, InvalidAssetDelta());
    }

    function _transferExact(IERC20 token, address to, uint256 amount) private returns (uint256 custodyAfter) {
        uint256 custodyBefore = token.balanceOf(address(this));
        token.safeTransfer(to, amount);
        custodyAfter = token.balanceOf(address(this));

        require(custodyBefore >= custodyAfter, InvalidAssetDelta());
        require(custodyBefore - custodyAfter == amount, InvalidAssetDelta());
    }

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
