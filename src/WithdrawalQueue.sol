// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {IUSDat} from "./interfaces/IUSDat.sol";
import {IERC20Burnable} from "./interfaces/IERC20Burnable.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

/// @title WithdrawalQueue
/// @notice FIFO withdrawal queue tracking tSTRC amounts with user-initiated claims
contract WithdrawalQueue is AccessControl, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.UintSet;

    struct Request {
        address user;
        uint256 strcAmount;
        uint256 usdatOwed;
        bool claimed;
        uint256 timestamp;
    }

    // Set all roles after deployment of the contract
    // Same PROCESSOR_ROLE in sUSDat contract
    bytes32 public constant PROCESSOR_ROLE = keccak256("PROCESSOR_ROLE");
    // Same compliance address of other contracts
    bytes32 public constant COMPLIANCE_ROLE = keccak256("COMPLIANCE_ROLE");
    //sUSDat Contract
    bytes32 public constant STAKED_USDAT_ROLE = keccak256("STAKED_USDAT_ROLE");

    IERC20 public immutable TSTRC;
    IUSDat public immutable USDAT;

    Request[] public queue;
    uint256 public nextToProcess;

    mapping(address user => EnumerableSet.UintSet requestIds) private userRequestIds;

    error ZeroAmount();
    error NoRequestsToProcess();
    error AlreadyProcessed();
    error NothingToClaim();
    error NotYourRequest();
    error NotBlacklisted();
    error InvalidRequestOrder();
    error LengthMismatch();
    error ToleranceExceeded();
    error InvalidTolerance();

    /// @notice Maximum allowed tolerance (50% = 5000 basis points)
    uint256 public constant MAX_TOLERANCE = 5000;

    event WithdrawalRequested(uint256 indexed requestId, address indexed user, uint256 strcAmount, uint256 timestamp);
    event WithdrawalProcessed(uint256 indexed requestId, uint256 strcAmount, uint256 usdatAmount);
    event Claimed(uint256 indexed requestId, address indexed user, uint256 usdatAmount);
    event FundsSeized(uint256 indexed requestId, address indexed user, uint256 usdatAmount, address indexed to);

    constructor(address tstrc, address usdat, address admin) {
        TSTRC = IERC20(tstrc);
        USDAT = IUSDat(usdat);

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    /// @notice Called by StakedUSDat to add a withdrawal request
    /// @dev tSTRC must be transferred to this contract before calling
    /// @param user The user requesting withdrawal
    /// @param strcAmount The amount of tSTRC owed to the user
    /// @return requestId The ID of the withdrawal request
    function addRequest(address user, uint256 strcAmount)
        external
        nonReentrant
        whenNotPaused
        onlyRole(STAKED_USDAT_ROLE)
        returns (uint256 requestId)
    {
        require(strcAmount != 0, ZeroAmount());

        requestId = queue.length;
        queue.push(
            Request({user: user, strcAmount: strcAmount, usdatOwed: 0, claimed: false, timestamp: block.timestamp})
        );

        userRequestIds[user].add(requestId);

        emit WithdrawalRequested(requestId, user, strcAmount, block.timestamp);
    }

    /// @notice Process the next batch of withdrawal requests
    /// @param requestIds Array of request IDs to process (must match expected order)
    /// @param usdatAmounts Array of USDat amounts corresponding to each request
    /// @param vwapExecutionPrice Current STRC price (8 decimals)
    /// @param toleranceBps Tolerance in basis points (e.g., 1000 = 10%)
    function processNext(
        uint256[] calldata requestIds,
        uint256[] calldata usdatAmounts,
        uint256 vwapExecutionPrice,
        uint256 toleranceBps
    ) external nonReentrant onlyRole(PROCESSOR_ROLE) {
        uint256 count = usdatAmounts.length;
        require(count > 0 && count == requestIds.length, ZeroAmount());
        require(nextToProcess + count <= queue.length, NoRequestsToProcess());
        require(toleranceBps <= MAX_TOLERANCE, InvalidTolerance());

        uint256 totalUsdat = 0;
        uint256 totalStrc = 0;

        for (uint256 i = 0; i < count; i++) {
            require(requestIds[i] == nextToProcess + i, InvalidRequestOrder());

            Request storage req = queue[requestIds[i]];

            require(req.usdatOwed == 0, AlreadyProcessed());

            // Calculate expected USDat amount: strcAmount * strcPrice / 1e8
            uint256 expectedUsdat = (req.strcAmount * vwapExecutionPrice) / 1e8;
            uint256 tolerance = (expectedUsdat * toleranceBps) / 10000;

            // Validate amount is within tolerance (avoid underflow)
            uint256 diff =
                usdatAmounts[i] > expectedUsdat ? usdatAmounts[i] - expectedUsdat : expectedUsdat - usdatAmounts[i];
            require(diff <= tolerance, ToleranceExceeded());

            // Update state
            req.usdatOwed = usdatAmounts[i];
            totalUsdat += usdatAmounts[i];
            totalStrc += req.strcAmount;

            emit WithdrawalProcessed(requestIds[i], req.strcAmount, usdatAmounts[i]);
        }

        nextToProcess += count;

        // External calls last
        USDAT.mint(address(this), totalUsdat);
        IERC20Burnable(address(TSTRC)).burn(totalStrc);
    }

    /// @notice Claim a specific withdrawal request
    /// @param requestId The ID of the request to claim
    /// @return amount The amount of USDat claimed
    function claim(uint256 requestId) external nonReentrant whenNotPaused returns (uint256 amount) {
        Request storage req = queue[requestId];

        require(req.user == msg.sender, NotYourRequest());
        require(req.usdatOwed != 0 && !req.claimed, NothingToClaim());

        req.claimed = true;
        amount = req.usdatOwed;

        userRequestIds[msg.sender].remove(requestId);

        IERC20(address(USDAT)).safeTransfer(msg.sender, amount);

        emit Claimed(requestId, msg.sender, amount);
    }

    /// @notice Claim all processed withdrawals for the caller
    /// @return totalAmount The total amount of USDat claimed
    function claimAll() external nonReentrant whenNotPaused returns (uint256 totalAmount) {
        totalAmount = _claimAll(msg.sender);
    }

    /// @notice Claim all processed withdrawals for a user (called by StakedUSDat)
    /// @param user The user to claim for
    /// @return totalAmount The total amount of USDat claimed
    function claimFor(address user)
        external
        nonReentrant
        whenNotPaused
        onlyRole(STAKED_USDAT_ROLE)
        returns (uint256 totalAmount)
    {
        totalAmount = _claimAll(user);
    }

    /// @dev Internal function to claim all processed withdrawals for a user
    /// @param user The user to claim for
    /// @return totalAmount The total amount of USDat claimed
    function _claimAll(address user) internal returns (uint256 totalAmount) {
        EnumerableSet.UintSet storage ids = userRequestIds[user];
        uint256 len = ids.length();

        // Collect IDs to remove (can't modify set while iterating)
        uint256[] memory toRemove = new uint256[](len);
        uint256 removeCount = 0;

        for (uint256 i = 0; i < len; i++) {
            uint256 requestId = ids.at(i);
            Request storage req = queue[requestId];

            if (req.usdatOwed > 0 && !req.claimed) {
                req.claimed = true;
                totalAmount += req.usdatOwed;
                toRemove[removeCount++] = requestId;

                emit Claimed(requestId, user, req.usdatOwed);
            }
        }

        // Remove claimed entries
        for (uint256 i = 0; i < removeCount; i++) {
            ids.remove(toRemove[i]);
        }

        require(totalAmount != 0, NothingToClaim());

        IERC20(address(USDAT)).safeTransfer(user, totalAmount);
    }

    // ============ View Functions ============

    /// @notice Get all request IDs for the caller
    function getMyRequests() external view returns (uint256[] memory) {
        return userRequestIds[msg.sender].values();
    }

    /// @notice Get all request IDs for any user
    function getUserRequests(address user) external view returns (uint256[] memory) {
        return userRequestIds[user].values();
    }

    /// @notice Get claimable amount and request IDs for a user
    function getClaimable(address user) external view returns (uint256 total, uint256[] memory claimableIds) {
        uint256[] memory requestIds = userRequestIds[user].values();
        uint256 len = requestIds.length;

        uint256[] memory temp = new uint256[](len);
        uint256 count = 0;

        for (uint256 i = 0; i < len; i++) {
            Request storage req = queue[requestIds[i]];
            if (req.usdatOwed > 0) {
                temp[count++] = requestIds[i];
                total += req.usdatOwed;
            }
        }

        claimableIds = new uint256[](count);
        for (uint256 i = 0; i < count; i++) {
            claimableIds[i] = temp[i];
        }
    }

    /// @notice Get pending (unprocessed) requests for a user
    function getPending(address user) external view returns (uint256 totalStrcAmount, uint256[] memory pendingIds) {
        uint256[] memory requestIds = userRequestIds[user].values();
        uint256 len = requestIds.length;

        uint256[] memory temp = new uint256[](len);
        uint256 count = 0;

        for (uint256 i = 0; i < len; i++) {
            Request storage req = queue[requestIds[i]];
            if (req.usdatOwed == 0) {
                temp[count++] = requestIds[i];
                totalStrcAmount += req.strcAmount;
            }
        }

        pendingIds = new uint256[](count);
        for (uint256 i = 0; i < count; i++) {
            pendingIds[i] = temp[i];
        }
    }

    /// @notice Get a specific request's details
    function getRequest(uint256 requestId) external view returns (Request memory) {
        return queue[requestId];
    }

    /// @notice Check if a specific request is claimable
    function isClaimable(uint256 requestId) external view returns (bool) {
        Request storage req = queue[requestId];
        return req.usdatOwed > 0 && !req.claimed;
    }

    /// @notice Get the number of pending requests in the queue
    function getPendingCount() external view returns (uint256) {
        return queue.length - nextToProcess;
    }

    /// @notice Get total tSTRC waiting to be processed
    function getTotalPendingStrc() external view returns (uint256 total) {
        for (uint256 i = nextToProcess; i < queue.length; i++) {
            total += queue[i].strcAmount;
        }
    }

    /// @notice Get the total number of requests ever made
    function getTotalRequests() external view returns (uint256) {
        return queue.length;
    }

    // ============ Admin Functions ============

    /// @notice Seize a single request for a blacklisted user
    /// @param requestId The request ID to seize
    /// @param to The address to send the seized funds to
    function seizeRequest(uint256 requestId, address to) external onlyRole(COMPLIANCE_ROLE) {
        Request storage req = queue[requestId];
        require(USDAT.isBlacklisted(req.user), NotBlacklisted());
        require(req.usdatOwed > 0 && !req.claimed, NothingToClaim());

        req.claimed = true;
        userRequestIds[req.user].remove(requestId);

        emit FundsSeized(requestId, req.user, req.usdatOwed, to);

        IERC20(address(USDAT)).safeTransfer(to, req.usdatOwed);
    }

    /// @notice Seize all pending funds for a blacklisted user
    /// @param user The blacklisted user whose funds to seize
    /// @param to The address to send the seized funds to
    function seizeBlacklistedFunds(address user, address to) external onlyRole(COMPLIANCE_ROLE) {
        require(USDAT.isBlacklisted(user), NotBlacklisted());

        EnumerableSet.UintSet storage ids = userRequestIds[user];
        uint256 len = ids.length();
        uint256 totalSeized = 0;

        // Collect IDs to remove
        uint256[] memory toRemove = new uint256[](len);
        uint256 removeCount = 0;

        for (uint256 i = 0; i < len; i++) {
            uint256 requestId = ids.at(i);
            Request storage req = queue[requestId];
            if (req.usdatOwed > 0 && !req.claimed) {
                req.claimed = true;
                totalSeized += req.usdatOwed;
                toRemove[removeCount++] = requestId;
                emit FundsSeized(requestId, user, req.usdatOwed, to);
            }
        }

        // Remove seized entries
        for (uint256 i = 0; i < removeCount; i++) {
            ids.remove(toRemove[i]);
        }

        require(totalSeized > 0, NothingToClaim());
        IERC20(address(USDAT)).safeTransfer(to, totalSeized);
    }

    function pause() external onlyRole(COMPLIANCE_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }
}
