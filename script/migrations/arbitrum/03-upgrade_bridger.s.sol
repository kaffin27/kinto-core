// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import {Bridger} from "@kinto-core/bridger/Bridger.sol";

import {MigrationHelper} from "@kinto-core-script/utils/MigrationHelper.sol";
import {ArtifactsReader} from "@kinto-core-test/helpers/ArtifactsReader.sol";
import {UUPSProxy} from "@kinto-core-test/helpers/UUPSProxy.sol";

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "forge-std/Test.sol";

import {Constants} from "@kinto-core-script/migrations/arbitrum/const.sol";

contract UpgradeBridgerScript is Constants, Test, MigrationHelper {
    function run() public override {
        super.run();

        vm.startBroadcast(deployerPrivateKey);
        Bridger bridger = Bridger(payable(_getChainDeployment("Bridger")));
        bridger.upgradeTo(0x51Be166199E39805ac68b758A2236a5b3c358B01);
        console.log("owner", bridger.owner());
        bridger.transferOwnership(0x8bFe32Ac9C21609F45eE6AE44d4E326973700614);
        vm.stopBroadcast();

        // Checks
        assertEq(bridger.owner(), 0x8bFe32Ac9C21609F45eE6AE44d4E326973700614, "Invalid owner");
    }
}
