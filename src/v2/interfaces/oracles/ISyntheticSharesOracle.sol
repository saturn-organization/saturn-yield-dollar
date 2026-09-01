// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

/**
 * @title ISyntheticSharesOracle
 * @dev Minimal interface for Ondo Global Markets' SyntheticSharesOracle
 * (Ethereum: 0x9BC39DB6fbB44B91a48b8D5A6C208B82B1741bE6). The per-asset `paused`
 * flag identifies an asset whose multiplier must not be consumed. Consumers
 * must fail closed while paused; they must not infer an economic reason from
 * the current value or pause flag alone.
 */
interface ISyntheticSharesOracle {
    /**
     * @dev Returns the shares multiplier and pause flag for a tokenized asset.
     * @param asset The tokenized asset address (e.g. STRCon).
     * @return sValue The cumulative shares multiplier (18 decimals).
     * @return paused True while the asset is paused for a corporate action.
     */
    function getSValue(address asset) external view returns (uint256 sValue, bool paused);
}
