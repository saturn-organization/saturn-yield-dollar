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
     * @dev Thrown when a withdrawal amount is below the minimum threshold.
     */
    error WithdrawalTooSmall();

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
     * @dev Emitted when the fee recipient is updated.
     * @param newRecipient The new fee recipient address.
     */
    event FeeRecipientUpdated(address indexed newRecipient);

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
     * @param shares The number of shares to redeem.
     * @param minUsdatReceived The minimum amount of USDat the user will accept.
     * @return requestId The ID of the withdrawal request NFT.
     */
    function requestRedeem(uint256 shares, uint256 minUsdatReceived) external returns (uint256 requestId);

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
     * @notice Returns the internally tracked USDat balance.
     * @return The USDat balance.
     */
    function usdatBalance() external view returns (uint256);

    // ============ Admin Functions ============

    /**
     * @notice Updates the fee recipient address.
     * @dev Only callable by addresses with the PARAMETER_MANAGER_ROLE.
     * @param newRecipient The new fee recipient address.
     */
    function setFeeRecipient(address newRecipient) external;

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
