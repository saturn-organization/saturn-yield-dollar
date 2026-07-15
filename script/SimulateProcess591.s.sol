// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IWithdrawalQueueERC721} from "../src/interfaces/IWithdrawalQueueERC721.sol";
import {IStakedUSDat} from "../src/interfaces/IStakedUSDat.sol";

/// Simulation only. Run: forge script script/SimulateProcess591.s.sol --fork-url $RPC_URL
contract SimulateProcess591 is Script {
    IWithdrawalQueueERC721 constant WQ =
        IWithdrawalQueueERC721(0x4Bc9FEC04F0F95e9b42a3EF18F3C96fB57923D2e);
    IStakedUSDat constant SUSDAT =
        IStakedUSDat(0xD166337499E176bbC38a1FBd113Ab144e5bd2Df7);
    IERC20 constant USDAT = IERC20(0x23238f20b894f29041f48D88eE91131C395Aaa71);

    function run() external {
        address processor = vm.envAddress("PROCESSOR");
        // uint256 feeBps = uint256(250); // 2000 = 0.2
        // uint256 positionUsdat = uint256(178396428163);
        // uint256 positionStrc = uint256(2040682088);

        // uint256 usdatAmount = (positionUsdat * (10000 - feeBps)) / 10000;
        // uint256 strcAmount = (positionStrc * (10000 - feeBps)) / 10000;
        uint256 usdatAmount = uint256(409000000000);
        uint256 strcAmount = uint256(4636136930);

        uint256 strcPrice = uint256(8822000000);
        uint256 tokenId = 606;

        IWithdrawalQueueERC721.Request memory req = WQ.getRequest(tokenId);
        console2.log("BEFORE  usdatAmount:", usdatAmount);
        console2.log("BEFORE  strcAmount:", strcAmount);
        // console2.log("BEFORE  positionUsdat:", positionUsdat);
        // console2.log("BEFORE  positionStrc:", positionStrc);
        console2.log("BEFORE  sUSDat usdatBalance:", SUSDAT.usdatBalance());
        console2.log("BEFORE  sUSDat strcBalance:", SUSDAT.strcBalance());

        uint256[] memory ids = new uint256[](1);
        ids[0] = tokenId;

        vm.startPrank(processor);
        SUSDAT.convertFromUsdat(usdatAmount, strcAmount, strcPrice); // vault funds processor with USDat
        USDAT.approve(address(WQ), usdatAmount);
        WQ.processRequests(ids, usdatAmount, strcAmount, strcPrice);
        vm.stopPrank();

        req = WQ.getRequest(tokenId);
        require(
            req.status == IWithdrawalQueueERC721.RequestStatus.Processed,
            "not Processed"
        );
        console2.log("AFTER   usdatOwed:", req.usdatOwed);
        console2.log("AFTER   sUSDat usdatBalance:", SUSDAT.usdatBalance());
        console2.log("AFTER   sUSDat strcBalance:", SUSDAT.strcBalance());
    }
}
