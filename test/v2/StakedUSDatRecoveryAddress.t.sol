// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {StakedUSDat as StakedUSDatV1} from "../../src/v1/StakedUSDat.sol";
import {IStrcPriceOracle as IStrcPriceOracleV1} from "../../src/v1/interfaces/IStrcPriceOracle.sol";
import {IWithdrawalQueueERC721 as IWithdrawalQueueV1} from "../../src/v1/interfaces/IWithdrawalQueueERC721.sol";
import {StakedUSDat as StakedUSDatV2} from "../../src/v2/StakedUSDat.sol";
import {IStakedUSDat} from "../../src/v2/interfaces/IStakedUSDat.sol";
import {IStrcPriceOracle as IStrcPriceOracleV2} from "../../src/v2/interfaces/IStrcPriceOracle.sol";
import {IWithdrawalQueueERC721 as IWithdrawalQueueV2} from "../../src/v2/interfaces/IWithdrawalQueueERC721.sol";
import {MirrorSTRC} from "../../src/v2/modules/MirrorSTRC/MirrorSTRC.sol";

contract RecoveryUSDatMock {
    mapping(address account => bool frozen) public isFrozen;

    function setFrozen(address account, bool frozen) external {
        isFrozen[account] = frozen;
    }
}

contract StakedUSDatRecoveryAddressTest is Test {
    RecoveryUSDatMock private usdat;
    StakedUSDatV1 private vaultV1;
    StakedUSDatV2 private vaultV2;
    StakedUSDatV2 private implementationV2;
    MirrorSTRC private mirror;

    address private recoveryAddress = makeAddr("recoveryAddress");
    address private replacementRecoveryAddress = makeAddr("replacementRecoveryAddress");
    address private withdrawalQueue = makeAddr("withdrawalQueue");
    address private oracle = makeAddr("oracle");

    event RecoveryAddressUpdated(address indexed oldAddress, address indexed newAddress);

    function setUp() public {
        usdat = new RecoveryUSDatMock();

        StakedUSDatV1 implementationV1 =
            new StakedUSDatV1(IStrcPriceOracleV1(oracle), IWithdrawalQueueV1(withdrawalQueue));
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(implementationV1),
            abi.encodeCall(
                StakedUSDatV1.initialize,
                (address(this), address(this), address(this), address(this), IERC20(address(usdat)))
            )
        );
        vaultV1 = StakedUSDatV1(address(proxy));

        implementationV2 = new StakedUSDatV2(IWithdrawalQueueV2(withdrawalQueue));
        mirror = new MirrorSTRC(address(proxy), IStrcPriceOracleV2(oracle), IERC20(address(usdat)));
    }

    function test_initializeV2_SetsRecoveryAddressThroughInterface() public {
        _upgrade(recoveryAddress);

        assertEq(IStakedUSDat(address(vaultV2)).recoveryAddress(), recoveryAddress);
    }

    function test_initializeV2_RejectsZeroRecoveryAddress() public {
        vm.expectRevert(IStakedUSDat.InvalidZeroAddress.selector);
        _upgrade(address(0));
    }

    function test_initializeV2_RejectsBlacklistedRecoveryAddress() public {
        vaultV1.addToBlacklist(recoveryAddress);

        vm.expectRevert(IStakedUSDat.AddressBlacklisted.selector);
        _upgrade(recoveryAddress);
    }

    function test_initializeV2_RejectsFrozenRecoveryAddress() public {
        usdat.setFrozen(recoveryAddress, true);

        vm.expectRevert(IStakedUSDat.AddressBlacklisted.selector);
        _upgrade(recoveryAddress);
    }

    function test_setRecoveryAddress_UpdatesAddressAndEmitsEvent() public {
        _upgrade(recoveryAddress);

        vm.expectEmit(true, true, false, true, address(vaultV2));
        emit RecoveryAddressUpdated(recoveryAddress, replacementRecoveryAddress);
        vaultV2.setRecoveryAddress(replacementRecoveryAddress);

        assertEq(vaultV2.recoveryAddress(), replacementRecoveryAddress);
    }

    function test_setRecoveryAddress_RequiresParameterManagerRole() public {
        _upgrade(recoveryAddress);
        address unauthorized = makeAddr("unauthorized");

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, unauthorized, vaultV2.PARAMETER_MANAGER_ROLE()
            )
        );
        vm.prank(unauthorized);
        vaultV2.setRecoveryAddress(replacementRecoveryAddress);
    }

    function test_setRecoveryAddress_RejectsZeroAddress() public {
        _upgrade(recoveryAddress);

        vm.expectRevert(IStakedUSDat.InvalidZeroAddress.selector);
        vaultV2.setRecoveryAddress(address(0));

        assertEq(vaultV2.recoveryAddress(), recoveryAddress);
    }

    function test_setRecoveryAddress_RejectsBlacklistedAddress() public {
        _upgrade(recoveryAddress);
        vaultV2.addToBlacklist(replacementRecoveryAddress);

        vm.expectRevert(IStakedUSDat.AddressBlacklisted.selector);
        vaultV2.setRecoveryAddress(replacementRecoveryAddress);

        assertEq(vaultV2.recoveryAddress(), recoveryAddress);
    }

    function test_setRecoveryAddress_RejectsFrozenAddress() public {
        _upgrade(recoveryAddress);
        usdat.setFrozen(replacementRecoveryAddress, true);

        vm.expectRevert(IStakedUSDat.AddressBlacklisted.selector);
        vaultV2.setRecoveryAddress(replacementRecoveryAddress);

        assertEq(vaultV2.recoveryAddress(), recoveryAddress);
    }

    function _upgrade(address initialRecoveryAddress) private {
        StakedUSDatV2.RoleHolders memory roles = StakedUSDatV2.RoleHolders({
            operator: address(this),
            moduleManager: address(this),
            parameterManager: address(this),
            blacklister: address(this),
            enforcer: address(this),
            pauser: address(this),
            unpauser: address(this)
        });

        vaultV1.upgradeToAndCall(
            address(implementationV2),
            abi.encodeCall(StakedUSDatV2.initializeV2, (mirror, 0, 0, roles, initialRecoveryAddress))
        );
        vaultV2 = StakedUSDatV2(address(vaultV1));
    }
}
