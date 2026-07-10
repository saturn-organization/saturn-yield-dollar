// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IExchanger
 * @author Saturn
 * @notice Swappable execution route between USDat and STRCon. The STRConModule holds
 * an exchanger behind an admin-gated setter: when a conversion venue changes
 * (a DEX migration, M → PYUSD backing), a new exchanger deploys and the module
 * re-points — the position is never unwound.
 * @dev The two directions are asymmetric by design. swapIn (into the position) routes
 * USDat → USDC → STRCon through whatever cash venue is current. swapOut (out of the
 * position) is the stable path: sell STRCon for USDC, then mint USDat through the
 * Swap Facility at zero fee. An exchanger pulls its input from the caller via
 * allowance and delivers output back to the caller. Callers must treat the return
 * value as untrusted and measure received balances themselves — the module's oracle
 * ± tolerance validation and minimum-out bounds are the trust boundary, not the
 * exchanger.
 */
interface IExchanger {
    /**
     * @notice Swaps USDat into STRCon (the buy direction).
     * @dev Pulls `usdatIn` from the caller (allowance) and delivers STRCon to the
     * caller.
     * @param usdatIn The amount of USDat to swap (6 decimals).
     * @param minStrconOut The minimum acceptable STRCon out (18 decimals).
     * @param data Route-specific execution data (e.g. Ondo RFQ payload, pool choice),
     * forwarded opaquely by the module.
     * @return strconOut The amount of STRCon delivered.
     */
    function swapIn(uint256 usdatIn, uint256 minStrconOut, bytes calldata data) external returns (uint256 strconOut);

    /**
     * @notice Swaps STRCon into USDat (the sell direction).
     * @dev Pulls `strconIn` from the caller (allowance) and delivers USDat to the
     * caller.
     * @param strconIn The amount of STRCon to swap (18 decimals).
     * @param minUsdatOut The minimum acceptable USDat out (6 decimals).
     * @param data Route-specific execution data, forwarded opaquely by the module.
     * @return usdatOut The amount of USDat delivered.
     */
    function swapOut(uint256 strconIn, uint256 minUsdatOut, bytes calldata data) external returns (uint256 usdatOut);
}
