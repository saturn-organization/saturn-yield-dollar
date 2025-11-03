// SPDX-License-Identifier: MIT
// Compatible with OpenZeppelin Contracts ^5.4.0
pragma solidity ^0.8.27;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title tSTRC
/// @notice The tSTRC token is used to track the amount of STRC that is held in the off chain entity.
/// This token is minted and directly transferred to sUSDat during the mint process. The mint
/// process starts with the user calling deposit on the sUSDat contract. At the same time the
/// sUSDat entity purchases STRC from the market, tSTRC is deposited into the sUSDat contract.

contract tokenizedSTRC is ERC20, ERC20Burnable, ReentrancyGuard, AccessControl, ERC20Permit {
    using SafeERC20 for IERC20;

    /// @notice The minter role is available to the sUSDat contract to mint tSTRC tokens.
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

    constructor(address defaultAdmin, address minter) ERC20("tokenizedSTRC", "tSTRC") ERC20Permit("tokenizedSTRC") {
        _grantRole(DEFAULT_ADMIN_ROLE, defaultAdmin);
        _grantRole(MINTER_ROLE, minter);
    }

    function mint(address to, uint256 amount) public onlyRole(MINTER_ROLE) {
        _mint(to, amount);
    }

    function rescueTokens(address token, uint256 amount, address to)
        external
        nonReentrant
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        IERC20(token).safeTransfer(to, amount);
    }
}
