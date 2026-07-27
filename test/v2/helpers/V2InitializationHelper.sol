// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {StakedUSDat} from "../../../src/v2/StakedUSDat.sol";
import {STRConExecutionPolicy} from "../../../src/v2/STRConExecutionPolicy.sol";
import {IStakedUSDat} from "../../../src/v2/interfaces/IStakedUSDat.sol";
import {ISTRConExecutionPolicy} from "../../../src/v2/interfaces/ISTRConExecutionPolicy.sol";
import {ISTRCMirrorModule} from "../../../src/v2/interfaces/modules/ISTRCMirrorModule.sol";
import {ISTRConModule} from "../../../src/v2/interfaces/modules/ISTRConModule.sol";

abstract contract BoundMirrorModuleMock {
    address public immutable VAULT;
    bool public seeded;
    bool public retired;

    constructor(address vault) {
        VAULT = vault;
    }

    function seed(uint256, uint256, uint256, uint256, uint256) external {
        seeded = true;
    }

    function retire() external {
        retired = true;
    }

    function getUnvestedAmount() external pure returns (uint256) {
        return 0;
    }
}

abstract contract BoundSTRConModuleMock {
    address public immutable VAULT;
    address public immutable ASSET;

    constructor(address vault, address asset_) {
        VAULT = vault;
        ASSET = asset_;
    }
}

library V2InitializationHelper {
    address internal constant RECOVERY_ADDRESS = address(0x1001);
    address internal constant EXECUTION_VEHICLE = address(0x1002);
    uint64 internal constant MAX_REGULAR_MODE_VALIDITY = 8 hours;

    function initialize(
        StakedUSDat vault,
        address mirror,
        address strcon,
        uint16 baseRedemptionFeeBps,
        uint16 elevatedRedemptionFeeBps,
        uint16 elevatedDepositFeeBps
    ) internal {
        initialize(
            vault,
            mirror,
            strcon,
            baseRedemptionFeeBps,
            elevatedRedemptionFeeBps,
            elevatedDepositFeeBps,
            uint64(block.timestamp + MAX_REGULAR_MODE_VALIDITY),
            type(uint128).max,
            0
        );
    }

    function initialize(
        StakedUSDat vault,
        address mirror,
        address strcon,
        uint16 baseRedemptionFeeBps,
        uint16 elevatedRedemptionFeeBps,
        uint16 elevatedDepositFeeBps,
        uint64 regularModeValidUntil
    ) internal {
        initialize(
            vault,
            mirror,
            strcon,
            baseRedemptionFeeBps,
            elevatedRedemptionFeeBps,
            elevatedDepositFeeBps,
            regularModeValidUntil,
            type(uint128).max,
            0
        );
    }

    function initialize(
        StakedUSDat vault,
        address mirror,
        address strcon,
        uint16 baseRedemptionFeeBps,
        uint16 elevatedRedemptionFeeBps,
        uint16 elevatedDepositFeeBps,
        uint64 regularModeValidUntil,
        uint128 initialExecutionCapacity,
        uint128 initialExecutionRefillPerDay
    ) internal {
        ISTRConModule strconModule = ISTRConModule(strcon);
        ISTRConExecutionPolicy executionPolicy = new STRConExecutionPolicy(address(vault), strconModule);

        initializeWithPolicy(
            vault,
            mirror,
            strconModule,
            executionPolicy,
            baseRedemptionFeeBps,
            elevatedRedemptionFeeBps,
            elevatedDepositFeeBps,
            regularModeValidUntil,
            initialExecutionCapacity,
            initialExecutionRefillPerDay
        );
    }

    function initializeWithPolicy(
        StakedUSDat vault,
        address mirror,
        ISTRConModule strconModule,
        ISTRConExecutionPolicy executionPolicy,
        uint16 baseRedemptionFeeBps,
        uint16 elevatedRedemptionFeeBps,
        uint16 elevatedDepositFeeBps,
        uint64 regularModeValidUntil,
        uint128 initialExecutionCapacity,
        uint128 initialExecutionRefillPerDay
    ) internal {
        vault.initializeV2(
            IStakedUSDat.V2Config({
                strcMirrorModule: ISTRCMirrorModule(mirror),
                strconModule: strconModule,
                executionPolicy: executionPolicy,
                recoveryAddress: RECOVERY_ADDRESS,
                executionVehicle: EXECUTION_VEHICLE,
                baseRedemptionFeeBps: baseRedemptionFeeBps,
                elevatedRedemptionFeeBps: elevatedRedemptionFeeBps,
                elevatedDepositFeeBps: elevatedDepositFeeBps,
                executionToleranceBps: 0,
                initialRegularModeValidUntil: regularModeValidUntil,
                initialExecutionCapacity: initialExecutionCapacity,
                initialExecutionRefillPerDay: initialExecutionRefillPerDay
            }),
            IStakedUSDat.V2Roles({
                parameterManager: address(this),
                marketModeManager: address(this),
                operator: address(this),
                blacklister: address(this),
                enforcer: address(this),
                pauser: address(this),
                unpauser: address(this)
            })
        );
    }
}
