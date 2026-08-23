// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {AuthenticatedMarginalClearingEpoch} from "./AuthenticatedMarginalClearingEpoch.sol";

/// @title Firstless
/// @notice Gives exact output immediately, then prices input from the completed Ethereum block set.
contract FirstlessHook is AuthenticatedMarginalClearingEpoch {
    /// @param manager Uniswap v4 PoolManager.
    /// @param numerator Fee multiplier numerator, for example 997.
    /// @param denominator Fee multiplier denominator, for example 1000.
    /// @param outputCapBps Maximum same-side output per clearing set.
    /// @param router Signed-order router accepted by the hook.
    /// @param _initialLiquidityProvider Address allowed to seed the first reserve pair.
    constructor(
        IPoolManager manager,
        uint256 numerator,
        uint256 denominator,
        uint256 outputCapBps,
        address router,
        address _initialLiquidityProvider
    )
        AuthenticatedMarginalClearingEpoch(manager, numerator, denominator, outputCapBps, router, _initialLiquidityProvider)
    {}
}
