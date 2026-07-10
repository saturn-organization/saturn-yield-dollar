// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IGMTokenManager
 * @dev Minimal interface for Ondo Global Markets' GMTokenManager
 * (Ethereum: 0x2c158BC456e027b2AfFCCadF1BDBD9f5fC4c5C8c). Mints and redemptions
 * execute against an RFQ quote signed by Ondo's attestation signer, fetched
 * off-chain from Ondo's API; the caller must be registered in Ondo's ID registry
 * and the quote's userId must match the caller's registration.
 */
interface IGMTokenManager {
    /**
     * @dev Ondo-signed RFQ quote. `side` is Ondo's QuoteSide enum (encoded uint8).
     */
    struct Quote {
        uint256 chainId;
        uint256 attestationId;
        bytes32 userId;
        address asset;
        uint256 price;
        uint256 quantity;
        uint256 expiration;
        uint8 side;
        bytes32 additionalData;
    }

    /**
     * @dev Mints `quote.quantity` of `quote.asset` against `depositTokenAmount` of
     * `depositToken`.
     * @return The amount of the GM token minted.
     */
    function mintWithAttestation(
        Quote calldata quote,
        bytes calldata signature,
        address depositToken,
        uint256 depositTokenAmount
    ) external returns (uint256);

    /**
     * @dev Redeems `quote.quantity` of `quote.asset` (pulled from the caller) for
     * `receiveToken`.
     * @return The amount of `receiveToken` received.
     */
    function redeemWithAttestation(
        Quote calldata quote,
        bytes calldata signature,
        address receiveToken,
        uint256 minimumReceiveAmount
    ) external returns (uint256);
}
