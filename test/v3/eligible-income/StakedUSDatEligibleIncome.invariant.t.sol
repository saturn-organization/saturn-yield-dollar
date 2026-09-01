// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {StakedUSDat as StakedUSDatV2} from "../../../src/v2/StakedUSDat.sol";
import {StakedUSDat} from "../../../src/v3/StakedUSDat.sol";
import {IStakedUSDat} from "../../../src/v2/interfaces/IStakedUSDat.sol";
import {ISTRConExecutionPolicy} from "../../../src/v2/interfaces/ISTRConExecutionPolicy.sol";
import {IWithdrawalQueueERC721} from "../../../src/v2/interfaces/IWithdrawalQueueERC721.sol";
import {IEligibleIncomeAccounting} from "../../../src/v3/interfaces/IEligibleIncomeAccounting.sol";
import {StakedUSDatEligibleIncomeModule} from "../../../src/v3/StakedUSDatEligibleIncomeModule.sol";
import {V2InitializationHelper} from "../../v2/helpers/V2InitializationHelper.sol";
import "../helpers/StakedUSDatEligibleIncomeFixture.sol";

contract EligibleIncomeHandler is Test {
    StakedUSDatV2 public immutable vault;
    StakedUSDatEligibleIncomeModule public immutable incomeModule;
    IncomeAdapterMock public immutable adapter;
    IncomeModuleMock public immutable module;
    IncomeTokenMock public immutable usdat;
    address public immutable vehicle;
    uint256 public totalFundedUSDat;

    constructor(
        StakedUSDatV2 vault_,
        StakedUSDatEligibleIncomeModule incomeModule_,
        IncomeAdapterMock adapter_,
        IncomeModuleMock module_,
        IncomeTokenMock usdat_,
        address vehicle_
    ) {
        vault = vault_;
        incomeModule = incomeModule_;
        adapter = adapter_;
        module = module_;
        usdat = usdat_;
        vehicle = vehicle_;
        usdat_.approve(address(vault_), type(uint256).max);
    }

    // ============ Handler Actions ============

    function growAndMaterialize(uint16 rawBps) external {
        _growWithinReviewLimit(rawBps);
        incomeModule.materializeSTRConEligibleIncome();
    }

    function growWithoutMaterializing(uint16 rawBps) external {
        _growWithinReviewLimit(rawBps);
    }

    function deposit(uint64 rawAssets) external {
        uint256 assets = bound(uint256(rawAssets), 1e6, 1_000e6);
        usdat.mint(address(this), assets);
        vault.deposit(assets, address(this));
    }

    function sellPartial(uint96 rawAmount) external {
        uint256 exposure = module.balance();
        uint256 wholeUnits = exposure / 1e18;
        if (wholeUnits < 2) return;
        uint256 delivered = bound(uint256(rawAmount), 1, wholeUnits / 2) * 1e18;
        uint256 received = Math.mulDiv(delivered, 100e6, 1e18);
        vault.sell(delivered, received, vehicle, block.timestamp);
    }

    function fundSurplus(uint64 rawAssets) external {
        if (vault.getUnvestedSurplus() != 0) return;
        uint256 assets = bound(uint256(rawAssets), 1e6, 1_000e6);
        usdat.mint(address(this), assets);
        vault.transferInSurplus(assets);
        totalFundedUSDat += assets;
    }

    function advanceAndSweep(uint32 rawSeconds) external {
        uint256 elapsed = bound(uint256(rawSeconds), 1, vault.surplusVestingPeriod());
        vm.warp(block.timestamp + elapsed);
        vault.sweep();
    }

    // ============ Handler Internals ============

    function _growWithinReviewLimit(uint16 rawBps) private {
        IEligibleIncomeAccounting.EligibleIncomeState memory state = incomeModule.eligibleIncomeState();
        uint256 ceiling =
            state.lastAcceptedRawIndex + Math.mulDiv(state.lastAcceptedRawIndex, state.maxUnreviewedGrowthBps, 10_000);
        uint256 current = adapter.index();
        if (current >= ceiling) return;
        uint256 increment = Math.mulDiv(ceiling - current, bound(uint256(rawBps), 0, 10_000), 10_000);
        adapter.setIndex(current + increment);
    }
}

contract StakedUSDatEligibleIncomeInvariantTest is StdInvariant, Test {
    IncomeTokenMock private usdat;
    IncomeTokenMock private strcon;
    IncomeModuleMock private module;
    IncomeAdapterMock private adapter;
    StakedUSDatV2 private vault;
    StakedUSDatEligibleIncomeModule private incomeModule;
    EligibleIncomeHandler private handler;

    // ============ Setup ============

    function setUp() public {
        vm.warp(1_000_000);
        usdat = new IncomeTokenMock("USDat", "USDat", 6);
        strcon = new IncomeTokenMock("STRCon", "STRCon", 18);
        StakedUSDatV2 implementation = new StakedUSDatV2(IWithdrawalQueueERC721(makeAddr("invariantQueue")));
        vault = StakedUSDatV2(
            address(
                new ERC1967Proxy(
                    address(implementation),
                    abi.encodeCall(StakedUSDatV2.initialize, (address(this), IERC20(address(usdat))))
                )
            )
        );
        IncomeMirrorMock mirror = new IncomeMirrorMock(address(vault));
        module = new IncomeModuleMock(address(vault), address(strcon), new IncomePriceOracleMock());
        V2InitializationHelper.initialize(vault, address(mirror), address(module), 5, 10, 0);

        usdat.mint(address(this), 100_000e6);
        usdat.approve(address(vault), type(uint256).max);
        vault.deposit(100_000e6, address(this));
        module.seed(10_000e18);
        strcon.mint(address(vault), 10_000e18);
        mirror.retire();

        adapter = new IncomeAdapterMock(address(strcon));
        incomeModule = new StakedUSDatEligibleIncomeModule(address(vault), address(this));
        vault.grantRole(vault.PARAMETER_MANAGER_ROLE(), address(incomeModule));
        StakedUSDat v3Implementation = new StakedUSDat(IWithdrawalQueueERC721(makeAddr("invariantQueue")));
        vault.upgradeToAndCall(
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

        address vehicle = makeAddr("invariantVehicle");
        usdat.mint(vehicle, 2_000_000e6);
        vm.prank(vehicle);
        usdat.approve(address(vault), type(uint256).max);
        _setVehicle(vehicle);

        handler = new EligibleIncomeHandler(vault, incomeModule, adapter, module, usdat, vehicle);
        vault.grantRole(vault.OPERATOR_ROLE(), address(handler));
        vault.grantRole(vault.SURPLUS_MANAGER_ROLE(), address(handler));
        incomeModule.configureEligibleIncomeDependency(
            address(vault), abi.encodeCall(IStakedUSDat.setSurplusSource, (address(handler)))
        );
        targetContract(address(handler));
    }

    // ============ Invariant Properties ============

    function invariant_incomeStateRemainsActiveUnderAdmissibleTransitions() public view {
        IEligibleIncomeAccounting.EligibleIncomeState memory state = incomeModule.eligibleIncomeState();
        assertEq(uint256(state.state), uint256(IEligibleIncomeAccounting.IncomeState.Active));
    }

    function invariant_strconCustodyCoversReportedExposure() public view {
        assertGe(strcon.balanceOf(address(vault)), module.balance());
        assertGt(module.balance(), 0);
    }

    function invariant_liveAffineTransformRemainsBoundedByCumulativeUnits() public view {
        IEligibleIncomeAccounting.EligibleIncomeState memory state = incomeModule.eligibleIncomeState();
        assertLe(state.liveUnitScaleWad, 1e18);
        assertLe(state.liveUnitsOffsetWad, state.eligibleUnitsPerSUSDatShareWad);
    }

    function invariant_fundedUSDatLedgerConservesRegisteredFunding() public view {
        IEligibleIncomeAccounting.EligibleIncomeState memory state = incomeModule.eligibleIncomeState();
        assertEq(state.fundedUSDat, handler.totalFundedUSDat());
        assertEq(state.fundedUSDat, state.pendingFundedUSDat + state.recognizedUSDat);
    }

    function invariant_acceptedIndexNeverLeadsTheCurrentAdapterIndex() public view {
        IEligibleIncomeAccounting.EligibleIncomeState memory state = incomeModule.eligibleIncomeState();
        uint256 normalized = Math.mulDiv(adapter.index(), 1e18, state.cumulativeStructuralAdjustmentFactorWad);
        assertLe(state.lastAcceptedRawIndex, adapter.index());
        assertLe(state.lastEligibleUnitIndexWad, normalized);
    }

    function invariant_previewMatchesIndependentCurrentIndexAccounting() public view {
        IEligibleIncomeAccounting.EligibleIncomeState memory state = incomeModule.eligibleIncomeState();
        uint256 normalized = Math.mulDiv(adapter.index(), 1e18, state.cumulativeStructuralAdjustmentFactorWad);
        uint256 expected = state.eligibleUnitsPerSUSDatShareWad;
        if (normalized != state.lastEligibleUnitIndexWad && vault.totalSupply() != 0) {
            expected += Math.mulDiv(
                module.balance(), normalized - state.lastEligibleUnitIndexWad, vault.totalSupply(), Math.Rounding.Floor
            );
        }
        assertEq(incomeModule.previewSTRConEligibleUnitsPerShareWad(), expected);
    }

    // ============ Helpers ============

    function _setVehicle(address newVehicle) private {
        incomeModule.configureEligibleIncomeDependency(
            address(vault.executionPolicy()), abi.encodeCall(ISTRConExecutionPolicy.setExecutionVehicle, (newVehicle))
        );
    }
}
