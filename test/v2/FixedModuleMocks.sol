// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IAccountingModule} from "../../src/v2/interfaces/IAccountingModule.sol";
import {ITradableModule} from "../../src/v2/interfaces/ITradableModule.sol";
import {BoundMirrorModuleMock, BoundSTRConModuleMock} from "./V2InitializationHelper.sol";

contract ZeroAccountingModuleMock is IAccountingModule, BoundMirrorModuleMock {
    constructor(address vault) BoundMirrorModuleMock(vault) {}

    function recognizedValue() external pure returns (uint256) {
        return 0;
    }

    function balance() external pure returns (uint256) {
        return 0;
    }
}

contract ZeroTradableModuleMock is ITradableModule, BoundSTRConModuleMock {
    constructor(address vault) BoundSTRConModuleMock(vault, address(this)) {}

    function recognizedValue() external pure returns (uint256) {
        return 0;
    }

    function balance() external pure returns (uint256) {
        return 0;
    }

    function asset() external view returns (address) {
        return ASSET;
    }

    function getPrice() external pure returns (uint256) {
        return 0;
    }

    function buy(uint256) external pure {}

    function sell(uint256) external pure {}
}
