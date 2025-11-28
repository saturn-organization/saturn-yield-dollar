// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {sUSDatSilo} from "./sUSDatSilo.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {tokenizedSTRC} from "./tokenizedSTRC.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

/**
 * @title StakedUSDat
 */
contract StakedUSDat is
    AccessControl,
    ReentrancyGuard,
    ERC20Permit,
    ERC4626,
    Pausable
{
    using SafeERC20 for IERC20;

    error InvalidZeroAddress();
    error CannotBlacklistAdmin();
    error InvalidAmount();
    error OperationNotAllowed();
    error InvalidCooldown();
    error ExcessiveWithdrawAmount();
    error ExcessiveRedeemAmount();
    error NotEnoughAssetsInSilo();
    error AlreadyBlacklisted();
    error InvalidToken();
    error NotBlacklisted();

    event Blacklisted(address target);
    event UnBlacklisted(address target);
    event Converted(uint256 usdatAmount, uint256 strcAmount);
    event CooldownDurationUpdated(uint24 previousDuration, uint24 newDuration);
    event RewardsReceived(uint256 amount);
    event LockedAmountRedistributed(address from, address to, uint256 amount);

    bytes32 public constant REWARDER_ROLE = keccak256("REWARDER_ROLE");
    bytes32 private constant BLACKLIST_MANAGER_ROLE =
        keccak256("BLACKLIST_MANAGER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    tokenizedSTRC private immutable TSTRC;
    sUSDatSilo private immutable SILO;

    uint24 private immutable MAX_COOLDOWN_DURATION;
    uint24 private cooldownDuration;
    mapping(address => bool) private _blacklisted;

    modifier notZero(uint256 amount) {
        _notZero(amount);
        _;
    }

    function _notZero(uint256 amount) internal pure {
        if (amount == 0) revert InvalidAmount();
    }

    modifier ensureCooldownOff() {
        _ensureCooldownOff();
        _;
    }

    function _ensureCooldownOff() internal view {
        if (cooldownDuration != 0) revert OperationNotAllowed();
    }

    /// @notice ensure cooldownDuration is gt 0
    modifier ensureCooldownOn() {
        _ensureCooldownOn();
        _;
    }

    function _ensureCooldownOn() internal view {
        if (cooldownDuration == 0) revert OperationNotAllowed();
    }

    /// @param usdat USDat contract address
    /// @param tstrc tokenizedSTRC contract address
    /// @param silo sUSDatSilo contract address
    /// @param defaultAdmin The default admin of the contract
    /// @param rewarder The address of the rewarder
    constructor(
        address defaultAdmin,
        address rewarder,
        IERC20 usdat,
        tokenizedSTRC tstrc,
        sUSDatSilo silo
    ) ERC20("Staked USDat", "sUSDat") ERC4626(usdat) ERC20Permit("sUSDat") {
        if (
            defaultAdmin == address(0) ||
            address(usdat) == address(0) ||
            rewarder == address(0) ||
            address(tstrc) == address(0) ||
            address(silo) == address(0)
        ) {
            revert InvalidZeroAddress();
        }
        _grantRole(DEFAULT_ADMIN_ROLE, defaultAdmin);
        _grantRole(REWARDER_ROLE, rewarder);
        _grantRole(PAUSER_ROLE, defaultAdmin);
        _grantRole(BLACKLIST_MANAGER_ROLE, defaultAdmin);
        TSTRC = tokenizedSTRC(tstrc);
        SILO = sUSDatSilo(silo);
    }

    /**
     * @notice Allows the owner (DEFAULT_ADMIN_ROLE) and blacklist managers to blacklist addresses.
     * @param target The address to blacklist.
     */
    function addToBlacklist(
        address target
    ) external onlyRole(BLACKLIST_MANAGER_ROLE) {
        if (hasRole(DEFAULT_ADMIN_ROLE, target)) revert CannotBlacklistAdmin();

        if (_blacklisted[target]) revert AlreadyBlacklisted();
        _blacklisted[target] = true;
        emit Blacklisted(target);
    }

    /**
     * @notice Allows the owner (DEFAULT_ADMIN_ROLE) and blacklist managers to un-blacklist addresses.
     * @param target The address to un-blacklist.
     */
    function removeFromBlacklist(
        address target
    ) external onlyRole(BLACKLIST_MANAGER_ROLE) {
        if (!_blacklisted[target]) revert NotBlacklisted();
        _blacklisted[target] = false;
        emit UnBlacklisted(target);
    }

    function _requireNotBlacklisted(address account) internal view {
        require(!_blacklisted[account], "USDat: recipient blacklisted");
    }

    function transfer(
        address to,
        uint256 amount
    ) public override(ERC20, IERC20) returns (bool) {
        _requireNotBlacklisted(to);
        return super.transfer(to, amount);
    }

    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) public override(ERC20, IERC20) returns (bool) {
        _requireNotBlacklisted(to);
        return super.transferFrom(from, to, amount);
    }

    function redistributeLockedAmount(
        address from,
        address to
    ) external nonReentrant onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_blacklisted[from] && !_blacklisted[to]) {
            uint256 amountToDistribute = balanceOf(from);
            _burn(from, amountToDistribute);
            if (to != address(0)) {
                _mint(to, amountToDistribute);
            }
            emit LockedAmountRedistributed(from, to, amountToDistribute);
        } else {
            revert OperationNotAllowed();
        }
    }

    /// @notice ASSUMPTION: asset is USDat and is always 1 dollar backed by treasuries.
    /// @notice new ERC4626 takes into account the donation attack using an offest on shares.
    function totalAssets() public view override returns (uint256) {
        return IERC20(asset()).balanceOf(address(this)) + _strcTotalAssets();
    }

    /// @dev Calculates the total value of STRC holdings in USD terms (18 decimals)
    function _strcTotalAssets() internal view returns (uint256) {
        (uint256 strcPrice, uint8 priceDecimals) = TSTRC.getPrice();
        uint256 strcBalance = TSTRC.balanceOf(address(this));

        // Convert to 18 decimal format: balance * price / 10^priceDecimals
        return
            Math.mulDiv(
                strcBalance,
                strcPrice,
                10 ** priceDecimals,
                Math.Rounding.Floor
            );
    }

    function decimals() public pure override(ERC4626, ERC20) returns (uint8) {
        return 18;
    }

    function rescueTokens(
        address token,
        uint256 amount,
        address to
    ) external nonReentrant onlyRole(DEFAULT_ADMIN_ROLE) {
        if (token != address(TSTRC) && token != address(asset()))
            revert InvalidToken();

        IERC20(token).safeTransfer(to, amount);
    }

    function transferInRewards(
        uint256 amount
    ) external nonReentrant onlyRole(REWARDER_ROLE) notZero(amount) {
        TSTRC.mint(address(this), amount);

        emit RewardsReceived(amount);
    }

    /**
     * @notice Called by the admin when the entity purchases STRC from the market and sells the Tbills backing USDat.
     * @param usdatAmount amount of USDat to convert
     * @param strcAmount amount of STRC to mint
     */
    function convert(
        uint256 usdatAmount,
        uint256 strcAmount
    ) external onlyRole(REWARDER_ROLE) {
        require(
            IERC20(asset()).balanceOf(address(this)) >= usdatAmount,
            "Not enough USD"
        );

        ERC20Burnable(asset()).burn(usdatAmount);

        TSTRC.mint(address(this), strcAmount);

        emit Converted(usdatAmount, strcAmount);
    }

    /**
     * @dev Deposit/mint common workflow.
     * @param caller sender of assets
     * @param receiver where to send shares
     * @param assets assets to deposit
     * @param shares shares to mint
     */
    function _deposit(
        address caller,
        address receiver,
        uint256 assets,
        uint256 shares
    )
        internal
        override
        whenNotPaused
        nonReentrant
        notZero(assets)
        notZero(shares)
    {
        if (_blacklisted[caller] || _blacklisted[receiver]) {
            revert OperationNotAllowed();
        }
        super._deposit(caller, receiver, assets, shares);
    }

    function withdraw(
        uint256 assets,
        address receiver,
        address _owner
    )
        public
        virtual
        override
        whenNotPaused
        ensureCooldownOff
        returns (uint256)
    {
        return super.withdraw(assets, receiver, _owner);
    }

    /**
     * @dev See {IERC4626-redeem}.
     */
    function redeem(
        uint256 shares,
        address receiver,
        address _owner
    )
        public
        virtual
        override
        whenNotPaused
        ensureCooldownOff
        returns (uint256)
    {
        return super.redeem(shares, receiver, _owner);
    }

    function cooldownAssets(
        uint256 assets
    ) external whenNotPaused ensureCooldownOn returns (uint256 shares) {
        if (assets > maxWithdraw(msg.sender)) revert ExcessiveWithdrawAmount();

        shares = previewWithdraw(assets);

        _withdraw(msg.sender, address(SILO), msg.sender, assets, shares);
    }

    function cooldownShares(
        uint256 shares
    ) external whenNotPaused ensureCooldownOn returns (uint256 assets) {
        if (shares > maxRedeem(msg.sender)) revert ExcessiveRedeemAmount();

        assets = previewRedeem(shares);

        _withdraw(msg.sender, address(SILO), msg.sender, assets, shares);
    }

    /**
     * @dev Withdraw/redeem common workflow.
     * @param caller tx sender
     * @param receiver where to send assets
     * @param owner where to burn shares from
     * @param assets asset amount to transfer out
     * @param shares shares to burn
     */

    // Calculate the amount of STRC that the user is owed in USD then send the STRC to a contact
    // convert that amount to USDat over 7 days. When the user calls unstake, it sends the USDat to the user
    // and the STRC in the silo contract gets burned.

    // Division is not great on chain need to figure out a soltuion here.
    // pricePerShare = totalAssets() / totalSupply()
    // assets = shares * pricePerShare -- Amount the user owns in USD
    // assets / strcPrice = amount of STRC

    // Risks: division and oricle pricing!!!
    function _withdraw(
        address caller,
        address receiver,
        address owner,
        uint256 assets,
        uint256 shares
    )
        internal
        override
        whenNotPaused
        nonReentrant
        notZero(assets)
        notZero(shares)
    {
        if (
            _blacklisted[caller] ||
            _blacklisted[receiver] ||
            _blacklisted[owner]
        ) {
            revert OperationNotAllowed();
        }

        // Get the current STRC price from the oracle
        (uint256 strcPrice, uint8 priceDecimals) = TSTRC.getPrice();

        // Always assume the user is withdrawing STRC not USDat
        // Calculate: assets (18 decimals) * 10^priceDecimals / price = STRC amount (18 decimals)
        uint256 strcAmount = Math.mulDiv(
            assets,
            10 ** priceDecimals,
            strcPrice,
            Math.Rounding.Floor
        );

        // Not enough STRC in the contract to cover please wait.
        if (strcAmount >= TSTRC.balanceOf(address(this))) {
            revert InvalidAmount();
        }

        if (caller != owner) {
            _spendAllowance(owner, caller, shares);
        }

        _burn(owner, shares);

        if (receiver == address(SILO)) {
            uint256 cooldownEnd = block.timestamp + cooldownDuration;
            SILO.recordWithdrawalRequest(msg.sender, strcAmount, cooldownEnd);
        }

        SafeERC20.safeTransfer(IERC20(TSTRC), receiver, strcAmount);
    }

    function setCooldownDuration(
        uint24 duration
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (duration > MAX_COOLDOWN_DURATION) {
            revert InvalidCooldown();
        }

        uint24 previousDuration = cooldownDuration;
        cooldownDuration = duration;
        emit CooldownDurationUpdated(previousDuration, cooldownDuration);
    }

    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }
}
