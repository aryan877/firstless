// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {BaseCustomAccounting} from "ozhooks/base/BaseCustomAccounting.sol";
import {BaseCustomCurve} from "ozhooks/base/BaseCustomCurve.sol";
import {BaseHook} from "ozhooks/base/BaseHook.sol";

/// @notice Exact-output clearing engine with immediate output and deferred refunds.
abstract contract ClearingCreditEpoch is BaseCustomCurve, ERC20 {
    using BalanceDeltaLibrary for BalanceDelta;
    using CurrencyLibrary for Currency;

    error BookNotSeeded();
    error ExactOutputOnly();
    error InvalidRefundOwner();
    error CreditOrderExpired();
    error UserMaximumTooLow();
    error EpochStillOpen();
    error EpochOutputCapExceeded();
    error NoExpiredEpoch();
    error UnknownOrder();
    error AlreadyClaimed();
    error SettlementInvariant();
    error InvalidLiquidityAmount();
    error InvalidInitialLiquidityProvider();
    error OnlyInitialLiquidityProvider();
    error NativeCurrencyUnsupported();
    error AmountTooLarge();
    error UnknownDeposit();
    error InvalidDepositOwner();
    error DepositStillMaturing();
    error InsufficientLiquidityShares();

    struct Order {
        address refundOwner;
        uint64 epochId;
        uint128 amountOut;
        uint128 maximumInput;
        bool tokenOut0;
        bool claimed;
    }

    struct Epoch {
        uint64 openedAtBlock;
        uint64 ordersOut0;
        uint64 ordersOut1;
        uint256 start0;
        uint256 start1;
        uint256 output0;
        uint256 output1;
        uint256 escrow0;
        uint256 escrow1;
    }

    struct Settlement {
        uint64 remainingOrdersOut0;
        uint64 remainingOrdersOut1;
        uint256 output0;
        uint256 output1;
        uint256 grossInput0;
        uint256 grossInput1;
        uint256 remainingRefund0;
        uint256 remainingRefund1;
        bool settled;
    }

    struct PendingLiquidity {
        address provider;
        uint64 queuedAtBlock;
        uint128 amount0;
        uint128 amount1;
    }

    uint256 public immutable feeNumerator;
    uint256 public immutable feeDenominator;
    uint256 public immutable capBps;
    address public immutable initialLiquidityProvider;

    bool public bookSeeded;
    uint64 public currentEpochId;
    uint256 public nextOrderId;
    uint256 public logicalReserve0;
    uint256 public logicalReserve1;
    uint256 public feeBucket0;
    uint256 public feeBucket1;
    uint256 public refundLiability0;
    uint256 public refundLiability1;
    uint256 public pendingDeposit0;
    uint256 public pendingDeposit1;
    uint256 public nextDepositId;

    Epoch public currentEpoch;
    mapping(uint64 epochId => Settlement) public settlements;
    mapping(uint256 orderId => Order) public orders;
    mapping(uint256 depositId => PendingLiquidity) public pendingLiquidity;

    uint256 internal _pendingMaximumInput;
    bool private _queueDeposit;

    event CreditOrderPlaced(
        uint256 indexed orderId,
        uint64 indexed epochId,
        address indexed refundOwner,
        bool tokenOut0,
        uint256 amountOut,
        uint256 maximumInput
    );
    event EpochSettled(
        uint64 indexed epochId,
        uint256 output0,
        uint256 output1,
        uint256 grossInput0,
        uint256 grossInput1,
        uint256 reserve0,
        uint256 reserve1
    );
    event RefundClaimed(uint256 indexed orderId, address indexed owner, uint256 refund);
    event DepositQueued(
        uint256 indexed depositId,
        address indexed provider,
        uint256 amount0,
        uint256 amount1,
        uint256 activationAfterBlock
    );
    event DepositActivated(
        uint256 indexed depositId,
        address indexed provider,
        uint256 amount0,
        uint256 amount1,
        uint256 shares,
        uint256 refund0,
        uint256 refund1
    );
    event DepositCancelled(uint256 indexed depositId, address indexed provider, uint256 amount0, uint256 amount1);
    event BookSeeded(address indexed provider, uint256 reserve0, uint256 reserve1, uint256 shares);

    constructor(
        IPoolManager manager,
        uint256 _feeNumerator,
        uint256 _feeDenominator,
        uint256 _capBps,
        address _initialLiquidityProvider
    ) BaseHook(manager) ERC20("Firstless LP Share", "FIRST-LP") {
        if (_feeNumerator == 0 || _feeNumerator > _feeDenominator || _capBps == 0 || _capBps >= 10_000) {
            revert SettlementInvariant();
        }
        if (_initialLiquidityProvider == address(0)) revert InvalidInitialLiquidityProvider();
        feeNumerator = _feeNumerator;
        feeDenominator = _feeDenominator;
        capBps = _capBps;
        initialLiquidityProvider = _initialLiquidityProvider;
    }

    /// @notice Settles a completed clearing set.
    function settleExpiredEpoch() external {
        uint64 currentBlock = _currentBlock();
        if (!_isEpochExpired(currentBlock)) revert NoExpiredEpoch();
        _settleCurrentEpoch(currentBlock);
    }

    /// @notice Quotes a matured deposit against current active LP equity.
    /// @dev Settle an expired epoch first; an open set can change the fair share price.
    function previewPendingLiquidity(uint256 depositId)
        public
        view
        returns (uint256 shares, uint256 amount0, uint256 amount1, uint256 refund0, uint256 refund1)
    {
        PendingLiquidity storage pending = pendingLiquidity[depositId];
        if (pending.provider == address(0)) revert UnknownDeposit();
        if (currentEpoch.openedAtBlock != 0) revert EpochStillOpen();
        (shares, amount0, amount1) = _quotePendingLiquidity(pending.amount0, pending.amount1);
        refund0 = uint256(pending.amount0) - amount0;
        refund1 = uint256(pending.amount1) - amount1;
    }

    /// @notice Activates only the proportional capital accepted at the current fair share price.
    /// @dev Only the provider chooses the minimum shares; unused tokens are returned as underlying.
    function activatePendingLiquidity(uint256 depositId, uint256 minimumShares)
        external
        returns (uint256 shares, uint256 refund0, uint256 refund1)
    {
        _settleIfExpired();
        if (currentEpoch.openedAtBlock != 0) revert EpochStillOpen();
        PendingLiquidity memory pending = pendingLiquidity[depositId];
        if (pending.provider == address(0)) revert UnknownDeposit();
        if (msg.sender != pending.provider) revert InvalidDepositOwner();
        if (_currentBlock() <= pending.queuedAtBlock) revert DepositStillMaturing();

        uint256 amount0;
        uint256 amount1;
        (shares, amount0, amount1) = _quotePendingLiquidity(pending.amount0, pending.amount1);
        if (shares < minimumShares) revert InsufficientLiquidityShares();
        refund0 = uint256(pending.amount0) - amount0;
        refund1 = uint256(pending.amount1) - amount1;

        delete pendingLiquidity[depositId];
        pendingDeposit0 -= pending.amount0;
        pendingDeposit1 -= pending.amount1;
        logicalReserve0 += amount0;
        logicalReserve1 += amount1;
        _mint(pending.provider, shares);
        _returnUnderlying(pending.provider, refund0, refund1);
        emit DepositActivated(depositId, pending.provider, amount0, amount1, shares, refund0, refund1);
    }

    /// @notice Cancels capital that has not entered the active reserve book.
    function cancelPendingLiquidity(uint256 depositId) external {
        PendingLiquidity memory pending = pendingLiquidity[depositId];
        if (pending.provider == address(0)) revert UnknownDeposit();
        if (msg.sender != pending.provider) revert InvalidDepositOwner();
        delete pendingLiquidity[depositId];
        pendingDeposit0 -= pending.amount0;
        pendingDeposit1 -= pending.amount1;
        _returnUnderlying(pending.provider, pending.amount0, pending.amount1);
        emit DepositCancelled(depositId, pending.provider, pending.amount0, pending.amount1);
    }

    function requiredMaximumInput(bool tokenOut0, uint256 amountOut) public view virtual returns (uint256);

    /// @notice Claims the settled difference between an order's escrow and final charge.
    function claimRefund(uint256 orderId) external virtual returns (uint256 refund);

    function _accountedClaims() internal view returns (uint256 amount0, uint256 amount1) {
        uint256 provisional0 = logicalReserve0;
        uint256 provisional1 = logicalReserve1;
        if (currentEpoch.openedAtBlock != 0) {
            provisional0 -= currentEpoch.output0;
            provisional1 -= currentEpoch.output1;
        }
        amount0 = provisional0 + feeBucket0 + refundLiability0 + currentEpoch.escrow0 + pendingDeposit0;
        amount1 = provisional1 + feeBucket1 + refundLiability1 + currentEpoch.escrow1 + pendingDeposit1;
    }

    function _finalizeRefund(uint256 orderId, Order storage order, Settlement storage settlement, uint256 refund)
        internal
    {
        order.claimed = true;
        PoolKey memory key = poolKey();
        if (order.tokenOut0) {
            settlement.remainingRefund1 -= refund;
            refundLiability1 -= refund;
            settlement.remainingOrdersOut0--;
            if (settlement.remainingOrdersOut0 == 0) {
                uint256 residual = settlement.remainingRefund1;
                settlement.remainingRefund1 = 0;
                refundLiability1 -= residual;
                _allocateResidualRefund(order.epochId, true, residual);
            }
            if (refund != 0) poolManager.transfer(msg.sender, key.currency1.toId(), refund);
        } else {
            settlement.remainingRefund0 -= refund;
            refundLiability0 -= refund;
            settlement.remainingOrdersOut1--;
            if (settlement.remainingOrdersOut1 == 0) {
                uint256 residual = settlement.remainingRefund0;
                settlement.remainingRefund0 = 0;
                refundLiability0 -= residual;
                _allocateResidualRefund(order.epochId, false, residual);
            }
            if (refund != 0) poolManager.transfer(msg.sender, key.currency0.toId(), refund);
        }
        emit RefundClaimed(orderId, msg.sender, refund);
    }

    function _allocateResidualRefund(uint64 epochId, bool token1, uint256 residual) internal virtual;

    function addLiquidity(BaseCustomAccounting.AddLiquidityParams calldata params)
        public
        payable
        override
        returns (BalanceDelta delta)
    {
        _settleIfExpired();
        bool initialDeposit = !bookSeeded;
        if (initialDeposit && msg.sender != initialLiquidityProvider) revert OnlyInitialLiquidityProvider();
        _queueDeposit = !initialDeposit;
        delta = super.addLiquidity(params);
        _queueDeposit = false;
        uint256 amount0 = uint256(uint128(-delta.amount0()));
        uint256 amount1 = uint256(uint128(-delta.amount1()));
        if (initialDeposit) {
            if (amount0 == 0 || amount1 == 0) revert SettlementInvariant();
            bookSeeded = true;
            logicalReserve0 = amount0;
            logicalReserve1 = amount1;
            emit BookSeeded(msg.sender, amount0, amount1, totalSupply());
            return delta;
        }

        uint256 depositId = nextDepositId++;
        uint64 currentBlock = _currentBlock();
        pendingLiquidity[depositId] = PendingLiquidity({
            provider: msg.sender,
            queuedAtBlock: currentBlock,
            amount0: uint128(amount0),
            amount1: uint128(amount1)
        });
        pendingDeposit0 += amount0;
        pendingDeposit1 += amount1;
        emit DepositQueued(depositId, msg.sender, amount0, amount1, uint256(currentBlock) + 1);
    }

    function removeLiquidity(BaseCustomAccounting.RemoveLiquidityParams calldata params)
        public
        override
        returns (BalanceDelta delta)
    {
        _settleIfExpired();
        if (currentEpoch.openedAtBlock != 0) revert EpochStillOpen();
        delta = super.removeLiquidity(params);
        if (bookSeeded) {
            uint256 supplyBefore = totalSupply() + params.liquidity;
            uint256 reserveOut0 = FullMath.mulDiv(params.liquidity, logicalReserve0, supplyBefore);
            uint256 reserveOut1 = FullMath.mulDiv(params.liquidity, logicalReserve1, supplyBefore);
            uint256 feeOut0 = FullMath.mulDiv(params.liquidity, feeBucket0, supplyBefore);
            uint256 feeOut1 = FullMath.mulDiv(params.liquidity, feeBucket1, supplyBefore);
            logicalReserve0 -= reserveOut0;
            logicalReserve1 -= reserveOut1;
            feeBucket0 -= feeOut0;
            feeBucket1 -= feeOut1;
        }
    }

    function _getAmountIn(BaseCustomAccounting.AddLiquidityParams memory params)
        internal
        view
        override
        returns (uint256 amount0, uint256 amount1, uint256 shares)
    {
        uint256 supply = totalSupply();
        if (supply == 0) {
            amount0 = params.amount0Desired;
            amount1 = params.amount1Desired;
            if (amount0 == 0 || amount1 == 0) revert InvalidLiquidityAmount();
            shares = amount0 < amount1 ? amount0 : amount1;
            return (amount0, amount1, shares);
        }

        uint256 equity0 = logicalReserve0 + feeBucket0;
        uint256 equity1 = logicalReserve1 + feeBucket1;
        if (equity0 == 0 || equity1 == 0) revert InvalidLiquidityAmount();
        uint256 shares0 = FullMath.mulDiv(params.amount0Desired, supply, equity0);
        uint256 shares1 = FullMath.mulDiv(params.amount1Desired, supply, equity1);
        shares = shares0 < shares1 ? shares0 : shares1;
        if (shares == 0) revert InvalidLiquidityAmount();
        amount0 = FullMath.mulDivRoundingUp(shares, equity0, supply);
        amount1 = FullMath.mulDivRoundingUp(shares, equity1, supply);
    }

    function _getAmountOut(BaseCustomAccounting.RemoveLiquidityParams memory params)
        internal
        view
        override
        returns (uint256 amount0, uint256 amount1, uint256 shares)
    {
        uint256 supply = totalSupply();
        shares = params.liquidity;
        if (shares == 0 || shares > supply) revert InvalidLiquidityAmount();
        amount0 = FullMath.mulDiv(shares, logicalReserve0, supply) + FullMath.mulDiv(shares, feeBucket0, supply);
        amount1 = FullMath.mulDiv(shares, logicalReserve1, supply) + FullMath.mulDiv(shares, feeBucket1, supply);
    }

    function _mint(BaseCustomAccounting.AddLiquidityParams memory, BalanceDelta, BalanceDelta, uint256 shares)
        internal
        override
    {
        if (!_queueDeposit) _mint(msg.sender, shares);
    }

    function _burn(BaseCustomAccounting.RemoveLiquidityParams memory, BalanceDelta, BalanceDelta, uint256 shares)
        internal
        override
    {
        _burn(msg.sender, shares);
    }

    /// @dev The clearing engine charges its configured curve fee during final billing, not in BaseCustomCurve.
    function _getSwapFeeAmount(SwapParams calldata, uint256) internal pure override returns (uint256 swapFeeAmount) {}

    function _beforeInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96)
        internal
        override
        returns (bytes4)
    {
        if (sender != initialLiquidityProvider) revert OnlyInitialLiquidityProvider();
        if (key.currency0.isAddressZero() || key.currency1.isAddressZero()) revert NativeCurrencyUnsupported();
        return super._beforeInitialize(sender, key, sqrtPriceX96);
    }

    function _getUnspecifiedAmount(SwapParams calldata) internal view override returns (uint256) {
        return _pendingMaximumInput;
    }

    function _openEpoch() internal {
        currentEpochId++;
        currentEpoch = Epoch({
            openedAtBlock: _currentBlock(),
            ordersOut0: 0,
            ordersOut1: 0,
            start0: logicalReserve0,
            start1: logicalReserve1,
            output0: 0,
            output1: 0,
            escrow0: 0,
            escrow1: 0
        });
    }

    function _settleIfExpired() internal {
        uint64 currentBlock = _currentBlock();
        if (_isEpochExpired(currentBlock)) _settleCurrentEpoch(currentBlock);
    }

    function _settleCurrentEpoch(uint64 currentBlock) internal {
        Epoch memory epoch = currentEpoch;
        if (!_isEpochExpired(currentBlock)) revert EpochStillOpen();

        uint256 matchedInput0;
        uint256 matchedInput1;
        uint256 residual0;
        uint256 residual1;
        uint256 netInput0;
        uint256 netInput1;

        if (_gte512(epoch.output0, epoch.start1, epoch.output1, epoch.start0)) {
            matchedInput0 =
                epoch.output1 == 0 ? 0 : FullMath.mulDivRoundingUp(epoch.output1, epoch.start0, epoch.start1);
            matchedInput1 = epoch.output1;
            residual0 = epoch.output0 - matchedInput0;
            uint256 curveInput1 =
                residual0 == 0 ? 0 : FullMath.mulDivRoundingUp(epoch.start1, residual0, epoch.start0 - residual0);
            netInput0 = matchedInput0;
            netInput1 = matchedInput1 + curveInput1;
            logicalReserve0 = epoch.start0 - residual0;
            logicalReserve1 = epoch.start1 + curveInput1;
        } else {
            matchedInput0 = epoch.output0;
            matchedInput1 =
                epoch.output0 == 0 ? 0 : FullMath.mulDivRoundingUp(epoch.output0, epoch.start1, epoch.start0);
            residual1 = epoch.output1 - matchedInput1;
            uint256 curveInput0 =
                residual1 == 0 ? 0 : FullMath.mulDivRoundingUp(epoch.start0, residual1, epoch.start1 - residual1);
            netInput0 = matchedInput0 + curveInput0;
            netInput1 = matchedInput1;
            logicalReserve0 = epoch.start0 + curveInput0;
            logicalReserve1 = epoch.start1 - residual1;
        }

        uint256 gross0 = _grossUp(netInput0);
        uint256 gross1 = _grossUp(netInput1);
        if (epoch.escrow0 < gross0 || epoch.escrow1 < gross1) revert SettlementInvariant();
        if (_lt512(logicalReserve0, logicalReserve1, epoch.start0, epoch.start1)) revert SettlementInvariant();

        uint256 refund0 = epoch.escrow0 - gross0;
        uint256 refund1 = epoch.escrow1 - gross1;
        feeBucket0 += gross0 - netInput0;
        feeBucket1 += gross1 - netInput1;
        refundLiability0 += refund0;
        refundLiability1 += refund1;
        settlements[currentEpochId] = Settlement({
            remainingOrdersOut0: epoch.ordersOut0,
            remainingOrdersOut1: epoch.ordersOut1,
            output0: epoch.output0,
            output1: epoch.output1,
            grossInput0: gross0,
            grossInput1: gross1,
            remainingRefund0: refund0,
            remainingRefund1: refund1,
            settled: true
        });

        emit EpochSettled(
            currentEpochId, epoch.output0, epoch.output1, gross0, gross1, logicalReserve0, logicalReserve1
        );
        delete currentEpoch;
    }

    function _grossUp(uint256 netInput) internal view returns (uint256) {
        return FullMath.mulDivRoundingUp(netInput, feeDenominator, feeNumerator);
    }

    function _isEpochExpired(uint64 currentBlock) internal view returns (bool) {
        return currentEpoch.openedAtBlock != 0 && currentBlock > currentEpoch.openedAtBlock;
    }

    function _quotePendingLiquidity(uint256 desired0, uint256 desired1)
        internal
        view
        returns (uint256 shares, uint256 amount0, uint256 amount1)
    {
        uint256 supply = totalSupply();
        if (supply == 0) {
            if (desired0 == 0 || desired1 == 0) revert InvalidLiquidityAmount();
            shares = desired0 < desired1 ? desired0 : desired1;
            return (shares, desired0, desired1);
        }

        uint256 equity0 = logicalReserve0 + feeBucket0;
        uint256 equity1 = logicalReserve1 + feeBucket1;
        if (equity0 == 0 || equity1 == 0) revert InvalidLiquidityAmount();
        uint256 shares0 = FullMath.mulDiv(desired0, supply, equity0);
        uint256 shares1 = FullMath.mulDiv(desired1, supply, equity1);
        shares = shares0 < shares1 ? shares0 : shares1;
        if (shares == 0) revert InvalidLiquidityAmount();
        amount0 = FullMath.mulDivRoundingUp(shares, equity0, supply);
        amount1 = FullMath.mulDivRoundingUp(shares, equity1, supply);
    }

    function _returnUnderlying(address recipient, uint256 amount0, uint256 amount1) internal {
        if (amount0 == 0 && amount1 == 0) return;
        uint256 maxAmount = uint256(uint128(type(int128).max));
        if (amount0 > maxAmount || amount1 > maxAmount) revert AmountTooLarge();
        int128 delta0 = -int128(uint128(amount0));
        int128 delta1 = -int128(uint128(amount1));
        // PoolManager reverts if the callback fails; the encoded deltas are not a second authorization decision here.
        // slither-disable-next-line unused-return
        poolManager.unlock(abi.encode(CallbackDataCustom(recipient, delta0, delta1)));
    }

    function _currentBlock() internal view returns (uint64 currentBlock) {
        if (block.number > type(uint64).max) revert AmountTooLarge();
        currentBlock = uint64(block.number);
    }

    function _gte512(uint256 a, uint256 b, uint256 c, uint256 d) internal pure returns (bool) {
        (uint256 h0, uint256 l0) = Math.mul512(a, b);
        (uint256 h1, uint256 l1) = Math.mul512(c, d);
        if (h0 != h1) return h0 > h1;
        return l0 >= l1;
    }

    function _lt512(uint256 a, uint256 b, uint256 c, uint256 d) internal pure returns (bool) {
        return !_gte512(a, b, c, d);
    }
}
