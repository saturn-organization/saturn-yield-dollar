// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

/**
 * @title IWithdrawalQueueERC721
 * @author Saturn
 * @notice Interface for the WithdrawalQueueERC721 contract.
 * @dev A UUPS upgradeable NFT-based withdrawal queue where each withdrawal request
 * is represented as an ERC721 token. Users request redemptions from StakedUSDat,
 * their shares are escrowed, and they receive an NFT representing their claim.
 * The queue is a limit-order book against the vault-calculated net redemption
 * price: the operator processes complete requests against the vault's cash buffer
 * using one vault snapshot per processing batch. The queue never prices; its
 * settlement coupling is redeemQueuedShares.
 */
interface IWithdrawalQueueERC721 {
    // ============ Enums ============

    /**
     * @notice Persistent request lifecycle status.
     * @dev Existing v1 values retain their numeric meaning. InProgress remains only
     * for storage compatibility; v2 never creates it. Cancelled is appended.
     */
    enum RequestStatus {
        NULL,
        Requested,
        InProgress,
        Processed,
        Claimed,
        Cancelled
    }

    // ============ Structs ============

    /**
     * @notice Withdrawal request data structure.
     * @dev Field order is unchanged from v1. minSharePrice reinterprets the
     * minUsdatReceived slot without converting legacy values. Lifecycle
     * authorization uses status rather than deriving state from numeric fields.
     * @param shares The complete escrowed share amount, retained unchanged.
     * @param usdatOwed Zero until processing assigns the complete fixed payout.
     * @param timestamp The timestamp when the request was created.
     * @param minSharePrice Limit: minimum net USDat payout per 1e18 shares after
     * the active redemption fee (v1 slot, was minUsdatReceived — legacy values
     * are reinterpreted unchanged).
     * @param status Authoritative request lifecycle state.
     */
    struct Request {
        uint256 shares;
        uint256 usdatOwed;
        uint256 timestamp;
        uint256 minSharePrice;
        RequestStatus status;
    }

    // ============ Errors ============

    /**
     * @dev Thrown when a zero amount is provided where a non-zero value is required.
     */
    error ZeroAmount();

    /**
     * @dev Thrown when the caller is not allowed to perform the operation.
     */
    error OperationNotAllowed();

    /**
     * @dev Thrown when an operation requires a Requested request.
     */
    error RequestNotOpen();

    /**
     * @dev Thrown when legacy recovery is attempted for a request that is not InProgress.
     */
    error RequestNotInProgress();

    /**
     * @dev Thrown when an operation requires a Processed request.
     */
    error RequestNotProcessed();

    /**
     * @dev Thrown when the caller is not the owner of the token.
     */
    error NotOwner();

    /**
     * @dev Thrown when an operation requires a blacklisted address but the address is not blacklisted.
     */
    error NotBlacklisted();

    /**
     * @dev Thrown when an operation involves a blacklisted address.
     */
    error AddressBlacklisted();

    // ============ Events ============

    /**
     * @dev Emitted when a new withdrawal request is created.
     * @param tokenId The NFT token ID representing the request.
     * @param user The user who created the request.
     * @param shares The number of shares escrowed.
     * @param timestamp The timestamp of the request.
     */
    event WithdrawalRequested(uint256 indexed tokenId, address indexed user, uint256 shares, uint256 timestamp);

    /**
     * @dev Emitted once when a complete request settles.
     * @param tokenId The NFT token ID of the settled request.
     * @param shares The complete number of shares redeemed.
     * @param usdatAmount The request's complete net USDat payout.
     */
    event WithdrawalProcessed(uint256 indexed tokenId, uint256 shares, uint256 usdatAmount);

    /**
     * @dev Emitted when a holder updates a request's limit price.
     * @param tokenId The NFT token ID of the updated request.
     * @param newMinSharePrice The new minimum net USDat payout per 1e18 shares.
     */
    event MinSharePriceUpdated(uint256 indexed tokenId, uint256 newMinSharePrice);

    /**
     * @dev Emitted when a holder claims a processed request's complete fixed payout.
     * @param tokenId The NFT token ID that was claimed.
     * @param user The user who claimed.
     * @param usdatAmount The amount of USDat claimed.
     */
    event Claimed(uint256 indexed tokenId, address indexed user, uint256 usdatAmount);

    /**
     * @dev Emitted when a holder cancels an open request.
     * @param tokenId The NFT token ID that was cancelled.
     * @param user The holder who received the returned shares.
     * @param shares The complete escrowed sUSDat amount returned.
     */
    event RequestCancelled(uint256 indexed tokenId, address indexed user, uint256 shares);

    /**
     * @dev Emitted when a legacy InProgress request is returned to Requested.
     * @param tokenId The request ID reset by the admin.
     */
    event LegacyInProgressRequestReset(uint256 indexed tokenId);

    /**
     * @dev Emitted when a processed request's complete payout is seized.
     * @param tokenId The NFT token ID of the seized request.
     * @param user The restricted user whose funds were seized.
     * @param usdatAmount The amount of USDat seized.
     * @param to The address that received the seized funds.
     */
    event FundsSeized(uint256 indexed tokenId, address indexed user, uint256 usdatAmount, address indexed to);

    /**
     * @dev Emitted when a live request is seized from a blacklisted user.
     * @param tokenId The NFT token ID of the seized request.
     * @param user The restricted user whose request was seized.
     * @param to The address that received the NFT.
     */
    event RequestSeized(uint256 indexed tokenId, address indexed user, address indexed to);

    // ============ Admin Functions ============

    /**
     * @notice Pauses the contract.
     * @dev Only callable by addresses with the PAUSER_ROLE.
     */
    function pause() external;

    /**
     * @notice Unpauses the contract.
     * @dev Only callable by addresses with the UNPAUSER_ROLE.
     */
    function unpause() external;

    /**
     * @notice Returns a legacy InProgress request to the Requested state.
     * @dev Only callable by OPERATOR_ROLE, including while paused. The request
     * must currently be InProgress.
     * @param tokenId Legacy request ID to reset.
     */
    function resetLegacyInProgressRequest(uint256 tokenId) external;

    // ============ Request Creation ============

    /**
     * @notice Creates a new withdrawal request.
     * @dev Called by StakedUSDat when a user requests redemption.
     * Mints an NFT to the user representing their withdrawal request.
     * Only callable by the StakedUSDat contract (immutable address check).
     * Reverts if the user is restricted by either sUSDat or USDat.
     * @param user The user requesting withdrawal.
     * @param shares The amount of sUSDat shares escrowed.
     * @param minSharePrice The minimum net USDat payout per 1e18 shares after the
     * active redemption fee.
     * @return tokenId The NFT token ID (same as request ID).
     */
    function addRequest(address user, uint256 shares, uint256 minSharePrice) external returns (uint256 tokenId);

    /**
     * @notice Updates a request's limit price. Freely updatable while open, in either
     * direction; applies to the request's future settlement attempt.
     * @dev Only callable by the NFT owner.
     * @param tokenId The token ID of the request to update.
     * @param newMinSharePrice The new minimum net USDat payout per 1e18 shares.
     */
    function updateMinSharePrice(uint256 tokenId, uint256 newMinSharePrice) external;

    /**
     * @notice Cancels an open request and returns all escrowed shares without a fee.
     * @dev Only the current NFT owner may cancel. The request record is retained with
     * status Cancelled after the NFT is burned. Queue pause and either owner
     * restriction block cancellation; vault pause makes the sUSDat return transfer
     * revert.
     * @param tokenId The NFT token ID to cancel.
     */
    function cancelRequest(uint256 tokenId) external;

    // ============ Processing Functions ============

    /**
     * @notice Attempts to settle complete withdrawal requests against the vault's cash buffer.
     * @dev Processing follows caller order at one vault-snapshotted price. Missing and
     * non-Requested IDs are skipped, including duplicates after settlement. Below-limit
     * and insufficient-liquidity requests remain unchanged and are also skipped so later
     * requests may settle. Unexpected vault failures revert the complete batch. Only
     * callable by addresses with the OPERATOR_ROLE.
     * @param tokenIds Ordered token IDs to process.
     */
    function processRequests(uint256[] calldata tokenIds) external;

    // ============ Claiming Functions ============

    /**
     * @notice Claims the complete fixed payout of a processed request.
     * @dev Only the current NFT owner may claim. The request record is retained with
     * status Claimed after the NFT is burned. Queue pause and either owner restriction
     * block claiming; vault pause alone does not block an already-funded payout.
     * @param tokenId The NFT token ID to claim.
     * @return amount The amount of USDat claimed.
     */
    function claim(uint256 tokenId) external returns (uint256 amount);

    // ============ View Functions ============

    /**
     * @notice Returns every live withdrawal request token currently owned by a user.
     * @dev Includes requests regardless of lifecycle status. Burned terminal requests
     * are excluded, and ERC721Enumerable does not guarantee a stable ordering. Runtime
     * and return size grow linearly with the user's live request balance.
     * @param user The current request owner to query.
     * @return tokenIds The token IDs currently owned by the user.
     */
    function getUserRequests(address user) external view returns (uint256[] memory tokenIds);

    // ============ Compliance Functions ============

    /**
     * @notice Seizes a live request NFT from a restricted holder.
     * @dev Transfers the NFT and its unchanged request record to the current recovery
     * address configured by StakedUSDat. Only callable by addresses with the
     * ENFORCER_ROLE.
     * @param tokenId The token ID to seize.
     */
    function seizeRequest(uint256 tokenId) external;

    /**
     * @notice Seizes a processed request's complete payout from a restricted holder.
     * @dev Marks the request Claimed, burns the NFT, and transfers the complete fixed
     * usdatOwed amount to the current recovery address configured by StakedUSDat. The
     * request record is retained. Only callable by addresses with the ENFORCER_ROLE.
     * @param tokenId The token ID to seize.
     */
    function seize(uint256 tokenId) external;
}
