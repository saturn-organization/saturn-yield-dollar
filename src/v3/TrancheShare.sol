// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

interface ITrancheTransferPolicy {
    function hardPaused() external view returns (bool);
    function isRestricted(address account) external view returns (bool);
}

/// @notice Minimal non-upgradeable share class controlled by one V3 accountant.
contract TrancheShare is ERC20, ERC20Permit {
    error OnlyAccountant();
    error TransfersPaused();
    error RestrictedAccount(address account);

    address public immutable ACCOUNTANT;
    ITrancheTransferPolicy public immutable TRANSFER_POLICY;

    constructor(string memory name_, string memory symbol_, address accountant_)
        ERC20(name_, symbol_)
        ERC20Permit(name_)
    {
        require(accountant_ != address(0));
        ACCOUNTANT = accountant_;
        TRANSFER_POLICY = ITrancheTransferPolicy(accountant_);
    }

    function mint(address receiver, uint256 shares) external {
        if (msg.sender != ACCOUNTANT) revert OnlyAccountant();
        _mint(receiver, shares);
    }

    function burn(address owner, uint256 shares) external {
        if (msg.sender != ACCOUNTANT) revert OnlyAccountant();
        _burn(owner, shares);
    }

    function transfer(address to, uint256 value) public override returns (bool) {
        _requireAllowed(msg.sender);
        return super.transfer(to, value);
    }

    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        _requireAllowed(msg.sender);
        return super.transferFrom(from, to, value);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (TRANSFER_POLICY.hardPaused()) revert TransfersPaused();
        if (from != address(0)) _requireAllowed(from);
        if (to != address(0)) _requireAllowed(to);
        super._update(from, to, value);
    }

    function _requireAllowed(address account) private view {
        if (TRANSFER_POLICY.isRestricted(account)) revert RestrictedAccount(account);
    }
}
