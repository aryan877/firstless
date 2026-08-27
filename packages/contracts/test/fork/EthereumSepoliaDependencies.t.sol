// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

contract EthereumSepoliaDependenciesTest is Test {
    address private constant ETHEREUM_SEPOLIA_POOL_MANAGER = 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543;

    function testFork_ethereumSepoliaPoolManagerIsLive() public {
        string memory rpcUrl = vm.envOr("ETHEREUM_SEPOLIA_RPC_URL", string(""));
        if (bytes(rpcUrl).length == 0) vm.skip(true, "ETHEREUM_SEPOLIA_RPC_URL not set");
        vm.createSelectFork(rpcUrl);

        assertEq(block.chainid, 11_155_111);
        assertGt(ETHEREUM_SEPOLIA_POOL_MANAGER.code.length, 0);
    }
}
