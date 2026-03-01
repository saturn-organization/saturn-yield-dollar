// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {StakedUSDat} from "../src/StakedUSDat.sol";
import {WithdrawalQueueERC721} from "../src/WithdrawalQueueERC721.sol";
import {StrcPriceOracle} from "../src/StrcPriceOracle.sol";
import {IStrcPriceOracle} from "../src/interfaces/IStrcPriceOracle.sol";
import {IWithdrawalQueueERC721} from "../src/interfaces/IWithdrawalQueueERC721.sol";

// Mock USDat token (6 decimals)
contract MockUSDat {
    string public name = "USDat";
    string public symbol = "USDat";
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

    function isFrozen(address) external pure returns (bool) {
        return false;
    }
}

// Mock Chainlink Oracle
contract MockOracle {
    int256 public constant PRICE = 100e8;
    uint8 public constant decimals = 8;

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, PRICE, block.timestamp, block.timestamp, 1);
    }
}

contract DecimalOffsetTest is Test {
    MockUSDat public usdat;
    MockOracle public chainlinkOracle;
    StrcPriceOracle public strcOracle;
    WithdrawalQueueERC721 public withdrawalQueue;
    StakedUSDat public stakedUsdat;

    address public admin = makeAddr("admin");
    address public processor = makeAddr("processor");
    address public compliance = makeAddr("compliance");
    address public feeRecipient = makeAddr("feeRecipient");

    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");

    function setUp() public {
        // Deploy mocks
        usdat = new MockUSDat();
        chainlinkOracle = new MockOracle();

        // Deploy StrcPriceOracle
        strcOracle = new StrcPriceOracle(admin, address(chainlinkOracle));

        // Compute StakedUSDat proxy address
        uint256 nonce = vm.getNonce(address(this));
        address stakedUsdatProxy = computeCreateAddress(address(this), nonce + 3);

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

        // Verify address prediction
        assertEq(address(stakedUsdat), stakedUsdatProxy, "Address mismatch");
    }

    function test_DecimalOffset_FirstAndSecondDeposit() public {
        // === Setup ===
        uint256 aliceDeposit = 100e6; // 100 USDat
        uint256 bobDeposit = 50e6; // 50 USDat

        usdat.mint(alice, aliceDeposit);
        usdat.mint(bob, bobDeposit);

        // === First Deposit: Alice deposits 100 USDat ===
        vm.startPrank(alice);
        usdat.approve(address(stakedUsdat), aliceDeposit);
        uint256 aliceShares = stakedUsdat.depositWithMinShares(aliceDeposit, alice, 0);
        vm.stopPrank();

        // Check Alice's shares
        // With offset=6: shares = 100e6 * 1e6 / 1 = 100e12 (before fee)
        // After 0.1% fee: 99.9e6 assets -> ~99.9e12 shares
        uint256 expectedAliceShares = 999e11; // 99.9e12
        assertApproxEqRel(aliceShares, expectedAliceShares, 1e15, "Alice shares wrong"); // 0.1% tolerance

        // Check displayed balance
        // 99.9e12 raw / 1e18 decimals = 0.0000999 sUSDat displayed
        uint256 aliceBalance = stakedUsdat.balanceOf(alice);
        assertApproxEqRel(aliceBalance, 999e11, 1e15, "Alice balance wrong");

        // Log for visibility
        emit log_named_uint("Alice deposited (USDat)", aliceDeposit / 1e6);
        emit log_named_uint("Alice shares (raw)", aliceShares);
        emit log_named_uint("Alice shares (displayed)", aliceShares / 1e18);

        // === Second Deposit: Bob deposits 50 USDat ===
        vm.startPrank(bob);
        usdat.approve(address(stakedUsdat), bobDeposit);
        uint256 bobShares = stakedUsdat.depositWithMinShares(bobDeposit, bob, 0);
        vm.stopPrank();

        // Check Bob's shares
        // With offset=6 and existing supply:
        // shares = 50e6 * (99.9e12 + 1e6) / (99.9e6 + 1) ≈ 50e12 (before fee)
        // After 0.1% fee: ~49.95e12 shares
        uint256 expectedBobShares = 4995e10; // ~49.95e12
        assertApproxEqRel(bobShares, expectedBobShares, 1e15, "Bob shares wrong");

        // Check displayed balance
        // ~49.95e12 raw / 1e18 decimals = ~0.00004995 sUSDat displayed
        uint256 bobBalance = stakedUsdat.balanceOf(bob);
        assertApproxEqRel(bobBalance, 4995e10, 1e15, "Bob balance wrong");

        // Log for visibility
        emit log_named_uint("Bob deposited (USDat)", bobDeposit / 1e6);
        emit log_named_uint("Bob shares (raw)", bobShares);
        emit log_named_uint("Bob shares (displayed)", bobShares / 1e18);

        // === Verify totals ===
        uint256 totalAssets = stakedUsdat.totalAssets();
        uint256 totalSupply = stakedUsdat.totalSupply();

        // Note: totalAssets is slightly less due to deposit fee (0.1% default)
        emit log_named_uint("Total assets (raw USDat)", totalAssets);
        emit log_named_uint("Total supply (raw shares)", totalSupply);

        // === Verify 1:1 ratio maintained ===
        // Each user's share of the pool should match their deposit ratio
        uint256 aliceSharePercent = (aliceBalance * 100) / totalSupply;
        uint256 bobSharePercent = (bobBalance * 100) / totalSupply;

        // Alice deposited 100, Bob deposited 50 -> Alice should have ~66.6%, Bob ~33.3%
        assertApproxEqAbs(aliceSharePercent, 66, 1, "Alice share percent wrong");
        assertApproxEqAbs(bobSharePercent, 33, 1, "Bob share percent wrong");

        emit log_named_uint("Alice share of pool (%)", aliceSharePercent);
        emit log_named_uint("Bob share of pool (%)", bobSharePercent);
    }
}
