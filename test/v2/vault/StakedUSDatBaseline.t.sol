// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {StakedUSDat as StakedUSDatV1} from "../../../src/v1/StakedUSDat.sol";
import {IStrcPriceOracle as IStrcPriceOracleV1} from "../../../src/v1/interfaces/IStrcPriceOracle.sol";
import {IWithdrawalQueueERC721 as IWithdrawalQueueV1} from "../../../src/v1/interfaces/IWithdrawalQueueERC721.sol";
import {StakedUSDat as StakedUSDatV2} from "../../../src/v2/StakedUSDat.sol";
import {IStakedUSDat} from "../../../src/v2/interfaces/IStakedUSDat.sol";
import {IWithdrawalQueueERC721 as IWithdrawalQueueV2} from "../../../src/v2/interfaces/IWithdrawalQueueERC721.sol";
import {ZeroAccountingModuleMock, ZeroTradableModuleMock} from "../helpers/FixedModuleMocks.sol";
import {V2InitializationHelper} from "../helpers/V2InitializationHelper.sol";

contract BaselineUSDatMock {
    // Lowercase public constant preserves the ERC20 metadata ABI.
    // forge-lint: disable-next-line(screaming-snake-case-const)
    uint8 public constant decimals = 6;

    function isFrozen(address) external pure returns (bool) {
        return false;
    }
}

contract StakedUSDatBaselineTest is Test {
    function test_implementsCurrentInterface() public {
        IStakedUSDat implementation = new StakedUSDatV2(IWithdrawalQueueV2(makeAddr("withdrawalQueue")));

        assertGt(address(implementation).code.length, 0);
    }

    function test_v1StoragePrefixSurvivesUpgradeAndV2StateAppendsAtSlotTen() public {
        BaselineUSDatMock usdat = new BaselineUSDatMock();
        address withdrawalQueue = makeAddr("withdrawalQueue");
        address legacyFeeRecipient = makeAddr("legacyFeeRecipient");
        address blacklisted = makeAddr("blacklisted");
        StakedUSDatV1 implementationV1 =
            new StakedUSDatV1(IStrcPriceOracleV1(makeAddr("oracle")), IWithdrawalQueueV1(withdrawalQueue));
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(implementationV1),
            abi.encodeCall(
                StakedUSDatV1.initialize,
                (address(this), address(this), address(this), legacyFeeRecipient, IERC20(address(usdat)))
            )
        );
        StakedUSDatV1 vaultV1 = StakedUSDatV1(address(proxy));
        ZeroAccountingModuleMock strcMirrorModule = new ZeroAccountingModuleMock(address(proxy));
        ZeroTradableModuleMock strconModule = new ZeroTradableModuleMock(address(proxy));
        vaultV1.addToBlacklist(blacklisted);

        for (uint256 slot = 1; slot < 10; slot++) {
            if (slot == 6) continue;
            vm.store(address(proxy), bytes32(slot), bytes32(0x1000 + slot));
        }

        bytes32[10] memory legacySlots;
        for (uint256 slot = 0; slot < 10; slot++) {
            legacySlots[slot] = vm.load(address(proxy), bytes32(slot));
        }

        StakedUSDatV2 implementationV2 = new StakedUSDatV2(IWithdrawalQueueV2(withdrawalQueue));
        vaultV1.upgradeToAndCall(address(implementationV2), "");
        StakedUSDatV2 vaultV2 = StakedUSDatV2(address(proxy));

        assertTrue(vaultV2.isBlacklisted(blacklisted));
        assertEq(vaultV2.usdatBalance(), uint256(legacySlots[7]));
        assertEq(vaultV2.recoveryAddress(), address(0));
        assertEq(uint256(vaultV2.marketMode()), uint256(IStakedUSDat.MarketMode.Elevated));
        assertEq(vaultV2.elevatedDepositFeeBps(), uint256(legacySlots[5]));
        assertEq(vaultV2.depositFeeBps(), uint256(legacySlots[5]));
        vm.expectRevert();
        vaultV2.totalAssets();
        assertEq(vaultV2.maxDeposit(address(this)), 0);
        assertEq(vaultV2.maxMint(address(this)), 0);

        V2InitializationHelper.initialize(vaultV2, address(strcMirrorModule), address(strconModule), 5, 10, 25);
        assertEq(vaultV2.baseRedemptionFeeBps(), 5);
        assertEq(vaultV2.elevatedRedemptionFeeBps(), 10);
        assertEq(vaultV2.elevatedDepositFeeBps(), 25);
        assertEq(address(vaultV2.strcMirrorModule()), address(strcMirrorModule));
        assertEq(address(vaultV2.strconModule()), address(strconModule));
        assertEq(vaultV2.surplusVestingAmount(), 0);
        assertEq(vaultV2.surplusVestingStartTimestamp(), 0);
        assertEq(vaultV2.surplusVestingPeriod(), 3 days);
        assertEq(vaultV2.MAX_SURPLUS_BPS(), 500);
        assertEq(vaultV2.totalAssets(), uint256(legacySlots[7]));

        address recoveryAddress = makeAddr("recoveryAddress");
        vaultV2.grantRole(vaultV2.PARAMETER_MANAGER_ROLE(), address(this));
        vaultV2.grantRole(vaultV2.MARKET_MODE_MANAGER_ROLE(), address(this));
        vaultV2.setRecoveryAddress(recoveryAddress);
        vaultV2.setMarketMode(IStakedUSDat.MarketMode.Elevated);
        assertEq(vaultV2.depositFeeBps(), 25);

        for (uint256 slot = 0; slot < 10; slot++) {
            if (slot == 5) continue;
            assertEq(vm.load(address(proxy), bytes32(slot)), legacySlots[slot]);
        }
        assertEq(vm.load(address(proxy), bytes32(uint256(5))), bytes32(uint256(25)));

        uint256 expectedSlotTen = uint256(uint160(recoveryAddress))
            | (uint256(uint8(IStakedUSDat.MarketMode.Elevated)) << 160) | (uint256(5) << 168) | (uint256(10) << 184);
        assertEq(vm.load(address(proxy), bytes32(uint256(10))), bytes32(expectedSlotTen));
        assertEq(vm.load(address(proxy), bytes32(uint256(11))), bytes32(uint256(uint160(address(strcMirrorModule)))));
        assertEq(vm.load(address(proxy), bytes32(uint256(12))), bytes32(uint256(uint160(address(strconModule)))));
        assertEq(vm.load(address(proxy), bytes32(uint256(13))), bytes32(0));
        assertEq(vm.load(address(proxy), bytes32(uint256(14))), bytes32(0));
        assertEq(vm.load(address(proxy), bytes32(uint256(15))), bytes32(uint256(3 days)));
        uint256 expectedSlotSixteen =
            uint256(uint160(address(vaultV2.executionPolicy()))) | (uint256(vaultV2.regularModeValidUntil()) << 176);
        assertEq(vm.load(address(proxy), bytes32(uint256(16))), bytes32(expectedSlotSixteen));
        assertEq(vm.load(address(proxy), bytes32(uint256(17))), bytes32(0));
    }
}
