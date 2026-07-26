// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {WithdrawalQueueERC721 as WithdrawalQueueV1} from "../../../src/v1/WithdrawalQueueERC721.sol";
import {WithdrawalQueueERC721 as WithdrawalQueueV2} from "../../../src/v2/WithdrawalQueueERC721.sol";
import {IStakedUSDat} from "../../../src/v2/interfaces/IStakedUSDat.sol";
import {IWithdrawalQueueERC721 as IWithdrawalQueueV2} from "../../../src/v2/interfaces/IWithdrawalQueueERC721.sol";

contract QueueUSDatMock {
    mapping(address account => uint256 balance) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function isFrozen(address) external pure returns (bool) {
        return false;
    }
}

contract QueueStakedUSDatMock {
    function isBlacklisted(address) external pure returns (bool) {
        return false;
    }

    function redeemQueuedShares(uint256 shares, uint256)
        external
        pure
        returns (IStakedUSDat.RedemptionResult result, uint256 usdat)
    {
        return (IStakedUSDat.RedemptionResult.Settled, shares / 1e12);
    }
}

contract WithdrawalQueueMigrationTest is Test {
    uint256 private constant REQUESTS_SLOT = 0;
    uint256 private constant NEXT_TOKEN_ID_SLOT = 1;
    uint256 private constant PENDING_COUNT_SLOT = 2;

    QueueUSDatMock private usdat;
    QueueStakedUSDatMock private stakedUsdat;

    WithdrawalQueueV1 private queueV1;
    WithdrawalQueueV2 private queueV2;
    WithdrawalQueueV2 private queueV2Implementation;

    address private proxy;

    address private operator = makeAddr("operator");
    address private enforcer = makeAddr("enforcer");
    address private pauser = makeAddr("pauser");
    address private unpauser = makeAddr("unpauser");
    address private processor = makeAddr("v1Processor");
    address private compliance = makeAddr("v1Compliance");
    address private alice = makeAddr("alice");
    address private bob = makeAddr("bob");

    function setUp() public {
        usdat = new QueueUSDatMock();
        stakedUsdat = new QueueStakedUSDatMock();

        WithdrawalQueueV1 queueV1Implementation = new WithdrawalQueueV1(address(usdat), address(stakedUsdat));
        ERC1967Proxy queueProxy = new ERC1967Proxy(
            address(queueV1Implementation),
            abi.encodeCall(WithdrawalQueueV1.initialize, (address(this), address(stakedUsdat), processor, compliance))
        );

        proxy = address(queueProxy);
        queueV1 = WithdrawalQueueV1(proxy);
        queueV2Implementation = new WithdrawalQueueV2(address(usdat), address(stakedUsdat));
    }

    function test_initializeV2_PreservesAllLegacyRequestAndCounterSlots() public {
        uint256 requestedId = _createV1Request(alice, 11e18, 101e6);
        uint256 inProgressId = _createV1Request(alice, 12e18, 102e6);
        uint256 processedId = _createV1Request(bob, 13e18, 103e6);
        uint256 claimedId = _createV1Request(bob, 14e18, 104e6);

        _setRequestState(inProgressId, 0, IWithdrawalQueueV2.RequestStatus.InProgress);
        _setRequestState(processedId, 97e6, IWithdrawalQueueV2.RequestStatus.Processed);
        _setRequestState(claimedId, 96e6, IWithdrawalQueueV2.RequestStatus.Processed);
        usdat.mint(proxy, 96e6);
        vm.prank(bob);
        queueV1.claim(claimedId);

        vm.prank(alice);
        queueV1.approve(bob, requestedId);
        vm.prank(compliance);
        queueV1.pause();

        bytes32[5][4] memory requestsBefore;
        requestsBefore[0] = _rawRequest(requestedId);
        requestsBefore[1] = _rawRequest(inProgressId);
        requestsBefore[2] = _rawRequest(processedId);
        requestsBefore[3] = _rawRequest(claimedId);

        bytes32 nextTokenIdBefore = vm.load(proxy, bytes32(NEXT_TOKEN_ID_SLOT));
        bytes32 pendingCountBefore = vm.load(proxy, bytes32(PENDING_COUNT_SLOT));

        _upgradeToV2();

        _assertRawRequestEquals(requestedId, requestsBefore[0]);
        _assertRawRequestEquals(inProgressId, requestsBefore[1]);
        _assertRawRequestEquals(processedId, requestsBefore[2]);
        _assertRawRequestEquals(claimedId, requestsBefore[3]);
        assertEq(vm.load(proxy, bytes32(NEXT_TOKEN_ID_SLOT)), nextTokenIdBefore);
        assertEq(vm.load(proxy, bytes32(PENDING_COUNT_SLOT)), pendingCountBefore);
        assertEq(queueV2.totalSupply(), 3);
        assertEq(queueV2.ownerOf(requestedId), alice);
        assertEq(queueV2.ownerOf(inProgressId), alice);
        assertEq(queueV2.ownerOf(processedId), bob);
        assertEq(queueV2.getApproved(requestedId), bob);
        assertTrue(queueV2.paused());

        {
            uint256[] memory aliceRequests = queueV2.getUserRequests(alice);
            assertEq(aliceRequests.length, 2);
            assertTrue(
                (aliceRequests[0] == requestedId && aliceRequests[1] == inProgressId)
                    || (aliceRequests[0] == inProgressId && aliceRequests[1] == requestedId)
            );
            uint256[] memory bobRequests = queueV2.getUserRequests(bob);
            assertEq(bobRequests.length, 1);
            assertEq(bobRequests[0], processedId);
        }

        (,,, uint256 requestedLimit, IWithdrawalQueueV2.RequestStatus requestedStatus) = queueV2.requests(requestedId);
        (,,, uint256 inProgressLimit, IWithdrawalQueueV2.RequestStatus inProgressStatus) =
            queueV2.requests(inProgressId);
        (uint256 processedShares, uint256 processedOwed,,, IWithdrawalQueueV2.RequestStatus processedStatus) =
            queueV2.requests(processedId);
        (,,, uint256 claimedLimit, IWithdrawalQueueV2.RequestStatus claimedStatus) = queueV2.requests(claimedId);

        assertEq(requestedLimit, 101e6);
        assertEq(uint256(requestedStatus), uint256(IWithdrawalQueueV2.RequestStatus.Requested));
        assertEq(inProgressLimit, 102e6);
        assertEq(uint256(inProgressStatus), uint256(IWithdrawalQueueV2.RequestStatus.InProgress));
        assertEq(processedShares, 13e18);
        assertEq(processedOwed, 97e6);
        assertEq(uint256(processedStatus), uint256(IWithdrawalQueueV2.RequestStatus.Processed));
        assertEq(claimedLimit, 104e6);
        assertEq(uint256(claimedStatus), uint256(IWithdrawalQueueV2.RequestStatus.Claimed));

        assertTrue(queueV2.hasRole(queueV2.OPERATOR_ROLE(), operator));
        assertTrue(queueV2.hasRole(queueV2.ENFORCER_ROLE(), enforcer));
        assertTrue(queueV2.hasRole(queueV2.PAUSER_ROLE(), pauser));
        assertTrue(queueV2.hasRole(queueV2.UNPAUSER_ROLE(), unpauser));
        assertTrue(queueV2.hasRole(keccak256("PROCESSOR_ROLE"), processor));
        assertTrue(queueV2.hasRole(keccak256("COMPLIANCE_ROLE"), compliance));
        assertTrue(queueV2.hasRole(keccak256("STAKED_USDAT_ROLE"), address(stakedUsdat)));
    }

    function test_initializeV2_DoesNotIterateOverNextTokenId() public {
        vm.store(proxy, bytes32(NEXT_TOKEN_ID_SLOT), bytes32(type(uint256).max));

        _upgradeToV2();

        assertEq(queueV2.nextTokenId(), type(uint256).max);
    }

    function test_addRequest_StoresRequestedStatusAndUnchangedLimit() public {
        _upgradeToV2();

        uint256 minSharePrice = 1_234_567;
        vm.prank(address(stakedUsdat));
        uint256 tokenId = queueV2.addRequest(alice, 10e18, minSharePrice);

        (uint256 shares, uint256 usdatOwed,, uint256 storedMinSharePrice, IWithdrawalQueueV2.RequestStatus status) =
            queueV2.requests(tokenId);

        assertEq(shares, 10e18);
        assertEq(usdatOwed, 0);
        assertEq(storedMinSharePrice, minSharePrice);
        assertEq(uint256(status), uint256(IWithdrawalQueueV2.RequestStatus.Requested));
    }

    function test_updateMinSharePrice_RejectsLegacyProcessedRequestWithShares() public {
        uint256 tokenId = _createV1Request(alice, 13e18, 103e6);
        _setRequestState(tokenId, 97e6, IWithdrawalQueueV2.RequestStatus.Processed);

        _upgradeToV2();

        vm.prank(alice);
        vm.expectRevert(IWithdrawalQueueV2.RequestNotOpen.selector);
        queueV2.updateMinSharePrice(tokenId, 1);

        (,,, uint256 minSharePrice, IWithdrawalQueueV2.RequestStatus status) = queueV2.requests(tokenId);
        assertEq(minSharePrice, 103e6);
        assertEq(uint256(status), uint256(IWithdrawalQueueV2.RequestStatus.Processed));
    }

    function test_processRequests_RejectsLegacyProcessedRequestWithShares() public {
        uint256 tokenId = _createV1Request(alice, 13e18, 103e6);
        _setRequestState(tokenId, 97e6, IWithdrawalQueueV2.RequestStatus.Processed);

        _upgradeToV2();

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = tokenId;

        vm.prank(operator);
        vm.expectRevert(IWithdrawalQueueV2.RequestNotOpen.selector);
        queueV2.processRequests(tokenIds);

        (uint256 shares, uint256 usdatOwed,,, IWithdrawalQueueV2.RequestStatus status) = queueV2.requests(tokenId);
        assertEq(shares, 13e18);
        assertEq(usdatOwed, 97e6);
        assertEq(uint256(status), uint256(IWithdrawalQueueV2.RequestStatus.Processed));
    }

    function test_processRequests_FullFillTransitionsToProcessed() public {
        _upgradeToV2();

        vm.prank(address(stakedUsdat));
        uint256 tokenId = queueV2.addRequest(alice, 10e18, 0);

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = tokenId;

        vm.prank(operator);
        queueV2.processRequests(tokenIds);

        (uint256 shares, uint256 usdatOwed,,, IWithdrawalQueueV2.RequestStatus status) = queueV2.requests(tokenId);
        assertEq(shares, 10e18);
        assertEq(usdatOwed, 10e6);
        assertEq(uint256(status), uint256(IWithdrawalQueueV2.RequestStatus.Processed));
    }

    function test_requestStatusOrdinalsRemainStorageCompatible() public pure {
        assertEq(uint256(IWithdrawalQueueV2.RequestStatus.NULL), 0);
        assertEq(uint256(IWithdrawalQueueV2.RequestStatus.Requested), 1);
        assertEq(uint256(IWithdrawalQueueV2.RequestStatus.InProgress), 2);
        assertEq(uint256(IWithdrawalQueueV2.RequestStatus.Processed), 3);
        assertEq(uint256(IWithdrawalQueueV2.RequestStatus.Claimed), 4);
        assertEq(uint256(IWithdrawalQueueV2.RequestStatus.Cancelled), 5);
    }

    function _createV1Request(address owner, uint256 shares, uint256 minUsdatReceived)
        private
        returns (uint256 tokenId)
    {
        vm.prank(address(stakedUsdat));
        tokenId = queueV1.addRequest(owner, shares, minUsdatReceived);
    }

    function _upgradeToV2() private {
        queueV1.upgradeToAndCall(
            address(queueV2Implementation),
            abi.encodeCall(WithdrawalQueueV2.initializeV2, (operator, enforcer, pauser, unpauser))
        );
        queueV2 = WithdrawalQueueV2(proxy);
    }

    function _setRequestState(uint256 tokenId, uint256 usdatOwed, IWithdrawalQueueV2.RequestStatus status) private {
        bytes32 base = _requestBaseSlot(tokenId);
        vm.store(proxy, _offset(base, 1), bytes32(usdatOwed));
        vm.store(proxy, _offset(base, 4), bytes32(uint256(status)));
    }

    function _rawRequest(uint256 tokenId) private view returns (bytes32[5] memory values) {
        bytes32 base = _requestBaseSlot(tokenId);
        for (uint256 i = 0; i < values.length; i++) {
            values[i] = vm.load(proxy, _offset(base, i));
        }
    }

    function _assertRawRequestEquals(uint256 tokenId, bytes32[5] memory expected) private view {
        bytes32 base = _requestBaseSlot(tokenId);
        for (uint256 i = 0; i < expected.length; i++) {
            assertEq(vm.load(proxy, _offset(base, i)), expected[i]);
        }
    }

    function _requestBaseSlot(uint256 tokenId) private pure returns (bytes32) {
        return keccak256(abi.encode(tokenId, REQUESTS_SLOT));
    }

    function _offset(bytes32 base, uint256 offset) private pure returns (bytes32) {
        return bytes32(uint256(base) + offset);
    }
}
