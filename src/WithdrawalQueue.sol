// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IUSDat} from "./interfaces/IUSDat.sol";
import {IERC20Burnable} from "./interfaces/IERC20Burnable.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

/// @title WithdrawalQueue
/// @notice FIFO withdrawal queue tracking tSTRC amounts with user-initiated claims
contract WithdrawalQueue is AccessControl, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

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

    mapping(address => uint256[]) private userRequestIds;

    error InvalidAmount();
    error NoRequestsToProcess();
    error AlreadyProcessed();
    error NothingToClaim();
    error NotYourRequest();

    event WithdrawalRequested(uint256 indexed requestId, address indexed user, uint256 strcAmount, uint256 timestamp);
    event WithdrawalProcessed(uint256 indexed requestId, uint256 strcAmount, uint256 usdatAmount);
    event Claimed(uint256 indexed requestId, address indexed user, uint256 usdatAmount);

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
        if (strcAmount == 0) revert InvalidAmount();

        requestId = queue.length;
        queue.push(
            Request({user: user, strcAmount: strcAmount, usdatOwed: 0, claimed: false, timestamp: block.timestamp})
        );

        userRequestIds[user].push(requestId);

        emit WithdrawalRequested(requestId, user, strcAmount, block.timestamp);
    }

    /// @notice Process the next batch of withdrawal requests
    /// @param usdatAmounts Array of USDat amounts corresponding to each request
    function processNext(uint256[] calldata usdatAmounts) external nonReentrant onlyRole(PROCESSOR_ROLE) {
        uint256 count = usdatAmounts.length;
        if (count == 0) revert InvalidAmount();
        if (nextToProcess + count > queue.length) revert NoRequestsToProcess();

        uint256 totalUsdat = 0;
        uint256 totalStrc = 0;

        for (uint256 i = 0; i < count; i++) {
            totalUsdat += usdatAmounts[i];
            totalStrc += queue[nextToProcess + i].strcAmount;
        }

        USDAT.mint(address(this), totalUsdat);

        IERC20Burnable(address(TSTRC)).burn(totalStrc);

        for (uint256 i = 0; i < count; i++) {
            uint256 requestId = nextToProcess + i;
            Request storage req = queue[requestId];

            if (req.usdatOwed != 0) revert AlreadyProcessed();

            req.usdatOwed = usdatAmounts[i];

            emit WithdrawalProcessed(requestId, req.strcAmount, usdatAmounts[i]);
        }

        nextToProcess += count;
    }

    /// @notice Claim a specific withdrawal request
    /// @param requestId The ID of the request to claim
    /// @return amount The amount of USDat claimed
    function claim(uint256 requestId) external nonReentrant whenNotPaused returns (uint256 amount) {
        Request storage req = queue[requestId];

        if (req.user != msg.sender) revert NotYourRequest();
        if (req.usdatOwed == 0 || req.claimed) revert NothingToClaim();

        req.claimed = true;
        amount = req.usdatOwed;

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
        uint256[] storage ids = userRequestIds[user];
        uint256 len = ids.length;

        for (uint256 i = 0; i < len; i++) {
            Request storage req = queue[ids[i]];

            if (req.usdatOwed > 0 && !req.claimed) {
                req.claimed = true;
                totalAmount += req.usdatOwed;

                emit Claimed(ids[i], user, req.usdatOwed);
            }
        }

        if (totalAmount == 0) revert NothingToClaim();

        IERC20(address(USDAT)).safeTransfer(user, totalAmount);
    }

    // ============ View Functions ============

    /// @notice Get all request IDs for the caller
    function getMyRequests() external view returns (uint256[] memory) {
        return userRequestIds[msg.sender];
    }

    /// @notice Get all request IDs for any user
    function getUserRequests(address user) external view returns (uint256[] memory) {
        return userRequestIds[user];
    }

    /// @notice Get claimable amount and request IDs for a user
    function getClaimable(address user) external view returns (uint256 total, uint256[] memory claimableIds) {
        uint256[] storage ids = userRequestIds[user];
        uint256 len = ids.length;

        uint256 count = 0;
        for (uint256 i = 0; i < len; i++) {
            Request storage req = queue[ids[i]];
            if (req.usdatOwed > 0 && !req.claimed) {
                count++;
            }
        }

        claimableIds = new uint256[](count);
        uint256 idx = 0;

        for (uint256 i = 0; i < len; i++) {
            Request storage req = queue[ids[i]];
            if (req.usdatOwed > 0 && !req.claimed) {
                claimableIds[idx] = ids[i];
                total += req.usdatOwed;
                idx++;
            }
        }
    }

    /// @notice Get pending (unprocessed) requests for a user
    function getPending(address user) external view returns (uint256 totalStrcAmount, uint256[] memory pendingIds) {
        uint256[] storage ids = userRequestIds[user];
        uint256 len = ids.length;

        uint256 count = 0;
        for (uint256 i = 0; i < len; i++) {
            Request storage req = queue[ids[i]];
            if (req.usdatOwed == 0 && !req.claimed) {
                count++;
            }
        }

        pendingIds = new uint256[](count);
        uint256 idx = 0;

        for (uint256 i = 0; i < len; i++) {
            Request storage req = queue[ids[i]];
            if (req.usdatOwed == 0 && !req.claimed) {
                pendingIds[idx] = ids[i];
                totalStrcAmount += req.strcAmount;
                idx++;
            }
        }
    }

    /// @notice Get a specific request's details
    function getRequest(uint256 requestId)
        external
        view
        returns (address user, uint256 strcAmount, uint256 usdatOwed, bool claimed, uint256 timestamp)
    {
        Request storage req = queue[requestId];
        return (req.user, req.strcAmount, req.usdatOwed, req.claimed, req.timestamp);
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

    function pause() external onlyRole(COMPLIANCE_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }
}
