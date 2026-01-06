// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {
    ERC20PermitUpgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";

import {IWithdrawalQueueERC721} from "./interfaces/IWithdrawalQueueERC721.sol";
import {ITokenizedSTRC} from "./interfaces/ITokenizedSTRC.sol";
import {IERC20Burnable} from "./interfaces/IERC20Burnable.sol";

/**
 * @title StakedUSDat
 * @notice UUPS upgradeable ERC4626 vault for staking USDat
 */
contract StakedUSDat is
    Initializable,
    AccessControlUpgradeable,
    ReentrancyGuard,
    ERC20PermitUpgradeable,
    ERC4626Upgradeable,
    PausableUpgradeable,
    UUPSUpgradeable
{
    using SafeERC20 for IERC20;

    error InvalidZeroAddress();
    error ZeroAmount();
    error OperationNotAllowed();
    error ExcessiveRequestedAmount();
    error AddressNotBlacklisted();
    error AddressBlacklisted();
    error CannotBlacklistAdmin();
    error InsufficientBalance();
    error StillVesting();
    error InvalidVestingPeriod();
    error WithdrawalTooSmall();

    event Blacklisted(address target);
    event UnBlacklisted(address target);
    event Converted(uint256 usdatAmount, uint256 strcAmount);
    event RewardsReceived(uint256 amount, uint256 newVestingAmount);
    event LockedAmountRedistributed(address from, uint256 amount);
    event VestingPeriodUpdated(uint256 oldPeriod, uint256 newPeriod);

    bytes32 public constant PROCESSOR_ROLE = keccak256("PROCESSOR_ROLE");
    bytes32 private constant COMPLIANCE_ROLE = keccak256("COMPLIANCE_ROLE");

    /// @dev Immutables are stored in the implementation contract's bytecode, not proxy storage
    ITokenizedSTRC private immutable TSTRC;
    IWithdrawalQueueERC721 private immutable WITHDRAWAL_QUEUE;

    mapping(address account => bool isBlacklisted) private _blacklisted;

    /// @notice Amount of tSTRC currently vesting
    uint256 public vestingAmount;

    /// @notice Timestamp of last reward distribution
    uint256 public lastDistributionTimestamp;

    /// @notice Vesting period duration in seconds
    uint256 public vestingPeriod;

    /// @notice Maximum allowed vesting period (90 days)
    uint256 public constant MAX_VESTING_PERIOD = 90 days;

    /// @notice Minimum withdrawal amount (10 USDat)
    /// If a user has less than $10 they can swap on a DEX
    /// Or they can purchase more and swap out
    uint256 public constant MIN_WITHDRAWAL = 10e18;

    modifier notZero(uint256 amount) {
        _notZero(amount);
        _;
    }

    function _notZero(uint256 amount) internal pure {
        require(amount != 0, ZeroAmount());
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    /// @param tstrc TokenizedSTRC contract address
    /// @param withdrawalQueue WithdrawalQueue contract address
    constructor(ITokenizedSTRC tstrc, IWithdrawalQueueERC721 withdrawalQueue) {
        require(address(tstrc) != address(0) && address(withdrawalQueue) != address(0), InvalidZeroAddress());
        TSTRC = tstrc;
        WITHDRAWAL_QUEUE = withdrawalQueue;
        _disableInitializers();
    }

    /// @notice Initializes the contract (called once via proxy)
    /// @param defaultAdmin The default admin of the contract
    /// @param processor The address of the processor
    /// @param compliance The address of the compliance role
    /// @param usdat USDat contract address
    function initialize(address defaultAdmin, address processor, address compliance, IERC20 usdat)
        external
        initializer
    {
        require(
            defaultAdmin != address(0) && address(usdat) != address(0) && processor != address(0)
                && compliance != address(0),
            InvalidZeroAddress()
        );

        __AccessControl_init();
        __Pausable_init();
        __ERC20_init("Staked USDat", "sUSDat");
        __ERC20Permit_init("Staked USDat");
        __ERC4626_init(usdat);

        _grantRole(DEFAULT_ADMIN_ROLE, defaultAdmin);
        _grantRole(PROCESSOR_ROLE, processor);
        _grantRole(COMPLIANCE_ROLE, compliance);

        // Initialize vesting period to 30 days
        vestingPeriod = 30 days;
    }

    /// @notice Authorizes an upgrade to a new implementation
    /// @dev Only callable by DEFAULT_ADMIN_ROLE
    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    /**
     * @notice Allows the owner (COMPLIANCE_ROLE) and blacklist managers to blacklist addresses.
     * @param target The address to blacklist.
     */
    function addToBlacklist(address target) external onlyRole(COMPLIANCE_ROLE) {
        require(!hasRole(DEFAULT_ADMIN_ROLE, target), CannotBlacklistAdmin());
        require(!_blacklisted[target], AddressBlacklisted());
        _blacklisted[target] = true;
        emit Blacklisted(target);
    }

    /**
     * @notice Allows the owner (DEFAULT_ADMIN_ROLE) and blacklist managers to un-blacklist addresses.
     * @param target The address to un-blacklist.
     */
    function removeFromBlacklist(address target) external onlyRole(COMPLIANCE_ROLE) {
        require(_blacklisted[target], AddressNotBlacklisted());
        _blacklisted[target] = false;
        emit UnBlacklisted(target);
    }

    function _requireNotBlacklisted(address account) internal view {
        require(!_blacklisted[account], AddressBlacklisted());
    }

    /// @notice Check if an address is blacklisted
    /// @param account The address to check
    /// @return True if the address is blacklisted
    function isBlacklisted(address account) external view returns (bool) {
        return _blacklisted[account];
    }

    function transfer(address to, uint256 amount) public override(ERC20Upgradeable, IERC20) returns (bool) {
        _requireNotBlacklisted(msg.sender);
        _requireNotBlacklisted(to);

        return super.transfer(to, amount);
    }

    function transferFrom(address from, address to, uint256 amount)
        public
        override(ERC20Upgradeable, IERC20)
        returns (bool)
    {
        _requireNotBlacklisted(from);
        _requireNotBlacklisted(to);

        return super.transferFrom(from, to, amount);
    }

    function redistributeLockedAmount(address from) external nonReentrant onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_blacklisted[from], AddressNotBlacklisted());
        uint256 amountToDistribute = balanceOf(from);
        _burn(from, amountToDistribute);
        emit LockedAmountRedistributed(from, amountToDistribute);
    }

    /// @notice ASSUMPTION: asset is USDat and is always 1 dollar backed by treasuries.
    /// @notice new ERC4626 takes into account the donation attack using an offset on shares.
    /// @notice Excludes unvested rewards to prevent front-running attacks
    function totalAssets() public view override returns (uint256) {
        return IERC20(asset()).balanceOf(address(this)) + _strcTotalAssets();
    }

    /// @notice Returns the amount of tSTRC that is still vesting
    /// @dev Rounds up to be conservative (slightly favor protocol over users)
    /// @return The unvested tSTRC amount
    function getUnvestedAmount() public view returns (uint256) {
        uint256 timeSinceLastDistribution = block.timestamp - lastDistributionTimestamp;

        if (timeSinceLastDistribution >= vestingPeriod) {
            return 0;
        }

        return Math.mulDiv(vestingPeriod - timeSinceLastDistribution, vestingAmount, vestingPeriod, Math.Rounding.Ceil);
    }

    /// @dev Calculates the total value of VESTED STRC holdings in USD terms (18 decimals)
    function _strcTotalAssets() internal view returns (uint256) {
        (uint256 strcPrice, uint8 priceDecimals) = TSTRC.getPrice();
        uint256 strcBalance = TSTRC.balanceOf(address(this));

        // Subtract unvested amount - only count vested rewards
        uint256 vestedBalance = strcBalance - getUnvestedAmount();

        // Convert to 18 decimal format: balance * price / 10^priceDecimals
        return Math.mulDiv(vestedBalance, strcPrice, 10 ** priceDecimals, Math.Rounding.Floor);
    }

    function decimals() public pure override(ERC4626Upgradeable, ERC20Upgradeable) returns (uint8) {
        return 18;
    }

    function rescueTokens(address token, uint256 amount, address to)
        external
        nonReentrant
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        require(token == address(TSTRC) || token == address(asset()), OperationNotAllowed());

        IERC20(token).safeTransfer(to, amount);
    }

    /// @notice Transfer rewards into the contract with linear vesting
    /// @dev Rewards vest linearly over vestingPeriod to prevent front-running
    /// @param amount The amount of tSTRC to mint as rewards
    function transferInRewards(uint256 amount) external nonReentrant onlyRole(PROCESSOR_ROLE) notZero(amount) {
        // Check if previous rewards are still vesting
        if (getUnvestedAmount() > 0) revert StillVesting();

        // Mint tSTRC rewards to this contract
        TSTRC.mint(address(this), amount);

        // Set new vesting amount and reset timestamp
        vestingAmount = amount;
        lastDistributionTimestamp = block.timestamp;

        emit RewardsReceived(amount, amount);
    }

    /**
     * @notice Called by the admin when the entity purchases STRC from the market and sells the Tbills backing USDat.
     * @param usdatAmount amount of USDat to convert
     * @param strcAmount amount of STRC to mint
     */
    function convert(uint256 usdatAmount, uint256 strcAmount) external onlyRole(PROCESSOR_ROLE) {
        require(IERC20(asset()).balanceOf(address(this)) >= usdatAmount, InsufficientBalance());

        IERC20Burnable(asset()).burn(usdatAmount);

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
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares)
        internal
        override
        whenNotPaused
        nonReentrant
        notZero(assets)
        notZero(shares)
    {
        _requireNotBlacklisted(caller);
        _requireNotBlacklisted(receiver);

        super._deposit(caller, receiver, assets, shares);
    }

    /// @notice ERC4626 withdraw is disabled - use requestWithdraw instead
    function withdraw(uint256, address, address) public pure override returns (uint256) {
        revert OperationNotAllowed();
    }

    /// @notice ERC4626 redeem is disabled - use requestRedeem instead
    function redeem(uint256, address, address) public pure override returns (uint256) {
        revert OperationNotAllowed();
    }

    /// @notice Request a withdrawal - burns shares, calculates STRC owed, adds to queue
    /// @param assets The amount of assets to withdraw
    /// @return shares The number of shares burned
    /// @return strcAmount The amount of tSTRC added to the withdrawal queue
    function requestWithdraw(uint256 assets) external whenNotPaused returns (uint256 shares, uint256 strcAmount) {
        require(assets <= maxWithdraw(msg.sender), ExcessiveRequestedAmount());

        shares = previewWithdraw(assets);

        strcAmount = _processWithdrawal(msg.sender, msg.sender, assets, shares);
    }

    /// @notice Request a redemption - burns shares, calculates STRC owed, adds to queue
    /// @param shares The number of shares to redeem
    /// @return assets The amount of assets being redeemed
    /// @return strcAmount The amount of tSTRC added to the withdrawal queue
    function requestRedeem(uint256 shares) external whenNotPaused returns (uint256 assets, uint256 strcAmount) {
        require(shares <= maxRedeem(msg.sender), ExcessiveRequestedAmount());

        assets = previewRedeem(shares);

        strcAmount = _processWithdrawal(msg.sender, msg.sender, assets, shares);
    }

    /// @dev Internal function to process withdrawal request
    /// @param caller The address initiating the withdrawal
    /// @param owner The owner of the shares
    /// @param assets The asset value being withdrawn
    /// @param shares The shares to burn
    /// @return strcAmount The amount of tSTRC sent to the queue
    function _processWithdrawal(address caller, address owner, uint256 assets, uint256 shares)
        internal
        nonReentrant
        notZero(assets)
        notZero(shares)
        returns (uint256 strcAmount)
    {
        _requireNotBlacklisted(caller);
        _requireNotBlacklisted(owner);
        require(assets >= MIN_WITHDRAWAL, WithdrawalTooSmall());

        // Get the current STRC price from the oracle
        (uint256 strcPrice, uint8 priceDecimals) = TSTRC.getPrice();

        // Calculate: assets (18 decimals) * 10^priceDecimals / price = STRC amount (18 decimals)
        strcAmount = Math.mulDiv(assets, 10 ** priceDecimals, strcPrice, Math.Rounding.Floor);

        // Can only transfer the unvested tSTRC in the contract
        require(strcAmount <= TSTRC.balanceOf(address(this)) - getUnvestedAmount(), InsufficientBalance());

        _burn(owner, shares);

        // Transfer tSTRC to queue and add request
        IERC20(address(TSTRC)).safeTransfer(address(WITHDRAWAL_QUEUE), strcAmount);
        WITHDRAWAL_QUEUE.addRequest(owner, strcAmount);
    }

    /// @notice Claim all processed withdrawals for the caller
    /// @return totalAmount The total amount of USDat claimed
    function claim() external returns (uint256 totalAmount) {
        return WITHDRAWAL_QUEUE.claimFor(msg.sender);
    }

    /// @notice Claim specific withdrawal requests for the caller
    /// @param tokenIds Array of token IDs to claim
    /// @return totalAmount The total amount of USDat claimed
    function claimBatch(uint256[] calldata tokenIds) external returns (uint256 totalAmount) {
        return WITHDRAWAL_QUEUE.claimBatchFor(msg.sender, tokenIds);
    }

    /// @notice Get the withdrawal queue address
    function getWithdrawalQueue() external view returns (address) {
        return address(WITHDRAWAL_QUEUE);
    }

    /// @notice Get the TokenizedSTRC address
    function getTstrc() external view returns (address) {
        return address(TSTRC);
    }

    function pause() external onlyRole(COMPLIANCE_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    /// @notice Updates the vesting period for reward distributions
    /// @dev Only callable by DEFAULT_ADMIN_ROLE. Cannot be changed while rewards are vesting.
    /// @param newVestingPeriod The new vesting period in seconds
    function setVestingPeriod(uint256 newVestingPeriod) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newVestingPeriod > 0 && newVestingPeriod <= MAX_VESTING_PERIOD, InvalidVestingPeriod());
        require(getUnvestedAmount() == 0, StillVesting());

        uint256 oldPeriod = vestingPeriod;
        vestingPeriod = newVestingPeriod;

        emit VestingPeriodUpdated(oldPeriod, newVestingPeriod);
    }

    /// @notice Get the current vesting period
    /// @return The vesting period in seconds
    function getVestingPeriod() external view returns (uint256) {
        return vestingPeriod;
    }
}
