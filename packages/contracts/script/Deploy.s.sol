// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {FirstlessHook} from "firstless/hooks/FirstlessHook.sol";
import {FirstlessRefundRedeemer} from "firstless/periphery/FirstlessRefundRedeemer.sol";
import {FirstlessRouter} from "firstless/periphery/FirstlessRouter.sol";

contract DeployFirstless is Script {
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    address internal constant ETHEREUM_SEPOLIA_POOL_MANAGER = 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543;
    uint256 internal constant ETHEREUM_SEPOLIA_CHAIN_ID = 11_155_111;
    uint160 internal constant FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
            | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
    );

    error HookAddressMismatch();
    error WrongChain();
    error WrongPoolManager();

    function run() external returns (FirstlessHook hook, FirstlessRouter router, FirstlessRefundRedeemer redeemer) {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(privateKey);
        IPoolManager manager = IPoolManager(vm.envAddress("POOL_MANAGER"));
        if (block.chainid != ETHEREUM_SEPOLIA_CHAIN_ID) revert WrongChain();
        if (address(manager) != ETHEREUM_SEPOLIA_POOL_MANAGER) revert WrongPoolManager();
        uint256 feeNumerator = vm.envOr("FEE_NUMERATOR", uint256(997));
        uint256 feeDenominator = vm.envOr("FEE_DENOMINATOR", uint256(1000));
        uint256 outputCapBps = vm.envOr("OUTPUT_CAP_BPS", uint256(1000));

        vm.startBroadcast(privateKey);
        router = new FirstlessRouter(manager);
        redeemer = new FirstlessRefundRedeemer(manager);
        bytes memory args = abi.encode(manager, feeNumerator, feeDenominator, outputCapBps, address(router), deployer);
        (address expected, bytes32 salt) =
            HookMiner.find(CREATE2_DEPLOYER, FLAGS, type(FirstlessHook).creationCode, args);
        hook = new FirstlessHook{salt: salt}(
            manager, feeNumerator, feeDenominator, outputCapBps, address(router), deployer
        );
        if (address(hook) != expected) revert HookAddressMismatch();
        vm.stopBroadcast();
    }
}
