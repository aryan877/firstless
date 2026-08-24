// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {CurrencySettler} from "ozhooks/utils/CurrencySettler.sol";

/// @notice Executes one signed Firstless exact-output order and optionally composes its output.
/// @dev Native ETH is intentionally unsupported; use WETH.
contract FirstlessRouter is IUnlockCallback, EIP712 {
    using CurrencyLibrary for Currency;
    using CurrencySettler for Currency;
    using PoolIdLibrary for PoolKey;
    using SafeERC20 for IERC20;

    bytes32 public constant ORDER_TYPEHASH = keccak256(
        "CreditOrder(bytes32 poolId,address payer,address recipient,address callTarget,bytes32 callDataHash,bool zeroForOne,uint128 amountOut,uint128 maximumInput,uint64 validAfter,uint64 validBefore,uint256 nonce,uint256 deadline)"
    );

    struct CreditOrder {
        PoolId poolId;
        address payer;
        address recipient;
        address callTarget;
        bytes32 callDataHash;
        bool zeroForOne;
        uint128 amountOut;
        uint128 maximumInput;
        uint64 validAfter;
        uint64 validBefore;
        uint256 nonce;
        uint256 deadline;
    }

    struct CallbackData {
        PoolKey key;
        CreditOrder order;
    }

    IPoolManager public immutable poolManager;
    mapping(address payer => uint256 nextNonce) public nonces;

    event NonceInvalidated(address indexed payer, uint256 oldNonce, uint256 newNonce);

    error OnlyPoolManager();
    error InvalidSignature();
    error InvalidNonce();
    error InvalidPool();
    error InvalidCallPlan();
    error OrderExpired();
    error NativeCurrencyUnsupported();
    error UnexpectedSwapDelta();
    error DownstreamCallFailed(bytes reason);

    constructor(IPoolManager manager) EIP712("Firstless", "1") {
        poolManager = manager;
    }

    /// @notice Invalidates all of the caller's signed orders below `newNonce`.
    function invalidateNonce(uint256 newNonce) external {
        uint256 oldNonce = nonces[msg.sender];
        if (newNonce <= oldNonce) revert InvalidNonce();
        nonces[msg.sender] = newNonce;
        emit NonceInvalidated(msg.sender, oldNonce, newNonce);
    }

    /// @notice Returns the EIP-712 digest that the payer signs for an order.
    function hashOrder(CreditOrder calldata order) public view returns (bytes32) {
        // CreditOrder contains only static ABI types, so encoding the tuple is
        // byte-for-byte identical to encoding each field after ORDER_TYPEHASH.
        return _hashTypedDataV4(keccak256(abi.encode(ORDER_TYPEHASH, order)));
    }

    /// @notice Executes one authenticated order and its signed downstream call plan.
    function execute(
        PoolKey calldata key,
        CreditOrder calldata order,
        bytes calldata signature,
        bytes calldata callData
    ) external returns (uint256 outputAmount) {
        if (PoolId.unwrap(key.toId()) != PoolId.unwrap(order.poolId)) revert InvalidPool();
        if (block.timestamp > order.deadline) revert OrderExpired();
        if (keccak256(callData) != order.callDataHash) revert InvalidCallPlan();
        if (order.nonce != nonces[order.payer]) revert InvalidNonce();
        if (!SignatureChecker.isValidSignatureNowCalldata(order.payer, hashOrder(order), signature)) {
            revert InvalidSignature();
        }
        nonces[order.payer] = order.nonce + 1;

        outputAmount = abi.decode(poolManager.unlock(abi.encode(CallbackData(key, order))), (uint256));
        Currency output = order.zeroForOne ? key.currency1 : key.currency0;
        IERC20(Currency.unwrap(output)).safeTransfer(order.recipient, outputAmount);

        if (order.callTarget != address(0)) {
            (bool success, bytes memory reason) = order.callTarget.call(callData);
            if (!success) revert DownstreamCallFailed(reason);
        } else if (callData.length != 0) {
            revert InvalidCallPlan();
        }
    }

    /// @notice Completes PoolManager settlement for an order initiated by `execute`.
    function unlockCallback(bytes calldata rawData) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
        CallbackData memory data = abi.decode(rawData, (CallbackData));
        CreditOrder memory order = data.order;
        Currency input = order.zeroForOne ? data.key.currency0 : data.key.currency1;
        Currency output = order.zeroForOne ? data.key.currency1 : data.key.currency0;
        if (input.isAddressZero() || output.isAddressZero()) revert NativeCurrencyUnsupported();

        BalanceDelta delta = poolManager.swap(
            data.key,
            SwapParams({
                zeroForOne: order.zeroForOne,
                amountSpecified: int256(uint256(order.amountOut)),
                sqrtPriceLimitX96: order.zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            abi.encode(order.payer, uint256(order.maximumInput), order.deadline, order.validAfter, order.validBefore)
        );

        int128 inputDelta = order.zeroForOne ? delta.amount0() : delta.amount1();
        int128 outputDelta = order.zeroForOne ? delta.amount1() : delta.amount0();
        if (inputDelta >= 0 || outputDelta <= 0) revert UnexpectedSwapDelta();

        uint256 paidInput = uint256(-int256(inputDelta));
        uint256 receivedOutput = uint256(int256(outputDelta));
        if (paidInput > order.maximumInput || receivedOutput != order.amountOut) revert UnexpectedSwapDelta();

        input.settle(poolManager, order.payer, paidInput, false);
        output.take(poolManager, address(this), receivedOutput, false);
        return abi.encode(receivedOutput);
    }
}
