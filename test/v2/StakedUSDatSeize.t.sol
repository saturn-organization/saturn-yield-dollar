// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {StakedUSDat} from "../../src/v2/StakedUSDat.sol";
import {IStakedUSDat} from "../../src/v2/interfaces/IStakedUSDat.sol";
import {IWithdrawalQueueERC721} from "../../src/v2/interfaces/IWithdrawalQueueERC721.sol";

contract SeizeUSDatMock {
    mapping(address account => bool frozen) public isFrozen;

    function setFrozen(address account, bool frozen) external {
        isFrozen[account] = frozen;
    }
}

contract StakedUSDatSeizeHarness is StakedUSDat {
    constructor(IWithdrawalQueueERC721 withdrawalQueue) StakedUSDat(withdrawalQueue) {}

    function mintShares(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract StakedUSDatSeizeTest is Test {
    uint256 private constant HOLDER_BALANCE = 25e18;

    SeizeUSDatMock private usdat;
    StakedUSDatSeizeHarness private vault;

    address private holder = makeAddr("holder");
    address private recoveryAddress = makeAddr("recoveryAddress");
    address private replacementRecoveryAddress = makeAddr("replacementRecoveryAddress");
    address private unauthorized = makeAddr("unauthorized");

    event Seized(address indexed from, address indexed to, uint256 amount);

    function setUp() public {
        usdat = new SeizeUSDatMock();
        vault = _deployVault();

        vault.grantRole(vault.PARAMETER_MANAGER_ROLE(), address(this));
        vault.grantRole(vault.BLACKLISTER_ROLE(), address(this));
        vault.grantRole(vault.ENFORCER_ROLE(), address(this));
        vault.grantRole(vault.PAUSER_ROLE(), address(this));

        vault.setRecoveryAddress(recoveryAddress);
        vault.mintShares(holder, HOLDER_BALANCE);
    }

    function test_seize_RequiresEnforcerRole() public {
        vault.addToBlacklist(holder);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, unauthorized, vault.ENFORCER_ROLE()
            )
        );
        vm.prank(unauthorized);
        vault.seize(holder);

        _assertBalances(HOLDER_BALANCE, 0, 0);
    }

    function test_seize_RejectsUnsetRecoveryAddress() public {
        StakedUSDatSeizeHarness unsetVault = _deployVault();
        unsetVault.grantRole(unsetVault.BLACKLISTER_ROLE(), address(this));
        unsetVault.grantRole(unsetVault.ENFORCER_ROLE(), address(this));
        unsetVault.mintShares(holder, HOLDER_BALANCE);
        unsetVault.addToBlacklist(holder);

        vm.expectRevert(IStakedUSDat.InvalidZeroAddress.selector);
        unsetVault.seize(holder);

        assertEq(unsetVault.balanceOf(holder), HOLDER_BALANCE);
        assertEq(unsetVault.totalSupply(), HOLDER_BALANCE);
    }

    function test_seize_RequiresBlacklistedSource() public {
        vm.expectRevert(IStakedUSDat.AddressNotBlacklisted.selector);
        vault.seize(holder);

        _assertBalances(HOLDER_BALANCE, 0, 0);
    }

    function test_seize_RequiresPositiveBalance() public {
        address emptyHolder = makeAddr("emptyHolder");
        vault.addToBlacklist(emptyHolder);

        vm.expectRevert(IStakedUSDat.ZeroAmount.selector);
        vault.seize(emptyHolder);

        _assertBalances(HOLDER_BALANCE, 0, 0);
    }

    function test_seize_TransfersFullBalanceToRecoveryAddress() public {
        vault.addToBlacklist(holder);

        vm.expectEmit(true, true, false, true, address(vault));
        emit Seized(holder, recoveryAddress, HOLDER_BALANCE);
        IStakedUSDat(address(vault)).seize(holder);

        _assertBalances(0, HOLDER_BALANCE, 0);
        assertEq(vault.totalSupply(), HOLDER_BALANCE);
    }

    function test_seize_UsesCurrentRecoveryAddress() public {
        vault.setRecoveryAddress(replacementRecoveryAddress);
        vault.addToBlacklist(holder);

        vault.seize(holder);

        _assertBalances(0, 0, HOLDER_BALANCE);
    }

    function test_seize_WorksWhilePausedAndRestoresPause() public {
        vault.addToBlacklist(holder);
        vault.pause();

        vault.seize(holder);

        assertTrue(vault.paused());
        _assertBalances(0, HOLDER_BALANCE, 0);
    }

    function test_seize_RejectsRecoveryAddressBlacklistedAfterConfiguration() public {
        vault.addToBlacklist(holder);
        vault.addToBlacklist(recoveryAddress);

        vm.expectRevert(IStakedUSDat.AddressBlacklisted.selector);
        vault.seize(holder);

        _assertBalances(HOLDER_BALANCE, 0, 0);
    }

    function test_seize_RejectsRecoveryAddressFrozenAfterConfiguration() public {
        vault.addToBlacklist(holder);
        usdat.setFrozen(recoveryAddress, true);

        vm.expectRevert(IStakedUSDat.AddressBlacklisted.selector);
        vault.seize(holder);

        _assertBalances(HOLDER_BALANCE, 0, 0);
    }

    function _assertBalances(uint256 holderAmount, uint256 recoveryAmount, uint256 replacementAmount) private view {
        assertEq(vault.balanceOf(holder), holderAmount);
        assertEq(vault.balanceOf(recoveryAddress), recoveryAmount);
        assertEq(vault.balanceOf(replacementRecoveryAddress), replacementAmount);
    }

    function _deployVault() private returns (StakedUSDatSeizeHarness deployedVault) {
        StakedUSDatSeizeHarness implementation =
            new StakedUSDatSeizeHarness(IWithdrawalQueueERC721(makeAddr("withdrawalQueue")));
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(implementation), abi.encodeCall(StakedUSDat.initialize, (address(this), IERC20(address(usdat))))
        );
        deployedVault = StakedUSDatSeizeHarness(address(proxy));
    }
}
