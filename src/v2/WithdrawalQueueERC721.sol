// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {
    ERC721EnumerableUpgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC721/extensions/ERC721EnumerableUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

import {IUSDat} from "./interfaces/IUSDat.sol";
import {IStakedUSDat} from "./interfaces/IStakedUSDat.sol";
import {IWithdrawalQueueERC721} from "./interfaces/IWithdrawalQueueERC721.sol";

/**
 * @title WithdrawalQueueERC721
 * @author Saturn
 * @notice Implementation of the IWithdrawalQueueERC721 interface.
 * @dev See {IWithdrawalQueueERC721} for full documentation.
 */
contract WithdrawalQueueERC721 is
    Initializable,
    ERC721EnumerableUpgradeable,
    AccessControlUpgradeable,
    ReentrancyGuard,
    PausableUpgradeable,
    UUPSUpgradeable,
    IWithdrawalQueueERC721
{
    using SafeERC20 for IERC20;

    /// @notice Role identifier for the operator (processRequests)
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    /// @notice Role identifier for enforcement actions against blacklisted holders
    bytes32 public constant ENFORCER_ROLE = keccak256("ENFORCER_ROLE");

    /// @notice Role identifier for pausing (cannot unpause)
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    /// @notice Role identifier for unpausing (cannot pause)
    bytes32 public constant UNPAUSER_ROLE = keccak256("UNPAUSER_ROLE");

    /// @dev The USDat token contract (immutable, stored in implementation bytecode)
    IUSDat public immutable USDAT;

    /// @dev The StakedUSDat contract (immutable, stored in implementation bytecode)
    IStakedUSDat public immutable STAKED_USDAT;

    /// @notice Mapping of token ID to request data
    mapping(uint256 tokenId => Request) public requests;

    /// @notice The next token ID to be minted
    uint256 public nextTokenId;

    /// @dev Retired v1 slot (was pendingCount); do not reuse
    uint256 private __deprecated_pendingCount;

    /// @dev Contract-relationship gate: immutable address check, deliberately not a
    /// grantable role.
    modifier onlyStakedUSDat() {
        require(msg.sender == address(STAKED_USDAT), OperationNotAllowed());
        _;
    }

    /// @dev Lifts an active pause for the duration of the call (enforcement actions
    /// work while paused).
    modifier whileUnpaused() {
        bool wasPaused = paused();
        if (wasPaused) _unpause();
        _;
        if (wasPaused) _pause();
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address usdat, address stakedUsdat) {
        require(usdat != address(0) && stakedUsdat != address(0), ZeroAmount());
        USDAT = IUSDat(usdat);
        STAKED_USDAT = IStakedUSDat(stakedUsdat);
        _disableInitializers();
    }

    /// @notice Initializes the contract (called once via proxy)
    /// @dev Grants only DEFAULT_ADMIN_ROLE; the admin grants the operational roles (§2.8)
    /// after deployment.
    /// @param admin The default admin of the contract
    function initialize(address admin) external initializer {
        require(admin != address(0), ZeroAmount());

        __ERC721_init("Saturn Withdrawal Request", "sWR");
        __ERC721Enumerable_init();
        __AccessControl_init();
        __Pausable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    /// @notice v1 → v2 migration reinitializer (§3.1), executed atomically inside
    /// upgradeToAndCall.
    /// @dev Grants the §2.8 roles (new role ids, nothing carries over from v1) and
    /// converts every historical request in place, scanning at execution time so
    /// requests created during the timelock delay are covered. v1 never zeroed
    /// `shares`/`usdatOwed`, so each v1 status needs its own conversion to satisfy
    /// v2's derived states (open = shares > 0, claimable = usdatOwed > 0):
    /// - Requested/InProgress: shares are genuinely still escrowed; the
    ///   minUsdatReceived slot converts to a per-share limit (ceilDiv — never weaker
    ///   than the user's original bound). InProgress resets to Requested.
    /// - Processed: settled in v1 (those shares were already burned) — zero `shares`
    ///   so only the claim remains; left as-is it would read as open and process
    ///   again, burning other requests' escrow.
    /// - Claimed: the NFT is already burned but v1 left the struct populated —
    ///   deleted, restoring "token exists iff shares > 0 || usdatOwed > 0".
    /// @param operator The OPERATOR_ROLE holder (processRequests).
    /// @param enforcer The ENFORCER_ROLE holder (seizeRequest, seize).
    /// @param pauser The PAUSER_ROLE holder.
    /// @param unpauser The UNPAUSER_ROLE holder.
    function initializeV2(address operator, address enforcer, address pauser, address unpauser)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
        reinitializer(2)
    {
        require(
            operator != address(0) && enforcer != address(0) && pauser != address(0) && unpauser != address(0),
            ZeroAmount()
        );

        _grantRole(OPERATOR_ROLE, operator);
        _grantRole(ENFORCER_ROLE, enforcer);
        _grantRole(PAUSER_ROLE, pauser);
        _grantRole(UNPAUSER_ROLE, unpauser);

        __deprecated_pendingCount = 0;

        uint256 count = nextTokenId;
        for (uint256 id = 0; id < count; id++) {
            Request storage req = requests[id];

            if (req.status == RequestStatus.Requested || req.status == RequestStatus.InProgress) {
                req.minSharePrice = Math.ceilDiv(req.minSharePrice * 1e18, req.shares);
                if (req.status == RequestStatus.InProgress) {
                    req.status = RequestStatus.Requested;
                }
            } else if (req.status == RequestStatus.Processed) {
                req.shares = 0;
            } else if (req.status == RequestStatus.Claimed) {
                delete requests[id];
            }
        }
    }

    /// @dev Authorizes an upgrade to a new implementation. Only callable by DEFAULT_ADMIN_ROLE.
    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    /// @dev Reverts if the given account is blacklisted in either StakedUSDat or USDat.
    function _requireNotBlacklisted(address account) internal view {
        require(!STAKED_USDAT.isBlacklisted(account), AddressBlacklisted());
        require(!USDAT.isFrozen(account), AddressBlacklisted());
    }

    /// @dev Reverts if the given account is NOT blacklisted in both StakedUSDat and USDat.
    function _requireBlacklisted(address account) internal view {
        require(STAKED_USDAT.isBlacklisted(account) || USDAT.isFrozen(account), NotBlacklisted());
    }

    // ============ Request Creation ============

    /// @inheritdoc IWithdrawalQueueERC721
    function addRequest(address user, uint256 shares, uint256 minSharePrice)
        external
        nonReentrant
        whenNotPaused
        onlyStakedUSDat
        returns (uint256 tokenId)
    {
        require(shares != 0, ZeroAmount());

        tokenId = nextTokenId++;

        requests[tokenId] = Request({
            shares: shares,
            usdatOwed: 0,
            timestamp: block.timestamp,
            status: RequestStatus.NULL, // legacy v1 slot; v2 logic neither reads nor writes it
            minSharePrice: minSharePrice
        });

        _safeMint(user, tokenId);

        emit WithdrawalRequested(tokenId, user, shares, block.timestamp);
    }

    /// @inheritdoc IWithdrawalQueueERC721
    function updateMinSharePrice(uint256 tokenId, uint256 newMinSharePrice) external whenNotPaused {
        require(ownerOf(tokenId) == msg.sender, NotOwner());
        _requireNotBlacklisted(msg.sender);

        Request storage req = requests[tokenId];
        require(req.shares > 0, RequestNotOpen());

        req.minSharePrice = newMinSharePrice;

        emit MinSharePriceUpdated(tokenId, newMinSharePrice);
    }

    // ============ Processing Functions ============

    /// @inheritdoc IWithdrawalQueueERC721
    /// @dev Per-request, buffer-clamped, settled at NAV. Three outcomes per request:
    /// revert on a dead token (operator bug), skip on an unmet limit (a later request
    /// may have a lower limit), break when the buffer is dry (nothing later fills either).
    function processRequests(uint256[] calldata tokenIds) external nonReentrant whenNotPaused onlyRole(OPERATOR_ROLE) {
        uint256 count = tokenIds.length;
        for (uint256 i = 0; i < count; i++) {
            uint256 tokenId = tokenIds[i];
            Request storage req = requests[tokenId];
            require(req.shares > 0, RequestNotOpen());

            if (STAKED_USDAT.convertToAssets(1e18) < req.minSharePrice) continue;

            (uint256 filled, uint256 usdat) = STAKED_USDAT.redeemQueuedShares(req.shares);
            if (filled == 0) break;

            req.usdatOwed += usdat;
            req.shares -= filled;

            emit WithdrawalProcessed(tokenId, filled, usdat);
        }
    }

    // ============ Claiming Functions ============

    /// @inheritdoc IWithdrawalQueueERC721
    /// @dev Pays the accrued usdatOwed and zeroes it; burns the NFT only when the
    /// request is fully filled and drained. Claimed can fire multiple times per token.
    function claim(uint256 tokenId) external nonReentrant whenNotPaused returns (uint256 amount) {
        _requireNotBlacklisted(msg.sender);
        require(ownerOf(tokenId) == msg.sender, NotOwner());

        Request storage req = requests[tokenId];
        amount = req.usdatOwed;
        require(amount > 0, NothingToClaim());

        req.usdatOwed = 0;

        if (req.shares == 0) {
            delete requests[tokenId];
            _burn(tokenId);
        }

        IERC20(address(USDAT)).safeTransfer(msg.sender, amount);

        emit Claimed(tokenId, msg.sender, amount);
    }

    // ============ Compliance Functions ============

    /// @inheritdoc IWithdrawalQueueERC721
    function seizeRequest(uint256 tokenId, address to) external nonReentrant onlyRole(ENFORCER_ROLE) whileUnpaused {
        _requireNotBlacklisted(to);
        address owner = ownerOf(tokenId);
        _requireBlacklisted(owner);

        // Accrued usdatOwed and the open remainder travel with the token.
        _transfer(owner, to, tokenId);

        emit RequestSeized(tokenId, owner, to);
    }

    /// @inheritdoc IWithdrawalQueueERC721
    function seize(uint256 tokenId, address to) external nonReentrant onlyRole(ENFORCER_ROLE) whileUnpaused {
        require(to != address(0), ZeroAmount());
        address owner = ownerOf(tokenId);
        _requireBlacklisted(owner);

        Request storage req = requests[tokenId];
        uint256 amount = req.usdatOwed;
        require(amount > 0, NothingToClaim());

        req.usdatOwed = 0;

        // Burn only when fully filled and drained — an open remainder keeps
        // accruing fills and stays seizable.
        if (req.shares == 0) {
            delete requests[tokenId];
            _burn(tokenId);
        }

        IERC20(address(USDAT)).safeTransfer(to, amount);

        emit FundsSeized(tokenId, owner, amount, to);
    }

    /// @inheritdoc IWithdrawalQueueERC721
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /// @inheritdoc IWithdrawalQueueERC721
    function unpause() external onlyRole(UNPAUSER_ROLE) {
        _unpause();
    }

    // ============ Required Overrides ============

    /// @dev Override to check blacklist and pause on all token movements.
    function _update(address to, uint256 tokenId, address auth) internal override whenNotPaused returns (address) {
        address from = _ownerOf(tokenId);

        if (from != address(0) && to != address(0)) {
            if (hasRole(ENFORCER_ROLE, msg.sender) && from != msg.sender) {
                _requireBlacklisted(from);
                _requireNotBlacklisted(to);
            } else {
                _requireNotBlacklisted(from);
                _requireNotBlacklisted(to);
            }
        }

        return super._update(to, tokenId, auth);
    }

    /// @dev Override required by Solidity for multiple inheritance.
    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721EnumerableUpgradeable, AccessControlUpgradeable)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}
