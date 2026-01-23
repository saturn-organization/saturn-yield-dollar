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
import {IUSDat} from "./interfaces/IUSDat.sol";

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
    error NoRecipientsForRedistribution();
    error CannotBlacklistAdmin();
    error InsufficientBalance();
    error StillVesting();
    error InvalidVestingPeriod();
    error WithdrawalTooSmall();
    error SlippageExceeded();
    error ExecutionPriceMismatch();
    error OraclePriceMismatch();
    error InvalidFee();

    event Blacklisted(address target);
    event UnBlacklisted(address target);
    event Converted(uint256 usdatAmount, uint256 strcAmount);
    event RewardsReceived(uint256 amount, uint256 newVestingAmount);
    event LockedAmountRedistributed(address from, uint256 amount);
    event VestingPeriodUpdated(uint256 oldPeriod, uint256 newPeriod);
    event DepositFeeUpdated(uint256 newFee);
    event FeeRecipientUpdated(address newRecipient);
    event toleranceUpdated(uint256 newToleranceBps);

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

    /// @notice Tolerance in basis points for validation
    uint256 public toleranceBps;
    uint256 public constant MAX_TOLERANCE_BPS = 10000; // 100% max
    uint256 public constant MIN_TOLERANCE_BPS = 100; // 1% min
    uint256 public constant BPS_DENOMINATOR = 10000;

    /// @notice Maximum deposit fee (5%)
    uint256 public constant MAX_DEPOSIT_FEE_BPS = 500;

    /// @notice Deposit fee in basis points (defaulxt 10 bps = 0.10%)
    uint256 public depositFeeBps;

    /// @notice Address that receives deposit fees
    address public feeRecipient;

    /// @notice Internally tracked USDat balance
    uint256 public usdatBalance;

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
    function initialize(
        address defaultAdmin,
        address processor,
        address compliance,
        address depositFeeRecipient,
        IERC20 usdat
    ) external initializer {
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
        depositFeeBps = 10;
        feeRecipient = depositFeeRecipient;
        toleranceBps = 2000; // Default 20%
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

        require(amountToDistribute > 0, ZeroAmount());
        require(totalSupply() > amountToDistribute, NoRecipientsForRedistribution());

        _burn(from, amountToDistribute);
        emit LockedAmountRedistributed(from, amountToDistribute);
    }

    /// @notice ASSUMPTION: asset is USDat and is always 1 dollar backed by treasuries.
    /// @notice new ERC4626 takes into account the donation attack using an offset on shares.
    /// @notice Excludes unvested rewards to prevent front-running attacks
    function totalAssets() public view override returns (uint256) {
        return usdatBalance + _strcTotalAssets();
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

    /// @notice Preview shares received for a deposit, accounting for fees
    /// @param assets The amount of assets to deposit
    /// @return shares The amount of shares that would be minted
    function previewDeposit(uint256 assets) public view override returns (uint256) {
        if (depositFeeBps == 0 || feeRecipient == address(0)) {
            return super.previewDeposit(assets);
        }
        uint256 fee = Math.mulDiv(assets, depositFeeBps, BPS_DENOMINATOR, Math.Rounding.Ceil);
        return super.previewDeposit(assets - fee);
    }

    /// @notice Preview assets required to mint shares, accounting for fees
    /// @param shares The amount of shares to mint
    /// @return assets The amount of assets required (including fee)
    function previewMint(uint256 shares) public view override returns (uint256) {
        if (depositFeeBps == 0 || feeRecipient == address(0)) {
            return super.previewMint(shares);
        }
        uint256 assets = super.previewMint(shares);
        // Gross up: assets / (1 - feeRate) = assets * BPS_DENOMINATOR / (BPS_DENOMINATOR - fee)
        return Math.mulDiv(assets, BPS_DENOMINATOR, BPS_DENOMINATOR - depositFeeBps, Math.Rounding.Ceil);
    }

    function rescueTokens(address token, uint256 amount, address to)
        external
        nonReentrant
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        require(token != address(TSTRC), OperationNotAllowed());

        // For USDat, only allow rescuing excess above tracked balance
        if (token == asset()) {
            uint256 excessBalance = IERC20(token).balanceOf(address(this)) - usdatBalance;
            require(amount <= excessBalance, InsufficientBalance());
        }

        IERC20(token).safeTransfer(to, amount);
    }

    /// @notice Checks if a value is within ±TOLERANCE_BPS of an expected value
    /// @param value The actual value to check
    /// @param expected The expected value
    /// @return True if value is within tolerance of expected
    function _isWithinTolerance(uint256 value, uint256 expected) internal view returns (bool) {
        uint256 minExpected = Math.mulDiv(expected, BPS_DENOMINATOR - toleranceBps, BPS_DENOMINATOR);
        uint256 maxExpected = Math.mulDiv(expected, BPS_DENOMINATOR + toleranceBps, BPS_DENOMINATOR);
        return value >= minExpected && value <= maxExpected;
    }

    /// @notice Validates that strcAmount matches usdatAmount / strcPurchasePrice within tolerance
    /// @param usdatAmount Amount of USDat being converted
    /// @param strcAmount Amount of STRC to mint
    /// @param strcPurchasePrice Price per STRC in USDat terms (8 decimals)
    function _validateConversion(uint256 usdatAmount, uint256 strcAmount, uint256 strcPurchasePrice) internal view {
        // Calculate expected STRC: usdatAmount / strcPurchasePrice
        // usdatAmount is 18 decimals, strcPurchasePrice is 8 decimals, result should be 18 decimals
        uint256 expectedStrc = Math.mulDiv(usdatAmount, 1e8, strcPurchasePrice);

        // Validate strcAmount is within tolerance of expected
        require(_isWithinTolerance(strcAmount, expectedStrc), ExecutionPriceMismatch());

        // Validate strcPurchasePrice against oracle price (within tolerance)
        (uint256 oraclePrice,) = TSTRC.getPrice();
        require(_isWithinTolerance(strcPurchasePrice, oraclePrice), OraclePriceMismatch());
    }

    /**
     * @notice Called by the admin when the entity purchases STRC from the market and sells the Tbills backing USDat.
     * @param usdatAmount amount of USDat to convert
     * @param strcAmount amount of STRC to mint
     * @param strcPurchasePrice price per STRC in USDat terms (8 decimals)
     */
    function convertFromUsdat(uint256 usdatAmount, uint256 strcAmount, uint256 strcPurchasePrice)
        external
        onlyRole(PROCESSOR_ROLE)
    {
        require(usdatBalance >= usdatAmount, InsufficientBalance());

        // Validate strcAmount matches usdatAmount / strcPurchasePrice within tolerance
        _validateConversion(usdatAmount, strcAmount, strcPurchasePrice);

        usdatBalance -= usdatAmount;

        IERC20Burnable(asset()).burn(usdatAmount);

        TSTRC.mint(address(this), strcAmount);

        emit Converted(usdatAmount, strcAmount);
    }

    /**
     * @notice Called by the admin when the entity sells STRC to the market and purchases Tbills to back USDat.
     * @param strcAmount amount of STRC to burn
     * @param usdatAmount amount of USDat to mint
     * @param strcSalePrice price per STRC in USDat terms (8 decimals)
     */
    function convertFromStrc(uint256 strcAmount, uint256 usdatAmount, uint256 strcSalePrice)
        external
        onlyRole(PROCESSOR_ROLE)
    {
        uint256 strcBalance = TSTRC.balanceOf(address(this));
        uint256 unvestedAmount = getUnvestedAmount();
        uint256 vestedBalance = strcBalance - unvestedAmount;
        require(strcAmount <= vestedBalance, InsufficientBalance());

        // Validate usdatAmount matches strcAmount * strcSalePrice within tolerance
        _validateConversion(usdatAmount, strcAmount, strcSalePrice);

        IERC20Burnable(address(TSTRC)).burn(strcAmount);

        usdatBalance += usdatAmount;
        IUSDat(asset()).mint(address(this), usdatAmount);

        emit Converted(usdatAmount, strcAmount);
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

        // Calculate and transfer fee if applicable
        uint256 fee = 0;
        if (depositFeeBps > 0 && feeRecipient != address(0)) {
            fee = Math.mulDiv(assets, depositFeeBps, BPS_DENOMINATOR, Math.Rounding.Ceil);
            IERC20(asset()).safeTransferFrom(caller, feeRecipient, fee);
        }

        uint256 netAssets = assets - fee;
        usdatBalance += netAssets;

        super._deposit(caller, receiver, netAssets, shares);
    }

    /// @notice Deposit assets with slippage protection
    /// @param assets The amount of assets to deposit
    /// @param receiver The address to receive the shares
    /// @param minShares The minimum number of shares to receive, reverts if less
    /// @return shares The number of shares minted
    function depositWithMinShares(uint256 assets, address receiver, uint256 minShares) public returns (uint256 shares) {
        shares = previewDeposit(assets);
        require(shares >= minShares, SlippageExceeded());
        _deposit(msg.sender, receiver, assets, shares);
    }

    /// @notice Mint shares with slippage protection
    /// @param shares The number of shares to mint
    /// @param receiver The address to receive the shares
    /// @param maxAssets The maximum amount of assets to spend, reverts if more
    /// @return assets The amount of assets spent
    function mintWithMaxAssets(uint256 shares, address receiver, uint256 maxAssets) public returns (uint256 assets) {
        assets = previewMint(shares);
        require(assets <= maxAssets, SlippageExceeded());
        _deposit(msg.sender, receiver, assets, shares);
    }

    /// @notice ERC4626 withdraw is disabled - use requestWithdraw instead
    function withdraw(uint256, address, address) public pure override returns (uint256) {
        revert OperationNotAllowed();
    }

    /// @notice ERC4626 redeem is disabled - use requestRedeem instead
    function redeem(uint256, address, address) public pure override returns (uint256) {
        revert OperationNotAllowed();
    }

    /// @notice Request a withdrawal - escrows shares in the queue
    /// @param assets The amount of assets to withdraw
    /// @param minUsdatReceived The minimum amount of USDat the user will accept
    /// @return shares The number of shares escrowed
    function requestWithdraw(uint256 assets, uint256 minUsdatReceived) external whenNotPaused returns (uint256 shares) {
        require(assets <= maxWithdraw(msg.sender), ExcessiveRequestedAmount());

        shares = previewWithdraw(assets);

        _processWithdrawal(msg.sender, msg.sender, assets, shares, minUsdatReceived);
    }

    /// @notice Request a redemption - escrows shares in the queue
    /// @param shares The number of shares to redeem
    /// @param minUsdatReceived The minimum amount of USDat the user will accept
    /// @return assets The amount of assets being redeemed
    function requestRedeem(uint256 shares, uint256 minUsdatReceived) external whenNotPaused returns (uint256 assets) {
        require(shares <= maxRedeem(msg.sender), ExcessiveRequestedAmount());

        assets = previewRedeem(shares);

        _processWithdrawal(msg.sender, msg.sender, assets, shares, minUsdatReceived);
    }

    /// @dev Internal function to process withdrawal request
    /// @param caller The address initiating the withdrawal
    /// @param owner The owner of the shares
    /// @param assets The asset value being withdrawn
    /// @param shares The shares to escrow
    /// @param minUsdatReceived The minimum amount of USDat the user will accept
    function _processWithdrawal(address caller, address owner, uint256 assets, uint256 shares, uint256 minUsdatReceived)
        internal
        nonReentrant
        notZero(assets)
        notZero(shares)
    {
        _requireNotBlacklisted(caller);
        _requireNotBlacklisted(owner);
        require(assets >= MIN_WITHDRAWAL, WithdrawalTooSmall());

        // Transfer shares to queue (escrow)
        _transfer(owner, address(WITHDRAWAL_QUEUE), shares);

        // Add request to queue
        WITHDRAWAL_QUEUE.addRequest(owner, shares, minUsdatReceived);
    }

    /// @notice Claim all processed withdrawals for the caller
    /// @return totalAmount The total amount of USDat claimed
    function claim() external returns (uint256 totalAmount) {
        return WITHDRAWAL_QUEUE.claimAllFor(msg.sender);
    }

    /// @notice Claim specific withdrawal requests for the caller
    /// @param tokenIds Array of token IDs to claim
    /// @return totalAmount The total amount of USDat claimed
    function claimBatch(uint256[] calldata tokenIds) external returns (uint256 totalAmount) {
        return WITHDRAWAL_QUEUE.claimBatchFor(msg.sender, tokenIds);
    }

    /// @notice Burns escrowed shares and the corresponding tSTRC sold off-chain
    /// @dev Only callable by the withdrawal queue during processing
    /// @param shares The number of shares to burn
    /// @param strcAmount The amount of tSTRC that was sold off-chain
    function burnQueuedShares(uint256 shares, uint256 strcAmount) external {
        require(msg.sender == address(WITHDRAWAL_QUEUE), OperationNotAllowed());
        IERC20Burnable(address(TSTRC)).burn(strcAmount);
        _burn(address(WITHDRAWAL_QUEUE), shares);
    }

    /// @notice Get the withdrawal queue address
    function getWithdrawalQueue() external view returns (address) {
        return address(WITHDRAWAL_QUEUE);
    }

    /// @notice Get the TokenizedSTRC address
    function getTstrc() external view returns (address) {
        return address(TSTRC);
    }

    /// @notice Updates the vesting period for reward distributions
    /// @dev Only callable by PROCESSOR_ROLE. Cannot be changed while rewards are vesting.
    /// @param newVestingPeriod The new vesting period in seconds
    function setVestingPeriod(uint256 newVestingPeriod) external onlyRole(PROCESSOR_ROLE) {
        require(newVestingPeriod > 0 && newVestingPeriod <= MAX_VESTING_PERIOD, InvalidVestingPeriod());
        require(getUnvestedAmount() == 0, StillVesting());

        uint256 oldPeriod = vestingPeriod;
        vestingPeriod = newVestingPeriod;

        emit VestingPeriodUpdated(oldPeriod, newVestingPeriod);
    }

    /// @notice Updates the deposit fee
    /// @dev Only callable by PROCESSOR_ROLE. Can be set to 0 to disable fees.
    /// @param newFeeBps The new fee in basis points (0 to MAX_DEPOSIT_FEE_BPS)
    function setDepositFee(uint256 newFeeBps) external onlyRole(PROCESSOR_ROLE) {
        require(newFeeBps <= MAX_DEPOSIT_FEE_BPS, InvalidFee());

        depositFeeBps = newFeeBps;

        emit DepositFeeUpdated(newFeeBps);
    }

    /// @notice Updates the fee recipient address
    /// @dev Only callable by PROCESSOR_ROLE. Can be set to address(0) to disable fees.
    /// @param newRecipient The new fee recipient address
    function setFeeRecipient(address newRecipient) external onlyRole(PROCESSOR_ROLE) {
        feeRecipient = newRecipient;

        emit FeeRecipientUpdated(newRecipient);
    }

    /// @notice Update the price tolerance for conversion validation
    /// @dev Only callable by PROCESSOR_ROLE. Use during black swan events.
    /// @param newToleranceBps The new tolerance in basis points
    function setTolerance(uint256 newToleranceBps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newToleranceBps >= MIN_TOLERANCE_BPS && newToleranceBps <= MAX_TOLERANCE_BPS, InvalidFee());

        toleranceBps = newToleranceBps;

        emit toleranceUpdated(newToleranceBps);
    }

    function pause() external onlyRole(COMPLIANCE_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }
}
