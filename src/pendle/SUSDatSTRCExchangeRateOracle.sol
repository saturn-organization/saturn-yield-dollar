// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPExchangeRateOracle} from "pendle-sy/interfaces/IPExchangeRateOracle.sol";

import {ISTRConPriceOracle} from "../v2/interfaces/oracles/ISTRConPriceOracle.sol";
import {ISyntheticSharesOracle} from "../v2/interfaces/oracles/ISyntheticSharesOracle.sol";
import {ISTRConModule} from "../v2/interfaces/modules/ISTRConModule.sol";

interface ISUSDatERC4626STRC {
    function asset() external view returns (address);
    function convertToAssets(uint256 shares) external view returns (uint256);
    function strconModule() external view returns (ISTRConModule);
}

interface IBoundSTRConPriceOracleSTRC is ISTRConPriceOracle {
    function VAULT() external view returns (address);
    function STRCON() external view returns (address);
    function syntheticSharesOracle() external view returns (ISyntheticSharesOracle);
}

/**
 * @title SUSDatSTRCExchangeRateOracle
 * @author Saturn
 * @notice Reports one sUSDat/SY share's value in underlying offchain STRC.
 * @dev Pendle expects accounting-asset base units per 1e18 SY. This integration
 *      defines one underlying STRC as 1e18 accounting base units. Let:
 *      A = sUSDat.convertToAssets(1e18), in 6-decimal USDat base units;
 *      S = Ondo sValue, 18-decimal underlying STRC shares per STRCon; and
 *      P = validated STRCon/USD, 8 decimals.
 *      Treating one USDat as one USD, this returns floor(A * S * 100 / P).
 *
 *      The implementation first checks that A * 100 fits, then uses 512-bit
 *      `mulDiv(A * 100, S, P)`. This is algebraically identical to the stated
 *      formula, performs exactly one final floor, and reverts if the final
 *      uint256 result cannot fit. The adapter immutably binds the economic
 *      identities (sUSDat, USDat, and STRCon), has no custody or approvals,
 *      and makes no external state changes.
 *
 *      The canonical Saturn oracle owns feed-round, reference-freshness,
 *      deviation, price-bound, and synthetic-pause validation. Its reverts
 *      propagate. On every read this adapter resolves sUSDat's active STRCon
 *      module, that module's active price oracle, and the synthetic-shares
 *      oracle named by that price oracle. It validates the complete graph and
 *      consumes P and S from that coherent active path. Compatible dependency
 *      rotations therefore remain live; malformed or cross-system paths fail
 *      closed.
 */
contract SUSDatSTRCExchangeRateOracle is IPExchangeRateOracle {
    error InvalidConfiguration();
    error InvalidRate();
    error RateOverflow();
    error SyntheticAssetPaused();
    error OracleBindingChanged();

    uint256 private constant ONE_SUSDAT = 1e18;
    uint256 private constant ASSET_SCALE = 100;
    uint8 private constant SUSDAT_DECIMALS = 18;
    uint8 private constant USDAT_DECIMALS = 6;
    uint8 private constant STRCON_DECIMALS = 18;
    uint8 private constant PRICE_DECIMALS = 8;

    ISUSDatERC4626STRC public immutable SUSDat;
    address public immutable USDAT;
    address public immutable STRCON;

    constructor(address susdat, address usdat, address strcon) {
        if (susdat.code.length == 0 || usdat.code.length == 0 || strcon.code.length == 0) {
            revert InvalidConfiguration();
        }

        if (ISUSDatERC4626STRC(susdat).asset() != usdat) revert InvalidConfiguration();
        if (
            IERC20Metadata(susdat).decimals() != SUSDAT_DECIMALS || IERC20Metadata(usdat).decimals() != USDAT_DECIMALS
                || IERC20Metadata(strcon).decimals() != STRCON_DECIMALS
        ) revert InvalidConfiguration();

        SUSDat = ISUSDatERC4626STRC(susdat);
        USDAT = usdat;
        STRCON = strcon;

        _resolveActivePricingPath(true);
    }

    /// @inheritdoc IPExchangeRateOracle
    /// @return rate 18-decimal underlying STRC units represented by one 1e18 sUSDat/SY share, rounded down.
    function getExchangeRate() external view override returns (uint256 rate) {
        (IBoundSTRConPriceOracleSTRC priceOracle, ISyntheticSharesOracle sharesOracle) =
            _resolveActivePricingPath(false);

        uint256 assets = SUSDat.convertToAssets(ONE_SUSDAT);
        uint256 price = priceOracle.getPrice();
        (uint256 sValue, bool paused) = sharesOracle.getSValue(STRCON);

        if (paused) revert SyntheticAssetPaused();
        if (assets == 0 || price == 0 || sValue == 0) revert InvalidRate();
        if (assets > type(uint256).max / ASSET_SCALE) revert RateOverflow();

        rate = Math.mulDiv(assets * ASSET_SCALE, sValue, price, Math.Rounding.Floor);
        if (rate == 0) revert InvalidRate();
    }

    function _resolveActivePricingPath(bool construction)
        private
        view
        returns (IBoundSTRConPriceOracleSTRC priceOracle, ISyntheticSharesOracle sharesOracle)
    {
        ISTRConModule module = SUSDat.strconModule();
        if (
            address(module).code.length == 0 || module.VAULT() != address(SUSDat) || module.ASSET() != STRCON
                || module.asset() != STRCON
        ) {
            _revertInvalidPath(construction);
        }

        priceOracle = IBoundSTRConPriceOracleSTRC(address(module.oracle()));
        if (
            address(priceOracle).code.length == 0 || priceOracle.VAULT() != address(SUSDat)
                || priceOracle.STRCON() != STRCON || priceOracle.decimals() != PRICE_DECIMALS
        ) {
            _revertInvalidPath(construction);
        }

        sharesOracle = priceOracle.syntheticSharesOracle();
        if (address(sharesOracle).code.length == 0) _revertInvalidPath(construction);
    }

    function _revertInvalidPath(bool construction) private pure {
        if (construction) revert InvalidConfiguration();
        revert OracleBindingChanged();
    }
}
