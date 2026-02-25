// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {StakedUSDat} from "../src/StakedUSDat.sol";
import {WithdrawalQueueERC721} from "../src/WithdrawalQueueERC721.sol";
import {StrcPriceOracle} from "../src/StrcPriceOracle.sol";
import {IStrcPriceOracle} from "../src/interfaces/IStrcPriceOracle.sol";
import {IWithdrawalQueueERC721} from "../src/interfaces/IWithdrawalQueueERC721.sol";

// Mock USDat token (6 decimals like real USDat)
contract MockUSDat is Test {
    string public name = "USDat";
    string public symbol = "USDat";
    uint8 public decimals = 6;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    mapping(address => bool) public frozen;

    uint256 public totalSupply;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function burn(address from, uint256 amount) external {
        balanceOf[from] -= amount;
        totalSupply -= amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (allowance[from][msg.sender] != type(uint256).max) {
            allowance[from][msg.sender] -= amount;
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function isFrozen(address account) external view returns (bool) {
        return frozen[account];
    }

    function setFrozen(address account, bool _frozen) external {
        frozen[account] = _frozen;
    }
}

// Mock Chainlink Oracle (8 decimals)
contract MockChainlinkOracle {
    int256 public price;
    uint256 public updatedAt;
    uint8 public decimals = 8;

    function setPrice(int256 _price) external {
        price = _price;
        updatedAt = block.timestamp;
    }

    function refreshTimestamp() external {
        updatedAt = block.timestamp;
    }

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt_, uint80 answeredInRound)
    {
        return (1, price, block.timestamp, updatedAt, 1);
    }
}

contract DecimalValidationTest is Test {
    // Contracts
    MockUSDat public usdat;
    MockChainlinkOracle public chainlinkOracle;
    StrcPriceOracle public strcOracle;
    WithdrawalQueueERC721 public withdrawalQueue;
    StakedUSDat public stakedUsdat;

    // Actors
    address public admin = makeAddr("admin");
    address public processor = makeAddr("processor");
    address public compliance = makeAddr("compliance");
    address public feeRecipient = makeAddr("feeRecipient");
    address public user = makeAddr("user");

    // Constants - STRC price ~$100
    int256 constant STRC_PRICE = 100e8; // $100 with 8 decimals

    // Decimal constants for clarity
    uint256 constant USDAT_DECIMALS = 6;
    uint256 constant STRC_DECIMALS = 6;
    uint256 constant PRICE_DECIMALS = 8;
    uint256 constant SHARES_DECIMALS = 18;

    function setUp() public {
        // Deploy mocks
        usdat = new MockUSDat();
        chainlinkOracle = new MockChainlinkOracle();
        chainlinkOracle.setPrice(STRC_PRICE);

        // Deploy StrcPriceOracle
        strcOracle = new StrcPriceOracle(admin, address(chainlinkOracle));

        // Compute StakedUSDat proxy address for WithdrawalQueue constructor
        address stakedUsdatProxy = _computeCreate1Address(address(this), vm.getNonce(address(this)) + 3);

        // Deploy WithdrawalQueue Implementation
        WithdrawalQueueERC721 wqImpl = new WithdrawalQueueERC721(address(usdat), stakedUsdatProxy);

        // Deploy WithdrawalQueue Proxy
        bytes memory wqInitData =
            abi.encodeCall(WithdrawalQueueERC721.initialize, (admin, stakedUsdatProxy, processor, compliance));
        ERC1967Proxy wqProxy = new ERC1967Proxy(address(wqImpl), wqInitData);
        withdrawalQueue = WithdrawalQueueERC721(address(wqProxy));

        // Deploy StakedUSDat Implementation
        StakedUSDat susdatImpl =
            new StakedUSDat(IStrcPriceOracle(address(strcOracle)), IWithdrawalQueueERC721(address(withdrawalQueue)));

        // Deploy StakedUSDat Proxy
        bytes memory susdatInitData = abi.encodeCall(
            StakedUSDat.initialize, (admin, processor, compliance, feeRecipient, IERC20(address(usdat)))
        );
        ERC1967Proxy susdatProxy = new ERC1967Proxy(address(susdatImpl), susdatInitData);
        stakedUsdat = StakedUSDat(address(susdatProxy));

        // Verify address matches prediction
        assertEq(address(stakedUsdat), stakedUsdatProxy, "StakedUSDat address mismatch");

        // Setup: Give user USDat and deposit into vault
        _setupUserWithDeposit(user, 100_000e6); // 100,000 USDat

        // Setup: Give processor USDat for conversions
        usdat.mint(processor, 1_000_000e6); // 1M USDat
        vm.prank(processor);
        usdat.approve(address(stakedUsdat), type(uint256).max);
        vm.prank(processor);
        usdat.approve(address(withdrawalQueue), type(uint256).max);
    }

    function _setupUserWithDeposit(address _user, uint256 amount) internal {
        usdat.mint(_user, amount);
        vm.startPrank(_user);
        usdat.approve(address(stakedUsdat), amount);
        stakedUsdat.depositWithMinShares(amount, _user, 0);
        vm.stopPrank();
    }

    // ============================================================
    //                    convertFromUsdat TESTS
    // ============================================================

    function test_convertFromUsdat_CorrectDecimals() public {
        // Vault has USDat, processor wants to buy STRC
        // Convert 1000 USDat to 10 STRC at $100/STRC
        uint256 usdatAmount = 1000e6; // 1000 USDat (6 decimals)
        uint256 strcAmount = 10e6; // 10 STRC (6 decimals)
        uint256 price = 100e8; // $100 (8 decimals)

        uint256 vaultUsdatBefore = stakedUsdat.usdatBalance();
        uint256 vaultStrcBefore = stakedUsdat.strcBalance();

        vm.prank(processor);
        stakedUsdat.convertFromUsdat(usdatAmount, strcAmount, price);

        assertEq(stakedUsdat.usdatBalance(), vaultUsdatBefore - usdatAmount, "USDat balance wrong");
        assertEq(stakedUsdat.strcBalance(), vaultStrcBefore + strcAmount, "STRC balance wrong");
    }

    function test_convertFromUsdat_ForgotDecimals_TooSmall() public {
        // MISTAKE: Forgot decimals entirely
        uint256 usdatAmount = 1000; // Should be 1000e6
        uint256 strcAmount = 10; // Should be 10e6
        uint256 price = 100e8;

        // This passes math validation (1000 * 1e8 / 100e8 = 10)
        // But does almost nothing - converts 0.001 USDat
        vm.prank(processor);
        stakedUsdat.convertFromUsdat(usdatAmount, strcAmount, price);

        // Verify it "worked" but did basically nothing
        // This is the risk - no revert, just meaningless transaction
    }

    function test_convertFromUsdat_18Decimals_RevertsInsufficientBalance() public {
        // MISTAKE: Used 18 decimals instead of 6
        uint256 usdatAmount = 1000e18; // Way too big
        uint256 strcAmount = 10e18;
        uint256 price = 100e8;

        // Vault doesn't have 1000e18 USDat (only ~100_000e6)
        vm.prank(processor);
        vm.expectRevert(abi.encodeWithSignature("InsufficientBalance()"));
        stakedUsdat.convertFromUsdat(usdatAmount, strcAmount, price);
    }

    function test_convertFromUsdat_MismatchedDecimals_Reverts() public {
        // MISTAKE: USDat in 6 decimals, STRC in 18 decimals
        uint256 usdatAmount = 1000e6; // Correct
        uint256 strcAmount = 10e18; // Wrong - should be 10e6
        uint256 price = 100e8;

        // expectedStrc = 1000e6 * 1e8 / 100e8 = 10e6
        // strcAmount = 10e18, not within tolerance of 10e6
        vm.prank(processor);
        vm.expectRevert(abi.encodeWithSignature("ExecutionPriceMismatch()"));
        stakedUsdat.convertFromUsdat(usdatAmount, strcAmount, price);
    }

    function test_convertFromUsdat_WrongMath_Reverts() public {
        // Convert 1000 USDat but claim 100 STRC (should be ~10 at $100)
        uint256 usdatAmount = 1000e6;
        uint256 strcAmount = 100e6; // 10x too much
        uint256 price = 100e8;

        // expectedStrc = 1000e6 * 1e8 / 100e8 = 10e6
        // 100e6 is not within 20% tolerance of 10e6
        vm.prank(processor);
        vm.expectRevert(abi.encodeWithSignature("ExecutionPriceMismatch()"));
        stakedUsdat.convertFromUsdat(usdatAmount, strcAmount, price);
    }

    function test_convertFromUsdat_PriceTooFarFromOracle_Reverts() public {
        // Correct amounts but price is way off from oracle
        uint256 usdatAmount = 1000e6;
        uint256 strcAmount = 20e6; // For $50 price
        uint256 price = 50e8; // $50, but oracle says $100

        // Price not within 20% tolerance of oracle price
        vm.prank(processor);
        vm.expectRevert(abi.encodeWithSignature("OraclePriceMismatch()"));
        stakedUsdat.convertFromUsdat(usdatAmount, strcAmount, price);
    }

    function test_convertFromUsdat_PriceWithin20Percent_Succeeds() public {
        // Price at edge of tolerance (oracle $100, using $85 = 15% off)
        uint256 price = 85e8;
        uint256 usdatAmount = 1000e6;
        // strcAmount = 1000e6 * 1e8 / 85e8 ≈ 11.76e6
        uint256 strcAmount = 1176e4; // ~11.76 STRC

        vm.prank(processor);
        stakedUsdat.convertFromUsdat(usdatAmount, strcAmount, price);
    }

    function test_convertFromUsdat_PriceOutside20Percent_Reverts() public {
        // Price outside tolerance (oracle $100, using $70 = 30% off)
        uint256 price = 70e8;
        uint256 usdatAmount = 1000e6;
        uint256 strcAmount = 1428e4; // ~14.28 STRC for $70

        vm.prank(processor);
        vm.expectRevert(abi.encodeWithSignature("OraclePriceMismatch()"));
        stakedUsdat.convertFromUsdat(usdatAmount, strcAmount, price);
    }

    // ============================================================
    //                    convertFromStrc TESTS
    // ============================================================

    function test_convertFromStrc_CorrectDecimals() public {
        // First add some STRC to the vault (this also warps time and refreshes oracle)
        _addStrcToVault(100e6); // 100 STRC

        // Sell 10 STRC for 1000 USDat at $100/STRC
        uint256 strcAmount = 10e6;
        uint256 usdatAmount = 1000e6;
        uint256 price = 100e8;

        uint256 vaultStrcBefore = stakedUsdat.strcBalance();
        uint256 vaultUsdatBefore = stakedUsdat.usdatBalance();

        vm.prank(processor);
        stakedUsdat.convertFromStrc(strcAmount, usdatAmount, price);

        assertEq(stakedUsdat.strcBalance(), vaultStrcBefore - strcAmount, "STRC balance wrong");
        assertEq(stakedUsdat.usdatBalance(), vaultUsdatBefore + usdatAmount, "USDat balance wrong");
    }

    function test_convertFromStrc_ForgotDecimals_TooSmall() public {
        // _addStrcToVault also warps time and refreshes oracle
        _addStrcToVault(100e6);

        // MISTAKE: Forgot decimals
        uint256 strcAmount = 10; // Should be 10e6
        uint256 usdatAmount = 1000; // Should be 1000e6
        uint256 price = 100e8;

        // Math checks pass, but meaningless transaction
        vm.prank(processor);
        stakedUsdat.convertFromStrc(strcAmount, usdatAmount, price);
    }

    function test_convertFromStrc_18Decimals_RevertsInsufficientBalance() public {
        // _addStrcToVault also warps time and refreshes oracle
        _addStrcToVault(100e6); // Only 100e6 STRC

        // MISTAKE: Used 18 decimals
        uint256 strcAmount = 10e18; // Way more than vault has
        uint256 usdatAmount = 1000e18;
        uint256 price = 100e8;

        vm.prank(processor);
        vm.expectRevert(abi.encodeWithSignature("InsufficientBalance()"));
        stakedUsdat.convertFromStrc(strcAmount, usdatAmount, price);
    }

    function test_convertFromStrc_CannotSellUnvested() public {
        // Add STRC as rewards (will be vesting)
        vm.prank(processor);
        stakedUsdat.transferInRewards(100e6);

        // Try to sell immediately (all unvested)
        vm.prank(processor);
        vm.expectRevert(abi.encodeWithSignature("InsufficientBalance()"));
        stakedUsdat.convertFromStrc(50e6, 5000e6, 100e8);
    }

    function test_convertFromStrc_CanSellAfterVesting() public {
        // Add STRC as rewards
        vm.prank(processor);
        stakedUsdat.transferInRewards(100e6);

        // Fast forward past vesting period and refresh oracle
        vm.warp(block.timestamp + 31 days);
        chainlinkOracle.refreshTimestamp();

        // Now can sell
        vm.prank(processor);
        stakedUsdat.convertFromStrc(50e6, 5000e6, 100e8);
    }

    // ============================================================
    //                  transferInRewards TESTS
    // ============================================================

    function test_transferInRewards_CorrectDecimals() public {
        uint256 strcBefore = stakedUsdat.strcBalance();

        vm.prank(processor);
        stakedUsdat.transferInRewards(100e6); // 100 STRC

        assertEq(stakedUsdat.strcBalance(), strcBefore + 100e6);
        assertEq(stakedUsdat.vestingAmount(), 100e6);
    }

    function test_transferInRewards_ForgotDecimals() public {
        // MISTAKE: Forgot decimals - only adds 100 wei of STRC
        vm.prank(processor);
        stakedUsdat.transferInRewards(100);

        // No revert, but added basically nothing
        assertEq(stakedUsdat.strcBalance(), 100);
        assertEq(stakedUsdat.vestingAmount(), 100);
    }

    function test_transferInRewards_18Decimals() public {
        // Using 18 decimals - this will "work" but grossly inflate strcBalance
        vm.prank(processor);
        stakedUsdat.transferInRewards(100e18);

        // This is dangerous - strcBalance is now huge
        assertEq(stakedUsdat.strcBalance(), 100e18);
    }

    function test_transferInRewards_CannotAddWhileVesting() public {
        vm.prank(processor);
        stakedUsdat.transferInRewards(100e6);

        // Try to add more while still vesting
        vm.prank(processor);
        vm.expectRevert(abi.encodeWithSignature("StillVesting()"));
        stakedUsdat.transferInRewards(50e6);
    }

    // ============================================================
    //                   processRequests TESTS
    // ============================================================

    function test_processRequests_CorrectDecimals() public {
        // Setup: Add STRC and let it vest (also warps time and refreshes oracle)
        // Use a large amount so we have enough for withdrawal
        _addStrcToVault(1000e6); // 1000 STRC = $100,000 worth

        // User requests a small redemption - use 10% of their actual balance
        uint256 userBalance = stakedUsdat.balanceOf(user);
        uint256 sharesToRedeem = userBalance / 10;
        vm.prank(user);
        uint256 tokenId = stakedUsdat.requestRedeem(sharesToRedeem, 0);

        // Lock the request
        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = tokenId;
        vm.prank(processor);
        withdrawalQueue.lockRequests(tokenIds);

        // Process with correct decimals
        uint256 expectedUsdat = stakedUsdat.previewRedeem(sharesToRedeem);
        uint256 strcToSell = expectedUsdat / 100; // At $100/STRC

        vm.prank(processor);
        withdrawalQueue.processRequests(
            tokenIds,
            expectedUsdat, // 6 decimals
            strcToSell, // 6 decimals
            100e8 // 8 decimals
        );

        // Verify processed
        assertEq(uint256(withdrawalQueue.getStatus(tokenId)), uint256(IWithdrawalQueueERC721.RequestStatus.Processed));
    }

    function test_processRequests_ForgotDecimals_Reverts() public {
        // _addStrcToVault also warps time and refreshes oracle
        _addStrcToVault(1000e6);

        uint256 userBalance = stakedUsdat.balanceOf(user);
        uint256 sharesToRedeem = userBalance / 10;
        vm.prank(user);
        uint256 tokenId = stakedUsdat.requestRedeem(sharesToRedeem, 0);

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = tokenId;
        vm.prank(processor);
        withdrawalQueue.lockRequests(tokenIds);

        // MISTAKE: Forgot decimals - should be ~5000e6 USDat, 50e6 STRC
        vm.prank(processor);
        vm.expectRevert(abi.encodeWithSignature("ExecutionPriceMismatch()"));
        withdrawalQueue.processRequests(
            tokenIds,
            1000, // Should be ~5000e6 (6 decimals)
            10, // Should be ~50e6 (6 decimals)
            100e8
        );
    }

    function test_processRequests_18Decimals_Reverts() public {
        // _addStrcToVault also warps time and refreshes oracle
        _addStrcToVault(1000e6);

        uint256 userBalance = stakedUsdat.balanceOf(user);
        uint256 sharesToRedeem = userBalance / 10;
        vm.prank(user);
        uint256 tokenId = stakedUsdat.requestRedeem(sharesToRedeem, 0);

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = tokenId;
        vm.prank(processor);
        withdrawalQueue.lockRequests(tokenIds);

        // MISTAKE: 18 decimals instead of 6
        // This will fail on ExceedsVestedBalance since 10e18 STRC >> 1000e6 vested
        vm.prank(processor);
        vm.expectRevert(abi.encodeWithSignature("ExceedsVestedBalance()"));
        withdrawalQueue.processRequests(
            tokenIds,
            5000e18, // Way too big - should be ~5000e6
            50e18, // Way too big - should be ~50e6
            100e8
        );
    }

    function test_processRequests_StrcExceedsVested_Reverts() public {
        // _addStrcToVault also warps time and refreshes oracle
        _addStrcToVault(10e6); // Only 10 STRC vested

        uint256 shares = stakedUsdat.balanceOf(user) / 2;
        vm.prank(user);
        uint256 tokenId = stakedUsdat.requestRedeem(shares, 0);

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = tokenId;
        vm.prank(processor);
        withdrawalQueue.lockRequests(tokenIds);

        uint256 expectedUsdat = stakedUsdat.previewRedeem(shares);

        // Try to sell more STRC than vested
        vm.prank(processor);
        vm.expectRevert(abi.encodeWithSignature("ExceedsVestedBalance()"));
        withdrawalQueue.processRequests(
            tokenIds,
            expectedUsdat,
            100e6, // More than the 10e6 vested
            100e8
        );
    }

    function test_processRequests_SlippageProtection() public {
        // _addStrcToVault also warps time and refreshes oracle
        _addStrcToVault(1000e6);

        uint256 userBalance = stakedUsdat.balanceOf(user);
        uint256 sharesToRedeem = userBalance / 10;
        uint256 expectedValue = stakedUsdat.previewRedeem(sharesToRedeem);

        // User sets minimum they'll accept
        uint256 minAccepted = (expectedValue * 95) / 100; // 95% of expected

        vm.prank(user);
        uint256 tokenId = stakedUsdat.requestRedeem(sharesToRedeem, minAccepted);

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = tokenId;
        vm.prank(processor);
        withdrawalQueue.lockRequests(tokenIds);

        // Try to process with less than minimum
        uint256 tooLowUsdat = minAccepted - 1;
        uint256 strcToSell = tooLowUsdat / 100;

        vm.prank(processor);
        vm.expectRevert(abi.encodeWithSignature("SlippageExceeded()"));
        withdrawalQueue.processRequests(tokenIds, tooLowUsdat, strcToSell, 100e8);
    }

    // ============================================================
    //                    TOLERANCE BOUNDARY TESTS
    // ============================================================

    function test_tolerance_Exactly20Percent_Succeeds() public {
        // Default tolerance is 20% (2000 bps)
        // Oracle price is $100, test at exactly 20% off ($80)
        uint256 price = 80e8;
        uint256 usdatAmount = 1000e6;
        // strcAmount = 1000e6 * 1e8 / 80e8 = 12.5e6
        uint256 strcAmount = 125e5;

        vm.prank(processor);
        stakedUsdat.convertFromUsdat(usdatAmount, strcAmount, price);
    }

    function test_tolerance_Just_Over_20Percent_Reverts() public {
        // Just over 20% off ($79)
        uint256 price = 79e8;
        uint256 usdatAmount = 1000e6;
        uint256 strcAmount = 1265e4; // ~12.65 STRC

        vm.prank(processor);
        vm.expectRevert(abi.encodeWithSignature("OraclePriceMismatch()"));
        stakedUsdat.convertFromUsdat(usdatAmount, strcAmount, price);
    }

    function test_tolerance_ChangeTolerance() public {
        // Admin changes tolerance to 10%
        vm.prank(admin);
        stakedUsdat.setTolerance(1000); // 10%

        // Now 15% off should fail
        uint256 price = 85e8;
        uint256 usdatAmount = 1000e6;
        uint256 strcAmount = 1176e4;

        vm.prank(processor);
        vm.expectRevert(abi.encodeWithSignature("OraclePriceMismatch()"));
        stakedUsdat.convertFromUsdat(usdatAmount, strcAmount, price);
    }

    // ============================================================
    //                       HELPER FUNCTIONS
    // ============================================================

    function _addStrcToVault(uint256 amount) internal {
        // Add STRC by doing a conversion, then wait for vesting
        // First ensure vault has enough USDat
        uint256 usdatNeeded = amount * 100; // At $100/STRC

        if (stakedUsdat.usdatBalance() < usdatNeeded) {
            // Deposit more
            usdat.mint(user, usdatNeeded);
            vm.startPrank(user);
            usdat.approve(address(stakedUsdat), usdatNeeded);
            stakedUsdat.depositWithMinShares(usdatNeeded, user, 0);
            vm.stopPrank();
        }

        vm.prank(processor);
        stakedUsdat.convertFromUsdat(usdatNeeded, amount, 100e8);

        // Fast forward to vest and refresh oracle timestamp
        vm.warp(block.timestamp + 31 days);
        chainlinkOracle.refreshTimestamp();
    }

    function _computeCreate1Address(address deployer, uint256 nonce) internal pure returns (address) {
        if (nonce == 0) {
            return
                address(
                    uint160(uint256(keccak256(abi.encodePacked(bytes1(0xd6), bytes1(0x94), deployer, bytes1(0x80)))))
                );
        } else if (nonce <= 0x7f) {
            return address(
                uint160(
                    uint256(keccak256(abi.encodePacked(bytes1(0xd6), bytes1(0x94), deployer, bytes1(uint8(nonce)))))
                )
            );
        } else if (nonce <= 0xff) {
            return address(
                uint160(
                    uint256(
                        keccak256(abi.encodePacked(bytes1(0xd7), bytes1(0x94), deployer, bytes1(0x81), uint8(nonce)))
                    )
                )
            );
        } else if (nonce <= 0xffff) {
            return address(
                uint160(
                    uint256(
                        keccak256(abi.encodePacked(bytes1(0xd8), bytes1(0x94), deployer, bytes1(0x82), uint16(nonce)))
                    )
                )
            );
        } else {
            return address(
                uint160(
                    uint256(
                        keccak256(abi.encodePacked(bytes1(0xd9), bytes1(0x94), deployer, bytes1(0x83), uint24(nonce)))
                    )
                )
            );
        }
    }
}
