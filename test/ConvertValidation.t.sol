// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {StakedUSDat} from "../src/StakedUSDat.sol";
import {WithdrawalQueueERC721} from "../src/WithdrawalQueueERC721.sol";
import {StrcPriceOracle} from "../src/StrcPriceOracle.sol";
import {IStakedUSDat} from "../src/interfaces/IStakedUSDat.sol";
import {IStrcPriceOracle} from "../src/interfaces/IStrcPriceOracle.sol";
import {IWithdrawalQueueERC721} from "../src/interfaces/IWithdrawalQueueERC721.sol";

// ─── Mocks ────────────────────────────────────────────────────────────────────

/// @dev Minimal ERC20 with 6 decimals — mirrors MockUSDat in DecimalOffset.t.sol.
contract MockUSDatCV {
    uint8 public decimals = 6;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (allowance[from][msg.sender] != type(uint256).max) allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function isFrozen(address) external pure returns (bool) {
        return false;
    }
}

/// @dev Fixed Chainlink mock: STRC = $100 (100e8), always fresh.
contract MockOracleCV {
    int256 public constant PRICE = 100e8;
    uint8 public constant decimals = 8;

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, PRICE, block.timestamp, block.timestamp, 1);
    }
}

// ─── Test suite ───────────────────────────────────────────────────────────────

/**
 * @title ConvertValidationTest
 * @notice Proves the two HIGH-severity bugs in the original _validateConversion and
 *         confirms that the fixed implementation correctly rejects them.
 *
 * Bugs addressed by the PR:
 *
 *  Bug 1 — Oracle tolerance too wide (HIGH)
 *    The original code used a single `toleranceBps = 2000` (20%) for BOTH the
 *    oracle-price sanity check AND the execution-quantity check.  A price 15% off
 *    the oracle (well within the 20% band) would silently pass, letting the
 *    processor report an execution price far from market without triggering a revert.
 *
 *    Fix: separate `oraclePriceTolerance = 500` (5%) for the oracle price check,
 *    keeping `toleranceBps = 2000` for the quantity / NAV checks.
 *
 *  Bug 2 — Self-referential bypass / no NAV cross-check (HIGH)
 *    `expectedStrc` was computed from the processor-supplied `strcPurchasePrice`,
 *    making the two old checks co-dependent: a consistently wrong price would cause
 *    both checks to move together and both pass.  No independent oracle-anchored
 *    verification of the USD value exchanged existed.
 *
 *    Fix: add a third check — `strcAmount × oraclePrice ≈ usdatAmount` — that
 *    independently validates the NAV impact of the trade using the oracle price,
 *    not the processor-reported price.
 *
 * Test structure:
 *  • Regression tests  — valid conversions that should still pass
 *  • Bug 1 tests       — price ±15% from oracle now reverts (OraclePriceMismatch)
 *  • Bug 2 tests       — NAV bypass now reverts (ExecutionPriceMismatch)
 *  • Admin setter tests — setOraclePriceTolerance access control and bounds
 */
contract ConvertValidationTest is Test {
    MockUSDatCV public usdat;
    MockOracleCV public chainlinkOracle;
    StrcPriceOracle public strcOracle;
    WithdrawalQueueERC721 public withdrawalQueue;
    StakedUSDat public stakedUsdat;

    address public admin = makeAddr("admin");
    address public processor = makeAddr("processor");
    address public compliance = makeAddr("compliance");
    address public feeRecipient = makeAddr("feeRecipient");
    address public alice = makeAddr("alice");

    /// Oracle price: $100 with 8 decimal places
    uint256 constant ORACLE_PRICE = 100e8;
    /// 1 000 USDat (6 decimals)
    uint256 constant USDAT_1000 = 1000e6;
    /// 10 STRC (6 decimals) — fair exchange for 1 000 USDat at $100/STRC
    uint256 constant STRC_10 = 10e6;

    // ─── Setup ────────────────────────────────────────────────────────────────

    function setUp() public {
        usdat = new MockUSDatCV();
        chainlinkOracle = new MockOracleCV();
        strcOracle = new StrcPriceOracle(admin, address(chainlinkOracle));

        // Mirror the nonce-based address prediction from DecimalOffset.t.sol
        uint256 nonce = vm.getNonce(address(this));
        address stakedUsdatProxy = computeCreateAddress(address(this), nonce + 3);

        WithdrawalQueueERC721 wqImpl = new WithdrawalQueueERC721(address(usdat), stakedUsdatProxy);
        bytes memory wqInit =
            abi.encodeCall(WithdrawalQueueERC721.initialize, (admin, stakedUsdatProxy, processor, compliance));
        ERC1967Proxy wqProxy = new ERC1967Proxy(address(wqImpl), wqInit);
        withdrawalQueue = WithdrawalQueueERC721(address(wqProxy));

        StakedUSDat susdatImpl =
            new StakedUSDat(IStrcPriceOracle(address(strcOracle)), IWithdrawalQueueERC721(address(withdrawalQueue)));
        bytes memory susdatInit =
            abi.encodeCall(StakedUSDat.initialize, (admin, processor, compliance, feeRecipient, IERC20(address(usdat))));
        ERC1967Proxy susdatProxy = new ERC1967Proxy(address(susdatImpl), susdatInit);
        stakedUsdat = StakedUSDat(address(susdatProxy));

        assertEq(address(stakedUsdat), stakedUsdatProxy, "Address prediction mismatch");

        // Seed the vault: Alice deposits 2 000 USDat.
        // After 0.1% deposit fee → usdatBalance = 1 998 USDat, vault holds 1 998e6 in ERC20 balance.
        uint256 seed = 2000e6;
        usdat.mint(alice, seed);
        vm.startPrank(alice);
        usdat.approve(address(stakedUsdat), seed);
        stakedUsdat.depositWithMinShares(seed, alice, 0);
        vm.stopPrank();

        // Processor pre-approves the vault to pull USDat (needed for convertFromStrc).
        vm.prank(processor);
        usdat.approve(address(stakedUsdat), type(uint256).max);
    }

    // ─── Helper ───────────────────────────────────────────────────────────────

    /// @dev Executes a valid convertFromUsdat to seed strcBalance and give the
    ///      processor USDat for subsequent convertFromStrc calls.
    function _seedStrcBalance(uint256 usdatAmount, uint256 strcAmount, uint256 price) internal {
        vm.prank(processor);
        stakedUsdat.convertFromUsdat(usdatAmount, strcAmount, price);
    }

    /// @dev Integer multiply-then-divide — safe for our test magnitudes (no overflow).
    function _mulDiv(uint256 x, uint256 y, uint256 d) internal pure returns (uint256) {
        return x * y / d;
    }

    // ─── Regression: convertFromUsdat happy paths ─────────────────────────────

    /// @notice Valid conversion at exact oracle price passes all three checks.
    function test_convertFromUsdat_happyPath() public {
        uint256 prevUsdat = stakedUsdat.usdatBalance();

        vm.expectEmit(false, false, false, true, address(stakedUsdat));
        emit IStakedUSDat.ConvertedToStrc(USDAT_1000, STRC_10);

        vm.prank(processor);
        stakedUsdat.convertFromUsdat(USDAT_1000, STRC_10, ORACLE_PRICE);

        assertEq(stakedUsdat.usdatBalance(), prevUsdat - USDAT_1000);
        assertEq(stakedUsdat.strcBalance(), STRC_10);
    }

    /// @notice Price exactly 5% below oracle (lower boundary of oraclePriceTolerance) passes.
    function test_convertFromUsdat_oracleToleranceLowerBoundary() public {
        // price = 95e8  →  min boundary of the 5% oracle tolerance band
        uint256 price = 95e8;
        // Internally consistent quantity at this price: mulDiv(1000e6, 1e8, 95e8) = 10 526 315
        uint256 strcAmount = _mulDiv(USDAT_1000, 1e8, price);

        // Check 3 (NAV): strcValueAtOracle = 10 526 315 × 100 = 1 052 631 500
        // _isWithinTolerance(1 052 631 500, 1 000 000 000): min=800M, max=1 200M → passes
        vm.prank(processor);
        stakedUsdat.convertFromUsdat(USDAT_1000, strcAmount, price);

        assertEq(stakedUsdat.strcBalance(), strcAmount);
    }

    /// @notice Price exactly 5% above oracle (upper boundary of oraclePriceTolerance) passes.
    function test_convertFromUsdat_oracleToleranceUpperBoundary() public {
        // price = 105e8  →  max boundary of the 5% oracle tolerance band
        uint256 price = 105e8;
        // expectedStrc at 105e8: mulDiv(1000e6, 1e8, 105e8) = 9 523 809
        uint256 strcAmount = _mulDiv(USDAT_1000, 1e8, price);

        // Check 3 (NAV): 9 523 809 × 100 = 952 380 900 — within 20% of 1 000 000 000 → passes
        vm.prank(processor);
        stakedUsdat.convertFromUsdat(USDAT_1000, strcAmount, price);

        assertEq(stakedUsdat.strcBalance(), strcAmount);
    }

    // ─── Bug 1: oracle tolerance too wide ────────────────────────────────────

    /// @notice Execution price 15% above oracle reverts with OraclePriceMismatch.
    ///
    /// Under the OLD code _isWithinTolerance used toleranceBps=2000 (20%) for both checks:
    ///   min = 80e8, max = 120e8  →  115e8 PASSED  (incorrect, vault could be defrauded)
    ///
    /// Under the NEW code _isWithinBps(..., oraclePriceTolerance=500) is used for the oracle check:
    ///   min = 95e8, max = 105e8  →  115e8 FAILS   ✓
    function test_convertFromUsdat_rejectsPrice15pctAboveOracle() public {
        uint256 badPrice = 115e8;
        // Quantity is internally consistent with the bad price so old check 2 would also have passed.
        // mulDiv(1000e6, 1e8, 115e8) = 8 695 652
        uint256 strcAmount = _mulDiv(USDAT_1000, 1e8, badPrice);

        vm.prank(processor);
        vm.expectRevert(IStakedUSDat.OraclePriceMismatch.selector);
        stakedUsdat.convertFromUsdat(USDAT_1000, strcAmount, badPrice);
    }

    /// @notice Execution price 15% below oracle reverts with OraclePriceMismatch.
    function test_convertFromUsdat_rejectsPrice15pctBelowOracle() public {
        uint256 badPrice = 85e8;
        // mulDiv(1000e6, 1e8, 85e8) = 11 764 705
        uint256 strcAmount = _mulDiv(USDAT_1000, 1e8, badPrice);

        vm.prank(processor);
        vm.expectRevert(IStakedUSDat.OraclePriceMismatch.selector);
        stakedUsdat.convertFromUsdat(USDAT_1000, strcAmount, badPrice);
    }

    // ─── Bug 2: self-referential bypass / missing NAV cross-check ────────────

    /// @notice Demonstrates the self-referential bypass that check 3 now closes.
    ///
    /// The processor reports strcPurchasePrice=105e8 (within 5% oracle tolerance → passes check 1)
    /// and strcAmount=7 700 000 (within 20% of expectedStrc at 105e8 → passes check 2).
    ///
    /// BUT the vault actually receives only 7.7M STRC worth $770 at the oracle,
    /// while handing out 1 000 USDat — a $230 NAV loss per call, undetectable by the old code.
    ///
    ///   Old check 2: expectedStrc = mulDiv(1000e6, 1e8, 105e8) = 9 523 809
    ///                min = 7 619 047  ≤  7 700 000  → PASSED  (old code was blind here)
    ///   New check 3:  strcValueAtOracle = 7 700 000 × 100 = 770 000 000
    ///                _isWithinTolerance(770 000 000, 1 000 000 000): min = 800 000 000
    ///                770 000 000 < 800 000 000  →  FAILS  ✓
    function test_convertFromUsdat_rejectsNavBypass() public {
        uint256 price = 105e8; // within oracle tolerance → passes check 1
        uint256 strcAmount = 7_700_000; // passes check 2, fails check 3

        vm.prank(processor);
        vm.expectRevert(IStakedUSDat.ExecutionPriceMismatch.selector);
        stakedUsdat.convertFromUsdat(USDAT_1000, strcAmount, price);
    }

    // ─── Regression: convertFromStrc happy path ───────────────────────────────

    /// @notice Valid sell-back of all STRC at exact oracle price emits ConvertedFromStrc
    ///         and correctly updates both tracked balances.
    function test_convertFromStrc_happyPath() public {
        // Seed: vault sells 1 000 USDat for 10 STRC; processor now holds 1 000 USDat
        _seedStrcBalance(USDAT_1000, STRC_10, ORACLE_PRICE);
        uint256 prevUsdat = stakedUsdat.usdatBalance();

        vm.expectEmit(false, false, false, true, address(stakedUsdat));
        emit IStakedUSDat.ConvertedFromStrc(STRC_10, USDAT_1000);

        vm.prank(processor);
        stakedUsdat.convertFromStrc(STRC_10, USDAT_1000, ORACLE_PRICE);

        assertEq(stakedUsdat.strcBalance(), 0);
        assertEq(stakedUsdat.usdatBalance(), prevUsdat + USDAT_1000);
    }

    // ─── Bug 1 (convertFromStrc): oracle tolerance too wide ──────────────────

    /// @notice Sale price 15% below oracle reverts with OraclePriceMismatch.
    function test_convertFromStrc_rejectsPrice15pctBelowOracle() public {
        _seedStrcBalance(USDAT_1000, STRC_10, ORACLE_PRICE);

        uint256 badSalePrice = 85e8;
        // USDat consistent with bad price: 10 STRC × $85 = $850
        uint256 usdatAmount = _mulDiv(STRC_10, badSalePrice, 1e8); // 850 000 000

        vm.prank(processor);
        vm.expectRevert(IStakedUSDat.OraclePriceMismatch.selector);
        stakedUsdat.convertFromStrc(STRC_10, usdatAmount, badSalePrice);
    }

    // ─── Bug 2 (convertFromStrc): NAV cross-check catches underpayment ────────

    /// @notice Processor sells 5 STRC at $95 (valid oracle price) but deposits only
    ///         400 USDat instead of the ~$475-$500 the STRC is worth — NAV theft.
    ///
    ///   check 1: _isWithinBps(95e8, 100e8, 500) → 95e8 = lower boundary → passes
    ///   check 2: expectedStrc = mulDiv(400e6, 1e8, 95e8) = 4 210 526
    ///            _isWithinTolerance(5 000 000, 4 210 526): min = 3 368 420 → passes
    ///   check 3: strcValueAtOracle = mulDiv(5e6, 100e8, 1e8) = 500 000 000
    ///            _isWithinTolerance(500 000 000, 400 000 000): max = 480 000 000
    ///            500 000 000 > 480 000 000  →  FAILS  ✓
    ///
    ///   Under old code: no check 3 existed → PASSED (processor pockets $100 per call).
    function test_convertFromStrc_rejectsNavBypass() public {
        _seedStrcBalance(USDAT_1000, STRC_10, ORACLE_PRICE);

        uint256 strcAmount = 5e6;
        uint256 usdatAmount = 400e6; // underpays vault: 5 STRC worth $500 at oracle → only $400 returned
        uint256 salePrice = 95e8; // within 5% oracle tolerance → passes check 1

        vm.prank(processor);
        vm.expectRevert(IStakedUSDat.ExecutionPriceMismatch.selector);
        stakedUsdat.convertFromStrc(strcAmount, usdatAmount, salePrice);
    }

    // ─── setOraclePriceTolerance ──────────────────────────────────────────────

    function test_setOraclePriceTolerance_setsValueAndEmits() public {
        vm.prank(admin);
        vm.expectEmit(false, false, false, true, address(stakedUsdat));
        emit IStakedUSDat.OraclePriceToleranceUpdated(800);
        stakedUsdat.setOraclePriceTolerance(800);

        assertEq(stakedUsdat.oraclePriceTolerance(), 800);
    }

    function test_setOraclePriceTolerance_atMinBound() public {
        vm.prank(admin);
        stakedUsdat.setOraclePriceTolerance(50); // MIN_ORACLE_TOLERANCE_BPS
        assertEq(stakedUsdat.oraclePriceTolerance(), 50);
    }

    function test_setOraclePriceTolerance_atMaxBound() public {
        vm.prank(admin);
        stakedUsdat.setOraclePriceTolerance(1000); // MAX_ORACLE_TOLERANCE_BPS
        assertEq(stakedUsdat.oraclePriceTolerance(), 1000);
    }

    function test_setOraclePriceTolerance_tooHigh_reverts() public {
        vm.prank(admin);
        vm.expectRevert(IStakedUSDat.InvalidFee.selector);
        stakedUsdat.setOraclePriceTolerance(1001);
    }

    function test_setOraclePriceTolerance_tooLow_reverts() public {
        vm.prank(admin);
        vm.expectRevert(IStakedUSDat.InvalidFee.selector);
        stakedUsdat.setOraclePriceTolerance(49);
    }

    function test_setOraclePriceTolerance_nonAdmin_reverts() public {
        vm.prank(alice);
        vm.expectRevert();
        stakedUsdat.setOraclePriceTolerance(500);
    }

    /// @notice After tightening oracle tolerance, a price that was previously borderline
    ///         (e.g. 103e8 at 5% tolerance) is still accepted.
    function test_oraclePriceTolerance_tighterBandStillAcceptsValidPrice() public {
        // Reduce oracle tolerance to 3%
        vm.prank(admin);
        stakedUsdat.setOraclePriceTolerance(300);

        // 103e8 is within 3% of 100e8
        uint256 price = 103e8;
        uint256 strcAmount = _mulDiv(USDAT_1000, 1e8, price); // 9 708 737

        vm.prank(processor);
        stakedUsdat.convertFromUsdat(USDAT_1000, strcAmount, price);
        // No revert = accepted ✓
        assert(stakedUsdat.strcBalance() == strcAmount);
    }

    /// @notice After tightening oracle tolerance, a price just outside the new band reverts.
    function test_oraclePriceTolerance_tighterBandRejectsOutsidePrice() public {
        vm.prank(admin);
        stakedUsdat.setOraclePriceTolerance(300); // 3%

        // 104e8 is 4% above oracle — outside 3% band
        uint256 price = 104e8;
        uint256 strcAmount = _mulDiv(USDAT_1000, 1e8, price);

        vm.prank(processor);
        vm.expectRevert(IStakedUSDat.OraclePriceMismatch.selector);
        stakedUsdat.convertFromUsdat(USDAT_1000, strcAmount, price);
    }
}
