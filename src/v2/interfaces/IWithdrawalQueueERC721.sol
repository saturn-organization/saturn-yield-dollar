// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IWithdrawalQueueERC721
 * @author Saturn
 * @notice Interface for the WithdrawalQueueERC721 contract.
 * @dev A UUPS upgradeable NFT-based withdrawal queue where each withdrawal request
 * is represented as an ERC721 token. Users request redemptions from StakedUSDat,
 * their shares are escrowed, and they receive an NFT representing their claim.
 * Processors then sell STRC off-chain, and users can claim their USDat once processed.
 */
interface IWithdrawalQueueERC721 {
    // ============ Enums ============

    /**
     * @notice The lifecycle status of a withdrawal request.
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
     * @param shares The number of sUSDat shares escrowed.
     * @param usdatOwed The amount of USDat owed after processing.
     * @param timestamp The timestamp when the request was created.
     * @param minUsdatReceived The minimum USDat the user will accept (slippage protection).
     * @param status The current status of the request.
     */
    struct Request {
        uint256 shares;
        uint256 usdatOwed;
        uint256 timestamp;
        uint256 minUsdatReceived;
        RequestStatus status;
    }

    // ============ Errors ============

    /**
     * @dev Thrown when a zero amount is provided where a non-zero value is required.
     */
    error ZeroAmount();

    /**
     * @dev Thrown when attempting to process a request that has already been processed.
     */
    error AlreadyProcessed();

    /**
     * @dev Thrown when the caller is not allowed to perform the operation.
     */
    error OperationNotAllowed();

    /**
     * @dev Thrown when the caller is not the owner of the token.
     */
    error NotOwner();

    /**
     * @dev Thrown when an operation requires a blacklisted address but the address is not blacklisted.
     */
    error NotBlacklisted();

    /**
     * @dev Thrown when attempting to claim a request that hasn't been processed yet.
     */
    error RequestNotProcessed();

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
     * @dev Emitted when a user claims their USDat.
     * @param tokenId The NFT token ID that was claimed.
     * @param user The user who claimed.
     * @param usdatAmount The amount of USDat claimed.
     */
    event Claimed(uint256 indexed tokenId, address indexed user, uint256 usdatAmount);

    /**
     * @dev Emitted when processed funds are seized from a blacklisted user.
     * @param tokenId The NFT token ID of the seized request.
     * @param user The blacklisted user whose funds were seized.
     * @param usdatAmount The amount of USDat seized.
     * @param to The address that received the seized funds.
     */
    event FundsSeized(uint256 indexed tokenId, address indexed user, uint256 usdatAmount, address indexed to);

    /**
     * @dev Emitted when a pending request is seized from a blacklisted user.
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
     * @param minUsdatReceived The minimum amount of USDat the user will accept.
     * @return tokenId The NFT token ID (same as request ID).
     */
    function addRequest(address user, uint256 shares, uint256 minUsdatReceived) external returns (uint256 tokenId);

    // ============ Claiming Functions ============

    /**
     * @notice Claims a specific withdrawal request by token ID.
     * @dev Burns the NFT and transfers USDat to the caller.
     * @param tokenId The NFT token ID to claim.
     * @return amount The amount of USDat claimed.
     */
    function claim(uint256 tokenId) external returns (uint256 amount);

    // ============ Compliance Functions ============

    /**
     * @notice Seizes pending requests from blacklisted holders.
     * @dev Transfers NFTs from blacklisted users to the specified address.
     * Only works for Requested and InProgress status.
     * Only callable by addresses with the ENFORCER_ROLE.
     * @param tokenIds Array of token IDs to seize.
     * @param to The address to transfer the NFTs to.
     */
    function seizeRequests(uint256[] calldata tokenIds, address to) external;

    /**
     * @notice Seizes processed requests from blacklisted holders.
     * @dev Burns NFTs and transfers USDat to the specified address.
     * Only works for Processed status.
     * Only callable by addresses with the ENFORCER_ROLE.
     * @param tokenIds Array of token IDs to seize.
     * @param to The address to transfer the USDat to.
     */
    function seizeBlacklistedFunds(uint256[] calldata tokenIds, address to) external;
}
