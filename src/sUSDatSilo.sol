// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.0;

/* solhint-disable var-name-mixedcase  */

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IUSDat} from "./IUSDat.sol";
import {tokenizedSTRC} from "./tokenizedSTRC.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract sUSDatSilo is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    error InvalidWithdrawalRequest();

    bytes32 public constant STAKED_USDAT_ROLE = keccak256("STAKED_USDAT_ROLE");

    address immutable SUSDAT;
    IUSDat immutable USDAT;
    tokenizedSTRC immutable TSTRC;

    error OnlyStakingVault();

    struct UserWithdrawalRequest {
        uint256 cooldownEnd;
        uint256 strcAmount;
        uint256 usdatAmount;
    }

    mapping(address => UserWithdrawalRequest) public withdrawalRequests;

    constructor(address defaultAdmin, address susdat, address usdat, address tstrc) {
        SUSDAT = susdat;
        USDAT = IUSDat(usdat);
        TSTRC = tokenizedSTRC(tstrc);
        _grantRole(DEFAULT_ADMIN_ROLE, defaultAdmin);
        _grantRole(STAKED_USDAT_ROLE, susdat);
    }

    function recordWithdrawalRequest(address user, uint256 strcAmount, uint256 cooldownEnd)
        external
        onlyRole(STAKED_USDAT_ROLE)
    {
        withdrawalRequests[user].cooldownEnd = cooldownEnd;
        withdrawalRequests[user].strcAmount += strcAmount;
    }

    function updateProceeds(address user, uint256 usdatAmount, uint256 strcAmount)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        withdrawalRequests[user].usdatAmount += usdatAmount;
        withdrawalRequests[user].strcAmount -= strcAmount;

        USDAT.mint(address(this), usdatAmount);
        tokenizedSTRC(TSTRC).burn(strcAmount);
    }

    function claim() external nonReentrant {
        uint256 usdatAmount = withdrawalRequests[msg.sender].usdatAmount;
        if (usdatAmount == 0  || withdrawalRequests[msg.sender].cooldownEnd > block.timestamp) revert InvalidWithdrawalRequest();

        withdrawalRequests[msg.sender].usdatAmount = 0;

        if (withdrawalRequests[msg.sender].strcAmount == 0) {
            delete withdrawalRequests[msg.sender];
        }

        SafeERC20.safeTransfer(USDAT, msg.sender, usdatAmount);
    }
}
