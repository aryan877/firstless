// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {BaseCustomAccounting} from "ozhooks/base/BaseCustomAccounting.sol";
import {FirstlessHook} from "firstless/hooks/FirstlessHook.sol";
import {FirstlessRefundRedeemer} from "firstless/periphery/FirstlessRefundRedeemer.sol";
import {FirstlessRouter} from "firstless/periphery/FirstlessRouter.sol";
import {FirstlessSepoliaToken} from "./testnet/FirstlessSepoliaToken.sol";

/// @notice Deploys and seeds the complete public Firstless demo on a supported testnet.
contract DeployFirstless is Script {
    using PoolIdLibrary for PoolKey;

    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    address internal constant ETHEREUM_SEPOLIA_POOL_MANAGER = 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543;
    address internal constant UNICHAIN_SEPOLIA_POOL_MANAGER = 0x00B036B58a818B1BC34d502D3fE730Db729e62AC;
    uint256 internal constant ETHEREUM_SEPOLIA_CHAIN_ID = 11_155_111;
    uint256 internal constant UNICHAIN_SEPOLIA_CHAIN_ID = 1301;
    uint160 internal constant FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
            | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
    );
    uint160 internal constant SQRT_PRICE_1_1 = 79_228_162_514_264_337_593_543_950_336;
    int24 internal constant MIN_TICK = -887_220;
    int24 internal constant MAX_TICK = 887_220;
    uint256 internal constant INITIAL_LIQUIDITY = 1_000 ether;
    uint256 internal constant INITIAL_TOKEN_SUPPLY = 10_000 ether;

    error HookAddressMismatch();
    error InvalidDeployer();
    error UnsupportedChain();
    error WrongPoolManager();

    struct NetworkConfig {
        address poolManager;
        string chainName;
        string publicRpcUrl;
        string explorerUrl;
        string manifestName;
    }

    function run()
        external
        returns (
            FirstlessHook hook,
            FirstlessRouter router,
            FirstlessRefundRedeemer redeemer,
            FirstlessSepoliaToken token0,
            FirstlessSepoliaToken token1
        )
    {
        NetworkConfig memory network = _networkConfig();
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(privateKey);
        if (deployer == address(0)) revert InvalidDeployer();
        IPoolManager manager = IPoolManager(vm.envAddress("POOL_MANAGER"));
        if (address(manager) != network.poolManager) revert WrongPoolManager();

        uint256 deploymentBlock = block.number;
        uint256 feeNumerator = vm.envOr("FEE_NUMERATOR", uint256(997));
        uint256 feeDenominator = vm.envOr("FEE_DENOMINATOR", uint256(1000));
        uint256 outputCapBps = vm.envOr("OUTPUT_CAP_BPS", uint256(1000));

        vm.startBroadcast(privateKey);
        FirstlessSepoliaToken faucetUsd =
            new FirstlessSepoliaToken("Firstless Sepolia USD", "fUSD", deployer, INITIAL_TOKEN_SUPPLY);
        FirstlessSepoliaToken faucetEth =
            new FirstlessSepoliaToken("Firstless Sepolia Ether", "fETH", deployer, INITIAL_TOKEN_SUPPLY);
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

        token0.approve(address(hook), INITIAL_LIQUIDITY);
        token1.approve(address(hook), INITIAL_LIQUIDITY);
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
        vm.stopBroadcast();

        _writeDeployment(deploymentBlock, network, key, manager, hook, router, redeemer, token0, token1);
        console2.log("Firstless testnet deployment");
        console2.log("PoolManager", address(manager));
        console2.log("FirstlessHook", address(hook));
        console2.log("FirstlessRouter", address(router));
        console2.log("FirstlessRefundRedeemer", address(redeemer));
        console2.log("token0", address(token0));
        console2.log("token1", address(token1));
        console2.log("poolId");
        console2.logBytes32(PoolId.unwrap(key.toId()));
    }

    function _writeDeployment(
        uint256 deploymentBlock,
        NetworkConfig memory network,
        PoolKey memory key,
        IPoolManager manager,
        FirstlessHook hook,
        FirstlessRouter router,
        FirstlessRefundRedeemer redeemer,
        FirstlessSepoliaToken token0,
        FirstlessSepoliaToken token1
    ) internal {
        string memory objectKey = "firstlessTestnetDeployment";
        vm.serializeUint(objectKey, "schemaVersion", 1);
        vm.serializeString(objectKey, "mode", "testnet");
        vm.serializeUint(objectKey, "chainId", block.chainid);
        vm.serializeString(objectKey, "chainName", network.chainName);
        vm.serializeString(objectKey, "rpcUrl", vm.envOr("FIRSTLESS_PUBLIC_RPC_URL", network.publicRpcUrl));
        vm.serializeString(objectKey, "explorerUrl", network.explorerUrl);
        vm.serializeUint(objectKey, "deploymentBlock", deploymentBlock);
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
        vm.serializeBytes32(objectKey, "poolId", PoolId.unwrap(key.toId()));
        vm.serializeUint(objectKey, "feeNumerator", hook.feeNumerator());
        vm.serializeUint(objectKey, "feeDenominator", hook.feeDenominator());
        vm.serializeUint(objectKey, "outputCapBps", hook.capBps());
        vm.serializeUint(objectKey, "initialLiquidity", INITIAL_LIQUIDITY);
        string memory json = vm.serializeUint(objectKey, "initialTokenSupply", INITIAL_TOKEN_SUPPLY);
        string memory defaultPath =
            string.concat(vm.projectRoot(), "/../../apps/web/public/deployments/", network.manifestName, ".json");
        vm.writeJson(json, vm.envOr("FIRSTLESS_DEPLOYMENT_PATH", defaultPath));
    }

    function _networkConfig() internal view returns (NetworkConfig memory network) {
        if (block.chainid == ETHEREUM_SEPOLIA_CHAIN_ID) {
            return NetworkConfig({
                poolManager: ETHEREUM_SEPOLIA_POOL_MANAGER,
                chainName: "Ethereum Sepolia",
                publicRpcUrl: "https://ethereum-sepolia-rpc.publicnode.com",
                explorerUrl: "https://sepolia.etherscan.io",
                manifestName: "sepolia"
            });
        }
        if (block.chainid == UNICHAIN_SEPOLIA_CHAIN_ID) {
            return NetworkConfig({
                poolManager: UNICHAIN_SEPOLIA_POOL_MANAGER,
                chainName: "Unichain Sepolia",
                publicRpcUrl: "https://sepolia.unichain.org",
                explorerUrl: "https://sepolia.uniscan.xyz",
                manifestName: "unichain-sepolia"
            });
        }
        revert UnsupportedChain();
    }
}
