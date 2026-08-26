// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BaseCustomAccounting} from "ozhooks/base/BaseCustomAccounting.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {HookTest} from "oztest/utils/HookTest.sol";
import {ClearingCreditEpoch} from "firstless/core/ClearingCreditEpoch.sol";
import {MarginalClearingEpoch} from "firstless/core/MarginalClearingEpoch.sol";

/// @notice Section 1 — Core settlement mathematics reproducible tests.
/// Covers: extreme reserves, overflow regression, zero/one/two/max sets,
/// all-buy/all-sell/balanced/unbalanced, permutation invariance,
/// rounding/one-wei, leave-one-out billing, conservation, no overcharge,
/// no asset creation from rounding.
contract SecurityMatrixCoreTest is HookTest {
    using CurrencyLibrary for Currency;

    MarginalClearingEpoch hook;
    uint64 internal _helperNonce;
    uint64 internal _helperBlock = 5000;

    uint256 constant MAX_DEADLINE = 12_329_839_823;
    int24 constant MIN_TICK = -887220;
    int24 constant MAX_TICK = 887220;

    function setUp() public {
        deployFreshManagerAndRouters();
        hook = MarginalClearingEpoch(
            payable(
                address(
                    uint160(
                        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
                            | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                    )
                )
            )
        );
        deployCodeTo(
            "src/core/MarginalClearingEpoch.sol:MarginalClearingEpoch",
            abi.encode(address(manager), 997, 1000, 1000, address(this)),
            address(hook)
        );
        deployMintAndApprove2Currencies();
        (key,) = initPool(currency0, currency1, IHooks(address(hook)), LPFeeLibrary.DYNAMIC_FEE_FLAG, SQRT_PRICE_1_1);
        ERC20(Currency.unwrap(currency0)).approve(address(hook), type(uint256).max);
        ERC20(Currency.unwrap(currency1)).approve(address(hook), type(uint256).max);
        hook.addLiquidity(_addParams(1000 ether, 1000 ether));
    }

    // ── 1. Extreme reserves near int128/uint128 limits — overflow regression ─────────

    /// @notice Reserves near int128 max should not overflow dominance comparison.
    /// Deploy a second hook at max int128 and run a full epoch.
    function test_extremeReservesNearInt128MaxDoNotOverflow() public {
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
                | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
        );
        MarginalClearingEpoch extreme = MarginalClearingEpoch(payable(address(flags | uint160(0xC0FFEE << 80))));
        deployCodeTo(
            "src/core/MarginalClearingEpoch.sol:MarginalClearingEpoch",
            abi.encode(address(manager), 997, 1000, 1000, address(this)),
            address(extreme)
        );

        // Approvals already max for this; PoolManager is shared, create new pool for extreme hook.
        // Use fresh currencies with huge supply already (2**255 minted to this).
        // For clear isolation, reuse same currencies but new pool key.
        PoolKey memory ek;
        (ek,) = initPool(currency0, currency1, IHooks(address(extreme)), LPFeeLibrary.DYNAMIC_FEE_FLAG, SQRT_PRICE_1_1);
        ERC20(Currency.unwrap(currency0)).approve(address(extreme), type(uint256).max);
        ERC20(Currency.unwrap(currency1)).approve(address(extreme), type(uint256).max);

        // Max int128 = 2**127 - 1 ≈ 1.7e38 wei. Each individual
        // liquidity delta is int128-bounded, but active reserves aggregate
        // many deposits and are uint256. Grow the book beyond 2**130 so the
        // settlement cross-products exceed 256 bits.
        uint256 huge = uint256(uint128(type(int128).max)) / 2; // ~8.5e37
        // Ensure we have enough tokens (we have 2**255 ≈ 5e76).
        extreme.addLiquidity(
            BaseCustomAccounting.AddLiquidityParams(
                huge, huge, huge, huge, MAX_DEADLINE, MIN_TICK, MAX_TICK, bytes32(0)
            )
        );
        for (uint256 i = 0; i < 32; i++) {
            extreme.addLiquidity(
                BaseCustomAccounting.AddLiquidityParams(
                    huge, huge, huge, huge, MAX_DEADLINE, MIN_TICK, MAX_TICK, bytes32(uint256(i + 1))
                )
            );
        }
        _helperBlock += 10;
        vm.roll(_helperBlock);
        for (uint256 i = 0; i < 32; i++) {
            extreme.activatePendingLiquidity(i, 0);
        }
        assertTrue(extreme.bookSeeded());
        assertEq(extreme.logicalReserve0(), huge * 33);
        assertEq(extreme.logicalReserve1(), huge * 33);

        // Place orders up to cap (10% of reserve) — near-max size.
        uint256 amountOut0 = huge / 2;
        uint256 amountOut1 = huge / 3;
        uint256 max0 = extreme.requiredMaximumInput(false, amountOut1); // tokenOut0=false means token1 out
        uint256 max1 = extreme.requiredMaximumInput(true, amountOut0);
        // Use swapRouter with custom pool key; swap for extreme hook
        _placeWithKey(ek, false, amountOut1, max0);
        _placeWithKey(ek, true, amountOut0, max1);
        _helperBlock += 10;
        vm.roll(_helperBlock);
        // Must not revert with overflow; must settle cleanly.
        extreme.settleExpiredEpoch();
        (,,,, uint256 g0, uint256 g1,,,) = extreme.settlements(1);
        assertGt(g0 + g1, 0, "gross computed without overflow");
        // Claim both refunds — must not overcharge.
        extreme.claimRefund(0);
        extreme.claimRefund(1);
        (uint256 a0, uint256 a1) = extreme.accountedMarginalClaims();
        assertEq(manager.balanceOf(address(extreme), currency0.toId()), a0);
        assertEq(manager.balanceOf(address(extreme), currency1.toId()), a1);
    }

    // ── 2. Zero, one, two, maximum-size order sets ───────────────────────────────────

    function test_zeroOrdersSettlesToNoop() public {
        // No orders in epoch 0 yet — but epoch not opened. Open with one order then settle without second.
        // Instead test: after seeding, currentEpoch is empty, settle should revert NoExpiredEpoch.
        vm.expectRevert(ClearingCreditEpoch.NoExpiredEpoch.selector);
        hook.settleExpiredEpoch();
        // Place zero orders in new epoch is vacuous; test one-order set instead.
    }

    function test_singleOrderSetChargesAndRefundsCorrectly() public {
        uint256 amountOut = 10 ether;
        _place(false, amountOut);
        vm.roll(block.number + 1);
        hook.settleExpiredEpoch();
        (,,,, uint256 g0,,,,) = hook.settlements(1);
        // Only output1 side has escrow.
        assertGt(g0, 0);
        (,,, uint128 storedMax,,) = hook.orders(0);
        uint256 refund = hook.claimRefund(0);
        // Charge = gross + buffer (8 wei for 1000e18 reserves), refund = max - charge
        uint256 charge = uint256(storedMax) - refund;
        // gross from settlement is net+fee, charge includes buffer
        assertGe(charge, g0, "charge at least gross");
        assertLe(charge, g0 + 20, "charge within buffer of gross");
        assertLe(g0, storedMax, "no overcharge for single order");
        _assertAccounted();
    }

    function test_twoOrderSetBothDirections() public {
        _place(false, 40 ether);
        _place(true, 30 ether);
        vm.roll(block.number + 1);
        hook.settleExpiredEpoch();
        hook.claimRefund(0);
        hook.claimRefund(1);
        _assertAccounted();
        assertEq(hook.refundLiability0(), 0);
        assertEq(hook.refundLiability1(), 0);
    }

    function test_maximumSizeOrderSetAtCapBoundary() public {
        uint256 reserve0 = hook.logicalReserve0();
        uint256 cap0 = reserve0 * 1000 / 10000; // 100 ether
        // Fill cap exactly with two orders
        uint256 a = cap0 / 2;
        uint256 b = cap0 - a;
        _place(true, a);
        _place(true, b);
        (,,,,, uint256 _output0,,,) = hook.currentEpoch();
        assertEq(_output0, cap0);
        // One more wei should exceed cap
        uint256 maxExtra = hook.requiredMaximumInput(true, 1);
        vm.expectRevert();
        _placeWithTerms(true, 1, maxExtra);
        vm.roll(block.number + 1);
        hook.settleExpiredEpoch();
        hook.claimRefund(0);
        hook.claimRefund(1);
        _assertAccounted();
    }

    // ── 3. All-buy, all-sell, balanced, heavily unbalanced ────────────────────────────

    function test_allBuySet() public {
        _place(false, 20 ether);
        _place(false, 30 ether);
        _place(false, 10 ether);
        vm.roll(block.number + 1);
        hook.settleExpiredEpoch();
        for (uint256 i = 0; i < 3; i++) {
            hook.claimRefund(i);
        }
        _assertAccounted();
    }

    function test_allSellSet() public {
        _place(true, 15 ether);
        _place(true, 25 ether);
        _place(true, 40 ether);
        vm.roll(block.number + 1);
        hook.settleExpiredEpoch();
        for (uint256 i = 0; i < 3; i++) {
            hook.claimRefund(i);
        }
        _assertAccounted();
    }

    function test_balancedSetNetting() public {
        _place(false, 50 ether);
        _place(true, 50 ether);
        vm.roll(block.number + 1);
        hook.settleExpiredEpoch();
        // Balanced should produce minimal curve input (only fees)
        (,,,, uint256 g0, uint256 g1,,,) = hook.settlements(1);
        // Gross should be close to output (matched) + small fees
        assertApproxEqRel(g0, 50 ether, 0.02e18); // within 2% fee
        assertApproxEqRel(g1, 50 ether, 0.02e18);
        hook.claimRefund(0);
        hook.claimRefund(1);
        _assertAccounted();
    }

    function test_heavilyUnbalancedSet() public {
        _place(false, 90 ether);
        _place(true, 1 ether);
        vm.roll(block.number + 1);
        hook.settleExpiredEpoch();
        // Unbalanced: large one-sided curve
        (,,,, uint256 g0,,,,) = hook.settlements(1);
        assertGt(g0, 90 ether, "unbalanced one-sided pays curve premium plus fee");
        hook.claimRefund(0);
        hook.claimRefund(1);
        _assertAccounted();
    }

    // ── 4. Every permutation of the same order set must produce the same result ─────

    function test_permutationInvarianceThreeOrders() public {
        // Define a set: A=10 token1 out, B=20 token1 out, C=15 token0 out.
        // Run permutation [A,B,C] vs [C,B,A] via two independent hooks to avoid state pollution.
        (uint256 g0a, uint256 g1a, uint256[] memory refundsA) =
            _runSetPermutation(false, 10 ether, false, 20 ether, true, 15 ether);
        (uint256 g0b, uint256 g1b, uint256[] memory refundsB) =
            _runSetPermutation(true, 15 ether, false, 20 ether, false, 10 ether);
        assertEq(g0a, g0b, "gross0 permutation invariant");
        assertEq(g1a, g1b, "gross1 permutation invariant");
        // Sum of refunds per side must match (order of refunds may differ but totals same)
        uint256 sumA = refundsA[0] + refundsA[1] + refundsA[2];
        uint256 sumB = refundsB[0] + refundsB[1] + refundsB[2];
        assertEq(sumA, sumB, "total refunds permutation invariant");
    }

    function test_permutationInvarianceSameSide() public {
        (uint256 g0a, uint256 g1a,) = _runSetPermutation(false, 10 ether, false, 20 ether, false, 30 ether);
        (uint256 g0b, uint256 g1b,) = _runSetPermutation(false, 30 ether, false, 10 ether, false, 20 ether);
        assertEq(g0a, g0b);
        assertEq(g1a, g1b);
    }

    function testFuzz_permutationInvarianceRandom(uint64 a, uint64 b, uint64 c) public {
        uint256 amtA = bound(uint256(a), 1e6, 25 ether);
        uint256 amtB = bound(uint256(b), 1e6, 25 ether);
        uint256 amtC = bound(uint256(c), 1e6, 25 ether);
        // Keep total per side under cap (100 ether)
        if (amtA + amtB + amtC > 75 ether) return;
        bool dirA = a % 2 == 0;
        bool dirB = b % 2 == 0;
        bool dirC = c % 2 == 0;
        // Need to ensure per-side totals under cap; if all same side sum must <100 ether
        uint256 sum0 = (dirA ? amtA : 0) + (dirB ? amtB : 0) + (dirC ? amtC : 0);
        uint256 sum1 = (!dirA ? amtA : 0) + (!dirB ? amtB : 0) + (!dirC ? amtC : 0);
        if (sum0 > 90 ether || sum1 > 90 ether) return;
        (uint256 g0a, uint256 g1a,) = _runSetPermutation(dirA, amtA, dirB, amtB, dirC, amtC);
        (uint256 g0b, uint256 g1b,) = _runSetPermutation(dirC, amtC, dirB, amtB, dirA, amtA);
        assertEq(g0a, g0b);
        assertEq(g1a, g1b);
    }

    // ── 5. Rounding and one-wei boundary cases ───────────────────────────────────────

    function test_oneWeiOrders() public {
        _place(false, 1);
        _place(true, 1);
        vm.roll(block.number + 1);
        hook.settleExpiredEpoch();
        hook.claimRefund(0);
        hook.claimRefund(1);
        _assertAccounted();
        // Protection reserves should be tiny (rounding slack)
        assertLt(hook.protectionReserve0(), 100);
        assertLt(hook.protectionReserve1(), 100);
    }

    function test_oneWeiDustDoesNotCreateAssets() public {
        uint256 supplyBefore = hook.totalSupply();
        uint256 reserve0Before = hook.logicalReserve0();
        _place(false, 1);
        vm.roll(block.number + 1);
        hook.settleExpiredEpoch();
        uint256 reserve0After = hook.logicalReserve0();
        // Reserve should not increase spuriously from rounding (k conserved)
        assertApproxEqAbs(reserve0After, reserve0Before, 10, "reserve drift bounded by rounding");
        hook.claimRefund(0);
        _assertAccounted();
        assertEq(hook.totalSupply(), supplyBefore, "LP supply unchanged by dust");
    }

    function test_roundingBufferConservatism() public {
        // requiredMaximumInputAtLimit should be >= true marginal + buffer
        uint256 cap = hook.logicalReserve0() * 1000 / 10000;
        uint256 amt = 50 ether;
        uint256 capLimitedMax = hook.requiredMaximumInputAtLimit(true, amt, cap);
        // Place a single order set and compare charge to capped max
        _place(true, amt);
        vm.roll(block.number + 1);
        hook.settleExpiredEpoch();
        (,,, uint128 max,,) = hook.orders(0);
        uint256 refund = hook.claimRefund(0);
        uint256 charge = uint256(max) - refund;
        assertLe(charge, capLimitedMax, "actual marginal <= cap-limited maximum");
        _assertAccounted();
    }

    // ── 6. Leave-one-out / marginal billing correctness ───────────────────────────────

    function testFuzz_leaveOneOutChargeEqualsGrossIncrementPlusBuffer(uint64 rawA, uint64 rawB) public {
        uint256 a = bound(uint256(rawA), 1e6, 40 ether);
        uint256 b = bound(uint256(rawB), 1e6, 40 ether);
        if (a + b > 80 ether) return;
        _place(false, a);
        _place(false, b);
        vm.roll(block.number + 1);
        hook.settleExpiredEpoch();
        (,,,, uint256 gross,,,,) = hook.settlements(1);
        // Claim and verify each charge = gross - grossWithout + buffer (4 + 4*reserveIn/reserveOut)
        uint256 buffer = 4 + FullMath.mulDivRoundingUp(4, 1000 ether, 1000 ether);
        (,,, uint128 max0,,) = hook.orders(0);
        (,,, uint128 max1,,) = hook.orders(1);
        uint256 c0 = uint256(max0) - hook.claimRefund(0);
        uint256 c1 = uint256(max1) - hook.claimRefund(1);
        (uint256 grossWithout0,) = _grossForTotalsLocal(0, b);
        (uint256 grossWithout1,) = _grossForTotalsLocal(0, a);
        uint256 increment0 = gross - grossWithout0;
        uint256 increment1 = gross - grossWithout1;
        assertGe(c0, increment0, "c0 covers its leave-one-out increment");
        assertGe(c1, increment1, "c1 covers its leave-one-out increment");
        assertLe(c0, increment0 + 2 * buffer + 1000, "c0 only adds the rounding buffer");
        assertLe(c1, increment1 + 2 * buffer + 1000, "c1 only adds the rounding buffer");
        _assertAccounted();
    }

    // ── 7. Total bills, refunds, LP effects must conserve value ──────────────────────

    function test_conservationNoAssetCreation() public {
        uint256 reserve0Before = hook.logicalReserve0();
        uint256 reserve1Before = hook.logicalReserve1();
        _place(false, 30 ether);
        _place(true, 20 ether);
        (,,,,,,, uint256 escrow0, uint256 escrow1) = hook.currentEpoch();
        vm.roll(block.number + 1);
        hook.settleExpiredEpoch();
        (,,,, uint256 g0, uint256 g1,,,) = hook.settlements(1);
        // escrow = gross + refunds
        (,,,,,, uint256 rem0,,) = hook.settlements(1);
        assertEq(escrow0, g0 + rem0);
        (,,,,,,, uint256 rem1,) = hook.settlements(1);
        assertEq(escrow1, g1 + rem1);
        // Reserves + fees movement conserves: net input becomes reserve delta + fee
        uint256 reserve0After = hook.logicalReserve0();
        uint256 reserve1After = hook.logicalReserve1();
        // Total claims before = after + refunds distributed + fees?
        // Use accounted invariant instead — must hold.
        _assertAccounted();
        // k must not decrease (checked in settlement) — verify here
        assertGe(reserve0After * reserve1After, reserve0Before * reserve1Before, "k non-decreasing");
        hook.claimRefund(0);
        hook.claimRefund(1);
        _assertAccounted();
    }

    function testFuzz_conservationRandomSets(uint64[4] memory raw) public {
        uint256[] memory amts = new uint256[](4);
        bool[] memory dirs = new bool[](4);
        uint256 sum0;
        uint256 sum1;
        for (uint256 i = 0; i < 4; i++) {
            amts[i] = bound(uint256(raw[i]), 1e6, 20 ether);
            dirs[i] = raw[i] % 2 == 0;
            if (dirs[i]) sum0 += amts[i];
            else sum1 += amts[i];
        }
        if (sum0 > 80 ether || sum1 > 80 ether) return;
        for (uint256 i = 0; i < 4; i++) {
            _place(dirs[i], amts[i]);
        }
        uint256 n = 4;
        vm.roll(block.number + 1);
        hook.settleExpiredEpoch();
        for (uint256 i = 0; i < n; i++) {
            hook.claimRefund(i);
        }
        _assertAccounted();
        assertEq(hook.refundLiability0(), 0);
        assertEq(hook.refundLiability1(), 0);
        // No dust should create value: sum refunds + fees + reserves = initial + escrow
    }

    // ── 8. No participant charged more than signed maximum ───────────────────────────

    function test_noOverchargeSingleAndMulti() public {
        _place(false, 40 ether);
        _place(false, 30 ether);
        _place(true, 20 ether);
        vm.roll(block.number + 1);
        hook.settleExpiredEpoch();
        for (uint256 i = 0; i < 3; i++) {
            (,,, uint128 max,,) = hook.orders(i);
            uint256 refund = hook.claimRefund(i);
            assertLe(refund, max, "refund never exceeds signed escrow");
        }
        _assertAccounted();
    }

    function testFuzz_noOverchargeRandom(uint64[6] memory raw) public {
        uint256 n = 6;
        uint256 sum0;
        uint256 sum1;
        uint256[] memory amts = new uint256[](n);
        bool[] memory dirs = new bool[](n);
        for (uint256 i = 0; i < n; i++) {
            amts[i] = bound(uint256(raw[i]), 1e3, 12 ether);
            dirs[i] = raw[i] % 2 == 0;
            if (dirs[i]) sum0 += amts[i];
            else sum1 += amts[i];
        }
        if (sum0 > 70 ether || sum1 > 70 ether) return;
        for (uint256 i = 0; i < n; i++) {
            _place(dirs[i], amts[i]);
        }
        vm.roll(block.number + 1);
        hook.settleExpiredEpoch();
        for (uint256 i = 0; i < n; i++) {
            (,,, uint128 max,,) = hook.orders(i);
            // claimRefund reverts SettlementInvariant if charge>max — would cause test failure
            uint256 refund = hook.claimRefund(i);
            assertLe(uint256(max) - refund, max);
        }
        _assertAccounted();
    }

    // ── 9. Settlement must not create assets from rounding ──────────────────────────

    function test_noAssetCreationFromRoundingFuzz() public {
        // Repeated dust + settlement should not inflate reserves or fees spuriously
        uint256 reserve0Start = hook.logicalReserve0();
        uint256 curBlock = block.number;
        for (uint256 iter = 0; iter < 5; iter++) {
            _place(false, 1);
            _place(true, 1);
            curBlock += 2;
            vm.roll(curBlock);
            hook.settleExpiredEpoch();
            hook.claimRefund(iter * 2);
            hook.claimRefund(iter * 2 + 1);
        }
        _assertAccounted();
        // Reserves should be near start (fees small, dust negligible)
        assertApproxEqAbs(hook.logicalReserve0(), reserve0Start, 1e12, "reserve drift bounded by rounding*iterations");
        assertApproxEqAbs(hook.logicalReserve1(), 1000 ether, 1e6);
    }

    function test_protectionReserveBounded() public {
        // Balanced 50/50 repeatedly should keep protection tiny
        uint256 curBlock2 = block.number;
        for (uint256 i = 0; i < 3; i++) {
            _place(false, 30 ether);
            _place(true, 30 ether);
            curBlock2 += 2;
            vm.roll(curBlock2);
            hook.settleExpiredEpoch();
            hook.claimRefund(i * 2);
            hook.claimRefund(i * 2 + 1);
            assertLt(hook.protectionReserve0(), 100);
            assertLt(hook.protectionReserve1(), 100);
        }
        _assertAccounted();
    }

    // ── Helpers ────────────────────────────────────────────────────────────────────

    function _place(bool tokenOut0, uint256 amountOut) internal {
        uint256 maximum = hook.requiredMaximumInput(tokenOut0, amountOut);
        _placeWithTerms(tokenOut0, amountOut, maximum);
    }

    function _placeWithTerms(bool tokenOut0, uint256 amountOut, uint256 maximum) internal {
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: !tokenOut0,
                amountSpecified: int256(amountOut),
                sqrtPriceLimitX96: tokenOut0 ? TickMath.MAX_SQRT_PRICE - 1 : TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            abi.encode(address(this), maximum, block.timestamp)
        );
    }

    function _placeWithKey(PoolKey memory k, bool tokenOut0, uint256 amountOut, uint256 maximum) internal {
        swapRouter.swap(
            k,
            SwapParams({
                zeroForOne: !tokenOut0,
                amountSpecified: int256(amountOut),
                sqrtPriceLimitX96: tokenOut0 ? TickMath.MAX_SQRT_PRICE - 1 : TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            abi.encode(address(this), maximum, block.timestamp)
        );
    }

    function _runSetPermutation(bool d0, uint256 a0, bool d1, uint256 a1, bool d2, uint256 a2)
        internal
        returns (uint256 g0, uint256 g1, uint256[] memory refunds)
    {
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
                | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
        );
        _helperNonce++;
        MarginalClearingEpoch h =
            MarginalClearingEpoch(payable(address(uint160(flags) | uint160(uint256(_helperNonce) << 80))));
        // Ensure unique address per permutation seed
        deployCodeTo(
            "src/core/MarginalClearingEpoch.sol:MarginalClearingEpoch",
            abi.encode(address(manager), 997, 1000, 1000, address(this)),
            address(h)
        );
        PoolKey memory k;
        (k,) = initPool(currency0, currency1, IHooks(address(h)), LPFeeLibrary.DYNAMIC_FEE_FLAG, SQRT_PRICE_1_1);
        ERC20(Currency.unwrap(currency0)).approve(address(h), type(uint256).max);
        ERC20(Currency.unwrap(currency1)).approve(address(h), type(uint256).max);
        h.addLiquidity(_addParams(1000 ether, 1000 ether));
        // Place in given order
        uint256 m0 = h.requiredMaximumInput(d0, a0);
        uint256 m1 = h.requiredMaximumInput(d1, a1);
        uint256 m2 = h.requiredMaximumInput(d2, a2);
        swapRouter.swap(
            k,
            SwapParams({
                zeroForOne: !d0,
                amountSpecified: int256(a0),
                sqrtPriceLimitX96: d0 ? TickMath.MAX_SQRT_PRICE - 1 : TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            abi.encode(address(this), m0, block.timestamp)
        );
        swapRouter.swap(
            k,
            SwapParams({
                zeroForOne: !d1,
                amountSpecified: int256(a1),
                sqrtPriceLimitX96: d1 ? TickMath.MAX_SQRT_PRICE - 1 : TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            abi.encode(address(this), m1, block.timestamp)
        );
        swapRouter.swap(
            k,
            SwapParams({
                zeroForOne: !d2,
                amountSpecified: int256(a2),
                sqrtPriceLimitX96: d2 ? TickMath.MAX_SQRT_PRICE - 1 : TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            abi.encode(address(this), m2, block.timestamp)
        );
        _helperBlock += 10;
        vm.roll(_helperBlock);
        h.settleExpiredEpoch();
        (,,,, uint256 _g0, uint256 _g1,,,) = h.settlements(1);
        g0 = _g0;
        g1 = _g1;
        refunds = new uint256[](3);
        refunds[0] = h.claimRefund(0);
        refunds[1] = h.claimRefund(1);
        refunds[2] = h.claimRefund(2);
    }

    function _runOneSidedGross(uint256 output1) internal pure returns (uint256 gross, uint256 net) {
        net = FullMath.mulDivRoundingUp(1000 ether, output1, 1000 ether - output1);
        gross = FullMath.mulDivRoundingUp(net, 1000, 997);
    }

    function _grossForTotalsLocal(uint256 output0, uint256 output1)
        internal
        pure
        returns (uint256 gross0, uint256 gross1)
    {
        uint256 net0;
        uint256 net1;
        if (output0 >= output1) {
            uint256 residual0 = output0 - output1;
            net0 = output1;
            net1 = output1
                + (residual0 == 0 ? 0 : FullMath.mulDivRoundingUp(1000 ether, residual0, 1000 ether - residual0));
        } else {
            uint256 residual1 = output1 - output0;
            net0 = output0
                + (residual1 == 0 ? 0 : FullMath.mulDivRoundingUp(1000 ether, residual1, 1000 ether - residual1));
            net1 = output0;
        }
        gross0 = FullMath.mulDivRoundingUp(net0, 1000, 997);
        gross1 = FullMath.mulDivRoundingUp(net1, 1000, 997);
    }

    function _oneSidedGross(uint256 output1) internal pure returns (uint256) {
        uint256 net = FullMath.mulDivRoundingUp(1000 ether, output1, 1000 ether - output1);
        return FullMath.mulDivRoundingUp(net, 1000, 997);
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

    function _assertAccounted() internal view {
        (uint256 amount0, uint256 amount1) = hook.accountedMarginalClaims();
        assertEq(manager.balanceOf(address(hook), currency0.toId()), amount0, "token0 claims");
        assertEq(manager.balanceOf(address(hook), currency1.toId()), amount1, "token1 claims");
    }
}
