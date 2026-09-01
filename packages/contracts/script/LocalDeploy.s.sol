// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {BaseCustomAccounting} from "ozhooks/base/BaseCustomAccounting.sol";
import {FirstlessHook} from "firstless/hooks/FirstlessHook.sol";
import {FirstlessRefundRedeemer} from "firstless/periphery/FirstlessRefundRedeemer.sol";
import {FirstlessRouter} from "firstless/periphery/FirstlessRouter.sol";
import {FirstlessDevToken} from "./mocks/LocalDevContracts.sol";

/// @notice Deploys a complete, seeded Firstless development environment to local Anvil.
contract LocalDeployFirstless is Script {
    using PoolIdLibrary for PoolKey;

    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    uint160 internal constant FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
            | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
    );
    uint160 internal constant SQRT_PRICE_1_1 = 79_228_162_514_264_337_593_543_950_336;
    int24 internal constant MIN_TICK = -887_220;
    int24 internal constant MAX_TICK = 887_220;
    uint256 internal constant INITIAL_LIQUIDITY = 1_000 ether;
    uint256 internal constant DEMO_WALLET_BALANCE = 10_000 ether;

    error HookAddressMismatch();
    error LocalChainRequired();

    function run()
        external
        returns (
            PoolManager manager,
            FirstlessHook hook,
            FirstlessRouter router,
            FirstlessRefundRedeemer redeemer,
            FirstlessDevToken token0,
            FirstlessDevToken token1
        )
    {
        if (block.chainid != 31_337) revert LocalChainRequired();

        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(privateKey);
        uint256 feeNumerator = vm.envOr("FEE_NUMERATOR", uint256(997));
        uint256 feeDenominator = vm.envOr("FEE_DENOMINATOR", uint256(1000));
        uint256 outputCapBps = vm.envOr("OUTPUT_CAP_BPS", uint256(1000));

        vm.startBroadcast(privateKey);
        manager = new PoolManager(deployer);
        FirstlessDevToken faucetUsd = new FirstlessDevToken("Firstless USD", "fUSD");
        FirstlessDevToken faucetEth = new FirstlessDevToken("Firstless Ether", "fETH");
        router = new FirstlessRouter(manager);
        redeemer = new FirstlessRefundRedeemer(manager);

        bytes memory args = abi.encode(manager, feeNumerator, feeDenominator, outputCapBps, address(router), deployer);
        (address expected, bytes32 salt) =
            HookMiner.find(CREATE2_DEPLOYER, FLAGS, type(FirstlessHook).creationCode, args);
        hook = new FirstlessHook{salt: salt}(
            manager, feeNumerator, feeDenominator, outputCapBps, address(router), deployer
        );
        if (address(hook) != expected) revert HookAddressMismatch();

        if (address(faucetUsd) < address(faucetEth)) {
            token0 = faucetUsd;
            token1 = faucetEth;
        } else {
            token0 = faucetEth;
            token1 = faucetUsd;
        }

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        manager.initialize(key, SQRT_PRICE_1_1);

        token0.faucet(deployer, INITIAL_LIQUIDITY);
        token1.faucet(deployer, INITIAL_LIQUIDITY);
        token0.approve(address(hook), type(uint256).max);
        token1.approve(address(hook), type(uint256).max);
        hook.addLiquidity(
            BaseCustomAccounting.AddLiquidityParams({
                amount0Desired: INITIAL_LIQUIDITY,
                amount1Desired: INITIAL_LIQUIDITY,
                amount0Min: INITIAL_LIQUIDITY,
                amount1Min: INITIAL_LIQUIDITY,
                deadline: type(uint256).max,
                tickLower: MIN_TICK,
                tickUpper: MAX_TICK,
                userInputSalt: bytes32(0)
            })
        );
        token0.faucet(deployer, DEMO_WALLET_BALANCE);
        token1.faucet(deployer, DEMO_WALLET_BALANCE);
        vm.stopBroadcast();

        _writeDeployment(key, manager, hook, router, redeemer, token0, token1);
    }

    function _writeDeployment(
        PoolKey memory key,
        PoolManager manager,
        FirstlessHook hook,
        FirstlessRouter router,
        FirstlessRefundRedeemer redeemer,
        FirstlessDevToken token0,
        FirstlessDevToken token1
    ) internal {
        string memory objectKey = "firstlessLocalDeployment";
        vm.serializeUint(objectKey, "schemaVersion", 1);
        vm.serializeString(objectKey, "mode", "local");
        vm.serializeUint(objectKey, "chainId", block.chainid);
        vm.serializeString(objectKey, "chainName", "Firstless Local (Ethereum block semantics)");
        vm.serializeString(objectKey, "rpcUrl", vm.envOr("FIRSTLESS_RPC_URL", string("http://127.0.0.1:8546")));
        vm.serializeUint(objectKey, "deploymentBlock", block.number);
        vm.serializeAddress(objectKey, "poolManager", address(manager));
        vm.serializeAddress(objectKey, "hook", address(hook));
        vm.serializeAddress(objectKey, "router", address(router));
        vm.serializeAddress(objectKey, "redeemer", address(redeemer));
        vm.serializeAddress(objectKey, "token0", address(token0));
        vm.serializeAddress(objectKey, "token1", address(token1));
        vm.serializeString(objectKey, "token0Symbol", token0.symbol());
        vm.serializeString(objectKey, "token1Symbol", token1.symbol());
        vm.serializeUint(objectKey, "token0Decimals", token0.decimals());
        vm.serializeUint(objectKey, "token1Decimals", token1.decimals());
        vm.serializeUint(objectKey, "poolFee", key.fee);
        vm.serializeInt(objectKey, "tickSpacing", key.tickSpacing);
        vm.serializeInt(objectKey, "minimumTick", MIN_TICK);
        vm.serializeInt(objectKey, "maximumTick", MAX_TICK);
        vm.serializeUint(objectKey, "feeNumerator", hook.feeNumerator());
        vm.serializeUint(objectKey, "feeDenominator", hook.feeDenominator());
        vm.serializeUint(objectKey, "outputCapBps", hook.capBps());
        vm.serializeBytes32(objectKey, "poolId", PoolId.unwrap(key.toId()));
        vm.serializeUint(objectKey, "initialLiquidity", INITIAL_LIQUIDITY);
        string memory json = vm.serializeUint(objectKey, "demoWalletBalance", DEMO_WALLET_BALANCE);
        string memory defaultPath = string.concat(vm.projectRoot(), "/../../apps/web/public/deployments/local.json");
        vm.writeJson(json, vm.envOr("FIRSTLESS_DEPLOYMENT_PATH", defaultPath));
    }
}
