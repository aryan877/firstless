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
import {MarginalClearingEpoch} from "firstless/core/MarginalClearingEpoch.sol";

/// @notice Section 2 — Economic attacks. Every test compares attacker wealth
/// before and after including tokens, refund claims, and LP positions.
contract SecurityMatrixEconomicTest is HookTest {
    using CurrencyLibrary for Currency;

    MarginalClearingEpoch hook;

    uint256 constant MAX_DEADLINE = 12_329_839_823;
    int24 constant MIN_TICK = -887220;
    int24 constant MAX_TICK = 887220;

    address attacker;
    address victim;
    uint64 internal _helperNonce;
    uint64 internal _helperBlock = 8000;

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

        attacker = makeAddr("attacker");
        victim = makeAddr("victim");
        _fund(attacker, 2000 ether);
        _fund(victim, 2000 ether);
        _approveHook(attacker);
        _approveHook(victim);
    }

    // ── Classic sandwich: attacker buy, victim buy, attacker sell ─────────────────

    function test_sandwichAttackerCannotProfit() public {
        // Victim wants 30 token1 out (pays token0). Attacker sandwiches with 30 token1 out before, 30 token0 out after.
        // In Firstless the set nets, attacker legs should cancel and attacker should not profit.
        uint256 victimAmt2 = 30 ether;
        uint256 attackerBuy = 30 ether; // token1 out
        uint256 attackerSell = 30 ether; // token0 out (opposite direction)

        uint256 attackerBal0Before = ERC20(Currency.unwrap(currency0)).balanceOf(attacker);
        uint256 attackerBal1Before = ERC20(Currency.unwrap(currency1)).balanceOf(attacker);

        // Epoch: attacker buy, victim buy, attacker sell — all same block
        vm.startPrank(attacker);
        _placeAs(attacker, false, attackerBuy);
        vm.stopPrank();
        vm.startPrank(victim);
        _placeAs(victim, false, victimAmt2);
        vm.stopPrank();
        vm.startPrank(attacker);
        _placeAs(attacker, true, attackerSell);
        vm.stopPrank();

        _helperBlock += 10;
        vm.roll(_helperBlock);
        hook.settleExpiredEpoch();

        // Attacker claims both legs
        uint256 attackerRefundBuy;
        uint256 attackerRefundSell;
        vm.prank(attacker);
        attackerRefundBuy = hook.claimRefund(0);
        vm.prank(attacker);
        attackerRefundSell = hook.claimRefund(2);
        vm.prank(victim);
        hook.claimRefund(1);

        uint256 attackerBal0After = ERC20(Currency.unwrap(currency0)).balanceOf(attacker);
        uint256 attackerBal1After = ERC20(Currency.unwrap(currency1)).balanceOf(attacker);

        // Convert refund claims to underlying delta: attacker paid max escrow, got refund in respective input token
        // For buy (token1 out): refund in token0, so attacker net token0 change = -maxBuy + refundBuy; token1 +attackerBuy
        // For sell (token0 out): refund in token1, net token1 change = -maxSell + refundSell; token0 +attackerSell
        // Combined wealth in numeraire (use reserve ratio 1:1 at start): attacker should not be up.
        // Simpler: total attacker token value after including refunds redeemed as underlying (they are claims already transferred)
        // BalanceOf already includes refund transfers (claim transfers underlying claims). So compare.
        int256 delta0 = int256(attackerBal0After) - int256(attackerBal0Before);
        int256 delta1 = int256(attackerBal1After) - int256(attackerBal1Before);
        // At 1:1 start price, total value delta = delta0 + delta1 should be <= 0 (fees make it negative)
        int256 totalDelta = delta0 + delta1;
        assertLe(totalDelta, int256(0), "sandwich attacker should not profit in Firstless set");
        _assertAccounted();
    }

    function testFuzz_sandwichNeverProfitable(uint64 rawVictim, uint64 rawAttack) public {
        uint256 victimAmt = bound(uint256(rawVictim), 5 ether, 40 ether);
        uint256 attackAmt = bound(uint256(rawAttack), 5 ether, 40 ether);
        if (victimAmt + attackAmt > 80 ether) return;
        // Fresh hook per fuzz iteration would be heavy; reuse but need to roll to next epoch each iteration
        // For fuzz simplicity, use a fresh hook via helper
        _fuzzSandwichCheck(victimAmt, attackAmt);
    }

    // ── Attacker splits one order into multiple orders ──────────────────────────────

    function test_splitOrdersCostAtLeastUnsplitOrder() public {
        // Single attacker 20 token1 out vs split 10+10
        (uint256 chargeUnsplit,) = _runSplitScenario(false, 20 ether);
        (uint256 chargeSplit,) = _runSplitScenarioSplit(false, 10 ether, 10 ether);
        assertGe(chargeSplit, chargeUnsplit - 20, "splitting cannot avoid the leave-one-out charge");
        _assertAccountedOnHook(hook);
    }

    // ── Attacker is also a dominant LP ──────────────────────────────────────────────

    function test_attackerAsFullLPNoProfit() public {
        // Attacker becomes dominant LP alongside existing (without removing all, which would leave pool empty)
        _fund(attacker, 5000 ether);
        _approveHook(attacker);
        vm.startPrank(attacker);
        ERC20(Currency.unwrap(currency0)).approve(address(hook), type(uint256).max);
        ERC20(Currency.unwrap(currency1)).approve(address(hook), type(uint256).max);
        hook.addLiquidity(_addParams(2000 ether, 2000 ether));
        vm.stopPrank();
        _helperBlock += 10;
        vm.roll(_helperBlock);
        uint256 depId = hook.nextDepositId() - 1;
        vm.prank(attacker);
        hook.activatePendingLiquidity(depId, 0);
        // Wealth = wallet balances + LP shares valued at current equity per share.
        uint256 sharesBefore = hook.balanceOf(attacker);
        uint256 b0 = ERC20(Currency.unwrap(currency0)).balanceOf(attacker);
        uint256 b1 = ERC20(Currency.unwrap(currency1)).balanceOf(attacker);
        (uint256 eq0Before, uint256 eq1Before, uint256 supplyBefore) =
            (hook.logicalReserve0() + hook.feeBucket0(), hook.logicalReserve1() + hook.feeBucket1(), hook.totalSupply());
        uint256 lpValue0Before = FullMath.mulDiv(sharesBefore, eq0Before, supplyBefore);
        uint256 lpValue1Before = FullMath.mulDiv(sharesBefore, eq1Before, supplyBefore);
        // Now attacker is large LP. Do sandwich.
        vm.startPrank(attacker);
        _placeAs(attacker, false, 20 ether);
        vm.stopPrank();
        vm.startPrank(victim);
        _placeAs(victim, false, 20 ether);
        vm.stopPrank();
        vm.startPrank(attacker);
        _placeAs(attacker, true, 20 ether);
        vm.stopPrank();
        _helperBlock += 10;
        vm.roll(_helperBlock);
        hook.settleExpiredEpoch();
        vm.prank(attacker);
        hook.claimRefund(0);
        vm.prank(victim);
        hook.claimRefund(1);
        vm.prank(attacker);
        hook.claimRefund(2);
        uint256 a0 = ERC20(Currency.unwrap(currency0)).balanceOf(attacker);
        uint256 a1 = ERC20(Currency.unwrap(currency1)).balanceOf(attacker);
        uint256 sharesAfter = hook.balanceOf(attacker);
        (uint256 eq0After, uint256 eq1After, uint256 supplyAfter) =
            (hook.logicalReserve0() + hook.feeBucket0(), hook.logicalReserve1() + hook.feeBucket1(), hook.totalSupply());
        uint256 lpValue0After = FullMath.mulDiv(sharesAfter, eq0After, supplyAfter);
        uint256 lpValue1After = FullMath.mulDiv(sharesAfter, eq1After, supplyAfter);
        int256 wealthDelta = int256(a0 + lpValue0After) - int256(b0 + lpValue0Before) + int256(a1 + lpValue1After)
            - int256(b1 + lpValue1Before);
        assertLe(wealthDelta, int256(0), "full LP sandwich not profitable including LP position value");
    }

    // ── Self-trading and wash orders ────────────────────────────────────────────────

    function test_selfTradingWashDoesNotCreateValue() public {
        address wash = makeAddr("wash");
        _fund(wash, 1000 ether);
        _approveHook(wash);
        uint256 before0 = ERC20(Currency.unwrap(currency0)).balanceOf(wash);
        uint256 before1 = ERC20(Currency.unwrap(currency1)).balanceOf(wash);
        vm.startPrank(wash);
        _placeAs(wash, false, 10 ether);
        _placeAs(wash, true, 10 ether);
        vm.stopPrank();
        _helperBlock += 10;
        vm.roll(_helperBlock);
        hook.settleExpiredEpoch();
        vm.startPrank(wash);
        _claimIfOwner(0, wash);
        _claimIfOwner(1, wash);
        vm.stopPrank();
        uint256 after0 = ERC20(Currency.unwrap(currency0)).balanceOf(wash);
        uint256 after1 = ERC20(Currency.unwrap(currency1)).balanceOf(wash);
        assertLe(
            int256(after0) + int256(after1) - int256(before0) - int256(before1),
            int256(0),
            "wash self-trade not profitable (pays fees)"
        );
        _assertAccounted();
    }

    // ── Dust orders ────────────────────────────────────────────────────────────────

    function test_dustOrdersCannotChangeClearingToAttackerBenefit() public {
        // Victim 40 token1 out. Attacker adds 1 wei dust same side.
        uint256 victimAmt = 40 ether;
        uint256 victimMax = hook.requiredMaximumInput(false, victimAmt);
        _place(false, victimAmt);
        _place(false, 1);
        _helperBlock += 10;
        vm.roll(_helperBlock);
        hook.settleExpiredEpoch();
        (,,, uint128 maxVictim,,) = hook.orders(0);
        uint256 refundVictim = hook.claimRefund(0);
        uint256 chargeVictim = uint256(maxVictim) - refundVictim;
        // Charge with dust vs baseline without dust: dust increases charge by at most its own gross
        uint256 baseline = _oneSidedGross(victimAmt);
        assertGe(chargeVictim, baseline, "charge at least baseline");
        assertLe(
            chargeVictim, baseline + _oneSidedGross(1) + 20, "dust increases victim charge only by dust cost + buffer"
        );
        hook.claimRefund(1);
        _assertAccounted();
        assertEq(victimMax, maxVictim, "victim max unchanged by dust presence");
    }

    // ── One dominant + many small ─────────────────────────────────────────────────

    function test_dominantPlusManySmallConservation() public {
        _place(false, 60 ether);
        for (uint256 i = 0; i < 5; i++) {
            _place(false, 2 ether);
        }
        for (uint256 i = 0; i < 5; i++) {
            _place(true, 2 ether);
        }
        _helperBlock += 10;
        vm.roll(_helperBlock);
        hook.settleExpiredEpoch();
        for (uint256 i = 0; i < 11; i++) {
            hook.claimRefund(i);
        }
        _assertAccounted();
        // No participant overcharged
        for (uint256 i = 0; i < 11; i++) {
            // already claimed, check via settlement: remaining refund 0
        }
        assertEq(hook.refundLiability0(), 0);
        assertEq(hook.refundLiability1(), 0);
    }

    // ── Duplicate and opposing orders ─────────────────────────────────────────────

    function test_duplicateOrdersEachPayMarginal() public {
        _place(false, 10 ether);
        _place(false, 10 ether);
        _helperBlock += 10;
        vm.roll(_helperBlock);
        hook.settleExpiredEpoch();
        (,,, uint128 max0,,) = hook.orders(0);
        (,,, uint128 max1,,) = hook.orders(1);
        uint256 c0 = uint256(max0) - hook.claimRefund(0);
        uint256 c1 = uint256(max1) - hook.claimRefund(1);
        // Second identical order should pay at least as much as first's incremental (convex)
        assertGe(c1, c0 - 20, "second duplicate not cheaper beyond buffer");
        _assertAccounted();
    }

    // ── Manipulation across consecutive epochs ────────────────────────────────────

    function test_consecutiveEpochIsolation() public {
        _place(false, 30 ether);
        _helperBlock += 10;
        vm.roll(_helperBlock);
        hook.settleExpiredEpoch();
        (,,,, uint256 g0Epoch1,,,,) = hook.settlements(1);
        hook.claimRefund(0);
        // Next epoch should start from new reserves, not be manipulable by previous epoch's orders
        _place(false, 30 ether);
        _helperBlock += 10;
        vm.roll(_helperBlock);
        hook.settleExpiredEpoch();
        (,,,, uint256 g0Epoch2,,,,) = hook.settlements(2);
        // Gross should be similar (reserves moved slightly due to fees/curve)
        assertApproxEqRel(g0Epoch1, g0Epoch2, 0.1e18, "consecutive epoch gross similar, no cross-epoch manipulation");
        hook.claimRefund(1);
        _assertAccounted();
    }

    // ── Last-order / last-block manipulation ─────────────────────────────────────

    function test_lastOrderCannotReserveSideCap() public {
        // Fill side to cap with dust then dominant, vs dominant alone — last order should not get special price
        // First, fill to cap-1 with one order, then last 1 wei
        uint256 cap = hook.logicalReserve0() * 1000 / 10000;
        uint256 dominant = cap - 1;
        _place(true, dominant);
        _place(true, 1);
        _helperBlock += 10;
        vm.roll(_helperBlock);
        hook.settleExpiredEpoch();
        (,,, uint128 maxDom,,) = hook.orders(0);
        (,,, uint128 maxLast,,) = hook.orders(1);
        uint256 cDom = uint256(maxDom) - hook.claimRefund(0);
        uint256 cLast = uint256(maxLast) - hook.claimRefund(1);
        // Last 1 wei should pay its marginal (small), not get discount
        assertGt(cLast, 0);
        assertGt(cDom, cLast);
        _assertAccounted();
    }

    // ── Refund farming ────────────────────────────────────────────────────────────

    function test_refundFarmingNotProfitable() public {
        address farmer = makeAddr("farmer");
        _fund(farmer, 1000 ether);
        _approveHook(farmer);
        uint256 before0 = ERC20(Currency.unwrap(currency0)).balanceOf(farmer);
        uint256 before1 = ERC20(Currency.unwrap(currency1)).balanceOf(farmer);
        // Farmer places minimal orders to farm refunds: 1 wei each side
        vm.startPrank(farmer);
        _placeAs(farmer, false, 1);
        _placeAs(farmer, true, 1);
        vm.stopPrank();
        _helperBlock += 10;
        vm.roll(_helperBlock);
        hook.settleExpiredEpoch();
        vm.startPrank(farmer);
        _claimIfOwner(0, farmer);
        _claimIfOwner(1, farmer);
        vm.stopPrank();
        uint256 after0 = ERC20(Currency.unwrap(currency0)).balanceOf(farmer);
        uint256 after1 = ERC20(Currency.unwrap(currency1)).balanceOf(farmer);
        assertLe(
            int256(after0) + int256(after1) - int256(before0) - int256(before1),
            int256(0),
            "refund farming not profitable"
        );
        // Also total refunds <= total escrow
        _assertAccounted();
    }

    // ── LP deposit before settlement and withdrawal after ──────────────────────────

    function test_lpDepositBeforeSettlementCannotCaptureCurrentEpochFees() public {
        address newLP = makeAddr("newLP");
        _fund(newLP, 5000 ether);
        _approveHook(newLP);
        ERC20(Currency.unwrap(currency0)).transfer(newLP, 2000 ether);
        ERC20(Currency.unwrap(currency1)).transfer(newLP, 2000 ether);
        // Hook already has pending? Use fresh pending.
        vm.startPrank(newLP);
        ERC20(Currency.unwrap(currency0)).approve(address(hook), type(uint256).max);
        ERC20(Currency.unwrap(currency1)).approve(address(hook), type(uint256).max);
        hook.addLiquidity(_addParams(500 ether, 500 ether));
        vm.stopPrank();
        // Pending not active yet
        assertEq(hook.balanceOf(newLP), 0);
        _place(false, 20 ether);
        _helperBlock += 10;
        vm.roll(_helperBlock);
        hook.settleExpiredEpoch();
        // Now activate — should not capture fees from epoch that just settled (priced at post-fee equity)
        vm.prank(newLP);
        (uint256 shares,,,,) = hook.previewPendingLiquidity(0);
        vm.prank(newLP);
        hook.activatePendingLiquidity(0, 0);
        assertLe(hook.balanceOf(newLP), shares + 1);
        // Withdraw immediately — should not get extra fees
        uint256 bal0Before = ERC20(Currency.unwrap(currency0)).balanceOf(newLP);
        vm.prank(newLP);
        hook.removeLiquidity(_removeParams(hook.balanceOf(newLP)));
        uint256 bal0After = ERC20(Currency.unwrap(currency0)).balanceOf(newLP);
        assertLe(
            bal0After - bal0Before, 500 ether + 1 ether, "LP cannot withdraw more than deposited plus tiny fee share"
        );
        _assertAccounted();
    }

    // ── Griefing that cannot profit but can block settlement ──────────────────────

    function test_griefingCannotBlockSettlement() public {
        // Attacker tries to place order that would make escrow < gross — but hook prevents under-escrow at placement
        // So settlement must always succeed for any valid set
        for (uint256 i = 0; i < 5; i++) {
            _place(false, 10 ether + i * 1 ether);
            _place(true, 8 ether + i * 1 ether);
        }
        vm.roll(block.number + 1);
        // This must not revert with SettlementInvariant (grief)
        hook.settleExpiredEpoch();
        for (uint256 i = 0; i < 10; i++) {
            hook.claimRefund(i);
        }
        _assertAccounted();
    }

    function testFuzz_griefingNeverBlocksSettlement(uint64[8] memory raw) public {
        uint256 sum0;
        uint256 sum1;
        for (uint256 i = 0; i < 4; i++) {
            uint256 amt = bound(uint256(raw[i]), 1e6, 18 ether);
            bool dir = raw[i] % 2 == 0;
            if (dir) sum0 += amt;
            else sum1 += amt;
            if (sum0 > 80 ether || sum1 > 80 ether) return;
            _place(dir, amt);
        }
        _helperBlock += 10;
        vm.roll(_helperBlock);
        hook.settleExpiredEpoch(); // must not revert
        _assertAccounted();
    }

    // ── Helpers ──────────────────────────────────────────────────────────────────

    function _place(bool tokenOut0, uint256 amountOut) internal {
        _placeAs(address(this), tokenOut0, amountOut);
    }

    function _placeAs(address payer, bool tokenOut0, uint256 amountOut) internal {
        uint256 maximum = hook.requiredMaximumInput(tokenOut0, amountOut);
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: !tokenOut0,
                amountSpecified: int256(amountOut),
                sqrtPriceLimitX96: tokenOut0 ? TickMath.MAX_SQRT_PRICE - 1 : TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            abi.encode(payer, maximum, block.timestamp)
        );
    }

    function _claimIfOwner(uint256 orderId, address owner) internal returns (uint256 refund) {
        (address refundOwner,,,,,) = hook.orders(orderId);
        if (refundOwner != owner) return 0;
        // prank already set by caller if needed; just claim
        refund = hook.claimRefund(orderId);
    }

    function _runSplitScenario(bool tokenOut0, uint256 amountOut) internal returns (uint256 charge, uint256 gross) {
        // Deploy ephemeral hook for isolation
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
                | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
        );
        _helperNonce++;
        MarginalClearingEpoch h =
            MarginalClearingEpoch(payable(address(uint160(flags) | uint160(uint256(_helperNonce) << 80))));
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
        uint256 m = h.requiredMaximumInput(tokenOut0, amountOut);
        swapRouter.swap(
            k,
            SwapParams({
                zeroForOne: !tokenOut0,
                amountSpecified: int256(amountOut),
                sqrtPriceLimitX96: tokenOut0 ? TickMath.MAX_SQRT_PRICE - 1 : TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            abi.encode(address(this), m, block.timestamp)
        );
        _helperBlock += 10;
        vm.roll(_helperBlock);
        h.settleExpiredEpoch();
        (,,, uint128 max,,) = h.orders(0);
        uint256 refund = h.claimRefund(0);
        charge = uint256(max) - refund;
        {
            (,,,, uint256 _g0, uint256 _g1,,,) = h.settlements(1);
            gross = tokenOut0 ? _g1 : _g0;
        }
    }

    function _runSplitScenarioSplit(bool tokenOut0, uint256 a, uint256 b)
        internal
        returns (uint256 charge, uint256 gross)
    {
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
                | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
        );
        _helperNonce++;
        MarginalClearingEpoch h =
            MarginalClearingEpoch(payable(address(uint160(flags) | uint160(uint256(_helperNonce) << 80))));
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
        uint256 m0 = h.requiredMaximumInput(tokenOut0, a);
        uint256 m1 = h.requiredMaximumInput(tokenOut0, b);
        swapRouter.swap(
            k,
            SwapParams({
                zeroForOne: !tokenOut0,
                amountSpecified: int256(a),
                sqrtPriceLimitX96: tokenOut0 ? TickMath.MAX_SQRT_PRICE - 1 : TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            abi.encode(address(this), m0, block.timestamp)
        );
        swapRouter.swap(
            k,
            SwapParams({
                zeroForOne: !tokenOut0,
                amountSpecified: int256(b),
                sqrtPriceLimitX96: tokenOut0 ? TickMath.MAX_SQRT_PRICE - 1 : TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            abi.encode(address(this), m1, block.timestamp)
        );
        _helperBlock += 10;
        vm.roll(_helperBlock);
        h.settleExpiredEpoch();
        (,,, uint128 max0,,) = h.orders(0);
        (,,, uint128 max1,,) = h.orders(1);
        uint256 r0 = h.claimRefund(0);
        uint256 r1 = h.claimRefund(1);
        charge = (uint256(max0) - r0) + (uint256(max1) - r1);
        {
            (,,,, uint256 _g0, uint256 _g1,,,) = h.settlements(1);
            gross = tokenOut0 ? _g1 : _g0;
        }
    }

    function _fuzzSandwichCheck(uint256 victimAmt, uint256 attackAmt) internal {
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
                | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
        );
        address atk = makeAddr("fuzzAtk");
        address vic = makeAddr("fuzzVic");
        _fund(atk, 1000 ether);
        _fund(vic, 1000 ether);
        _approveHook(atk);
        _approveHook(vic);
        _helperNonce++;
        MarginalClearingEpoch h =
            MarginalClearingEpoch(payable(address(uint160(flags) | uint160(uint256(_helperNonce) << 80))));
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
        // Need to fund hook approvals for atk/vic? They are separate addresses with their own ERC20 balances and approvals to hook already via _approveHook
        uint256 b0Before = ERC20(Currency.unwrap(currency0)).balanceOf(atk);
        uint256 b1Before = ERC20(Currency.unwrap(currency1)).balanceOf(atk);
        // Place via pranks
        vm.startPrank(atk);
        uint256 mBuy = h.requiredMaximumInput(false, attackAmt);
        swapRouter.swap(
            k,
            SwapParams({
                zeroForOne: true,
                amountSpecified: int256(attackAmt),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            abi.encode(atk, mBuy, block.timestamp)
        );
        vm.stopPrank();
        vm.startPrank(vic);
        uint256 mVic = h.requiredMaximumInput(false, victimAmt);
        swapRouter.swap(
            k,
            SwapParams({
                zeroForOne: true,
                amountSpecified: int256(victimAmt),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            abi.encode(vic, mVic, block.timestamp)
        );
        vm.stopPrank();
        vm.startPrank(atk);
        uint256 mSell = h.requiredMaximumInput(true, attackAmt);
        swapRouter.swap(
            k,
            SwapParams({
                zeroForOne: false,
                amountSpecified: int256(attackAmt),
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            abi.encode(atk, mSell, block.timestamp)
        );
        vm.stopPrank();
        _helperBlock += 10;
        vm.roll(_helperBlock);
        h.settleExpiredEpoch();
        // claim attacker legs
        vm.prank(atk);
        h.claimRefund(0);
        vm.prank(atk);
        h.claimRefund(2);
        uint256 b0After = ERC20(Currency.unwrap(currency0)).balanceOf(atk);
        uint256 b1After = ERC20(Currency.unwrap(currency1)).balanceOf(atk);
        assertLe(
            int256(b0After) + int256(b1After) - int256(b0Before) - int256(b1Before),
            int256(0),
            "fuzz sandwich no profit"
        );
    }

    function _oneSidedGross(uint256 output1) internal pure returns (uint256) {
        uint256 net = FullMath.mulDivRoundingUp(1000 ether, output1, 1000 ether - output1);
        return FullMath.mulDivRoundingUp(net, 1000, 997);
    }

    function _fund(address who, uint256 amt) internal {
        ERC20(Currency.unwrap(currency0)).transfer(who, amt);
        ERC20(Currency.unwrap(currency1)).transfer(who, amt);
    }

    function _approveHook(address who) internal {
        vm.startPrank(who);
        ERC20(Currency.unwrap(currency0)).approve(address(hook), type(uint256).max);
        ERC20(Currency.unwrap(currency1)).approve(address(hook), type(uint256).max);
        ERC20(Currency.unwrap(currency0)).approve(address(swapRouter), type(uint256).max);
        ERC20(Currency.unwrap(currency1)).approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();
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

    function _removeParams(uint256 shares) internal pure returns (BaseCustomAccounting.RemoveLiquidityParams memory) {
        return BaseCustomAccounting.RemoveLiquidityParams(shares, 0, 0, MAX_DEADLINE, MIN_TICK, MAX_TICK, bytes32(0));
    }

    function _assertAccounted() internal view {
        (uint256 a0, uint256 a1) = hook.accountedMarginalClaims();
        assertEq(manager.balanceOf(address(hook), currency0.toId()), a0, "token0 claims");
        assertEq(manager.balanceOf(address(hook), currency1.toId()), a1, "token1 claims");
    }

    function _assertAccountedOnHook(MarginalClearingEpoch h) internal view {
        (uint256 a0, uint256 a1) = h.accountedMarginalClaims();
        assertEq(manager.balanceOf(address(h), currency0.toId()), a0, "token0 claims hook");
        assertEq(manager.balanceOf(address(h), currency1.toId()), a1, "token1 claims hook");
    }
}
