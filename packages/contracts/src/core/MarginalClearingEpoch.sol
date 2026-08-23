// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {BeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BaseCustomCurve} from "ozhooks/base/BaseCustomCurve.sol";
import {ClearingCreditEpoch} from "./ClearingCreditEpoch.sol";

/// @notice Prices each order by the incremental pool input it adds to its set.
contract MarginalClearingEpoch is ClearingCreditEpoch {
    using CurrencyLibrary for *;

    mapping(uint64 epochId => uint256 reserve0) public epochStart0;
    mapping(uint64 epochId => uint256 reserve1) public epochStart1;

    uint256 public protectionReserve0;
    uint256 public protectionReserve1;

    error InvalidSideOutputLimit();

    event ProtectionReserveAccrued(uint64 indexed epochId, bool token1, uint256 amount);

    constructor(
        IPoolManager manager,
        uint256 numerator,
        uint256 denominator,
        uint256 outputCapBps,
        address _initialLiquidityProvider
    ) ClearingCreditEpoch(manager, numerator, denominator, outputCapBps, _initialLiquidityProvider) {}

    /// @dev Escrows a conservative one-sided cap marginal plus raw-unit slack.
    function requiredMaximumInput(bool tokenOut0, uint256 amountOut)
        public
        view
        override
        returns (uint256 maximumInput)
    {
        if (!bookSeeded) revert BookNotSeeded();
        uint256 reserveOut = tokenOut0 ? logicalReserve0 : logicalReserve1;
        uint256 cap = FullMath.mulDiv(reserveOut, capBps, 10_000);
        return requiredMaximumInputAtLimit(tokenOut0, amountOut, cap);
    }

    /// @notice Returns collateral sufficient for an order at its signed same-side epoch limit.
    function requiredMaximumInputAtLimit(bool tokenOut0, uint256 amountOut, uint256 sideOutputLimit)
        public
        view
        returns (uint256 maximumInput)
    {
        if (!bookSeeded) revert BookNotSeeded();
        uint256 reserveOut = tokenOut0 ? logicalReserve0 : logicalReserve1;
        uint256 reserveIn = tokenOut0 ? logicalReserve1 : logicalReserve0;
        uint256 cap = FullMath.mulDiv(reserveOut, capBps, 10_000);
        if (amountOut == 0 || sideOutputLimit < amountOut || sideOutputLimit > cap) {
            revert InvalidSideOutputLimit();
        }

        uint256 atLimit = _oneSidedGrossCeil(reserveIn, reserveOut, sideOutputLimit);
        uint256 beforeOrder = _oneSidedGrossFloor(reserveIn, reserveOut, sideOutputLimit - amountOut);
        maximumInput = atLimit - beforeOrder + 2 * _roundingBuffer(tokenOut0, reserveOut, reserveIn);
    }

    /// @notice Claims an order's marginal-cost refund after its set is complete.
    function claimRefund(uint256 orderId) external virtual override returns (uint256 refund) {
        Order storage order = orders[orderId];
        if (order.refundOwner == address(0)) revert UnknownOrder();
        if (order.claimed) revert AlreadyClaimed();
        if (msg.sender != order.refundOwner) revert InvalidRefundOwner();
        Settlement storage settlement = settlements[order.epochId];
        if (!settlement.settled) revert EpochStillOpen();

        uint256 without0 = settlement.output0 - (order.tokenOut0 ? uint256(order.amountOut) : 0);
        uint256 without1 = settlement.output1 - (order.tokenOut0 ? 0 : uint256(order.amountOut));
        (uint256 priorGross0, uint256 priorGross1) =
            _grossForTotals(epochStart0[order.epochId], epochStart1[order.epochId], without0, without1);

        uint256 finalGross = order.tokenOut0 ? settlement.grossInput1 : settlement.grossInput0;
        uint256 priorGross = order.tokenOut0 ? priorGross1 : priorGross0;
        if (priorGross > finalGross) revert SettlementInvariant();
        uint256 charge = finalGross - priorGross
            + _roundingBuffer(
                order.tokenOut0,
                order.tokenOut0 ? epochStart0[order.epochId] : epochStart1[order.epochId],
                order.tokenOut0 ? epochStart1[order.epochId] : epochStart0[order.epochId]
            );
        if (charge > order.maximumInput) revert SettlementInvariant();

        refund = uint256(order.maximumInput) - charge;
        _finalizeRefund(orderId, order, settlement, refund);
    }

    /// @notice Returns all hook claims, including the non-LP protection reserve.
    function accountedMarginalClaims() external view returns (uint256 amount0, uint256 amount1) {
        (amount0, amount1) = _accountedClaims();
        amount0 += protectionReserve0;
        amount1 += protectionReserve1;
    }

    function _allocateResidualRefund(uint64 epochId, bool token1, uint256 residual) internal override {
        if (token1) protectionReserve1 += residual;
        else protectionReserve0 += residual;
        emit ProtectionReserveAccrued(epochId, token1, residual);
    }

    function _beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        internal
        virtual
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (!bookSeeded) revert BookNotSeeded();
        if (params.amountSpecified <= 0) revert ExactOutputOnly();
        _settleIfExpired();
        if (currentEpoch.openedAtBlock == 0) {
            _openEpoch();
            epochStart0[currentEpochId] = currentEpoch.start0;
            epochStart1[currentEpochId] = currentEpoch.start1;
        }

        _recordOrder(params, hookData);
        return BaseCustomCurve._beforeSwap(sender, key, params, hookData);
    }

    function _recordOrder(SwapParams calldata params, bytes calldata hookData) internal {
        (address refundOwner, uint256 userMaximumInput, uint256 deadline) = _decodeOrderTerms(hookData);
        if (refundOwner == address(0)) revert InvalidRefundOwner();
        if (block.timestamp > deadline) revert CreditOrderExpired();

        bool tokenOut0 = !params.zeroForOne;
        uint256 amountOut = uint256(params.amountSpecified);
        if (amountOut > uint256(uint128(type(int128).max))) revert AmountTooLarge();
        uint256 priorTotal = tokenOut0 ? currentEpoch.output0 : currentEpoch.output1;
        uint256 newTotal = priorTotal + amountOut;
        uint256 reserveOut = tokenOut0 ? currentEpoch.start0 : currentEpoch.start1;
        uint256 sideOutputLimit = FullMath.mulDiv(reserveOut, capBps, 10_000);
        if (newTotal > sideOutputLimit) revert EpochOutputCapExceeded();

        uint256 maximumInput = requiredMaximumInput(tokenOut0, amountOut);
        if (maximumInput > userMaximumInput) revert UserMaximumTooLow();
        if (maximumInput > uint256(uint128(type(int128).max))) revert AmountTooLarge();

        uint256 orderId = nextOrderId++;
        orders[orderId] =
            Order(refundOwner, currentEpochId, uint128(amountOut), uint128(maximumInput), tokenOut0, false);
        if (tokenOut0) {
            currentEpoch.output0 = newTotal;
            currentEpoch.escrow1 += maximumInput;
            currentEpoch.ordersOut0++;
        } else {
            currentEpoch.output1 = newTotal;
            currentEpoch.escrow0 += maximumInput;
            currentEpoch.ordersOut1++;
        }

        _pendingMaximumInput = maximumInput;
        emit CreditOrderPlaced(orderId, currentEpochId, refundOwner, tokenOut0, amountOut, maximumInput);
    }

    function _decodeOrderTerms(bytes calldata hookData)
        internal
        view
        virtual
        returns (address refundOwner, uint256 userMaximumInput, uint256 deadline)
    {
        return abi.decode(hookData, (address, uint256, uint256));
    }

    function _grossForTotals(uint256 start0, uint256 start1, uint256 output0, uint256 output1)
        internal
        view
        returns (uint256 gross0, uint256 gross1)
    {
        uint256 net0;
        uint256 net1;
        if (_gte512(output0, start1, output1, start0)) {
            uint256 matched0 = output1 == 0 ? 0 : FullMath.mulDivRoundingUp(output1, start0, start1);
            uint256 residual0 = output0 - matched0;
            uint256 curve1 = residual0 == 0 ? 0 : FullMath.mulDivRoundingUp(start1, residual0, start0 - residual0);
            net0 = matched0;
            net1 = output1 + curve1;
        } else {
            uint256 matched1 = output0 == 0 ? 0 : FullMath.mulDivRoundingUp(output0, start1, start0);
            uint256 residual1 = output1 - matched1;
            uint256 curve0 = residual1 == 0 ? 0 : FullMath.mulDivRoundingUp(start0, residual1, start1 - residual1);
            net0 = output0 + curve0;
            net1 = matched1;
        }
        gross0 = _grossUp(net0);
        gross1 = _grossUp(net1);
    }

    function _oneSidedGrossCeil(uint256 reserveIn, uint256 reserveOut, uint256 amountOut)
        internal
        view
        returns (uint256)
    {
        if (amountOut == 0) return 0;
        uint256 net = FullMath.mulDivRoundingUp(reserveIn, amountOut, reserveOut - amountOut);
        return FullMath.mulDivRoundingUp(net, feeDenominator, feeNumerator);
    }

    function _oneSidedGrossFloor(uint256 reserveIn, uint256 reserveOut, uint256 amountOut)
        internal
        view
        returns (uint256)
    {
        if (amountOut == 0) return 0;
        uint256 net = FullMath.mulDiv(reserveIn, amountOut, reserveOut - amountOut);
        return FullMath.mulDiv(net, feeDenominator, feeNumerator);
    }

    function _roundingBuffer(bool, uint256 reserveOut, uint256 reserveIn) internal pure returns (uint256) {
        return 4 + FullMath.mulDivRoundingUp(4, reserveIn, reserveOut);
    }
}
