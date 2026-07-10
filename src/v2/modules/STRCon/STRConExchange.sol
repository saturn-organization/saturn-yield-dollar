// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IExchanger} from "../../interfaces/IExchanger.sol";
import {IGMTokenManager} from "../../interfaces/IGMTokenManager.sol";
import {ISwapFacility} from "../../interfaces/ISwapFacility.sol";

/**
 * @title STRConExchange
 * @author Saturn
 * @notice IExchanger implementation routing between USDat and STRCon. Deployed per
 * venue configuration and re-pointed on the module (`setExchanger`) when a route
 * changes (a DEX migration, M → PYUSD backing) — never upgraded in place. Current
 * swapIn venue: the Fluid USDat/USDC DEX pool.
 * @dev Low-trust by design: the STRConModule measures delivery, enforces min-out and
 * oracle-bounded pricing itself. Pulls input from the caller via allowance, delivers
 * output back to the caller. Holds no funds between transactions.
 * Operational prerequisites: this address must be registered in Ondo's ID registry
 * (quotes bind to its userId) and permissioned on the Swap Facility for the
 * USDC → USDat path.
 */
contract STRConExchange is IExchanger {
    using SafeERC20 for IERC20;

    error NotImplemented();
    error InvalidZeroAddress();
    error QuantityMismatch();

    /// @notice The USDat token (6 decimals)
    IERC20 public immutable USDAT;

    /// @notice The USDC token (6 decimals) — the intermediate settlement leg
    IERC20 public immutable USDC;

    /// @notice The STRCon token (18 decimals)
    IERC20 public immutable STRCON;

    /// @notice Ondo's GMTokenManager (STRCon mint/redeem against signed RFQ quotes)
    IGMTokenManager public immutable GM_TOKEN_MANAGER;

    /// @notice M0's SwapFacility (zero-fee USDC → USDat mint)
    ISwapFacility public immutable SWAP_FACILITY;

    constructor(IERC20 usdat, IERC20 usdc, IERC20 strcon, IGMTokenManager gmTokenManager, ISwapFacility swapFacility) {
        require(
            address(usdat) != address(0) && address(usdc) != address(0) && address(strcon) != address(0)
                && address(gmTokenManager) != address(0) && address(swapFacility) != address(0),
            InvalidZeroAddress()
        );
        USDAT = usdat;
        USDC = usdc;
        STRCON = strcon;
        GM_TOKEN_MANAGER = gmTokenManager;
        SWAP_FACILITY = swapFacility;
    }

    /// @inheritdoc IExchanger
    /// @dev Will route USDat → USDC (current cash venue) → STRCon (Ondo).
    function swapIn(uint256 usdatIn, uint256 minStrconOut, bytes calldata data) external returns (uint256 strconOut) {
        revert NotImplemented();
    }

    /// @inheritdoc IExchanger
    /// @dev The stable exit path: redeem STRCon for USDC on Ondo's GMTokenManager,
    /// then mint USDat 1:1 through the Swap Facility at zero fee, delivered straight
    /// to the caller. `data`: abi.encode(IGMTokenManager.Quote, bytes signature) —
    /// the Ondo-signed RFQ quote the operator fetched off-chain. The redeemed amount
    /// is quote.quantity, so it must equal strconIn exactly (a smaller quote would
    /// strand the difference here). USDC and USDat are both 6 decimals and swap 1:1,
    /// so minUsdatOut doubles as the USDC minimum on the Ondo leg.
    function swapOut(uint256 strconIn, uint256 minUsdatOut, bytes calldata data) external returns (uint256 usdatOut) {
        (IGMTokenManager.Quote memory quote, bytes memory signature) = abi.decode(data, (IGMTokenManager.Quote, bytes));
        require(quote.quantity == strconIn, QuantityMismatch());

        STRCON.safeTransferFrom(msg.sender, address(this), strconIn);
        STRCON.forceApprove(address(GM_TOKEN_MANAGER), strconIn);

        usdatOut = GM_TOKEN_MANAGER.redeemWithAttestation(quote, signature, address(USDC), minUsdatOut);

        STRCON.forceApprove(address(GM_TOKEN_MANAGER), 0);

        USDC.forceApprove(address(SWAP_FACILITY), usdatOut);
        SWAP_FACILITY.swap(address(USDC), address(USDAT), usdatOut, msg.sender);
    }
}
