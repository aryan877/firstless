// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

contract UnichainSepoliaDependenciesTest is Test {
    address private constant UNICHAIN_SEPOLIA_POOL_MANAGER = 0x00B036B58a818B1BC34d502D3fE730Db729e62AC;

    function testFork_unichainSepoliaPoolManagerIsLive() public {
        string memory rpcUrl = vm.envOr("UNICHAIN_SEPOLIA_RPC_URL", string(""));
        if (bytes(rpcUrl).length == 0) vm.skip(true, "UNICHAIN_SEPOLIA_RPC_URL not set");
        vm.createSelectFork(rpcUrl);

        assertEq(block.chainid, 1301);
        assertGt(UNICHAIN_SEPOLIA_POOL_MANAGER.code.length, 0);
    }
}
