// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BaseCustomAccounting} from "ozhooks/base/BaseCustomAccounting.sol";
import {HookTest} from "oztest/utils/HookTest.sol";
import {Test} from "forge-std/Test.sol";
import {MarginalClearingEpoch} from "firstless/core/MarginalClearingEpoch.sol";

contract ClearingLifecycleDriver is Test {
    uint256 private constant MAX_DEADLINE = 12_329_839_823;
    int24 private constant MIN_TICK = -887220;
    int24 private constant MAX_TICK = 887220;

    MarginalClearingEpoch public immutable hook;
    PoolSwapTest public immutable router;
    uint256 public expectedPending0;
    uint256 public expectedPending1;
    PoolKey internal _key;

    constructor(MarginalClearingEpoch clearingHook, PoolSwapTest swapRouter, PoolKey memory pool) {
        hook = clearingHook;
        router = swapRouter;
        _key = pool;
        ERC20(Currency.unwrap(pool.currency0)).approve(address(swapRouter), type(uint256).max);
        ERC20(Currency.unwrap(pool.currency1)).approve(address(swapRouter), type(uint256).max);
        ERC20(Currency.unwrap(pool.currency0)).approve(address(clearingHook), type(uint256).max);
        ERC20(Currency.unwrap(pool.currency1)).approve(address(clearingHook), type(uint256).max);
    }

    function place(bool tokenOut0, uint64 rawAmount) external {
        uint256 amountOut = _range(uint256(rawAmount), 1e6, 3 ether);
        uint256 maximumInput;
        try hook.requiredMaximumInput(tokenOut0, amountOut) returns (uint256 quotedMaximum) {
            maximumInput = quotedMaximum;
        } catch {
            return;
        }

        try router.swap(
            _key,
            SwapParams({
                zeroForOne: !tokenOut0,
                amountSpecified: int256(amountOut),
                sqrtPriceLimitX96: tokenOut0 ? TickMath.MAX_SQRT_PRICE - 1 : TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            abi.encode(address(this), maximumInput, block.timestamp)
        ) {} catch {}
    }

    function advanceAndSettle() external {
        vm.roll(block.number + 1);
        try hook.settleExpiredEpoch() {} catch {}
    }

    function claim(uint256 rawOrderId) external {
        uint256 count = hook.nextOrderId();
        if (count == 0) return;
        uint256 orderId = rawOrderId % count;
        (address refundOwner, uint64 epochId,,,, bool claimed) = hook.orders(orderId);
        (,,,,,,,, bool settled) = hook.settlements(epochId);
        if (refundOwner != address(this) || claimed || !settled) return;
        try hook.claimRefund(orderId) {} catch {}
    }

    function addLiquidity(uint64 rawAmount0, uint64 rawAmount1) external {
        uint256 amount0 = _range(uint256(rawAmount0), 1e6, 2 ether);
        uint256 amount1 = _range(uint256(rawAmount1), 1e6, 2 ether);
        uint256 depositId = hook.nextDepositId();
        try hook.addLiquidity(_addParams(amount0, amount1)) {
            (address provider,, uint128 deposited0, uint128 deposited1) = hook.pendingLiquidity(depositId);
            if (provider == address(this)) {
                expectedPending0 += deposited0;
                expectedPending1 += deposited1;
            }
        } catch {}
    }

    function activateLiquidity(uint256 rawDepositId) external {
        uint256 count = hook.nextDepositId();
        if (count == 0) return;
        uint256 depositId = rawDepositId % count;
        (address provider,, uint128 amount0, uint128 amount1) = hook.pendingLiquidity(depositId);
        if (provider != address(this)) return;
        try hook.activatePendingLiquidity(depositId, 0) {
            expectedPending0 -= amount0;
            expectedPending1 -= amount1;
        } catch {}
    }

    function cancelLiquidity(uint256 rawDepositId) external {
        uint256 count = hook.nextDepositId();
        if (count == 0) return;
        uint256 depositId = rawDepositId % count;
        (address provider,, uint128 amount0, uint128 amount1) = hook.pendingLiquidity(depositId);
        if (provider != address(this)) return;
        try hook.cancelPendingLiquidity(depositId) {
            expectedPending0 -= amount0;
            expectedPending1 -= amount1;
        } catch {}
    }

    function removeLiquidity(uint96 rawShares) external {
        uint256 shares = hook.balanceOf(address(this));
        if (shares == 0) return;
        uint256 amount = 1 + uint256(rawShares) % shares;
        try hook.removeLiquidity(_removeParams(amount)) {} catch {}
    }

    function _addParams(uint256 amount0, uint256 amount1)
        private
        pure
        returns (BaseCustomAccounting.AddLiquidityParams memory)
    {
        return BaseCustomAccounting.AddLiquidityParams(
            amount0, amount1, 0, 0, MAX_DEADLINE, MIN_TICK, MAX_TICK, bytes32(0)
        );
    }

    function _removeParams(uint256 shares) private pure returns (BaseCustomAccounting.RemoveLiquidityParams memory) {
        return BaseCustomAccounting.RemoveLiquidityParams(shares, 0, 0, MAX_DEADLINE, MIN_TICK, MAX_TICK, bytes32(0));
    }

    function _range(uint256 value, uint256 minimum, uint256 maximum) private pure returns (uint256) {
        return minimum + value % (maximum - minimum + 1);
    }
}

contract ClearingLifecyclePropertiesTest is HookTest {
    using CurrencyLibrary for Currency;

    uint256 private constant MAX_DEADLINE = 12_329_839_823;
    int24 private constant MIN_TICK = -887220;
    int24 private constant MAX_TICK = 887220;
    uint160 private constant REQUIRED_FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
            | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
    );

    MarginalClearingEpoch internal hook;
    ClearingLifecycleDriver internal driver;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();
        hook = MarginalClearingEpoch(payable(address(REQUIRED_FLAGS | uint160(21 << 80))));
        deployCodeTo(
            "src/core/MarginalClearingEpoch.sol:MarginalClearingEpoch",
            abi.encode(address(manager), 997, 1000, 1000, address(this)),
            address(hook)
        );

        PoolKey memory invariantKey;
        (invariantKey,) =
            initPool(currency0, currency1, IHooks(address(hook)), LPFeeLibrary.DYNAMIC_FEE_FLAG, SQRT_PRICE_1_1);
        ERC20(Currency.unwrap(currency0)).approve(address(hook), type(uint256).max);
        ERC20(Currency.unwrap(currency1)).approve(address(hook), type(uint256).max);
        hook.addLiquidity(_addParams(1000 ether, 1000 ether));

        driver = new ClearingLifecycleDriver(hook, swapRouter, invariantKey);
        ERC20(Currency.unwrap(currency0)).transfer(address(driver), 1_000_000 ether);
        ERC20(Currency.unwrap(currency1)).transfer(address(driver), 1_000_000 ether);

        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = ClearingLifecycleDriver.place.selector;
        selectors[1] = ClearingLifecycleDriver.advanceAndSettle.selector;
        selectors[2] = ClearingLifecycleDriver.claim.selector;
        selectors[3] = ClearingLifecycleDriver.addLiquidity.selector;
        selectors[4] = ClearingLifecycleDriver.removeLiquidity.selector;
        selectors[5] = ClearingLifecycleDriver.activateLiquidity.selector;
        selectors[6] = ClearingLifecycleDriver.cancelLiquidity.selector;
        targetContract(address(driver));
        targetSelector(FuzzSelector({addr: address(driver), selectors: selectors}));
    }

    function invariant_allInternalBucketsEqualPoolManagerCustody() public view {
        (uint256 accounted0, uint256 accounted1) = hook.accountedMarginalClaims();
        assertEq(manager.balanceOf(address(hook), currency0.toId()), accounted0);
        assertEq(manager.balanceOf(address(hook), currency1.toId()), accounted1);
    }

    function invariant_globalRefundLiabilityEqualsEverySettlementRemainder() public view {
        uint256 remaining0;
        uint256 remaining1;
        uint64 latestEpoch = hook.currentEpochId();
        for (uint64 epochId = 1; epochId <= latestEpoch; epochId++) {
            (,,,,,, uint256 refund0, uint256 refund1, bool settled) = hook.settlements(epochId);
            if (settled) {
                remaining0 += refund0;
                remaining1 += refund1;
            }
        }
        assertEq(hook.refundLiability0(), remaining0);
        assertEq(hook.refundLiability1(), remaining1);
    }

    function invariant_openEpochNeverExceedsItsSignedOutputCap() public view {
        (uint64 openedAtBlock,,, uint256 start0, uint256 start1, uint256 output0, uint256 output1,,) =
            hook.currentEpoch();
        if (openedAtBlock == 0) return;
        assertLe(output0, start0 * hook.capBps() / 10_000);
        assertLe(output1, start1 * hook.capBps() / 10_000);
    }

    function invariant_initialLpCannotBeDilutedIntoZeroBacking() public view {
        assertGt(hook.totalSupply(), 0);
        assertGt(hook.logicalReserve0(), 0);
        assertGt(hook.logicalReserve1(), 0);
    }

    function invariant_pendingTotalsEqualIndependentProviderReceipts() public view {
        assertEq(hook.pendingDeposit0(), driver.expectedPending0());
        assertEq(hook.pendingDeposit1(), driver.expectedPending1());
    }

    function _addParams(uint256 amount0, uint256 amount1)
        internal
        pure
        returns (BaseCustomAccounting.AddLiquidityParams memory)
    {
        return BaseCustomAccounting.AddLiquidityParams(
            amount0, amount1, amount0, amount1, MAX_DEADLINE, MIN_TICK, MAX_TICK, bytes32(0)
        );
    }
}
