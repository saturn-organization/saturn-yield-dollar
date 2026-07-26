// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {StakedUSDat} from "../../../src/v2/StakedUSDat.sol";
import {IStakedUSDat} from "../../../src/v2/interfaces/IStakedUSDat.sol";
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

    function initialize(
        StakedUSDat vault,
        address mirror,
        address strcon,
        uint16 baseRedemptionFeeBps,
        uint16 elevatedRedemptionFeeBps,
        uint16 elevatedDepositFeeBps
    ) internal {
        vault.initializeV2(
            IStakedUSDat.V2Config({
                strcMirrorModule: ISTRCMirrorModule(mirror),
                strconModule: ISTRConModule(strcon),
                recoveryAddress: RECOVERY_ADDRESS,
                executionVehicle: EXECUTION_VEHICLE,
                baseRedemptionFeeBps: baseRedemptionFeeBps,
                elevatedRedemptionFeeBps: elevatedRedemptionFeeBps,
                elevatedDepositFeeBps: elevatedDepositFeeBps,
                executionToleranceBps: 0
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
