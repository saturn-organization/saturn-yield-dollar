// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {StakedUSDat} from "../../src/v2/StakedUSDat.sol";
import {WithdrawalQueueERC721} from "../../src/v2/WithdrawalQueueERC721.sol";
import {IStakedUSDat} from "../../src/v2/interfaces/IStakedUSDat.sol";
import {IWithdrawalQueueERC721} from "../../src/v2/interfaces/IWithdrawalQueueERC721.sol";

contract SettlementUSDatMock {
    string public constant name = "USDat";
    string public constant symbol = "USDat";
    uint8 public constant decimals = 6;

    uint256 public totalSupply;
    mapping(address account => uint256 balance) public balanceOf;
    mapping(address owner => mapping(address spender => uint256 amount)) public allowance;
    mapping(address account => bool frozen) public isFrozen;

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            allowance[from][msg.sender] = allowed - amount;
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }
}

contract QueueSettlementStakedMock {
    SettlementUSDatMock public immutable USDAT;

    mapping(address account => uint256 balance) public balanceOf;
    mapping(address account => bool blacklisted) public isBlacklisted;
    mapping(uint256 minSharePrice => IStakedUSDat.RedemptionResult result) private _results;
    mapping(uint256 minSharePrice => uint256 payout) private _payouts;

    uint256[] public callShares;
    uint256[] public callLimits;

    constructor(SettlementUSDatMock usdat) {
        USDAT = usdat;
    }

    function createRequest(WithdrawalQueueERC721 queue, address owner, uint256 shares, uint256 minSharePrice)
        external
        returns (uint256 tokenId)
    {
        balanceOf[address(queue)] += shares;
        tokenId = queue.addRequest(owner, shares, minSharePrice);
    }

    function configure(uint256 minSharePrice, IStakedUSDat.RedemptionResult result, uint256 payout) external {
        _results[minSharePrice] = result;
        _payouts[minSharePrice] = payout;
    }

    function redeemQueuedShares(uint256 shares, uint256 minSharePrice)
        external
        returns (IStakedUSDat.RedemptionResult result, uint256 usdat)
    {
        callShares.push(shares);
        callLimits.push(minSharePrice);

        result = _results[minSharePrice];
        if (result != IStakedUSDat.RedemptionResult.Settled) {
            return (result, 0);
        }

        usdat = _payouts[minSharePrice];
        balanceOf[msg.sender] -= shares;
        USDAT.mint(msg.sender, usdat);
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function callCount() external view returns (uint256) {
        return callShares.length;
    }
}

contract VaultQueueHarness {
    function redeemQueuedShares(IStakedUSDat vault, uint256 shares, uint256 minSharePrice)
        external
        returns (IStakedUSDat.RedemptionResult result, uint256 usdat)
    {
        return vault.redeemQueuedShares(shares, minSharePrice);
    }
}

contract RecognizedValueModuleMock {
    uint256 public recognizedValue;

    function setRecognizedValue(uint256 newValue) external {
        recognizedValue = newValue;
    }
}

contract WithdrawalQueueSettlementTest is Test {
    bytes4 private constant ENFORCED_PAUSE_ERROR = bytes4(keccak256("EnforcedPause()"));

    SettlementUSDatMock private usdat;
    QueueSettlementStakedMock private stakedUsdat;
    WithdrawalQueueERC721 private queue;

    address private alice = makeAddr("alice");

    event WithdrawalProcessed(uint256 indexed tokenId, uint256 shares, uint256 usdatAmount);

    function setUp() public {
        usdat = new SettlementUSDatMock();
        stakedUsdat = new QueueSettlementStakedMock(usdat);

        WithdrawalQueueERC721 implementation = new WithdrawalQueueERC721(address(usdat), address(stakedUsdat));
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(implementation), abi.encodeCall(WithdrawalQueueERC721.initialize, (address(this)))
        );

        queue = WithdrawalQueueERC721(address(proxy));
        queue.initializeV2(address(this), address(this), address(this), address(this));
    }

    function test_processRequests_SettlesCompleteRequestAndRetainsShares() public {
        uint256 shares = 12e18;
        uint256 limit = 101;
        uint256 payout = 9e6;
        stakedUsdat.configure(limit, IStakedUSDat.RedemptionResult.Settled, payout);
        uint256 tokenId = stakedUsdat.createRequest(queue, alice, shares, limit);

        uint256[] memory tokenIds = _single(tokenId);

        vm.expectEmit(true, false, false, true, address(queue));
        emit WithdrawalProcessed(tokenId, shares, payout);
        queue.processRequests(tokenIds);

        (uint256 storedShares, uint256 usdatOwed,, uint256 storedLimit, IWithdrawalQueueERC721.RequestStatus status) =
            queue.requests(tokenId);
        assertEq(storedShares, shares);
        assertEq(usdatOwed, payout);
        assertEq(storedLimit, limit);
        assertEq(uint256(status), uint256(IWithdrawalQueueERC721.RequestStatus.Processed));
        assertEq(queue.ownerOf(tokenId), alice);
        assertEq(stakedUsdat.balanceOf(address(queue)), 0);
        assertEq(usdat.balanceOf(address(queue)), payout);
    }

    function test_processRequests_SkipsExpectedFailuresAndContinuesInCallerOrder() public {
        uint256 belowId = _configuredRequest(13e18, 101, IStakedUSDat.RedemptionResult.BelowLimit, 0);
        uint256 insufficientId = _configuredRequest(50e18, 102, IStakedUSDat.RedemptionResult.InsufficientLiquidity, 0);
        uint256 settledId = _configuredRequest(11e18, 103, IStakedUSDat.RedemptionResult.Settled, 10e6);

        uint256[] memory tokenIds = new uint256[](3);
        tokenIds[0] = insufficientId;
        tokenIds[1] = belowId;
        tokenIds[2] = settledId;
        queue.processRequests(tokenIds);

        _assertRequest(insufficientId, 50e18, 0, 102, IWithdrawalQueueERC721.RequestStatus.Requested);
        _assertRequest(belowId, 13e18, 0, 101, IWithdrawalQueueERC721.RequestStatus.Requested);
        _assertRequest(settledId, 11e18, 10e6, 103, IWithdrawalQueueERC721.RequestStatus.Processed);

        assertEq(stakedUsdat.callCount(), 3);
        assertEq(stakedUsdat.callLimits(0), 102);
        assertEq(stakedUsdat.callLimits(1), 101);
        assertEq(stakedUsdat.callLimits(2), 103);
        assertEq(stakedUsdat.balanceOf(address(queue)), 63e18);
        assertEq(usdat.balanceOf(address(queue)), 10e6);
    }

    function testFuzz_processRequests_RetriesSkippedDuplicatesWithoutMutation(
        uint128 rawShares,
        uint8 rawRepeats,
        uint256 limit,
        bool insufficientLiquidity
    ) public {
        uint256 shares = bound(uint256(rawShares), 1, type(uint128).max);
        uint256 repeats = bound(uint256(rawRepeats), 2, 32);
        IStakedUSDat.RedemptionResult result = insufficientLiquidity
            ? IStakedUSDat.RedemptionResult.InsufficientLiquidity
            : IStakedUSDat.RedemptionResult.BelowLimit;
        uint256 tokenId = _configuredRequest(shares, limit, result, 0);
        uint256[] memory tokenIds = new uint256[](repeats);
        for (uint256 i = 0; i < repeats; i++) {
            tokenIds[i] = tokenId;
        }

        queue.processRequests(tokenIds);

        assertEq(stakedUsdat.callCount(), repeats);
        for (uint256 i = 0; i < repeats; i++) {
            assertEq(stakedUsdat.callShares(i), shares);
            assertEq(stakedUsdat.callLimits(i), limit);
        }
        _assertRequest(tokenId, shares, 0, limit, IWithdrawalQueueERC721.RequestStatus.Requested);
        assertEq(queue.ownerOf(tokenId), alice);
        assertEq(stakedUsdat.balanceOf(address(queue)), shares);
        assertEq(usdat.balanceOf(address(queue)), 0);
    }

    function testFuzz_processRequests_SettledDuplicateAlwaysRevertsAndRollsBackSettlement(
        uint128 rawShares,
        uint96 rawPayout,
        uint256 limit
    ) public {
        uint256 shares = bound(uint256(rawShares), 1, type(uint128).max);
        uint256 payout = uint256(rawPayout);
        uint256 tokenId = _configuredRequest(shares, limit, IStakedUSDat.RedemptionResult.Settled, payout);
        uint256[] memory tokenIds = new uint256[](2);
        tokenIds[0] = tokenId;
        tokenIds[1] = tokenId;

        vm.expectRevert(IWithdrawalQueueERC721.RequestNotOpen.selector);
        queue.processRequests(tokenIds);

        assertEq(stakedUsdat.callCount(), 0);
        _assertRequest(tokenId, shares, 0, limit, IWithdrawalQueueERC721.RequestStatus.Requested);
        assertEq(queue.ownerOf(tokenId), alice);
        assertEq(queue.totalSupply(), 1);
        assertEq(stakedUsdat.balanceOf(address(queue)), shares);
        assertEq(usdat.balanceOf(address(queue)), 0);
    }

    function test_processRequests_LaterInvalidStatusRollsBackWholeBatch() public {
        uint256 validId = _configuredRequest(12e18, 101, IStakedUSDat.RedemptionResult.Settled, 9e6);
        uint256 cancelledId = _configuredRequest(13e18, 102, IStakedUSDat.RedemptionResult.Settled, 10e6);
        vm.prank(alice);
        queue.cancelRequest(cancelledId);

        uint256[] memory tokenIds = new uint256[](2);
        tokenIds[0] = validId;
        tokenIds[1] = cancelledId;

        vm.expectRevert(IWithdrawalQueueERC721.RequestNotOpen.selector);
        queue.processRequests(tokenIds);

        assertEq(stakedUsdat.callCount(), 0);
        _assertRequest(validId, 12e18, 0, 101, IWithdrawalQueueERC721.RequestStatus.Requested);
        assertEq(stakedUsdat.balanceOf(address(queue)), 12e18);
        assertEq(usdat.balanceOf(address(queue)), 0);
    }

    function test_processRequests_QueuePauseBlocksBeforeCallingVault() public {
        uint256 tokenId = _configuredRequest(12e18, 101, IStakedUSDat.RedemptionResult.Settled, 9e6);
        queue.pause();

        vm.expectRevert(ENFORCED_PAUSE_ERROR);
        queue.processRequests(_single(tokenId));

        assertEq(stakedUsdat.callCount(), 0);
        _assertRequest(tokenId, 12e18, 0, 101, IWithdrawalQueueERC721.RequestStatus.Requested);
        assertEq(stakedUsdat.balanceOf(address(queue)), 12e18);
        assertEq(usdat.balanceOf(address(queue)), 0);
    }

    function _configuredRequest(uint256 shares, uint256 limit, IStakedUSDat.RedemptionResult result, uint256 payout)
        private
        returns (uint256 tokenId)
    {
        stakedUsdat.configure(limit, result, payout);
        tokenId = stakedUsdat.createRequest(queue, alice, shares, limit);
    }

    function _assertRequest(
        uint256 tokenId,
        uint256 shares,
        uint256 usdatOwed,
        uint256 limit,
        IWithdrawalQueueERC721.RequestStatus expectedStatus
    ) private view {
        (uint256 storedShares, uint256 storedOwed,, uint256 storedLimit, IWithdrawalQueueERC721.RequestStatus status) =
            queue.requests(tokenId);
        assertEq(storedShares, shares);
        assertEq(storedOwed, usdatOwed);
        assertEq(storedLimit, limit);
        assertEq(uint256(status), uint256(expectedStatus));
    }

    function _single(uint256 tokenId) private pure returns (uint256[] memory tokenIds) {
        tokenIds = new uint256[](1);
        tokenIds[0] = tokenId;
    }
}

contract StakedUSDatQueuedRedemptionTest is Test {
    uint256 private constant DEPOSIT = 100e6;
    bytes4 private constant ENFORCED_PAUSE_ERROR = bytes4(keccak256("EnforcedPause()"));

    SettlementUSDatMock private usdat;
    VaultQueueHarness private queueHarness;
    StakedUSDat private vault;

    function setUp() public {
        usdat = new SettlementUSDatMock();
        queueHarness = new VaultQueueHarness();

        StakedUSDat implementation = new StakedUSDat(IWithdrawalQueueERC721(address(queueHarness)));
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(implementation),
            abi.encodeCall(StakedUSDat.initialize, (address(this), address(this), IERC20(address(usdat))))
        );
        vault = StakedUSDat(address(proxy));

        vault.grantRole(vault.PARAMETER_MANAGER_ROLE(), address(this));
        vault.grantRole(vault.MODULE_MANAGER_ROLE(), address(this));
        vault.grantRole(vault.OPERATOR_ROLE(), address(this));
        vault.grantRole(vault.PAUSER_ROLE(), address(this));

        usdat.mint(address(this), DEPOSIT);
        usdat.approve(address(vault), DEPOSIT);
        uint256 shares = vault.depositWithMinShares(DEPOSIT, address(queueHarness), 0);
        assertEq(shares, 100e18);
    }

    function testFuzz_redeemQueuedShares_SettlesEveryShareWithCeilingRoundedFee(uint96 rawShares, uint16 rawFeeBps)
        public
    {
        uint256 shares = bound(uint256(rawShares), 10e18, 100e18);
        uint16 feeBps = uint16(bound(uint256(rawFeeBps), 0, 500));
        vault.setRedemptionFees(feeBps, feeBps);

        uint256 gross = vault.convertToAssets(shares);
        uint256 exactLimit = Math.mulDiv(gross, 1e18, shares);
        uint256 expectedFee = Math.mulDiv(gross, feeBps, vault.BPS_DENOMINATOR(), Math.Rounding.Ceil);
        uint256 expectedPayout = gross - expectedFee;

        (IStakedUSDat.RedemptionResult result, uint256 payout) =
            queueHarness.redeemQueuedShares(vault, shares, exactLimit);

        assertEq(uint256(result), uint256(IStakedUSDat.RedemptionResult.Settled));
        assertEq(payout, expectedPayout);
        assertEq(vault.balanceOf(address(queueHarness)), 100e18 - shares);
        assertEq(vault.totalSupply(), 100e18 - shares);
        assertEq(vault.usdatBalance(), DEPOSIT - expectedPayout);
        assertEq(usdat.balanceOf(address(queueHarness)), expectedPayout);
        assertEq(usdat.balanceOf(address(vault)), DEPOSIT - expectedPayout);
    }

    function test_redeemQueuedShares_BelowLimitDoesNotBurnOrTransfer() public {
        uint256 shares = 40e18;
        uint256 gross = vault.convertToAssets(shares);
        uint256 limit = Math.mulDiv(gross, 1e18, shares) + 1;

        (IStakedUSDat.RedemptionResult result, uint256 payout) = queueHarness.redeemQueuedShares(vault, shares, limit);

        assertEq(uint256(result), uint256(IStakedUSDat.RedemptionResult.BelowLimit));
        assertEq(payout, 0);
        _assertVaultUnchanged();
    }

    function test_redeemQueuedShares_MaximumLimitReturnsBelowLimitWithoutOverflow() public {
        (IStakedUSDat.RedemptionResult result, uint256 payout) =
            queueHarness.redeemQueuedShares(vault, 40e18, type(uint256).max);

        assertEq(uint256(result), uint256(IStakedUSDat.RedemptionResult.BelowLimit));
        assertEq(payout, 0);
        _assertVaultUnchanged();
    }

    function test_redeemQueuedShares_InsufficientLiquidityDoesNotBurnOrTransfer() public {
        RecognizedValueModuleMock module = new RecognizedValueModuleMock();
        module.setRecognizedValue(100e6);
        vault.registerModule(address(module), 10_000);

        uint256 shares = 60e18;
        assertGt(vault.convertToAssets(shares), vault.usdatBalance());

        (IStakedUSDat.RedemptionResult result, uint256 payout) = queueHarness.redeemQueuedShares(vault, shares, 0);

        assertEq(uint256(result), uint256(IStakedUSDat.RedemptionResult.InsufficientLiquidity));
        assertEq(payout, 0);
        _assertVaultUnchanged();
    }

    function test_redeemQueuedShares_PauseBlocksBelowLimitEarlyReturn() public {
        vault.pause();

        vm.expectRevert(ENFORCED_PAUSE_ERROR);
        queueHarness.redeemQueuedShares(vault, 40e18, type(uint256).max);

        _assertVaultUnchanged();
    }

    function test_redeemQueuedShares_RejectsNonQueueCallerAndZeroShares() public {
        vm.expectRevert(IStakedUSDat.OperationNotAllowed.selector);
        vault.redeemQueuedShares(40e18, 0);

        vm.expectRevert(IStakedUSDat.ZeroAmount.selector);
        queueHarness.redeemQueuedShares(vault, 0, 0);
    }

    function test_redeemQueuedShares_SequentialFeeAccretionRaisesExecutionPrice() public {
        vault.setRedemptionFees(500, 500);

        uint256 firstGross = vault.convertToAssets(40e18);
        (IStakedUSDat.RedemptionResult firstResult,) = queueHarness.redeemQueuedShares(vault, 40e18, 0);
        uint256 secondGross = vault.convertToAssets(40e18);

        assertEq(uint256(firstResult), uint256(IStakedUSDat.RedemptionResult.Settled));
        assertGt(secondGross, firstGross);

        uint256 crossedLimit = Math.mulDiv(firstGross, 1e18, 40e18) + 1;
        (IStakedUSDat.RedemptionResult secondResult,) = queueHarness.redeemQueuedShares(vault, 40e18, crossedLimit);

        assertEq(uint256(secondResult), uint256(IStakedUSDat.RedemptionResult.Settled));
        assertEq(vault.balanceOf(address(queueHarness)), 20e18);
    }

    function test_redeemQueuedShares_UsesActiveRedemptionFeeTier() public {
        vault.setRedemptionFees(100, 500);

        uint256 shares = 20e18;
        uint256 baseGross = vault.convertToAssets(shares);
        uint256 expectedBaseFee = Math.mulDiv(baseGross, 100, 10_000, Math.Rounding.Ceil);
        (IStakedUSDat.RedemptionResult baseResult, uint256 basePayout) =
            queueHarness.redeemQueuedShares(vault, shares, 0);

        vault.setElevatedFeeActive(true);
        uint256 elevatedGross = vault.convertToAssets(shares);
        uint256 expectedElevatedFee = Math.mulDiv(elevatedGross, 500, 10_000, Math.Rounding.Ceil);
        (IStakedUSDat.RedemptionResult elevatedResult, uint256 elevatedPayout) =
            queueHarness.redeemQueuedShares(vault, shares, 0);

        assertEq(uint256(baseResult), uint256(IStakedUSDat.RedemptionResult.Settled));
        assertEq(basePayout, baseGross - expectedBaseFee);
        assertEq(uint256(elevatedResult), uint256(IStakedUSDat.RedemptionResult.Settled));
        assertEq(elevatedPayout, elevatedGross - expectedElevatedFee);
        assertEq(usdat.balanceOf(address(queueHarness)), basePayout + elevatedPayout);
        assertEq(vault.usdatBalance(), DEPOSIT - basePayout - elevatedPayout);
    }

    function _assertVaultUnchanged() private view {
        assertEq(vault.balanceOf(address(queueHarness)), 100e18);
        assertEq(vault.totalSupply(), 100e18);
        assertEq(vault.usdatBalance(), DEPOSIT);
        assertEq(usdat.balanceOf(address(queueHarness)), 0);
        assertEq(usdat.balanceOf(address(vault)), DEPOSIT);
    }
}

contract WithdrawalQueueRealSettlementIntegrationTest is Test {
    bytes4 private constant ENFORCED_PAUSE_ERROR = bytes4(keccak256("EnforcedPause()"));
    bytes4 private constant EXCEEDED_MAX_REDEEM_ERROR =
        bytes4(keccak256("ERC4626ExceededMaxRedeem(address,uint256,uint256)"));

    SettlementUSDatMock private usdat;
    StakedUSDat private vault;
    WithdrawalQueueERC721 private queue;

    address private alice = makeAddr("alice");

    function setUp() public {
        usdat = new SettlementUSDatMock();

        uint256 nonce = vm.getNonce(address(this));
        address predictedVaultProxy = vm.computeCreateAddress(address(this), nonce + 3);

        WithdrawalQueueERC721 queueImplementation = new WithdrawalQueueERC721(address(usdat), predictedVaultProxy);
        ERC1967Proxy queueProxy = new ERC1967Proxy(
            address(queueImplementation), abi.encodeCall(WithdrawalQueueERC721.initialize, (address(this)))
        );
        queue = WithdrawalQueueERC721(address(queueProxy));

        StakedUSDat vaultImplementation = new StakedUSDat(IWithdrawalQueueERC721(address(queue)));
        ERC1967Proxy vaultProxy = new ERC1967Proxy(
            address(vaultImplementation),
            abi.encodeCall(StakedUSDat.initialize, (address(this), address(this), IERC20(address(usdat))))
        );
        vault = StakedUSDat(address(vaultProxy));
        assertEq(address(vault), predictedVaultProxy);

        queue.initializeV2(address(this), address(this), address(this), address(this));
        vault.grantRole(vault.MODULE_MANAGER_ROLE(), address(this));
        vault.grantRole(vault.PARAMETER_MANAGER_ROLE(), address(this));

        usdat.mint(alice, 100e6);
        vm.startPrank(alice);
        usdat.approve(address(vault), 100e6);
        vault.depositWithMinShares(100e6, alice, 0);
        vm.stopPrank();
    }

    function test_vaultPauseBlocksRequestCreationAndProcessing() public {
        vm.prank(alice);
        uint256 tokenId = vault.requestRedeem(20e18, 0);

        vault.grantRole(vault.PAUSER_ROLE(), address(this));
        vault.pause();

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(EXCEEDED_MAX_REDEEM_ERROR, alice, 10e18, 0));
        vault.requestRedeem(10e18, 0);

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = tokenId;
        vm.expectRevert(ENFORCED_PAUSE_ERROR);
        queue.processRequests(tokenIds);

        (uint256 shares, uint256 owed,,, IWithdrawalQueueERC721.RequestStatus status) = queue.requests(tokenId);
        assertEq(shares, 20e18);
        assertEq(owed, 0);
        assertEq(uint256(status), uint256(IWithdrawalQueueERC721.RequestStatus.Requested));
        assertEq(queue.nextTokenId(), 1);
        assertEq(queue.ownerOf(tokenId), alice);
        assertEq(vault.balanceOf(alice), 80e18);
        assertEq(vault.balanceOf(address(queue)), 20e18);
        assertEq(vault.totalSupply(), 100e18);
        assertEq(vault.usdatBalance(), 100e6);
        assertEq(usdat.balanceOf(address(queue)), 0);
        assertEq(usdat.balanceOf(address(vault)), 100e6);
    }

    function test_processRequests_RealVaultRetriesInsufficientDuplicateWithoutDoubleSpend() public {
        RecognizedValueModuleMock module = new RecognizedValueModuleMock();
        module.setRecognizedValue(100e6);
        vault.registerModule(address(module), 10_000);

        vm.startPrank(alice);
        uint256 largeId = vault.requestRedeem(60e18, 0);
        uint256 smallId = vault.requestRedeem(40e18, 0);
        vm.stopPrank();

        uint256 expectedSmallPayout = vault.convertToAssets(40e18);
        assertGt(vault.convertToAssets(60e18), vault.usdatBalance());
        assertLe(expectedSmallPayout, vault.usdatBalance());

        uint256[] memory tokenIds = new uint256[](3);
        tokenIds[0] = largeId;
        tokenIds[1] = smallId;
        tokenIds[2] = largeId;
        queue.processRequests(tokenIds);

        (uint256 largeShares, uint256 largeOwed,,, IWithdrawalQueueERC721.RequestStatus largeStatus) =
            queue.requests(largeId);
        (uint256 smallShares, uint256 smallOwed,,, IWithdrawalQueueERC721.RequestStatus smallStatus) =
            queue.requests(smallId);

        assertEq(largeShares, 60e18);
        assertEq(largeOwed, 0);
        assertEq(uint256(largeStatus), uint256(IWithdrawalQueueERC721.RequestStatus.Requested));
        assertEq(smallShares, 40e18);
        assertEq(smallOwed, expectedSmallPayout);
        assertEq(uint256(smallStatus), uint256(IWithdrawalQueueERC721.RequestStatus.Processed));

        assertEq(queue.ownerOf(largeId), alice);
        assertEq(queue.ownerOf(smallId), alice);
        assertEq(vault.balanceOf(address(queue)), 60e18);
        assertEq(vault.totalSupply(), 60e18);
        assertEq(usdat.balanceOf(address(queue)), expectedSmallPayout);
        assertEq(vault.usdatBalance(), 100e6 - expectedSmallPayout);
        assertEq(usdat.balanceOf(address(vault)), 100e6 - expectedSmallPayout);
    }

    function test_processRequests_RealVaultSettledDuplicateRollsBackAcrossBothContracts() public {
        vm.prank(alice);
        uint256 tokenId = vault.requestRedeem(20e18, 0);

        uint256[] memory tokenIds = new uint256[](2);
        tokenIds[0] = tokenId;
        tokenIds[1] = tokenId;

        vm.expectRevert(IWithdrawalQueueERC721.RequestNotOpen.selector);
        queue.processRequests(tokenIds);

        (uint256 shares, uint256 owed,,, IWithdrawalQueueERC721.RequestStatus status) = queue.requests(tokenId);
        assertEq(shares, 20e18);
        assertEq(owed, 0);
        assertEq(uint256(status), uint256(IWithdrawalQueueERC721.RequestStatus.Requested));
        assertEq(queue.ownerOf(tokenId), alice);

        assertEq(vault.balanceOf(alice), 80e18);
        assertEq(vault.balanceOf(address(queue)), 20e18);
        assertEq(vault.totalSupply(), 100e18);
        assertEq(vault.usdatBalance(), 100e6);
        assertEq(usdat.balanceOf(address(queue)), 0);
        assertEq(usdat.balanceOf(address(vault)), 100e6);
    }

    function test_processRequests_RealVaultRetriesBelowLimitThenSettlesOnceAfterFeeAccrual() public {
        vault.setRedemptionFees(500, 500);
        uint256 repricedRequestShares = 40e18;
        uint256 fundingRequestShares = 20e18;
        uint256 initialPrice = Math.mulDiv(vault.convertToAssets(repricedRequestShares), 1e18, repricedRequestShares);

        vm.startPrank(alice);
        uint256 repricedId = vault.requestRedeem(repricedRequestShares, initialPrice + 1);
        uint256 fundingId = vault.requestRedeem(fundingRequestShares, 0);
        vm.stopPrank();

        uint256[] memory tokenIds = new uint256[](3);
        tokenIds[0] = repricedId;
        tokenIds[1] = fundingId;
        tokenIds[2] = repricedId;
        queue.processRequests(tokenIds);

        (uint256 repricedShares, uint256 repricedOwed,,, IWithdrawalQueueERC721.RequestStatus repricedStatus) =
            queue.requests(repricedId);
        (uint256 fundingShares, uint256 fundingOwed,,, IWithdrawalQueueERC721.RequestStatus fundingStatus) =
            queue.requests(fundingId);

        assertEq(repricedShares, repricedRequestShares);
        assertEq(fundingShares, fundingRequestShares);
        assertEq(uint256(repricedStatus), uint256(IWithdrawalQueueERC721.RequestStatus.Processed));
        assertEq(uint256(fundingStatus), uint256(IWithdrawalQueueERC721.RequestStatus.Processed));
        assertGt(repricedOwed, fundingOwed);

        uint256 totalOwed = repricedOwed + fundingOwed;
        assertEq(vault.balanceOf(address(queue)), 0);
        assertEq(vault.balanceOf(alice), 40e18);
        assertEq(vault.totalSupply(), 40e18);
        assertEq(usdat.balanceOf(address(queue)), totalOwed);
        assertEq(vault.usdatBalance(), 100e6 - totalOwed);
        assertEq(usdat.balanceOf(address(vault)), 100e6 - totalOwed);
        assertEq(usdat.balanceOf(address(vault)) + usdat.balanceOf(address(queue)), 100e6);
    }
}
