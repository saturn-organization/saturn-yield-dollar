// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IAccountingModule
 * @author Saturn
 * @notice An accounting adapter for one backing asset of the StakedUSDat vault.
 * @dev Custody stays in the vault; modules hold no tokens. `balance()` is a recognized
 * counter written only by `buy`/`sell`, never a live balanceOf — so NAV moves only
 * through authorized paths and a stray transfer cannot inflate it.
 */
interface IAccountingModule {
    /**
     * @notice USD value (6 decimals) the vault recognizes now.
     * @dev REVERTS when the asset cannot be reliably priced (stale / out-of-bounds /
     * tripwire); the revert propagates through the vault's totalAssets() into every
     * value-sensitive path. Returns 0 without pricing when `balance()` == 0.
     * @return The recognized USD value (6 decimals).
     */
    function recognizedValue() external view returns (uint256);

    /**
     * @notice The ERC20 custodied in the vault, or address(0) for a token-less module.
     * @return The asset token address.
     */
    function asset() external view returns (address);

    /**
     * @notice Recognized quantity of `asset()`.
     * @dev A counter, not a live balanceOf. For token-backed modules the vault's actual
     * holding is a floor: `asset().balanceOf(vault) >= balance()`.
     * @return The recognized asset quantity.
     */
    function balance() external view returns (uint256);

    /**
     * @notice Acquires the asset with USDat.
     * @dev Vault-only. Validates the realized (or attested) price against the module's
     * oracle within the module's tolerance. The vault grants a per-call exact-amount
     * USDat approval before delegating.
     * @param usdatIn The amount of USDat spent (6 decimals).
     * @param minAssetOut The minimum acceptable amount of asset acquired.
     * @param venueData Venue-specific execution data (e.g. attested execution price,
     * Ondo RFQ attestation).
     * @return assetOut The amount of asset recognized.
     */
    function buy(uint256 usdatIn, uint256 minAssetOut, bytes calldata venueData) external returns (uint256 assetOut);

    /**
     * @notice Closes position back to USDat.
     * @dev Vault-only. Validates the realized (or attested) price against the module's
     * oracle within the module's tolerance.
     * @param assetIn The amount of asset sold.
     * @param minUsdatOut The minimum acceptable amount of USDat received.
     * @param venueData Venue-specific execution data.
     * @return usdatOut The amount of USDat returned to the vault (6 decimals).
     */
    function sell(uint256 assetIn, uint256 minUsdatOut, bytes calldata venueData) external returns (uint256 usdatOut);
}
