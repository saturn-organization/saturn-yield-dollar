// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {StrcPriceOracle} from "../src/StrcPriceOracle.sol";
import {WithdrawalQueueERC721} from "../src/WithdrawalQueueERC721.sol";
import {StakedUSDat} from "../src/StakedUSDat.sol";
import {IStrcPriceOracle} from "../src/interfaces/IStrcPriceOracle.sol";
import {IWithdrawalQueueERC721} from "../src/interfaces/IWithdrawalQueueERC721.sol";

/**
 * @title VerifyCodeHash
 * @notice Rebuilds each protocol implementation in a local EVM and logs its
 *         runtime code hash (EXTCODEHASH), so the hashes can be compared to the
 *         live on-chain implementations.
 *
 *         Two of the contracts are UUPS upgradeable and bake immutables into
 *         their runtime bytecode at construction time, including the contract's
 *         OWN address (UUPSUpgradeable's `__self`). That makes their code hash
 *         address-dependent, so to reproduce the on-chain hash exactly this
 *         script replays each original deployment context -- the same deployer
 *         EOA and nonce -- so the implementation lands at the same address with
 *         the same immutables:
 *
 *           - StakedUSDat            immutables: (strcOracle, withdrawalQueue, __self)
 *           - WithdrawalQueueERC721  immutables: (usdat, stakedUsdat, __self)
 *           - StrcPriceOracle        NO immutables (AccessControl, not UUPS) --
 *                                    its code hash is address- and arg-independent.
 *
 *         All values are public and taken directly from the mainnet broadcasts
 *         under broadcast/.../1/run-latest.json. They are NOT read from the env
 *         file: `.env.prod`'s ORACLE/USDAT are different addresses than the
 *         constructor args wired between these contracts.
 */
contract VerifyCodeHash is Script {
    // ---- Shared / constructor-arg addresses (mainnet) --------------------------
    address constant DEPLOYER = 0x610182581C93687Ca03F4a8E7f124f8cEC616820; // Fireblocks admin EOA
    address constant USDAT = 0x23238f20b894f29041f48D88eE91131C395Aaa71;
    address constant STRC_ORACLE = 0x5f7eCD0D045c393da6cb6c933c671AC305A871BF; // StrcPriceOracle (deployed below)
    address constant WQ_PROXY = 0x4Bc9FEC04F0F95e9b42a3EF18F3C96fB57923D2e;
    address constant SUSDAT_PROXY = 0xD166337499E176bbC38a1FBd113Ab144e5bd2Df7;

    // ---- Original deployment context (deployer + nonce -> impl address) --------
    uint64 constant WQ_NONCE = 8; // UpgradeWithdrawalQueueERC721 (PR #87)
    uint64 constant SUSDAT_NONCE = 11; // UpgradeStakedUSDat (PR #88)
    address constant WQ_IMPL = 0x256fA0ba1b6dFB50EE883955c5a99D3C1b017Fd5;
    address constant SUSDAT_IMPL = 0x2005E0CA201a37694125fF267ae57872bEA0a0Ce;

    function run() external {
        // --- StrcPriceOracle: no immutables, so code hash is independent of the
        //     deploy address and constructor args (which only set storage). Any
        //     non-zero (admin, oracle) pair yields the same runtime code hash. ---
        StrcPriceOracle oracle = new StrcPriceOracle(DEPLOYER, STRC_ORACLE);
        console.log("StrcPriceOracle CODEHASH:");
        console.logBytes32(address(oracle).codehash);

        // --- WithdrawalQueueERC721: replay deployer + nonce 8 -> WQ_IMPL ---
        vm.setNonce(DEPLOYER, WQ_NONCE);
        vm.startPrank(DEPLOYER);
        WithdrawalQueueERC721 wq = new WithdrawalQueueERC721(USDAT, SUSDAT_PROXY);
        vm.stopPrank();
        require(address(wq) == WQ_IMPL, "WQ local deploy address != on-chain impl");
        console.log("WithdrawalQueueERC721 CODEHASH:");
        console.logBytes32(address(wq).codehash);

        // --- StakedUSDat: replay deployer + nonce 11 -> SUSDAT_IMPL ---
        vm.setNonce(DEPLOYER, SUSDAT_NONCE);
        vm.startPrank(DEPLOYER);
        StakedUSDat susdat =
            new StakedUSDat(IStrcPriceOracle(STRC_ORACLE), IWithdrawalQueueERC721(WQ_PROXY));
        vm.stopPrank();
        require(address(susdat) == SUSDAT_IMPL, "StakedUSDat local deploy address != on-chain impl");
        console.log("StakedUSDat CODEHASH:");
        console.logBytes32(address(susdat).codehash);
    }
}
