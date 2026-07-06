// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IWithdrawalQueueERC721
 * @author Saturn
 * @notice Interface for the WithdrawalQueueERC721 contract.
 * @dev A UUPS upgradeable NFT-based withdrawal queue where each withdrawal request
 * is represented as an ERC721 token. Users request redemptions from StakedUSDat,
 * their shares are escrowed, and they receive an NFT representing their claim.
 * The queue is a limit-order book against NAV: the operator processes requests
 * against the vault's cash buffer, each fill priced by the vault at its live mark.
 * The queue never prices; its only vault couplings are previewRedeem and
 * redeemQueuedShares.
 */
interface IWithdrawalQueueERC721 {
    // ============ Enums ============

    /**
     * @notice Legacy v1 request lifecycle status. v2 logic neither reads nor writes it;
     * the variants are kept so stored values keep their meaning.
     */
    enum RequestStatus {
        NULL,
        Requested,
        InProgress,
        Processed,
        Claimed
    }

    // ============ Structs ============

    /**
     * @notice Withdrawal request data structure.
     * @dev Two derived states drive all logic — open (shares > 0) and claimable
     * (usdatOwed > 0) — and both can hold at once (a partially filled request).
     * A token exists iff shares > 0 || usdatOwed > 0. The original request size lives
     * in the WithdrawalRequested event.
     * @param shares Shares STILL QUEUED — decremented per fill.
     * @param usdatOwed Accrued, unclaimed payout.
     * @param timestamp The timestamp when the request was created.
     * @param minSharePrice Limit: minimum execution price per 1e18 shares (v1 slot,
     * was minUsdatReceived — pending entries converted in place at upgrade).
     * @param status Legacy v1 slot; v2 logic neither reads nor writes it.
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
     * @dev Thrown when a request has no shares still queued (dead or fully filled token).
     */
    error RequestNotOpen();

    /**
     * @dev Thrown when a request has no accrued payout to claim or seize.
     */
    error NothingToClaim();

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
     * @dev Emitted when a new withdrawal request is created. `shares` here is the
     * original request size; the struct's shares field decrements per fill.
     * @param tokenId The NFT token ID representing the request.
     * @param user The user who created the request.
     * @param shares The number of shares escrowed.
     * @param timestamp The timestamp of the request.
     */
    event WithdrawalRequested(uint256 indexed tokenId, address indexed user, uint256 shares, uint256 timestamp);

    /**
     * @dev Emitted per fill during processing. A request filled in slices emits once
     * per slice.
     * @param tokenId The NFT token ID of the filled request.
     * @param sharesFilled The number of shares redeemed in this fill.
     * @param usdatAmount The net USDat accrued to the request in this fill.
     */
    event WithdrawalProcessed(uint256 indexed tokenId, uint256 sharesFilled, uint256 usdatAmount);

    /**
     * @dev Emitted when a holder updates a request's limit price.
     * @param tokenId The NFT token ID of the updated request.
     * @param newMinSharePrice The new minimum execution price per 1e18 shares.
     */
    event MinSharePriceUpdated(uint256 indexed tokenId, uint256 newMinSharePrice);

    /**
     * @dev Emitted when a user claims accrued USDat. Can fire multiple times per token
     * (partial fills); a claim does not imply a burn.
     * @param tokenId The NFT token ID that was claimed.
     * @param user The user who claimed.
     * @param usdatAmount The amount of USDat claimed.
     */
    event Claimed(uint256 indexed tokenId, address indexed user, uint256 usdatAmount);

    /**
     * @dev Emitted when accrued funds are seized from a blacklisted user.
     * @param tokenId The NFT token ID of the seized request.
     * @param user The blacklisted user whose funds were seized.
     * @param usdatAmount The amount of USDat seized.
     * @param to The address that received the seized funds.
     */
    event FundsSeized(uint256 indexed tokenId, address indexed user, uint256 usdatAmount, address indexed to);

    /**
     * @dev Emitted when a live request is seized from a blacklisted user.
     * @param tokenId The NFT token ID of the seized request.
     * @param user The blacklisted user whose request was seized.
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

    // ============ Request Creation ============

    /**
     * @notice Creates a new withdrawal request.
     * @dev Called by StakedUSDat when a user requests redemption.
     * Mints an NFT to the user representing their withdrawal request.
     * Only callable by the StakedUSDat contract (immutable address check).
     * @param user The user requesting withdrawal.
     * @param shares The amount of sUSDat shares escrowed.
     * @param minSharePrice The minimum execution price per 1e18 shares.
     * @return tokenId The NFT token ID (same as request ID).
     */
    function addRequest(address user, uint256 shares, uint256 minSharePrice) external returns (uint256 tokenId);

    /**
     * @notice Updates a request's limit price. Freely updatable while open, in either
     * direction; applies to future fills only.
     * @dev Only callable by the NFT owner.
     * @param tokenId The token ID of the request to update.
     * @param newMinSharePrice The new minimum execution price per 1e18 shares.
     */
    function updateMinSharePrice(uint256 tokenId, uint256 newMinSharePrice) external;

    // ============ Processing Functions ============

    /**
     * @notice Processes withdrawal requests against the vault's cash buffer.
     * @dev The operator passes ordered tokenIds and no amounts; the buffer decides fill
     * sizes via the vault's redeemQueuedShares clamp. Per request: reverts on a dead
     * token, skips when the live share price is below the request's limit, breaks when
     * the buffer is dry. Only callable by addresses with the OPERATOR_ROLE.
     * @param tokenIds Ordered token IDs to process.
     */
    function processRequests(uint256[] calldata tokenIds) external;

    // ============ Claiming Functions ============

    /**
     * @notice Claims the accrued payout of a request.
     * @dev Pays usdatOwed and zeroes it; burns the NFT only when the request is fully
     * filled and drained. A partially filled holder can claim accrued payout anytime.
     * @param tokenId The NFT token ID to claim.
     * @return amount The amount of USDat claimed.
     */
    function claim(uint256 tokenId) external returns (uint256 amount);

    // ============ Compliance Functions ============

    /**
     * @notice Seizes live request NFTs from blacklisted holders.
     * @dev Transfers the NFTs to the specified address; accrued usdatOwed and the open
     * remainder travel with the token.
     * Only callable by addresses with the ENFORCER_ROLE.
     * @param tokenIds Array of token IDs to seize.
     * @param to The address to transfer the NFTs to.
     */
    function seizeRequests(uint256[] calldata tokenIds, address to) external;

    /**
     * @notice Seizes accrued payouts from blacklisted holders.
     * @dev Transfers each request's usdatOwed to the specified address, burning the
     * token only if fully filled — an open remainder keeps accruing fills and stays
     * seizable. Only callable by addresses with the ENFORCER_ROLE.
     * @param tokenIds Array of token IDs to seize.
     * @param to The address to transfer the USDat to.
     */
    function seizeBlacklistedFunds(uint256[] calldata tokenIds, address to) external;
}
