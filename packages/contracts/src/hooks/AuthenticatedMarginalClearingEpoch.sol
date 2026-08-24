// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {BeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {MarginalClearingEpoch} from "../core/MarginalClearingEpoch.sol";

/// @notice Accepts clearing orders only from the signed-order router.
contract AuthenticatedMarginalClearingEpoch is MarginalClearingEpoch {
    address public immutable trustedRouter;

    error UntrustedRouter();
    error InvalidClockWindow();

    constructor(
        IPoolManager manager,
        uint256 numerator,
        uint256 denominator,
        uint256 outputCapBps,
        address router,
        address _initialLiquidityProvider
    ) MarginalClearingEpoch(manager, numerator, denominator, outputCapBps, _initialLiquidityProvider) {
        if (router == address(0)) revert UntrustedRouter();
        trustedRouter = router;
    }

    function _beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (sender != trustedRouter) revert UntrustedRouter();
        return super._beforeSwap(sender, key, params, hookData);
    }

    function _decodeOrderTerms(bytes calldata hookData)
        internal
        view
        override
        returns (address refundOwner, uint256 userMaximumInput, uint256 deadline)
    {
        uint64 validAfter;
        uint64 validBefore;
        (refundOwner, userMaximumInput, deadline, validAfter, validBefore) =
            abi.decode(hookData, (address, uint256, uint256, uint64, uint64));
        uint64 currentBlock = _currentBlock();
        if (validAfter > validBefore || currentBlock < validAfter || currentBlock > validBefore) {
            revert InvalidClockWindow();
        }
    }
}
