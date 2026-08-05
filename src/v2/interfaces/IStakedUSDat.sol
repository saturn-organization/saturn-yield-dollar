// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ISTRConExecutionPolicy} from "./ISTRConExecutionPolicy.sol";
import {ISTRCMirrorModule} from "./modules/ISTRCMirrorModule.sol";
import {ISTRConModule} from "./modules/ISTRConModule.sol";

/**
 * @title IStakedUSDat
 * @author Saturn
 * @notice Interface for the StakedUSDat (sUSDat) ERC4626 vault contract.
 * @dev StakedUSDat is a UUPS upgradeable ERC4626 vault for staking USDat.
 * Users deposit USDat and receive sUSDat shares representing their stake, with
 * asynchronous redemptions, compliance controls, and explicit market modes.
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

    /**
     * @notice Vault operating mode selected for current market conditions.
     */
    enum MarketMode {
        Regular,
        Elevated,
        Restricted
    }

    // ============ V2 Initialization ============

    struct V2Config {
        ISTRCMirrorModule strcMirrorModule;
        ISTRConModule strconModule;
        ISTRConExecutionPolicy executionPolicy;
        address recoveryAddress;
        address executionVehicle;
        uint16 baseRedemptionFeeBps;
        uint16 elevatedRedemptionFeeBps;
        uint16 elevatedDepositFeeBps;
        uint16 executionToleranceBps;
        uint16 migrationToleranceBps;
        uint128 initialExecutionCapacity;
        uint128 initialExecutionRefillPerDay;
    }

    struct V2Roles {
        address parameterManager;
        address marketModeManager;
        address operator;
        address blacklister;
        address enforcer;
        address pauser;
        address unpauser;
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
     * @dev Thrown when an operation is disabled in Restricted mode.
     */
    error MarketRestricted();

    /**
     * @dev Thrown when Regular mode is selected without a valid bounded authorization.
     */
    error InvalidRegularModeAuthorization();

    /**
     * @dev Thrown when attempting to un-blacklist an address that is not blacklisted.
     */
    error AddressNotBlacklisted();

    /**
     * @dev Thrown when an operation involves a blacklisted address.
     */
    error AddressBlacklisted();

    /**
     * @dev Thrown when attempting to blacklist an admin address.
     */
    error CannotBlacklistAdmin();

    /**
     * @dev Thrown when a redemption request is below MIN_REQUEST_SHARES.
     */
    error WithdrawalTooSmall();

    /**
     * @dev Thrown when slippage protection is triggered (received less than minimum).
     */
    error SlippageExceeded();

    /**
     * @dev Thrown when an operation requires more recognized balance than is available.
     */
    error InsufficientBalance();

    /**
     * @dev Thrown when redemption fee tiers are invalid.
     */
    error InvalidFee();

    /**
     * @dev Thrown when a fixed module address does not contain deployed code.
     */
    error InvalidModule();

    /**
     * @dev Thrown when the migration tolerance exceeds the protocol maximum.
     */
    error InvalidMigrationTolerance();

    /**
     * @dev Thrown when migration cannot establish a non-zero pre-migration NAV.
     */
    error ZeroNAV();

    /**
     * @dev Thrown when migration changes whole-vault NAV beyond the approved tolerance.
     */
    error MigrationNAVMismatch();

    /**
     * @dev Thrown when a trade deadline has passed.
     */
    error DeadlineExpired();

    /**
     * @dev Thrown when a new surplus tranche is attempted while the prior tranche is vesting.
     */
    error StillVesting();

    /**
     * @dev Thrown when the surplus vesting period is zero or exceeds the protocol maximum.
     */
    error InvalidVestingPeriod();

    /**
     * @dev Thrown when a surplus transfer exceeds the configured percentage of pre-transfer NAV.
     */
    error SurplusExceedsMax();

    /**
     * @dev Thrown when a measured token or module balance delta is not exact.
     */
    error InvalidAssetDelta();

    /**
     * @dev Thrown when physical token custody is below its recognized balance.
     */
    error CustodyShortfall();

    /**
     * @dev Thrown when a rescue exceeds untracked custody or tracked custody is short.
     */
    error ExceedsRescuable();

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
     * @dev Emitted when a blacklisted holder's shares are seized to a destination.
     * @param from The blacklisted address seized from.
     * @param to The address the shares were transferred to.
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
     * @dev Emitted when the migration NAV tolerance changes.
     * @param oldBps The previous tolerance in basis points.
     * @param newBps The new tolerance in basis points.
     */
    event MigrationToleranceUpdated(uint16 oldBps, uint16 newBps);

    /**
     * @dev Emitted after an exact STRCon purchase settles.
     * @param module The fixed STRCon module.
     * @param vehicle The configured execution counterparty.
     * @param usdatPaid The exact USDat paid, in 6-decimal units.
     * @param assetReceived The exact STRCon received, in 18-decimal units.
     * @param oraclePrice The validated STRCon price, in 8-decimal units.
     */
    event AssetBought(
        address indexed module, address indexed vehicle, uint256 usdatPaid, uint256 assetReceived, uint256 oraclePrice
    );

    /**
     * @dev Emitted after an exact STRCon sale settles.
     * @param module The fixed STRCon module.
     * @param vehicle The configured execution counterparty.
     * @param assetDelivered The exact STRCon delivered to the execution vehicle, in 18-decimal units.
     * @param usdatReceived The exact USDat received, in 6-decimal units.
     * @param oraclePrice The validated STRCon price, in 8-decimal units.
     */
    event AssetSold(
        address indexed module,
        address indexed vehicle,
        uint256 assetDelivered,
        uint256 usdatReceived,
        uint256 oraclePrice
    );

    /**
     * @dev Emitted when the vault operating mode changes.
     * @param oldMode The previous market mode.
     * @param newMode The new market mode.
     */
    event MarketModeChanged(MarketMode oldMode, MarketMode newMode);

    /**
     * @dev Emitted when Regular mode is authorized through a new deadline.
     * @param validUntil The exclusive timestamp through which Regular mode is authorized.
     */
    event RegularModeAuthorized(uint64 validUntil);

    /**
     * @dev Emitted when the redemption fee tiers are updated.
     * @param baseBps The base redemption fee in basis points.
     * @param elevatedBps The elevated redemption fee in basis points.
     */
    event RedemptionFeesUpdated(uint16 baseBps, uint16 elevatedBps);

    /**
     * @dev Emitted when the elevated deposit fee is updated.
     * @param newFee The new elevated deposit fee in basis points.
     */
    event DepositFeeUpdated(uint256 newFee);

    /**
     * @dev Emitted when a new USDat surplus tranche begins vesting.
     * @param amount The USDat amount received.
     */
    event SurplusReceived(uint256 amount);

    /**
     * @dev Emitted when newly vested surplus is folded into the cash balance.
     * @param amount The incremental USDat amount moved into usdatBalance.
     */
    event SurplusSwept(uint256 amount);

    /**
     * @dev Emitted when the surplus vesting period changes.
     * @param oldPeriod The previous period in seconds.
     * @param newPeriod The new period in seconds.
     */
    event SurplusVestingPeriodUpdated(uint256 oldPeriod, uint256 newPeriod);

    // ============ Blacklist Functions ============

    /**
     * @notice Performs the one-shot v1 to v2 vault-state migration.
     */
    function initializeV2(V2Config calldata config, V2Roles calldata roles) external;

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
     * @notice Transfers a blacklisted holder's full sUSDat balance to a recovery address.
     * @dev Only callable by addresses with the ENFORCER_ROLE. Moves shares, no burn,
     * no liquidity needed. Resolves the current valid recoveryAddress internally.
     * @param from The blacklisted address to seize from.
     */
    function seize(address from) external;

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

    // ============ Surplus Functions ============

    /**
     * @notice Transfers a USDat surplus tranche into the vault for linear vesting.
     * @dev Only callable by OPERATOR_ROLE while unpaused. The function pulls only the
     * configured ERC4626 asset and requires the exact requested custody increase.
     * @param amount The USDat amount to transfer, in 6-decimal asset units.
     */
    function transferInSurplus(uint256 amount) external;

    /**
     * @notice Returns the portion of the current surplus tranche that remains unvested.
     * @return The unvested USDat amount, rounded up.
     */
    function getUnvestedSurplus() external view returns (uint256);

    /**
     * @notice Folds newly vested surplus into the spendable USDat balance.
     * @dev Permissionless and a no-op when no newly vested amount is available.
     */
    function sweep() external;

    // ============ Rotation Functions ============

    /**
     * @notice Buys an exact amount of STRCon from the configured execution vehicle.
     * @dev Only callable by OPERATOR_ROLE while unpaused and outside Restricted mode.
     * The vehicle must approve the vault to pull assetReceived of the fixed module asset.
     * @param usdatPaid The exact USDat paid, in 6-decimal units.
     * @param assetReceived The exact module asset received, in its native decimals.
     * @param expectedVehicle The execution vehicle approved for this exact trade.
     * @param deadline The inclusive execution deadline.
     */
    function buy(uint256 usdatPaid, uint256 assetReceived, address expectedVehicle, uint256 deadline) external;

    /**
     * @notice Sells an exact amount of STRCon to the configured execution vehicle.
     * @dev Only callable by OPERATOR_ROLE while unpaused and outside Restricted mode.
     * The vehicle must approve the vault to pull usdatReceived USDat.
     * @param assetDelivered The exact module asset delivered to the vehicle, in its native decimals.
     * @param usdatReceived The exact USDat received, in 6-decimal units.
     * @param expectedVehicle The execution vehicle approved for this exact trade.
     * @param deadline The inclusive execution deadline.
     */
    function sell(uint256 assetDelivered, uint256 usdatReceived, address expectedVehicle, uint256 deadline) external;

    // ============ Migration Functions ============

    /**
     * @notice Replaces the legacy STRC mirror position with an exact STRCon delivery.
     * @dev Only callable once by DEFAULT_ADMIN_ROLE while unpaused.
     * @param expectedStrcon The exact STRCon amount pulled from the execution vehicle.
     * @param deadline The inclusive migration deadline.
     */
    function migrate(uint256 expectedStrcon, uint256 deadline) external;

    // ============ Withdrawal Functions ============

    /**
     * @notice Requests a redemption by escrowing shares in the withdrawal queue.
     * @dev Standard ERC4626 withdraw/redeem are disabled. Use this function instead.
     * Transfers shares to the withdrawal queue and mints an NFT representing the request.
     * Never prices.
     * @param shares The number of shares to redeem (>= MIN_REQUEST_SHARES).
     * @param minSharePrice Limit: minimum net USDat payout per 1e18 shares after the
     * active redemption fee. The request fills at this price or better; below it,
     * it is skipped and stays queued.
     * @return requestId The ID of the withdrawal request NFT.
     */
    function requestRedeem(uint256 shares, uint256 minSharePrice) external returns (uint256 requestId);

    /**
     * @notice Attempts to redeem a complete queued request against the cash buffer.
     * @dev Only callable by the withdrawal queue (immutable address check). Prices,
     * deducts the active fee, checks the net payout limit and liquidity, then burns
     * and transfers atomically.
     * @param shares The complete number of escrowed shares to redeem.
     * @param minSharePrice The minimum net USDat payout per 1e18 shares.
     * @return result Whether the request settled or why it was skipped.
     * @return usdat The net USDat transferred to the queue when settled.
     */
    function redeemQueuedShares(uint256 shares, uint256 minSharePrice)
        external
        returns (RedemptionResult result, uint256 usdat);

    // ============ View Functions ============

    /**
     * @notice Returns the withdrawal queue contract address.
     * @return The address of the WithdrawalQueueERC721 contract.
     */
    function getWithdrawalQueue() external view returns (address);

    /**
     * @notice Returns the canonical destination for seized assets.
     * @return The recovery address.
     */
    function recoveryAddress() external view returns (address);

    /**
     * @notice Returns the effective vault operating mode.
     * @return Regular before its authorization expires, otherwise Elevated or Restricted.
     */
    function marketMode() external view returns (MarketMode);

    /**
     * @notice Returns the exclusive timestamp through which Regular mode is authorized.
     */
    function regularModeValidUntil() external view returns (uint64);

    /**
     * @notice Returns the base redemption fee in basis points.
     */
    function baseRedemptionFeeBps() external view returns (uint16);

    /**
     * @notice Returns the elevated redemption fee in basis points.
     */
    function elevatedRedemptionFeeBps() external view returns (uint16);

    /**
     * @notice Returns the configured elevated deposit fee in basis points.
     */
    function elevatedDepositFeeBps() external view returns (uint256);

    /**
     * @notice Returns the deposit fee selected by the current market mode.
     */
    function depositFeeBps() external view returns (uint256);

    /**
     * @notice Returns the fixed tokenless STRC mirror accounting module.
     */
    function strcMirrorModule() external view returns (ISTRCMirrorModule);

    /**
     * @notice Returns the fixed STRCon accounting and trading module.
     */
    function strconModule() external view returns (ISTRConModule);

    /**
     * @notice Returns the fixed STRCon execution policy.
     */
    function executionPolicy() external view returns (ISTRConExecutionPolicy);

    /**
     * @notice Returns the maximum permitted whole-vault NAV change during migration.
     */
    function migrationToleranceBps() external view returns (uint16);

    /**
     * @notice Returns the redemption fee selected by the current market mode.
     */
    function redemptionFeeBps() external view returns (uint16);

    /**
     * @notice Returns the internally tracked USDat balance.
     * @return The USDat balance.
     */
    function usdatBalance() external view returns (uint256);

    /**
     * @notice Returns the original amount of the active surplus tranche.
     * @dev Returns zero after the tranche is fully vested and swept.
     */
    function surplusVestingAmount() external view returns (uint256);

    /**
     * @notice Returns the timestamp at which the current surplus tranche began vesting.
     */
    function surplusVestingStartTimestamp() external view returns (uint256);

    /**
     * @notice Returns the configured surplus vesting period.
     */
    function surplusVestingPeriod() external view returns (uint256);

    // ============ Enforcer Functions ============

    /**
     * @notice Rescues untracked ERC20 tokens held by the vault.
     * @dev Only callable by ENFORCER_ROLE. USDat cash and surplus custody,
     * plus the STRCon module's tracked token balance, cannot be rescued. The current
     * valid recoveryAddress is the only destination.
     * @param token The ERC20 token to rescue.
     * @param amount The amount to transfer.
     */
    function rescueTokens(address token, uint256 amount) external;

    // ============ Admin Functions ============

    /**
     * @notice Updates the canonical destination for seized assets.
     * @dev Only callable by addresses with the PARAMETER_MANAGER_ROLE. The destination
     * cannot be zero, blacklisted in StakedUSDat, or frozen in USDat.
     * @param newRecoveryAddress The new recovery address.
     */
    function setRecoveryAddress(address newRecoveryAddress) external;

    /**
     * @notice Updates the whole-vault NAV tolerance for migration.
     * @dev Only callable by PARAMETER_MANAGER_ROLE and capped at
     * MAX_MIGRATION_TOLERANCE_BPS.
     * @param newBps The new tolerance in basis points.
     */
    function setMigrationTolerance(uint16 newBps) external;

    /**
     * @notice Sets the vault to Elevated or Restricted mode.
     * @dev Only callable by addresses with the MARKET_MODE_MANAGER_ROLE. This remains
     * callable while the vault is paused. Regular requires authorizeRegularMode.
     * @param newMode The explicit target market mode.
     */
    function setMarketMode(MarketMode newMode) external;

    /**
     * @notice Authorizes Regular mode through a bounded future deadline.
     * @dev Only callable by addresses with the MARKET_MODE_MANAGER_ROLE. This remains
     * callable while the vault is paused.
     * @param validUntil The exclusive timestamp through which Regular mode is authorized.
     */
    function authorizeRegularMode(uint64 validUntil) external;

    /**
     * @notice Updates both redemption fee tiers.
     * @dev Only callable by addresses with the PARAMETER_MANAGER_ROLE.
     * Requires baseBps <= elevatedBps <= MAX_REDEMPTION_FEE_BPS.
     */
    function setRedemptionFees(uint16 baseBps, uint16 elevatedBps) external;

    /**
     * @notice Updates the elevated deposit fee.
     * @dev Only callable by addresses with the PARAMETER_MANAGER_ROLE.
     * Requires newFeeBps <= MAX_DEPOSIT_FEE_BPS.
     */
    function setElevatedDepositFee(uint256 newFeeBps) external;

    /**
     * @notice Updates the surplus vesting period.
     * @dev Only callable by PARAMETER_MANAGER_ROLE when no tranche remains unvested.
     * @param newPeriod The new period in seconds.
     */
    function setSurplusVestingPeriod(uint256 newPeriod) external;

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
