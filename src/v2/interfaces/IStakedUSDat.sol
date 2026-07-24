// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

/**
 * @title IStakedUSDat
 * @author Saturn
 * @notice Interface for the StakedUSDat (sUSDat) ERC4626 vault contract.
 * @dev StakedUSDat is a UUPS upgradeable ERC4626 vault for staking USDat.
 * Users deposit USDat and receive sUSDat shares representing their stake.
 * Backing assets are recognized through registered accounting modules;
 * totalAssets() is idle USDat plus each module's recognizedValue().
 */
interface IStakedUSDat is IERC4626 {
    // ============ Enums ============

    /**
     * @notice Outcome of attempting to settle a queued withdrawal request.
     */
    enum RedemptionResult {
        Settled,
        BelowLimit,
        InsufficientLiquidity
    }

    // ============ Structs ============

    /**
     * @notice Per-module configuration.
     * @param maxWeightBps Hard cap on the module's share of totalAssets, in basis points.
     */
    struct ModuleConfig {
        uint16 maxWeightBps;
    }

    // ============ Errors ============

    /**
     * @dev Thrown when a zero address is provided where a valid address is required.
     */
    error InvalidZeroAddress();

    /**
     * @dev Thrown when an operation involves a zero amount where a non-zero value is required.
     */
    error ZeroAmount();

    /**
     * @dev Thrown when an operation is not allowed (e.g., direct withdraw/redeem,
     * caller not the withdrawal queue).
     */
    error OperationNotAllowed();

    /**
     * @dev Thrown when attempting to un-blacklist an address that is not blacklisted.
     */
    error AddressNotBlacklisted();

    /**
     * @dev Thrown when an operation involves a blacklisted address.
     */
    error AddressBlacklisted();

    /**
     * @dev Thrown when attempting to redistribute locked amounts with no valid recipients.
     */
    error NoRecipientsForRedistribution();

    /**
     * @dev Thrown when attempting to blacklist an admin address.
     */
    error CannotBlacklistAdmin();

    /**
     * @dev Thrown when an operation requires more balance than available.
     */
    error InsufficientBalance();

    /**
     * @dev Thrown when a redemption request is below MIN_REQUEST_SHARES.
     */
    error WithdrawalTooSmall();

    /**
     * @dev Thrown when a fee exceeds its maximum.
     */
    error InvalidFee();

    /**
     * @dev Thrown when a new surplus tranche arrives while the prior one is still vesting.
     */
    error StillVesting();

    /**
     * @dev Thrown when a surplus tranche exceeds maxSurplusBps of totalAssets.
     */
    error SurplusExceedsMax();

    /**
     * @dev Thrown when an invalid surplus vesting period is provided.
     */
    error InvalidVestingPeriod();

    /**
     * @dev Thrown when slippage protection is triggered (received less than minimum).
     */
    error SlippageExceeded();

    /**
     * @dev Thrown when a basis-points weight exceeds the denominator.
     */
    error InvalidWeight();

    /**
     * @dev Thrown when registering a module would exceed MAX_MODULES.
     */
    error MaxModulesReached();

    /**
     * @dev Thrown when registering a module that is already registered.
     */
    error ModuleAlreadyRegistered();

    /**
     * @dev Thrown when the target module is not registered.
     */
    error ModuleNotRegistered();

    /**
     * @dev Thrown when deregistering a module whose balance is not zero.
     */
    error ModuleBalanceNotZero();

    /**
     * @dev Thrown when a buy would push a module above its maxWeightBps.
     */
    error MaxWeightExceeded();

    /**
     * @dev Thrown when a buy would push cash below minCashBufferBps.
     */
    error CashBufferBreached();

    // ============ Events ============

    /**
     * @dev Emitted when an address is added to the blacklist.
     * @param target The address that was blacklisted.
     */
    event Blacklisted(address indexed target);

    /**
     * @dev Emitted when an address is removed from the blacklist.
     * @param target The address that was un-blacklisted.
     */
    event UnBlacklisted(address indexed target);

    /**
     * @dev Emitted when locked amounts are redistributed from a blacklisted address.
     * @param from The blacklisted address whose funds were redistributed.
     * @param amount The amount of shares that were burned.
     */
    event LockedAmountRedistributed(address indexed from, uint256 amount);

    /**
     * @dev Emitted when a blacklisted holder's shares are seized to a recovery address.
     * @param from The blacklisted address seized from.
     * @param to The recovery address the shares were transferred to.
     * @param amount The amount of shares transferred.
     */
    event Seized(address indexed from, address indexed to, uint256 amount);

    /**
     * @dev Emitted when the canonical seizure destination is updated.
     * @param oldAddress The previous recovery address.
     * @param newAddress The new recovery address.
     */
    event RecoveryAddressUpdated(address indexed oldAddress, address indexed newAddress);

    /**
     * @dev Emitted when the fee recipient is updated.
     * @param newRecipient The new fee recipient address.
     */
    event FeeRecipientUpdated(address indexed newRecipient);

    /**
     * @dev Emitted when the redemption fee tiers are updated.
     * @param baseBps The base redemption fee in basis points.
     * @param elevatedBps The elevated redemption fee in basis points.
     */
    event RedemptionFeesUpdated(uint16 baseBps, uint16 elevatedBps);

    /**
     * @dev Emitted when the active redemption fee tier changes.
     * @param active True if the elevated tier now applies.
     */
    event ElevatedFeeActiveUpdated(bool active);

    /**
     * @dev Emitted when a surplus tranche enters vesting.
     * @param amount The USDat amount of the tranche.
     */
    event SurplusReceived(uint256 amount);

    /**
     * @dev Emitted when a fully vested surplus tranche folds into usdatBalance.
     * @param amount The USDat amount swept.
     */
    event SurplusSwept(uint256 amount);

    /**
     * @dev Emitted when the surplus vesting period is updated.
     * @param oldPeriod The previous vesting period in seconds.
     * @param newPeriod The new vesting period in seconds.
     */
    event SurplusVestingPeriodUpdated(uint256 oldPeriod, uint256 newPeriod);

    /**
     * @dev Emitted when the per-tranche surplus cap is updated.
     * @param newMaxBps The new cap in basis points.
     */
    event MaxSurplusBpsUpdated(uint16 newMaxBps);

    /**
     * @dev Emitted when accrued management fees are collected.
     * @param recipient The fee recipient the shares were minted to.
     * @param shares The number of shares minted.
     */
    event ManagementFeeCollected(address indexed recipient, uint256 shares);

    /**
     * @dev Emitted when the management fee rate is updated.
     * @param newFeeBps The new fee in basis points per year.
     */
    event ManagementFeeUpdated(uint16 newFeeBps);

    /**
     * @dev Emitted when a module is registered.
     * @param module The module address.
     * @param maxWeightBps The module's weight cap in basis points.
     */
    event ModuleRegistered(address indexed module, uint16 maxWeightBps);

    /**
     * @dev Emitted when a module's weight cap is updated.
     * @param module The module address.
     * @param maxWeightBps The new weight cap in basis points.
     */
    event ModuleMaxWeightUpdated(address indexed module, uint16 maxWeightBps);

    /**
     * @dev Emitted when a module is deregistered.
     * @param module The module address.
     */
    event ModuleDeregistered(address indexed module);

    /**
     * @dev Emitted when the global cash floor is updated.
     * @param newMinCashBufferBps The new cash floor in basis points.
     */
    event MinCashBufferUpdated(uint16 newMinCashBufferBps);

    // ============ Blacklist Functions ============

    /**
     * @notice Adds an address to the blacklist.
     * @dev Only callable by addresses with the BLACKLISTER_ROLE.
     * Cannot blacklist addresses with DEFAULT_ADMIN_ROLE.
     * @param target The address to blacklist.
     */
    function addToBlacklist(address target) external;

    /**
     * @notice Removes an address from the blacklist.
     * @dev Only callable by addresses with the BLACKLISTER_ROLE.
     * @param target The address to un-blacklist.
     */
    function removeFromBlacklist(address target) external;

    /**
     * @notice Checks if an address is blacklisted.
     * @param account The address to check.
     * @return True if the address is blacklisted, false otherwise.
     */
    function isBlacklisted(address account) external view returns (bool);

    /**
     * @notice Burns shares from a blacklisted address, redistributing value to other holders.
     * @dev Only callable by addresses with the ENFORCER_ROLE.
     * The target address must be blacklisted and have a positive balance.
     * @param from The blacklisted address to redistribute from.
     */
    function redistributeLockedAmount(address from) external;

    /**
     * @notice Transfers a blacklisted holder's full sUSDat balance to a recovery address.
     * @dev Only callable by addresses with the ENFORCER_ROLE. Moves shares, no burn,
     * no liquidity needed. The recovery address must not be blacklisted.
     * @param from The blacklisted address to seize from.
     * @param to The recovery address to receive the shares.
     */
    function seize(address from, address to) external;

    // ============ Asset Management Functions ============

    /**
     * @notice Rescues tokens accidentally sent to the contract.
     * @dev Only callable by addresses with the DEFAULT_ADMIN_ROLE.
     * For USDat, only allows rescuing amounts above the internally tracked balance.
     * @param token The address of the token to rescue.
     * @param amount The amount of tokens to rescue.
     * @param to The address to send the rescued tokens to.
     */
    function rescueTokens(address token, uint256 amount, address to) external;

    // ============ Deposit Functions ============

    /**
     * @notice Deposits assets with slippage protection.
     * @dev Reverts if the shares received would be less than minShares.
     * @param assets The amount of assets to deposit.
     * @param receiver The address to receive the shares.
     * @param minShares The minimum number of shares to receive.
     * @return shares The number of shares minted.
     */
    function depositWithMinShares(uint256 assets, address receiver, uint256 minShares) external returns (uint256 shares);

    /**
     * @notice Mints shares with slippage protection.
     * @dev Reverts if the assets required would exceed maxAssets.
     * @param shares The number of shares to mint.
     * @param receiver The address to receive the shares.
     * @param maxAssets The maximum amount of assets to spend.
     * @return assets The amount of assets spent.
     */
    function mintWithMaxAssets(uint256 shares, address receiver, uint256 maxAssets) external returns (uint256 assets);

    /**
     * @notice Deposits assets with EIP-2612 permit for gasless approval.
     * @dev Combines permit and deposit in a single transaction.
     * @param assets The amount of assets to deposit.
     * @param receiver The address to receive the shares.
     * @param minShares The minimum number of shares to receive (slippage protection).
     * @param deadline The permit signature deadline.
     * @param v The permit signature v component.
     * @param r The permit signature r component.
     * @param s The permit signature s component.
     * @return shares The number of shares minted.
     */
    function depositWithPermit(
        uint256 assets,
        address receiver,
        uint256 minShares,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external returns (uint256 shares);

    /**
     * @notice Mints shares with EIP-2612 permit for gasless approval.
     * @dev Combines permit and mint in a single transaction.
     * @param shares The number of shares to mint.
     * @param receiver The address to receive the shares.
     * @param maxAssets The maximum amount of assets to spend (slippage protection).
     * @param deadline The permit signature deadline.
     * @param v The permit signature v component.
     * @param r The permit signature r component.
     * @param s The permit signature s component.
     * @return assets The amount of assets spent.
     */
    function mintWithPermit(
        uint256 shares,
        address receiver,
        uint256 maxAssets,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external returns (uint256 assets);

    /**
     * @notice Deposits assets with EIP-1271 permit for smart contract wallet approval.
     * @dev Combines permit and deposit in a single transaction. Supports smart contract
     * wallets like Gnosis Safe, Argent, etc. that implement EIP-1271.
     * @param assets The amount of assets to deposit.
     * @param receiver The address to receive the shares.
     * @param minShares The minimum number of shares to receive (slippage protection).
     * @param deadline The permit signature deadline.
     * @param signature The EIP-1271 compatible signature bytes.
     * @return shares The number of shares minted.
     */
    function depositWithPermit(
        uint256 assets,
        address receiver,
        uint256 minShares,
        uint256 deadline,
        bytes memory signature
    ) external returns (uint256 shares);

    /**
     * @notice Mints shares with EIP-1271 permit for smart contract wallet approval.
     * @dev Combines permit and mint in a single transaction. Supports smart contract
     * wallets like Gnosis Safe, Argent, etc. that implement EIP-1271.
     * @param shares The number of shares to mint.
     * @param receiver The address to receive the shares.
     * @param maxAssets The maximum amount of assets to spend (slippage protection).
     * @param deadline The permit signature deadline.
     * @param signature The EIP-1271 compatible signature bytes.
     * @return assets The amount of assets spent.
     */
    function mintWithPermit(
        uint256 shares,
        address receiver,
        uint256 maxAssets,
        uint256 deadline,
        bytes memory signature
    ) external returns (uint256 assets);

    // ============ Withdrawal Functions ============

    /**
     * @notice Requests a redemption by escrowing shares in the withdrawal queue.
     * @dev Standard ERC4626 withdraw/redeem are disabled. Use this function instead.
     * Transfers shares to the withdrawal queue and mints an NFT representing the request.
     * Never prices — stays live while any module oracle is down.
     * @param shares The number of shares to redeem (>= MIN_REQUEST_SHARES).
     * @param minSharePrice Limit: minimum execution price per 1e18 shares. The request
     * fills at this price or better; below it, it is skipped and stays queued.
     * @return requestId The ID of the withdrawal request NFT.
     */
    function requestRedeem(uint256 shares, uint256 minSharePrice) external returns (uint256 requestId);

    /**
     * @notice Attempts to redeem a complete queued request against the cash buffer.
     * @dev Only callable by the withdrawal queue (immutable address check). Prices,
     * checks the gross limit and liquidity, then burns and transfers atomically. A
     * skipped request does not mutate vault state beyond sweeping vested surplus.
     * @param shares The complete number of escrowed shares to redeem.
     * @param minSharePrice The minimum gross USDat per 1e18 shares.
     * @return result Whether the request settled or why it was skipped.
     * @return usdat The net USDat transferred to the queue when settled.
     */
    function redeemQueuedShares(uint256 shares, uint256 minSharePrice)
        external
        returns (RedemptionResult result, uint256 usdat);

    // ============ Module Management ============

    /**
     * @notice Registers an accounting module.
     * @dev Only callable by addresses with the MODULE_MANAGER_ROLE.
     * Reverts if MAX_MODULES modules are already registered.
     * @param module The module address.
     * @param maxWeightBps Hard cap on the module's share of totalAssets, in basis points.
     */
    function registerModule(address module, uint16 maxWeightBps) external;

    /**
     * @notice Updates a module's weight cap.
     * @dev Only callable by addresses with the MODULE_MANAGER_ROLE.
     * @param module The module address.
     * @param maxWeightBps The new weight cap in basis points.
     */
    function setMaxWeight(address module, uint16 maxWeightBps) external;

    /**
     * @notice Deregisters a module. Real removal; config cleared.
     * @dev Only callable by addresses with the MODULE_MANAGER_ROLE.
     * Requires the module's balance() to be zero (checked without pricing).
     * @param module The module address.
     */
    function deregisterModule(address module) external;

    /**
     * @notice Updates the global cash floor.
     * @dev Only callable by addresses with the PARAMETER_MANAGER_ROLE.
     * @param newMinCashBufferBps The new cash floor in basis points.
     */
    function setMinCashBuffer(uint16 newMinCashBufferBps) external;

    /**
     * @notice Returns the registered module addresses.
     * @return The module addresses.
     */
    function getModules() external view returns (address[] memory);

    /**
     * @notice Returns a module's configuration.
     * @param module The module address.
     * @return The module configuration.
     */
    function moduleConfig(address module) external view returns (ModuleConfig memory);

    /**
     * @notice Returns the global cash floor in basis points of totalAssets.
     * @return The cash floor in basis points.
     */
    function minCashBufferBps() external view returns (uint16);

    // ============ Rotations ============

    /**
     * @notice Acquires a backing asset with idle USDat via a registered module.
     * @dev Only callable by addresses with the OPERATOR_ROLE. May not push the module
     * above its maxWeightBps or cash below minCashBufferBps.
     * @param module The registered module to buy through.
     * @param usdatIn The amount of USDat to spend (6 decimals).
     * @param minAssetOut The minimum acceptable amount of asset acquired.
     * @param venueData Venue-specific execution data, forwarded to the module.
     * @return assetOut The amount of asset recognized.
     */
    function buyVia(address module, uint256 usdatIn, uint256 minAssetOut, bytes calldata venueData)
        external
        returns (uint256 assetOut);

    /**
     * @notice Closes part of a backing position back to USDat via a registered module.
     * @dev Only callable by addresses with the OPERATOR_ROLE. Never blocked by weight
     * or cash-floor checks.
     * @param module The registered module to sell through.
     * @param assetIn The amount of asset to sell.
     * @param minUsdatOut The minimum acceptable amount of USDat received.
     * @param venueData Venue-specific execution data, forwarded to the module.
     * @return usdatOut The amount of USDat returned to the buffer (6 decimals).
     */
    function sellVia(address module, uint256 assetIn, uint256 minUsdatOut, bytes calldata venueData)
        external
        returns (uint256 usdatOut);

    // ============ Surplus Inlet ============

    /**
     * @notice Transfers surplus USDat from Saturn's float into the vault.
     * @dev Only callable by addresses with the OPERATOR_ROLE. Enters a segregated leg
     * outside usdatBalance and vests linearly over surplusVestingPeriod; capped per
     * tranche at maxSurplusBps of totalAssets. One tranche at a time.
     * @param amount The USDat amount to transfer in (6 decimals).
     */
    function transferInSurplus(uint256 amount) external;

    /**
     * @notice Returns the unvested slice of the current surplus tranche.
     * @return The unvested USDat amount.
     */
    function getUnvestedSurplus() external view returns (uint256);

    /**
     * @notice Folds a fully vested surplus tranche into the cash buffer.
     * @dev Permissionless, NAV-neutral; also runs atop value-sensitive entrypoints.
     */
    function sweep() external;

    /**
     * @notice Returns the current surplus tranche amount.
     * @return The tranche USDat amount (6 decimals).
     */
    function surplusVestingAmount() external view returns (uint256);

    /**
     * @notice Returns the surplus vesting period.
     * @return The vesting period in seconds.
     */
    function surplusVestingPeriod() external view returns (uint256);

    /**
     * @notice Returns the per-tranche surplus cap.
     * @return The cap in basis points of totalAssets.
     */
    function maxSurplusBps() external view returns (uint16);

    // ============ View Functions ============

    /**
     * @notice Returns the withdrawal queue contract address.
     * @return The address of the WithdrawalQueueERC721 contract.
     */
    function getWithdrawalQueue() external view returns (address);

    /**
     * @notice Returns the current fee recipient address.
     * @return The fee recipient address.
     */
    function feeRecipient() external view returns (address);

    /**
     * @notice Returns the canonical destination for seized assets.
     * @return The recovery address.
     */
    function recoveryAddress() external view returns (address);

    /**
     * @notice Returns the internally tracked USDat balance.
     * @return The USDat balance.
     */
    function usdatBalance() external view returns (uint256);

    /**
     * @notice Returns the base redemption fee in basis points.
     * @return The base redemption fee in basis points.
     */
    function baseRedemptionFeeBps() external view returns (uint16);

    /**
     * @notice Returns the elevated redemption fee in basis points.
     * @return The elevated redemption fee in basis points.
     */
    function elevatedRedemptionFeeBps() external view returns (uint16);

    /**
     * @notice Returns whether the elevated redemption fee tier currently applies.
     * @return True if the elevated tier is active.
     */
    function elevatedFeeActive() external view returns (bool);

    /**
     * @notice Returns the redemption fee currently in effect (the active tier).
     * @return The applicable fee in basis points.
     */
    function redemptionFeeBps() external view returns (uint16);

    /**
     * @notice Returns the management fee in basis points per year.
     * @return The management fee in basis points per year.
     */
    function managementFeeBps() external view returns (uint16);

    /**
     * @notice Returns the timestamp of the last management fee collection.
     * @return The Unix timestamp.
     */
    function lastFeeCollection() external view returns (uint256);

    /**
     * @notice Collects the accrued management fee as newly minted shares to feeRecipient.
     * @dev Permissionless; pure supply dilution, oracle-independent. Time-determined —
     * collection timing and frequency don't change the total.
     */
    function collectManagementFee() external;

    // ============ Admin Functions ============

    /**
     * @notice Updates the surplus vesting period.
     * @dev Only callable by addresses with the PARAMETER_MANAGER_ROLE.
     * Cannot be changed while a tranche is still vesting.
     * @param newPeriod The new period in seconds (must be <= MAX_SURPLUS_VESTING_PERIOD).
     */
    function setSurplusVestingPeriod(uint256 newPeriod) external;

    /**
     * @notice Updates the per-tranche surplus cap.
     * @dev Only callable by addresses with the PARAMETER_MANAGER_ROLE.
     * @param newMaxBps The new cap in basis points of totalAssets.
     */
    function setMaxSurplusBps(uint16 newMaxBps) external;

    /**
     * @notice Updates both redemption fee tiers.
     * @dev Only callable by addresses with the PARAMETER_MANAGER_ROLE.
     * Requires base <= elevated <= MAX_REDEMPTION_FEE_BPS.
     * @param baseBps The base fee in basis points.
     * @param elevatedBps The elevated fee in basis points.
     */
    function setRedemptionFees(uint16 baseBps, uint16 elevatedBps) external;

    /**
     * @notice Selects which redemption fee tier applies.
     * @dev Only callable by addresses with the OPERATOR_ROLE, e.g. flipped with the
     * settlement risk environment (off-hours, stress). Explicit state, not a toggle.
     * @param active True to apply the elevated tier.
     */
    function setElevatedFeeActive(bool active) external;

    /**
     * @notice Updates the management fee rate.
     * @dev Only callable by addresses with the PARAMETER_MANAGER_ROLE. Collects at the
     * old rate first so the change never applies retroactively.
     * @param newFeeBps The new fee in basis points per year (<= MAX_MANAGEMENT_FEE_BPS).
     */
    function setManagementFee(uint16 newFeeBps) external;

    /**
     * @notice Updates the fee recipient address.
     * @dev Only callable by addresses with the PARAMETER_MANAGER_ROLE.
     * @param newRecipient The new fee recipient address.
     */
    function setFeeRecipient(address newRecipient) external;

    /**
     * @notice Updates the canonical destination for seized assets.
     * @dev Only callable by addresses with the PARAMETER_MANAGER_ROLE. The destination
     * cannot be zero, blacklisted in StakedUSDat, or frozen in USDat.
     * @param newRecoveryAddress The new recovery address.
     */
    function setRecoveryAddress(address newRecoveryAddress) external;

    /**
     * @notice Pauses the contract.
     * @dev Only callable by addresses with the PAUSER_ROLE.
     * When paused, deposits, mints, and redemption requests are disabled.
     */
    function pause() external;

    /**
     * @notice Unpauses the contract.
     * @dev Only callable by addresses with the UNPAUSER_ROLE.
     */
    function unpause() external;
}
