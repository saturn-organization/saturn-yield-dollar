// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {StakedUSDat as StakedUSDatV2} from "../../../../src/v2/StakedUSDat.sol";
import {StakedUSDat} from "../../../../src/v3/StakedUSDat.sol";
import {TrancheAccountant} from "../../../../src/v3/TrancheAccountant.sol";
import {TrancheShare} from "../../../../src/v3/TrancheShare.sol";
import {ISTRConExecutionPolicy} from "../../../../src/v2/interfaces/ISTRConExecutionPolicy.sol";
import {IWithdrawalQueueERC721} from "../../../../src/v2/interfaces/IWithdrawalQueueERC721.sol";
import {IEligibleIncomeAccounting} from "../../../../src/v3/interfaces/IEligibleIncomeAccounting.sol";
import {StakedUSDatEligibleIncomeModule} from "../../../../src/v3/StakedUSDatEligibleIncomeModule.sol";
import {V2InitializationHelper} from "../../../v2/helpers/V2InitializationHelper.sol";
import {
    IncomeTokenMock,
    IncomeMirrorMock,
    IncomePriceOracleMock,
    IncomeModuleMock,
    IncomeAdapterMock
} from "../../helpers/StakedUSDatEligibleIncomeFixture.sol";

abstract contract TrancheAccountantFixture is Test {
    uint256 internal constant CASH = 100_000e6;
    uint256 internal constant POSITION = 10_000e18;
    uint256 internal constant WAD = 1e18;
    uint256 internal constant MAX_BACKING_VALUE = 500_000e6;

    IncomeTokenMock internal usdat;
    IncomeTokenMock internal strcon;
    IncomeMirrorMock internal mirror;
    IncomePriceOracleMock internal priceOracle;
    IncomeModuleMock internal strconModule;
    IncomeAdapterMock internal adapter;
    StakedUSDat internal vault;
    StakedUSDatEligibleIncomeModule internal incomeModule;
    TrancheAccountant internal accountant;
    TrancheShare internal senior;
    TrancheShare internal junior;

    address internal vehicle = makeAddr("vehicle");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public virtual {
        vm.warp(1_000_000);
        usdat = new IncomeTokenMock("USDat", "USDat", 6);
        strcon = new IncomeTokenMock("STRCon", "STRCon", 18);
        IWithdrawalQueueERC721 queue = IWithdrawalQueueERC721(makeAddr("v3Queue"));

        StakedUSDatV2 implementation = new StakedUSDatV2(queue);
        StakedUSDatV2 vaultV2 = StakedUSDatV2(
            address(
                new ERC1967Proxy(
                    address(implementation),
                    abi.encodeCall(StakedUSDatV2.initialize, (address(this), IERC20(address(usdat))))
                )
            )
        );
        mirror = new IncomeMirrorMock(address(vaultV2));
        priceOracle = new IncomePriceOracleMock();
        strconModule = new IncomeModuleMock(address(vaultV2), address(strcon), priceOracle);
        V2InitializationHelper.initialize(vaultV2, address(mirror), address(strconModule), 5, 10, 0);
        vaultV2.grantRole(vaultV2.OPERATOR_ROLE(), address(this));

        usdat.mint(address(this), CASH);
        usdat.approve(address(vaultV2), type(uint256).max);
        vaultV2.deposit(CASH, address(this));
        strconModule.seed(POSITION);
        strcon.mint(address(vaultV2), POSITION);
        mirror.retire();

        adapter = new IncomeAdapterMock(address(strcon));
        incomeModule = new StakedUSDatEligibleIncomeModule(address(vaultV2), address(this));
        vaultV2.grantRole(vaultV2.PARAMETER_MANAGER_ROLE(), address(incomeModule));
        StakedUSDat v3Implementation = new StakedUSDat(queue);
        vaultV2.upgradeToAndCall(
            address(v3Implementation),
            abi.encodeCall(
                StakedUSDat.initializeV3,
                (
                    incomeModule,
                    IEligibleIncomeAccounting.EligibleIncomeConfig({
                        adapter: adapter, configManager: address(this), maxUnreviewedGrowthBps: 2_000
                    })
                )
            )
        );
        vault = StakedUSDat(address(vaultV2));

        usdat.mint(vehicle, 2_000_000e6);
        vm.prank(vehicle);
        usdat.approve(address(vault), type(uint256).max);
        incomeModule.configureEligibleIncomeDependency(
            address(vault.executionPolicy()), abi.encodeCall(ISTRConExecutionPolicy.setExecutionVehicle, (vehicle))
        );

        accountant =
            new TrancheAccountant(vault, incomeModule, 5_000, 1.5e18, MAX_BACKING_VALUE, address(this), address(this));
        senior = accountant.SENIOR_TOKEN();
        junior = accountant.JUNIOR_TOKEN();
        vault.approve(address(accountant), type(uint256).max);
    }

    function _bootstrap() internal returns (uint256 juniorAssets, uint256 seniorAssets) {
        juniorAssets = vault.balanceOf(address(this)) / 10;
        seniorAssets = juniorAssets * 2;
        accountant.depositJunior(juniorAssets, address(this), 0, block.timestamp);
        accountant.depositSenior(seniorAssets, address(this), 0, block.timestamp);
    }
}
