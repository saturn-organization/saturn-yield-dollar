// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {StakedUSDat as StakedUSDatV2} from "../../../src/v2/StakedUSDat.sol";
import {StakedUSDat} from "../../../src/v3/StakedUSDat.sol";
import {IStakedUSDat} from "../../../src/v2/interfaces/IStakedUSDat.sol";
import {ISTRConExecutionPolicy} from "../../../src/v2/interfaces/ISTRConExecutionPolicy.sol";
import {IWithdrawalQueueERC721} from "../../../src/v2/interfaces/IWithdrawalQueueERC721.sol";
import {IAccountingModule} from "../../../src/v2/interfaces/modules/IAccountingModule.sol";
import {ISTRConModule} from "../../../src/v2/interfaces/modules/ISTRConModule.sol";
import {ISTRConPriceOracle} from "../../../src/v2/interfaces/oracles/ISTRConPriceOracle.sol";
import {IEligibleIncomeAccounting} from "../../../src/v3/interfaces/IEligibleIncomeAccounting.sol";
import {IEligibleIncomeAdapter} from "../../../src/v3/interfaces/IEligibleIncomeAdapter.sol";
import {StakedUSDatEligibleIncomeModule} from "../../../src/v3/StakedUSDatEligibleIncomeModule.sol";
import {BoundMirrorModuleMock, V2InitializationHelper} from "../../v2/helpers/V2InitializationHelper.sol";

contract IncomeTokenMock is ERC20 {
    uint8 private immutable _DECIMALS;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _DECIMALS = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _DECIMALS;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function isFrozen(address) external pure returns (bool) {
        return false;
    }
}

contract IncomeMirrorMock is IAccountingModule, BoundMirrorModuleMock {
    constructor(address vault) BoundMirrorModuleMock(vault) {}

    function recognizedValue() external pure returns (uint256) {
        return 0;
    }

    function balance() external pure returns (uint256) {
        return 0;
    }
}

contract IncomePriceOracleMock is ISTRConPriceOracle {
    uint256 public price = 100e8;
    bool public unhealthy;

    function setUnhealthy(bool value) external {
        unhealthy = value;
    }

    function setPrice(uint256 value) external {
        price = value;
    }

    function decimals() external pure returns (uint8) {
        return 8;
    }

    function getPrice() external view returns (uint256) {
        require(!unhealthy, "unhealthy");
        return price;
    }
}

contract IncomeModuleMock is ISTRConModule {
    error Unauthorized();

    bytes32 private constant PARAMETER_MANAGER_ROLE = keccak256("PARAMETER_MANAGER_ROLE");
    address public immutable override VAULT;
    address public immutable override ASSET;
    uint256 private _balance;
    ISTRConPriceOracle public override oracle;

    constructor(address vault, address asset_, ISTRConPriceOracle oracle_) {
        VAULT = vault;
        ASSET = asset_;
        oracle = oracle_;
    }

    function seed(uint256 amount) external {
        _balance = amount;
    }

    function recognizedValue() external view returns (uint256) {
        return Math.mulDiv(_balance, oracle.getPrice(), 1e20);
    }

    function balance() external view returns (uint256) {
        return _balance;
    }

    function asset() external view returns (address) {
        return ASSET;
    }

    function getPrice() external view returns (uint256) {
        return oracle.getPrice();
    }

    function buy(uint256 amount) external {
        if (msg.sender != VAULT) revert Unauthorized();
        _balance += amount;
    }

    function sell(uint256 amount) external {
        if (msg.sender != VAULT) revert Unauthorized();
        _balance -= amount;
    }

    function setOracle(address newOracle) external {
        if (!IAccessControl(VAULT).hasRole(PARAMETER_MANAGER_ROLE, msg.sender)) revert Unauthorized();
        oracle = ISTRConPriceOracle(newOracle);
    }
}

contract IncomeAdapterMock is IEligibleIncomeAdapter {
    address public immutable override asset;
    uint256 public index = 1e18;
    bool public unhealthy;

    constructor(address asset_) {
        asset = asset_;
    }

    function setIndex(uint256 newIndex) external {
        index = newIndex;
    }

    function setUnhealthy(bool value) external {
        unhealthy = value;
    }

    function rawIndex() external view returns (uint256) {
        require(!unhealthy && index != 0, "unhealthy");
        return index;
    }
}

contract IncomeWithdrawalQueueHarness {
    function checkpoint(IStakedUSDat vault, StakedUSDatEligibleIncomeModule incomeModule)
        external
        returns (IEligibleIncomeAccounting.EligibleIncomeState memory state)
    {
        vault.beginRedemptionBatch();
        state = incomeModule.eligibleIncomeState();
        vault.endRedemptionBatch();
    }
}

abstract contract StakedUSDatEligibleIncomeFixture is Test {
    uint256 internal constant CASH = 100_000e6;
    uint256 internal constant POSITION = 10_000e18;
    uint16 internal constant MAX_GROWTH_BPS = 2_000;

    IncomeTokenMock internal usdat;
    IncomeTokenMock internal strcon;
    IncomeMirrorMock internal mirror;
    IncomeModuleMock internal module;
    IncomeAdapterMock internal adapter;
    StakedUSDatV2 internal vault;
    StakedUSDat internal v3Implementation;
    StakedUSDatEligibleIncomeModule internal incomeModule;
    address internal vehicle = makeAddr("vehicle");
    IncomeWithdrawalQueueHarness internal withdrawalQueue;
    address internal alice = makeAddr("alice");
    address internal oldParameterManager = makeAddr("oldParameterManager");
    bytes32[19] internal v2LinearSlots;

    function setUp() public virtual {
        vm.warp(1_000_000);
        usdat = new IncomeTokenMock("USDat", "USDat", 6);
        strcon = new IncomeTokenMock("STRCon", "STRCon", 18);
        withdrawalQueue = new IncomeWithdrawalQueueHarness();

        IWithdrawalQueueERC721 queue = IWithdrawalQueueERC721(address(withdrawalQueue));
        StakedUSDatV2 implementation = new StakedUSDatV2(queue);
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(implementation), abi.encodeCall(StakedUSDatV2.initialize, (address(this), IERC20(address(usdat))))
        );
        vault = StakedUSDatV2(address(proxy));

        mirror = new IncomeMirrorMock(address(vault));
        module = new IncomeModuleMock(address(vault), address(strcon), new IncomePriceOracleMock());
        V2InitializationHelper.initialize(vault, address(mirror), address(module), 5, 10, 0);
        vault.grantRole(vault.OPERATOR_ROLE(), address(this));
        vault.grantRole(vault.PARAMETER_MANAGER_ROLE(), oldParameterManager);

        usdat.mint(address(this), CASH);
        usdat.approve(address(vault), type(uint256).max);
        vault.deposit(CASH, address(this));

        module.seed(POSITION);
        strcon.mint(address(vault), POSITION);
        mirror.retire();

        usdat.mint(vehicle, 1_000_000e6);
        vm.prank(vehicle);
        usdat.approve(address(vault), type(uint256).max);

        adapter = new IncomeAdapterMock(address(strcon));
        incomeModule = new StakedUSDatEligibleIncomeModule(address(vault), address(this));
        vault.grantRole(vault.PARAMETER_MANAGER_ROLE(), address(incomeModule));
        for (uint256 slot; slot < v2LinearSlots.length; ++slot) {
            v2LinearSlots[slot] = vm.load(address(vault), bytes32(slot));
        }

        v3Implementation = new StakedUSDat(queue);
        vault.upgradeToAndCall(
            address(v3Implementation),
            abi.encodeCall(
                StakedUSDat.initializeV3,
                (
                    incomeModule,
                    IEligibleIncomeAccounting.EligibleIncomeConfig({
                        adapter: adapter, configManager: address(this), maxUnreviewedGrowthBps: MAX_GROWTH_BPS
                    })
                )
            )
        );
    }

    function _setVehicle(address newVehicle) internal {
        incomeModule.configureEligibleIncomeDependency(
            address(vault.executionPolicy()), abi.encodeCall(ISTRConExecutionPolicy.setExecutionVehicle, (newVehicle))
        );
    }

    function _setModuleOracle(address newOracle) internal {
        incomeModule.configureEligibleIncomeDependency(
            address(module), abi.encodeCall(ISTRConModule.setOracle, (newOracle))
        );
    }
}
