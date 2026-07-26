// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {StakedUSDat} from "../../src/v2/StakedUSDat.sol";
import {IStakedUSDat} from "../../src/v2/interfaces/IStakedUSDat.sol";
import {IWithdrawalQueueERC721} from "../../src/v2/interfaces/IWithdrawalQueueERC721.sol";

contract RecoveryUSDatMock {
    mapping(address account => bool frozen) public isFrozen;

    function setFrozen(address account, bool frozen) external {
        isFrozen[account] = frozen;
    }
}

contract StakedUSDatRecoveryAddressTest is Test {
    RecoveryUSDatMock private usdat;
    StakedUSDat private vault;

    address private recoveryAddress = makeAddr("recoveryAddress");
    address private replacementRecoveryAddress = makeAddr("replacementRecoveryAddress");
    address private withdrawalQueue = makeAddr("withdrawalQueue");

    event RecoveryAddressUpdated(address indexed oldAddress, address indexed newAddress);

    function setUp() public {
        usdat = new RecoveryUSDatMock();

        StakedUSDat implementation = new StakedUSDat(IWithdrawalQueueERC721(withdrawalQueue));
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(implementation), abi.encodeCall(StakedUSDat.initialize, (address(this), IERC20(address(usdat))))
        );
        vault = StakedUSDat(address(proxy));
        vault.grantRole(vault.PARAMETER_MANAGER_ROLE(), address(this));
        vault.grantRole(vault.BLACKLISTER_ROLE(), address(this));
        vault.grantRole(vault.PAUSER_ROLE(), address(this));
        vault.setRecoveryAddress(recoveryAddress);
    }

    function test_recoveryAddress_ReturnsAddressThroughInterface() public view {
        assertEq(IStakedUSDat(address(vault)).recoveryAddress(), recoveryAddress);
    }

    function test_setRecoveryAddress_UpdatesAddressAndEmitsEvent() public {
        vm.expectEmit(true, true, false, true, address(vault));
        emit RecoveryAddressUpdated(recoveryAddress, replacementRecoveryAddress);
        vault.setRecoveryAddress(replacementRecoveryAddress);

        assertEq(vault.recoveryAddress(), replacementRecoveryAddress);
    }

    function test_setRecoveryAddress_RequiresParameterManagerRole() public {
        address unauthorized = makeAddr("unauthorized");

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, unauthorized, vault.PARAMETER_MANAGER_ROLE()
            )
        );
        vm.prank(unauthorized);
        vault.setRecoveryAddress(replacementRecoveryAddress);

        assertEq(vault.recoveryAddress(), recoveryAddress);
    }

    function test_setRecoveryAddress_RejectsZeroAddress() public {
        vm.expectRevert(IStakedUSDat.InvalidZeroAddress.selector);
        vault.setRecoveryAddress(address(0));

        assertEq(vault.recoveryAddress(), recoveryAddress);
    }

    function test_setRecoveryAddress_RejectsBlacklistedAddress() public {
        vault.addToBlacklist(replacementRecoveryAddress);

        vm.expectRevert(IStakedUSDat.AddressBlacklisted.selector);
        vault.setRecoveryAddress(replacementRecoveryAddress);

        assertEq(vault.recoveryAddress(), recoveryAddress);
    }

    function test_setRecoveryAddress_RejectsFrozenAddress() public {
        usdat.setFrozen(replacementRecoveryAddress, true);

        vm.expectRevert(IStakedUSDat.AddressBlacklisted.selector);
        vault.setRecoveryAddress(replacementRecoveryAddress);

        assertEq(vault.recoveryAddress(), recoveryAddress);
    }

    function test_setRecoveryAddress_WorksWhilePaused() public {
        vault.pause();

        vault.setRecoveryAddress(replacementRecoveryAddress);

        assertTrue(vault.paused());
        assertEq(vault.recoveryAddress(), replacementRecoveryAddress);
    }
}
