// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC721Enumerable} from "@openzeppelin/contracts/token/ERC721/extensions/IERC721Enumerable.sol";
import {IERC721Metadata} from "@openzeppelin/contracts/token/ERC721/extensions/IERC721Metadata.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {WithdrawalQueueERC721} from "../../../src/v2/WithdrawalQueueERC721.sol";
import {IWithdrawalQueueERC721} from "../../../src/v2/interfaces/IWithdrawalQueueERC721.sol";

contract TerminalTokenMock is IERC721Receiver {
    enum TransferMode {
        Normal,
        Revert,
        ReturnFalse
    }

    error TokenPaused();
    error TransferFailed();

    mapping(address account => uint256 balance) public balanceOf;
    mapping(address account => bool restricted) private _blacklisted;
    mapping(address account => bool restricted) private _frozen;

    uint256 public totalSupply;
    uint8 public marketMode;
    bool public paused;
    address public recoveryAddress;
    TransferMode public transferMode;

    address public callbackTarget;
    bytes public callbackData;
    bool public callbackAttempted;
    bool public callbackSucceeded;
    bytes4 public callbackRevertSelector;

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        if (paused) revert TokenPaused();
        if (transferMode == TransferMode.Revert) revert TransferFailed();
        if (transferMode == TransferMode.ReturnFalse) return false;

        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;

        address target = callbackTarget;
        if (target != address(0)) {
            bytes memory data = callbackData;
            callbackTarget = address(0);
            delete callbackData;
            callbackAttempted = true;

            (callbackSucceeded, data) = target.call(data);
            if (!callbackSucceeded && data.length >= 4) {
                bytes4 selector;
                assembly ("memory-safe") {
                    selector := mload(add(data, 0x20))
                }
                callbackRevertSelector = selector;
            }
        }

        return true;
    }

    function setBlacklisted(address account, bool restricted) external {
        _blacklisted[account] = restricted;
    }

    function setFrozen(address account, bool restricted) external {
        _frozen[account] = restricted;
    }

    function isBlacklisted(address account) external view returns (bool) {
        return _blacklisted[account];
    }

    function isFrozen(address account) external view returns (bool) {
        return _frozen[account];
    }

    function setPaused(bool newPaused) external {
        paused = newPaused;
    }

    function setMarketMode(uint8 newMarketMode) external {
        marketMode = newMarketMode;
    }

    function setRecoveryAddress(address newRecoveryAddress) external {
        recoveryAddress = newRecoveryAddress;
    }

    function setTransferMode(TransferMode newMode) external {
        transferMode = newMode;
    }

    function setCallback(address target, bytes calldata data) external {
        callbackTarget = target;
        callbackData = data;
        callbackAttempted = false;
        callbackSucceeded = false;
        callbackRevertSelector = bytes4(0);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }
}

contract WithdrawalQueueLifecycleTest is Test {
    uint256 private constant REQUESTS_SLOT = 0;
    bytes4 private constant ACCESS_CONTROL_UNAUTHORIZED_ERROR =
        bytes4(keccak256("AccessControlUnauthorizedAccount(address,bytes32)"));
    bytes4 private constant ENFORCED_PAUSE_ERROR = bytes4(keccak256("EnforcedPause()"));
    bytes4 private constant REENTRANCY_ERROR = bytes4(keccak256("ReentrancyGuardReentrantCall()"));

    TerminalTokenMock private usdat;
    TerminalTokenMock private stakedUsdat;
    WithdrawalQueueERC721 private queue;

    address private alice = makeAddr("alice");
    address private bob = makeAddr("bob");
    address private carol = makeAddr("carol");

    event Claimed(uint256 indexed tokenId, address indexed user, uint256 usdatAmount);
    event RequestCancelled(uint256 indexed tokenId, address indexed user, uint256 shares);
    event RequestSeized(uint256 indexed tokenId, address indexed user, address indexed to);
    event FundsSeized(uint256 indexed tokenId, address indexed user, uint256 usdatAmount, address indexed to);

    function setUp() public {
        usdat = new TerminalTokenMock();
        stakedUsdat = new TerminalTokenMock();

        WithdrawalQueueERC721 implementation = new WithdrawalQueueERC721(address(usdat), address(stakedUsdat));
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(implementation), abi.encodeCall(WithdrawalQueueERC721.initialize, (address(this)))
        );

        queue = WithdrawalQueueERC721(address(proxy));
        queue.initializeV2(address(this), address(this), address(this), address(this));
        stakedUsdat.setRecoveryAddress(bob);
    }

    function test_supportsInterface_AdvertisesQueueAndInheritedInterfaces() public view {
        bytes4 queueInterfaceId = type(IWithdrawalQueueERC721).interfaceId;
        assertEq(queueInterfaceId, bytes4(0xcf58cc7c));
        assertTrue(queue.supportsInterface(queueInterfaceId));
        assertTrue(queue.supportsInterface(type(IERC165).interfaceId));
        assertTrue(queue.supportsInterface(type(IERC721).interfaceId));
        assertTrue(queue.supportsInterface(type(IERC721Metadata).interfaceId));
        assertTrue(queue.supportsInterface(type(IERC721Enumerable).interfaceId));
        assertTrue(queue.supportsInterface(type(IAccessControl).interfaceId));
        assertFalse(queue.supportsInterface(0xffffffff));
    }

    function test_addRequest_RejectsRestrictedUserByEitherToken() public {
        stakedUsdat.setBlacklisted(alice, true);

        vm.prank(address(stakedUsdat));
        vm.expectRevert(IWithdrawalQueueERC721.AddressBlacklisted.selector);
        queue.addRequest(alice, 12e18, 1);

        stakedUsdat.setBlacklisted(alice, false);
        usdat.setFrozen(alice, true);

        vm.prank(address(stakedUsdat));
        vm.expectRevert(IWithdrawalQueueERC721.AddressBlacklisted.selector);
        queue.addRequest(alice, 12e18, 1);

        assertEq(queue.nextTokenId(), 0);
        assertEq(queue.totalSupply(), 0);
    }

    function test_nftTransfer_RejectsRestrictedSenderAndRecipientByEitherToken() public {
        uint256 tokenId = _createRequest(alice, 12e18, 1);

        stakedUsdat.setBlacklisted(alice, true);
        vm.prank(alice);
        vm.expectRevert(IWithdrawalQueueERC721.AddressBlacklisted.selector);
        queue.transferFrom(alice, bob, tokenId);

        stakedUsdat.setBlacklisted(alice, false);
        usdat.setFrozen(alice, true);
        vm.prank(alice);
        vm.expectRevert(IWithdrawalQueueERC721.AddressBlacklisted.selector);
        queue.safeTransferFrom(alice, bob, tokenId);

        usdat.setFrozen(alice, false);
        stakedUsdat.setBlacklisted(bob, true);
        vm.prank(alice);
        vm.expectRevert(IWithdrawalQueueERC721.AddressBlacklisted.selector);
        queue.transferFrom(alice, bob, tokenId);

        stakedUsdat.setBlacklisted(bob, false);
        usdat.setFrozen(bob, true);
        vm.prank(alice);
        vm.expectRevert(IWithdrawalQueueERC721.AddressBlacklisted.selector);
        queue.safeTransferFrom(alice, bob, tokenId, hex"1234");

        assertEq(queue.ownerOf(tokenId), alice);
    }

    function test_getUserRequests_ReturnsAllCurrentlyOwnedRequests() public {
        uint256 requestedId = _createRequest(alice, 12e18, 1);
        uint256 processedId = _createRequest(alice, 13e18, 1);
        uint256 bobId = _createRequest(bob, 14e18, 1);
        _makeProcessed(processedId, 9e6);

        uint256[] memory aliceIds = IWithdrawalQueueERC721(address(queue)).getUserRequests(alice);
        assertEq(aliceIds.length, 2);
        assertTrue(
            (aliceIds[0] == requestedId && aliceIds[1] == processedId)
                || (aliceIds[0] == processedId && aliceIds[1] == requestedId)
        );

        vm.prank(alice);
        queue.transferFrom(alice, bob, requestedId);

        aliceIds = IWithdrawalQueueERC721(address(queue)).getUserRequests(alice);
        assertEq(aliceIds.length, 1);
        assertEq(aliceIds[0], processedId);

        uint256[] memory bobIds = IWithdrawalQueueERC721(address(queue)).getUserRequests(bob);
        assertEq(bobIds.length, 2);
        assertTrue((bobIds[0] == bobId && bobIds[1] == requestedId) || (bobIds[0] == requestedId && bobIds[1] == bobId));

        vm.prank(alice);
        queue.claim(processedId);

        aliceIds = IWithdrawalQueueERC721(address(queue)).getUserRequests(alice);
        assertEq(aliceIds.length, 0);
    }

    function testFuzz_cancelRequest_ReturnsAllSharesAndPreservesTerminalRecord(uint128 rawShares, uint256 limit)
        public
    {
        uint256 shares = bound(uint256(rawShares), 1, type(uint128).max);
        uint256 tokenId = _createRequest(alice, shares, limit);
        (,, uint256 timestamp,,) = queue.requests(tokenId);

        uint256 supplyBefore = stakedUsdat.totalSupply();
        uint256 usdatBefore = usdat.balanceOf(alice);

        vm.expectEmit(true, true, false, true, address(queue));
        emit RequestCancelled(tokenId, alice, shares);
        vm.prank(alice);
        queue.cancelRequest(tokenId);

        assertEq(stakedUsdat.balanceOf(address(queue)), 0);
        assertEq(stakedUsdat.balanceOf(alice), shares);
        assertEq(stakedUsdat.totalSupply(), supplyBefore);
        assertEq(usdat.balanceOf(alice), usdatBefore);
        assertEq(queue.totalSupply(), 0);

        (
            uint256 storedShares,
            uint256 usdatOwed,
            uint256 storedTimestamp,
            uint256 storedLimit,
            IWithdrawalQueueERC721.RequestStatus status
        ) = queue.requests(tokenId);
        assertEq(storedShares, shares);
        assertEq(usdatOwed, 0);
        assertEq(storedTimestamp, timestamp);
        assertEq(storedLimit, limit);
        assertEq(uint256(status), uint256(IWithdrawalQueueERC721.RequestStatus.Cancelled));

        vm.prank(alice);
        vm.expectRevert();
        queue.cancelRequest(tokenId);
    }

    function testFuzz_claim_PaysFixedAmountOnceAndPreservesTerminalRecord(uint128 rawAmount, uint256 limit) public {
        uint256 amount = uint256(rawAmount);
        uint256 shares = 37e18;
        uint256 tokenId = _createRequest(alice, shares, limit);
        (,, uint256 timestamp,,) = queue.requests(tokenId);
        _makeProcessed(tokenId, amount);

        uint256 stakedBalanceBefore = stakedUsdat.balanceOf(address(queue));

        vm.expectEmit(true, true, false, true, address(queue));
        emit Claimed(tokenId, alice, amount);
        vm.prank(alice);
        uint256 claimed = queue.claim(tokenId);

        assertEq(claimed, amount);
        assertEq(usdat.balanceOf(alice), amount);
        assertEq(usdat.balanceOf(address(queue)), 0);
        assertEq(stakedUsdat.balanceOf(address(queue)), stakedBalanceBefore);
        assertEq(queue.totalSupply(), 0);

        (
            uint256 storedShares,
            uint256 usdatOwed,
            uint256 storedTimestamp,
            uint256 storedLimit,
            IWithdrawalQueueERC721.RequestStatus status
        ) = queue.requests(tokenId);
        assertEq(storedShares, shares);
        assertEq(usdatOwed, amount);
        assertEq(storedTimestamp, timestamp);
        assertEq(storedLimit, limit);
        assertEq(uint256(status), uint256(IWithdrawalQueueERC721.RequestStatus.Claimed));

        vm.prank(alice);
        vm.expectRevert();
        queue.claim(tokenId);
        assertEq(usdat.balanceOf(alice), amount);
    }

    function test_cancelRequest_PaysCurrentOwner() public {
        uint256 tokenId = _createRequest(alice, 12e18, 1);

        vm.prank(alice);
        queue.transferFrom(alice, bob, tokenId);
        vm.prank(bob);
        queue.cancelRequest(tokenId);

        assertEq(stakedUsdat.balanceOf(bob), 12e18);
        assertEq(stakedUsdat.balanceOf(alice), 0);
    }

    function test_claim_PaysCurrentOwner() public {
        uint256 tokenId = _createRequest(alice, 12e18, 1);
        _makeProcessed(tokenId, 9e6);

        vm.prank(alice);
        queue.transferFrom(alice, bob, tokenId);
        vm.prank(bob);
        queue.claim(tokenId);

        assertEq(usdat.balanceOf(bob), 9e6);
        assertEq(usdat.balanceOf(alice), 0);
    }

    function test_ApprovedOperatorCannotCancelOrClaim() public {
        uint256 cancelId = _createRequest(alice, 12e18, 1);
        uint256 claimId = _createRequest(alice, 13e18, 1);
        _makeProcessed(claimId, 9e6);

        vm.startPrank(alice);
        queue.approve(bob, cancelId);
        queue.approve(bob, claimId);
        vm.stopPrank();

        vm.startPrank(bob);
        vm.expectRevert(IWithdrawalQueueERC721.NotOwner.selector);
        queue.cancelRequest(cancelId);
        vm.expectRevert(IWithdrawalQueueERC721.NotOwner.selector);
        queue.claim(claimId);
        vm.stopPrank();
    }

    function test_cancelRequest_RejectsEveryNonRequestedStatus() public {
        for (uint256 rawStatus = 0; rawStatus <= uint256(IWithdrawalQueueERC721.RequestStatus.Cancelled); rawStatus++) {
            if (rawStatus == uint256(IWithdrawalQueueERC721.RequestStatus.Requested)) continue;

            uint256 tokenId = _createRequest(alice, 10e18 + rawStatus, rawStatus);
            _setStatus(tokenId, IWithdrawalQueueERC721.RequestStatus(rawStatus));

            vm.prank(alice);
            vm.expectRevert(IWithdrawalQueueERC721.RequestNotOpen.selector);
            queue.cancelRequest(tokenId);
        }
    }

    function test_claim_RejectsEveryNonProcessedStatus() public {
        for (uint256 rawStatus = 0; rawStatus <= uint256(IWithdrawalQueueERC721.RequestStatus.Cancelled); rawStatus++) {
            if (rawStatus == uint256(IWithdrawalQueueERC721.RequestStatus.Processed)) continue;

            uint256 tokenId = _createRequest(alice, 10e18 + rawStatus, rawStatus);
            _setRequestWord(tokenId, 1, 7e6);
            _setStatus(tokenId, IWithdrawalQueueERC721.RequestStatus(rawStatus));

            vm.prank(alice);
            vm.expectRevert(IWithdrawalQueueERC721.RequestNotProcessed.selector);
            queue.claim(tokenId);
        }
    }

    function test_sUsdatBlacklistBlocksCancellationAndClaim() public {
        uint256 cancelId = _createRequest(alice, 12e18, 1);
        uint256 claimId = _createRequest(alice, 13e18, 1);
        _makeProcessed(claimId, 9e6);
        stakedUsdat.setBlacklisted(alice, true);

        _expectRestrictedOwnerReverts(cancelId, claimId);
    }

    function test_usdatFreezeBlocksCancellationAndClaim() public {
        uint256 cancelId = _createRequest(alice, 12e18, 1);
        uint256 claimId = _createRequest(alice, 13e18, 1);
        _makeProcessed(claimId, 9e6);
        usdat.setFrozen(alice, true);

        _expectRestrictedOwnerReverts(cancelId, claimId);
    }

    function test_queuePauseBlocksCancellationAndClaim() public {
        uint256 cancelId = _createRequest(alice, 12e18, 1);
        uint256 claimId = _createRequest(alice, 13e18, 1);
        _makeProcessed(claimId, 9e6);
        vm.startPrank(alice);
        queue.approve(bob, cancelId);
        queue.approve(bob, claimId);
        vm.stopPrank();
        queue.pause();

        vm.startPrank(alice);
        vm.expectRevert(ENFORCED_PAUSE_ERROR);
        queue.cancelRequest(cancelId);
        vm.expectRevert(ENFORCED_PAUSE_ERROR);
        queue.claim(claimId);
        vm.stopPrank();

        assertEq(queue.ownerOf(cancelId), alice);
        assertEq(queue.ownerOf(claimId), alice);
        assertEq(queue.getApproved(cancelId), bob);
        assertEq(queue.getApproved(claimId), bob);
        assertEq(queue.totalSupply(), 2);
        assertEq(stakedUsdat.balanceOf(address(queue)), 25e18);
        assertEq(stakedUsdat.balanceOf(alice), 0);
        assertEq(usdat.balanceOf(address(queue)), 9e6);
        assertEq(usdat.balanceOf(alice), 0);
        (,,,, IWithdrawalQueueERC721.RequestStatus cancelStatus) = queue.requests(cancelId);
        (,,,, IWithdrawalQueueERC721.RequestStatus claimStatus) = queue.requests(claimId);
        assertEq(uint256(cancelStatus), uint256(IWithdrawalQueueERC721.RequestStatus.Requested));
        assertEq(uint256(claimStatus), uint256(IWithdrawalQueueERC721.RequestStatus.Processed));
    }

    function test_queuePauseBlocksCreationLimitUpdatesAndNftTransfers() public {
        uint256 tokenId = _createRequest(alice, 12e18, 1);
        vm.prank(alice);
        queue.approve(bob, tokenId);
        uint256 nextTokenId = queue.nextTokenId();
        queue.pause();

        vm.prank(address(stakedUsdat));
        vm.expectRevert(ENFORCED_PAUSE_ERROR);
        queue.addRequest(bob, 13e18, 2);

        vm.prank(alice);
        vm.expectRevert(ENFORCED_PAUSE_ERROR);
        queue.updateMinSharePrice(tokenId, 2);
        vm.prank(bob);
        vm.expectRevert(ENFORCED_PAUSE_ERROR);
        queue.transferFrom(alice, bob, tokenId);

        assertEq(queue.nextTokenId(), nextTokenId);
        assertEq(queue.ownerOf(tokenId), alice);
        assertEq(queue.getApproved(tokenId), bob);
        (,,, uint256 limit,) = queue.requests(tokenId);
        assertEq(limit, 1);
    }

    function test_vaultPauseRollsBackCancellationButAllowsFundedClaim() public {
        uint256 cancelId = _createRequest(alice, 12e18, 1);
        uint256 claimId = _createRequest(alice, 13e18, 1);
        _makeProcessed(claimId, 9e6);
        vm.prank(alice);
        queue.approve(bob, cancelId);
        stakedUsdat.setPaused(true);

        vm.prank(alice);
        vm.expectRevert(TerminalTokenMock.TokenPaused.selector);
        queue.cancelRequest(cancelId);

        assertEq(queue.ownerOf(cancelId), alice);
        assertEq(queue.getApproved(cancelId), bob);
        assertEq(queue.totalSupply(), 2);
        assertEq(stakedUsdat.balanceOf(address(queue)), 25e18);
        assertEq(stakedUsdat.balanceOf(alice), 0);
        (,,,, IWithdrawalQueueERC721.RequestStatus cancelStatus) = queue.requests(cancelId);
        assertEq(uint256(cancelStatus), uint256(IWithdrawalQueueERC721.RequestStatus.Requested));

        vm.prank(alice);
        queue.claim(claimId);

        assertEq(usdat.balanceOf(alice), 9e6);
        (,,,, IWithdrawalQueueERC721.RequestStatus claimStatus) = queue.requests(claimId);
        assertEq(uint256(claimStatus), uint256(IWithdrawalQueueERC721.RequestStatus.Claimed));
    }

    function test_vaultPauseAllowsLimitUpdateAndRequestNftTransfer() public {
        uint256 tokenId = _createRequest(alice, 12e18, 1);
        stakedUsdat.setPaused(true);

        vm.startPrank(alice);
        queue.updateMinSharePrice(tokenId, 2);
        queue.transferFrom(alice, bob, tokenId);
        vm.stopPrank();

        (,,, uint256 limit,) = queue.requests(tokenId);
        assertEq(limit, 2);
        assertEq(queue.ownerOf(tokenId), bob);
    }

    function test_restrictedModeAllowsCancellationAndClaim() public {
        uint256 cancelId = _createRequest(alice, 12e18, 1);
        uint256 claimId = _createRequest(alice, 13e18, 1);
        _makeProcessed(claimId, 9e6);
        stakedUsdat.setMarketMode(2);

        vm.startPrank(alice);
        queue.cancelRequest(cancelId);
        queue.claim(claimId);
        vm.stopPrank();

        assertEq(stakedUsdat.balanceOf(alice), 12e18);
        assertEq(usdat.balanceOf(alice), 9e6);
    }

    function test_cancelRequest_TransferFailureModesRollBackAllState() public {
        for (uint256 rawMode = 1; rawMode <= 2; rawMode++) {
            uint256 tokenId = _createRequest(alice, 12e18, 1);
            vm.prank(alice);
            queue.approve(bob, tokenId);
            stakedUsdat.setTransferMode(TerminalTokenMock.TransferMode(rawMode));

            vm.prank(alice);
            vm.expectRevert();
            queue.cancelRequest(tokenId);

            assertEq(queue.ownerOf(tokenId), alice);
            assertEq(queue.getApproved(tokenId), bob);
            assertEq(queue.totalSupply(), rawMode);
            assertEq(stakedUsdat.balanceOf(address(queue)), 12e18 * rawMode);
            assertEq(stakedUsdat.balanceOf(alice), 0);
            (,,,, IWithdrawalQueueERC721.RequestStatus status) = queue.requests(tokenId);
            assertEq(uint256(status), uint256(IWithdrawalQueueERC721.RequestStatus.Requested));
        }
    }

    function test_claim_TransferFailureModesRollBackAllState() public {
        for (uint256 rawMode = 1; rawMode <= 2; rawMode++) {
            uint256 tokenId = _createRequest(alice, 12e18, 1);
            _makeProcessed(tokenId, 9e6);
            vm.prank(alice);
            queue.approve(bob, tokenId);
            usdat.setTransferMode(TerminalTokenMock.TransferMode(rawMode));

            vm.prank(alice);
            vm.expectRevert();
            queue.claim(tokenId);

            assertEq(queue.ownerOf(tokenId), alice);
            assertEq(queue.getApproved(tokenId), bob);
            assertEq(queue.totalSupply(), rawMode);
            assertEq(usdat.balanceOf(address(queue)), 9e6 * rawMode);
            assertEq(usdat.balanceOf(alice), 0);
            (uint256 shares, uint256 owed,,, IWithdrawalQueueERC721.RequestStatus status) = queue.requests(tokenId);
            assertEq(shares, 12e18);
            assertEq(owed, 9e6);
            assertEq(uint256(status), uint256(IWithdrawalQueueERC721.RequestStatus.Processed));
        }
    }

    function testFuzz_seize_PaysCompleteProcessedRequestAndPreservesTerminalRecord(uint128 rawAmount, uint256 limit)
        public
    {
        uint256 amount = uint256(rawAmount);
        uint256 shares = 37e18;
        uint256 tokenId = _createRequest(alice, shares, limit);
        (,, uint256 timestamp,,) = queue.requests(tokenId);
        _makeProcessed(tokenId, amount);
        stakedUsdat.setBlacklisted(alice, true);

        vm.expectEmit(true, true, true, true, address(queue));
        emit FundsSeized(tokenId, alice, amount, bob);
        queue.seize(tokenId);

        assertEq(usdat.balanceOf(bob), amount);
        assertEq(usdat.balanceOf(address(queue)), 0);
        assertEq(queue.totalSupply(), 0);

        (
            uint256 storedShares,
            uint256 usdatOwed,
            uint256 storedTimestamp,
            uint256 storedLimit,
            IWithdrawalQueueERC721.RequestStatus status
        ) = queue.requests(tokenId);
        assertEq(storedShares, shares);
        assertEq(usdatOwed, amount);
        assertEq(storedTimestamp, timestamp);
        assertEq(storedLimit, limit);
        assertEq(uint256(status), uint256(IWithdrawalQueueERC721.RequestStatus.Claimed));

        vm.expectRevert();
        queue.ownerOf(tokenId);
    }

    function test_seize_RejectsNonProcessedRequestEvenWithOwedAmount() public {
        uint256 tokenId = _createRequest(alice, 37e18, 1);
        _setRequestWord(tokenId, 1, 9e6);
        usdat.mint(address(queue), 9e6);
        stakedUsdat.setBlacklisted(alice, true);

        vm.expectRevert(IWithdrawalQueueERC721.RequestNotProcessed.selector);
        queue.seize(tokenId);

        assertEq(queue.ownerOf(tokenId), alice);
        assertEq(usdat.balanceOf(address(queue)), 9e6);
        (uint256 shares, uint256 owed,,, IWithdrawalQueueERC721.RequestStatus status) = queue.requests(tokenId);
        assertEq(shares, 37e18);
        assertEq(owed, 9e6);
        assertEq(uint256(status), uint256(IWithdrawalQueueERC721.RequestStatus.Requested));
    }

    function test_seize_UsesUsdatFreezeAndRestoresQueuePause() public {
        uint256 tokenId = _createRequest(alice, 37e18, 1);
        _makeProcessed(tokenId, 9e6);
        usdat.setFrozen(alice, true);
        queue.pause();

        queue.seize(tokenId);

        assertTrue(queue.paused());
        assertEq(usdat.balanceOf(bob), 9e6);
        assertEq(queue.totalSupply(), 0);
        (uint256 shares, uint256 owed,,, IWithdrawalQueueERC721.RequestStatus status) = queue.requests(tokenId);
        assertEq(shares, 37e18);
        assertEq(owed, 9e6);
        assertEq(uint256(status), uint256(IWithdrawalQueueERC721.RequestStatus.Claimed));

        vm.expectRevert();
        queue.ownerOf(tokenId);
    }

    function test_seizeRequest_TransfersUnchangedRequestAndRestoresQueuePause() public {
        uint256 tokenId = _createRequest(alice, 37e18, 1);
        (uint256 shares, uint256 owed, uint256 timestamp, uint256 limit, IWithdrawalQueueERC721.RequestStatus status) =
            queue.requests(tokenId);
        usdat.setFrozen(alice, true);
        queue.pause();

        vm.expectEmit(true, true, true, true, address(queue));
        emit RequestSeized(tokenId, alice, bob);
        queue.seizeRequest(tokenId);

        assertTrue(queue.paused());
        assertEq(queue.ownerOf(tokenId), bob);
        (
            uint256 storedShares,
            uint256 storedOwed,
            uint256 storedTimestamp,
            uint256 storedLimit,
            IWithdrawalQueueERC721.RequestStatus storedStatus
        ) = queue.requests(tokenId);
        assertEq(storedShares, shares);
        assertEq(storedOwed, owed);
        assertEq(storedTimestamp, timestamp);
        assertEq(storedLimit, limit);
        assertEq(uint256(storedStatus), uint256(status));
    }

    function test_seizures_RejectUnauthorizedCaller() public {
        uint256 requestedId = _createRequest(alice, 12e18, 1);
        uint256 processedId = _createRequest(alice, 13e18, 1);
        _makeProcessed(processedId, 9e6);
        stakedUsdat.setBlacklisted(alice, true);

        bytes memory unauthorizedError =
            abi.encodeWithSelector(ACCESS_CONTROL_UNAUTHORIZED_ERROR, carol, queue.ENFORCER_ROLE());

        vm.startPrank(carol);
        vm.expectRevert(unauthorizedError);
        queue.seizeRequest(requestedId);
        vm.expectRevert(unauthorizedError);
        queue.seize(processedId);
        vm.stopPrank();

        assertEq(queue.ownerOf(requestedId), alice);
        assertEq(queue.ownerOf(processedId), alice);
        assertEq(usdat.balanceOf(address(queue)), 9e6);
    }

    function test_seizures_RejectUnrestrictedOwner() public {
        uint256 requestedId = _createRequest(alice, 12e18, 1);
        uint256 processedId = _createRequest(alice, 13e18, 1);
        _makeProcessed(processedId, 9e6);

        vm.expectRevert(IWithdrawalQueueERC721.NotBlacklisted.selector);
        queue.seizeRequest(requestedId);
        vm.expectRevert(IWithdrawalQueueERC721.NotBlacklisted.selector);
        queue.seize(processedId);

        assertEq(queue.ownerOf(requestedId), alice);
        assertEq(queue.ownerOf(processedId), alice);
        assertEq(usdat.balanceOf(address(queue)), 9e6);
    }

    function test_seizures_RejectDuplicateAttempts() public {
        uint256 requestedId = _createRequest(alice, 12e18, 1);
        uint256 processedId = _createRequest(alice, 13e18, 1);
        _makeProcessed(processedId, 9e6);
        stakedUsdat.setBlacklisted(alice, true);

        queue.seizeRequest(requestedId);
        vm.expectRevert(IWithdrawalQueueERC721.NotBlacklisted.selector);
        queue.seizeRequest(requestedId);

        queue.seize(processedId);
        vm.expectRevert();
        queue.seize(processedId);

        assertEq(queue.ownerOf(requestedId), bob);
        assertEq(usdat.balanceOf(bob), 9e6);
        assertEq(usdat.balanceOf(address(queue)), 0);
    }

    function test_seizeRequest_RejectsEveryNonRequestedStatus() public {
        for (uint256 rawStatus = 0; rawStatus <= uint256(IWithdrawalQueueERC721.RequestStatus.Cancelled); rawStatus++) {
            if (rawStatus == uint256(IWithdrawalQueueERC721.RequestStatus.Requested)) continue;

            stakedUsdat.setBlacklisted(alice, false);
            uint256 tokenId = _createRequest(alice, 10e18 + rawStatus, rawStatus);
            _setStatus(tokenId, IWithdrawalQueueERC721.RequestStatus(rawStatus));
            stakedUsdat.setBlacklisted(alice, true);

            vm.expectRevert(IWithdrawalQueueERC721.RequestNotOpen.selector);
            queue.seizeRequest(tokenId);

            assertEq(queue.ownerOf(tokenId), alice);
        }
    }

    function test_seizures_UseCurrentRecoveryAddress() public {
        uint256 requestedId = _createRequest(alice, 12e18, 1);
        uint256 processedId = _createRequest(alice, 13e18, 1);
        _makeProcessed(processedId, 9e6);
        stakedUsdat.setBlacklisted(alice, true);

        queue.seizeRequest(requestedId);
        assertEq(queue.ownerOf(requestedId), bob);

        stakedUsdat.setRecoveryAddress(carol);
        queue.seize(processedId);

        assertEq(usdat.balanceOf(bob), 0);
        assertEq(usdat.balanceOf(carol), 9e6);
        assertEq(usdat.balanceOf(address(queue)), 0);
    }

    function test_seizures_RejectZeroRecoveryAddress() public {
        uint256 requestedId = _createRequest(alice, 12e18, 1);
        uint256 processedId = _createRequest(alice, 13e18, 1);
        _makeProcessed(processedId, 9e6);
        stakedUsdat.setBlacklisted(alice, true);
        stakedUsdat.setRecoveryAddress(address(0));

        vm.expectRevert(IWithdrawalQueueERC721.ZeroAmount.selector);
        queue.seizeRequest(requestedId);
        vm.expectRevert(IWithdrawalQueueERC721.ZeroAmount.selector);
        queue.seize(processedId);

        assertEq(queue.ownerOf(requestedId), alice);
        assertEq(queue.ownerOf(processedId), alice);
        assertEq(usdat.balanceOf(address(queue)), 9e6);
    }

    function test_seizures_RejectRecoveryRestrictedByEitherToken() public {
        uint256 requestedId = _createRequest(alice, 12e18, 1);
        uint256 processedId = _createRequest(alice, 13e18, 1);
        _makeProcessed(processedId, 9e6);
        stakedUsdat.setBlacklisted(alice, true);
        stakedUsdat.setBlacklisted(bob, true);

        vm.expectRevert(IWithdrawalQueueERC721.AddressBlacklisted.selector);
        queue.seizeRequest(requestedId);
        vm.expectRevert(IWithdrawalQueueERC721.AddressBlacklisted.selector);
        queue.seize(processedId);

        stakedUsdat.setBlacklisted(bob, false);
        usdat.setFrozen(bob, true);

        vm.expectRevert(IWithdrawalQueueERC721.AddressBlacklisted.selector);
        queue.seizeRequest(requestedId);
        vm.expectRevert(IWithdrawalQueueERC721.AddressBlacklisted.selector);
        queue.seize(processedId);

        assertEq(queue.ownerOf(requestedId), alice);
        assertEq(queue.ownerOf(processedId), alice);
        assertEq(usdat.balanceOf(address(queue)), 9e6);
    }

    function test_ApprovedEnforcerCannotBypassCanonicalRequestSeizure() public {
        uint256 tokenId = _createRequest(alice, 12e18, 1);
        vm.prank(alice);
        queue.approve(address(this), tokenId);
        stakedUsdat.setBlacklisted(alice, true);

        vm.expectRevert(IWithdrawalQueueERC721.AddressBlacklisted.selector);
        queue.transferFrom(alice, carol, tokenId);
        vm.expectRevert(IWithdrawalQueueERC721.AddressBlacklisted.selector);
        queue.safeTransferFrom(alice, carol, tokenId);

        assertEq(queue.ownerOf(tokenId), alice);
        assertEq(queue.getApproved(tokenId), address(this));

        queue.seizeRequest(tokenId);
        assertEq(queue.ownerOf(tokenId), bob);
        assertEq(queue.getApproved(tokenId), address(0));
    }

    function test_seize_TransferFailureModesRollBackAllState() public {
        for (uint256 rawMode = 1; rawMode <= 2; rawMode++) {
            uint256 tokenId = _createRequest(alice, 12e18, 1);
            _makeProcessed(tokenId, 9e6);
            stakedUsdat.setBlacklisted(alice, true);
            usdat.setTransferMode(TerminalTokenMock.TransferMode(rawMode));

            vm.expectRevert();
            queue.seize(tokenId);

            assertEq(queue.ownerOf(tokenId), alice);
            assertEq(queue.totalSupply(), rawMode);
            assertEq(usdat.balanceOf(address(queue)), 9e6 * rawMode);
            assertEq(usdat.balanceOf(bob), 0);
            (uint256 shares, uint256 owed,,, IWithdrawalQueueERC721.RequestStatus status) = queue.requests(tokenId);
            assertEq(shares, 12e18);
            assertEq(owed, 9e6);
            assertEq(uint256(status), uint256(IWithdrawalQueueERC721.RequestStatus.Processed));

            stakedUsdat.setBlacklisted(alice, false);
        }
    }

    function test_cancelRequest_BlocksAuthorizedCrossRequestReentrancy() public {
        uint256 outerId = _createRequest(alice, 12e18, 1);
        uint256 reentrantId = _createRequest(address(stakedUsdat), 13e18, 1);
        stakedUsdat.setCallback(
            address(queue), abi.encodeWithSelector(IWithdrawalQueueERC721.cancelRequest.selector, reentrantId)
        );

        vm.prank(alice);
        queue.cancelRequest(outerId);

        assertTrue(stakedUsdat.callbackAttempted());
        assertFalse(stakedUsdat.callbackSucceeded());
        assertEq(stakedUsdat.callbackRevertSelector(), REENTRANCY_ERROR);
        assertEq(queue.ownerOf(reentrantId), address(stakedUsdat));
        assertEq(stakedUsdat.balanceOf(address(queue)), 13e18);
        assertEq(stakedUsdat.balanceOf(alice), 12e18);
        (,,,, IWithdrawalQueueERC721.RequestStatus status) = queue.requests(reentrantId);
        assertEq(uint256(status), uint256(IWithdrawalQueueERC721.RequestStatus.Requested));
    }

    function test_claim_BlocksAuthorizedCrossRequestReentrancy() public {
        uint256 outerId = _createRequest(alice, 12e18, 1);
        uint256 reentrantId = _createRequest(address(usdat), 13e18, 1);
        _makeProcessed(outerId, 9e6);
        _makeProcessed(reentrantId, 10e6);
        usdat.setCallback(address(queue), abi.encodeWithSelector(IWithdrawalQueueERC721.claim.selector, reentrantId));

        vm.prank(alice);
        queue.claim(outerId);

        assertTrue(usdat.callbackAttempted());
        assertFalse(usdat.callbackSucceeded());
        assertEq(usdat.callbackRevertSelector(), REENTRANCY_ERROR);
        assertEq(queue.ownerOf(reentrantId), address(usdat));
        assertEq(usdat.balanceOf(address(queue)), 10e6);
        assertEq(usdat.balanceOf(alice), 9e6);
        assertEq(usdat.balanceOf(address(usdat)), 0);
        (uint256 shares, uint256 owed,,, IWithdrawalQueueERC721.RequestStatus status) = queue.requests(reentrantId);
        assertEq(shares, 13e18);
        assertEq(owed, 10e6);
        assertEq(uint256(status), uint256(IWithdrawalQueueERC721.RequestStatus.Processed));
    }

    function _createRequest(address owner, uint256 shares, uint256 limit) private returns (uint256 tokenId) {
        stakedUsdat.mint(address(queue), shares);
        vm.prank(address(stakedUsdat));
        tokenId = queue.addRequest(owner, shares, limit);
    }

    function _makeProcessed(uint256 tokenId, uint256 amount) private {
        _setRequestWord(tokenId, 1, amount);
        _setStatus(tokenId, IWithdrawalQueueERC721.RequestStatus.Processed);
        usdat.mint(address(queue), amount);
    }

    function _setStatus(uint256 tokenId, IWithdrawalQueueERC721.RequestStatus status) private {
        _setRequestWord(tokenId, 4, uint256(status));
    }

    function _setRequestWord(uint256 tokenId, uint256 offset, uint256 value) private {
        bytes32 base = keccak256(abi.encode(tokenId, REQUESTS_SLOT));
        vm.store(address(queue), bytes32(uint256(base) + offset), bytes32(value));
    }

    function _expectRestrictedOwnerReverts(uint256 cancelId, uint256 claimId) private {
        vm.startPrank(alice);
        vm.expectRevert(IWithdrawalQueueERC721.AddressBlacklisted.selector);
        queue.cancelRequest(cancelId);
        vm.expectRevert(IWithdrawalQueueERC721.AddressBlacklisted.selector);
        queue.claim(claimId);
        vm.stopPrank();

        assertEq(queue.ownerOf(cancelId), alice);
        assertEq(queue.ownerOf(claimId), alice);
    }
}
