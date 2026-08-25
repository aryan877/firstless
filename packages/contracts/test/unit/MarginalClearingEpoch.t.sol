// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
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

contract MockOutputVault {
    ERC20 public immutable asset;
    mapping(address owner => uint256 shares) public balanceOf;

    constructor(ERC20 token) {
        asset = token;
    }

    function depositFor(address owner, uint256 amount) external {
        asset.transferFrom(msg.sender, address(this), amount);
        balanceOf[owner] += amount;
    }
}

/// @dev Product-seam harness only. It proves that the underlying exact output
/// can fund a second protocol action before the set or refund is finalized.
contract AtomicCreditComposer {
    using CurrencyLibrary for Currency;

    function swapAndDeposit(
        PoolSwapTest router,
        PoolKey calldata key,
        MockOutputVault vault,
        bool tokenOut0,
        uint256 amountOut,
        uint256 maximumInput,
        address beneficiary
    ) external {
        ERC20 input = ERC20(Currency.unwrap(tokenOut0 ? key.currency1 : key.currency0));
        ERC20 output = ERC20(Currency.unwrap(tokenOut0 ? key.currency0 : key.currency1));
        input.transferFrom(msg.sender, address(this), maximumInput);
        input.approve(address(router), maximumInput);

        router.swap(
            key,
            SwapParams({
                zeroForOne: !tokenOut0,
                amountSpecified: int256(amountOut),
                sqrtPriceLimitX96: tokenOut0 ? TickMath.MAX_SQRT_PRICE - 1 : TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            abi.encode(address(this), maximumInput, block.timestamp)
        );

        output.approve(address(vault), amountOut);
        vault.depositFor(beneficiary, amountOut);
    }
}

contract MarginalClearingEpochCoverageHarness is MarginalClearingEpoch {
    constructor(IPoolManager manager, address initialProvider)
        MarginalClearingEpoch(manager, 997, 1000, 1000, initialProvider)
    {}

    function exposedSwapFee(SwapParams calldata params, uint256 unspecifiedAmount) external pure returns (uint256) {
        return _getSwapFeeAmount(params, unspecifiedAmount);
    }
}

contract MarginalClearingEpochTest is HookTest {
    using CurrencyLibrary for Currency;

    MarginalClearingEpoch hook;

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

    function test_initialDepositAtomicallySeedsTheExactBackedBook() public view {
        assertTrue(hook.bookSeeded());
        assertEq(hook.logicalReserve0(), 1000 ether);
        assertEq(hook.logicalReserve1(), 1000 ether);
        assertEq(manager.balanceOf(address(hook), currency0.toId()), hook.logicalReserve0());
        assertEq(manager.balanceOf(address(hook), currency1.toId()), hook.logicalReserve1());
        assertEq(hook.totalSupply(), 1000 ether);
    }

    function test_blockNumberAboveUint64RangeRevertsInsteadOfTruncating() public {
        vm.roll(uint256(type(uint64).max) + 1);
        vm.expectRevert(ClearingCreditEpoch.AmountTooLarge.selector);
        hook.settleExpiredEpoch();
    }

    function test_constructorRejectsEveryInvalidFeeAndCapBoundary() public {
        _expectInvalidDeployment(0, 1000, 1000, address(this), 0x10);
        _expectInvalidDeployment(1001, 1000, 1000, address(this), 0x11);
        _expectInvalidDeployment(997, 1000, 0, address(this), 0x12);
        _expectInvalidDeployment(997, 1000, 10_000, address(this), 0x13);
        _expectInvalidDeployment(997, 1000, 1000, address(0), 0x14);
    }

    function test_requiredMaximumInputAtLimitRejectsEveryInvalidLimitBoundary() public {
        uint256 cap = 100 ether;
        assertGt(hook.requiredMaximumInputAtLimit(false, 1 ether, cap), 0);

        vm.expectRevert(MarginalClearingEpoch.InvalidSideOutputLimit.selector);
        hook.requiredMaximumInputAtLimit(false, 0, cap);
        vm.expectRevert(MarginalClearingEpoch.InvalidSideOutputLimit.selector);
        hook.requiredMaximumInputAtLimit(false, 2 ether, 1 ether);
        vm.expectRevert(MarginalClearingEpoch.InvalidSideOutputLimit.selector);
        hook.requiredMaximumInputAtLimit(false, 1 ether, cap + 1);
    }

    function test_pendingLiquidityCanReseedAfterTheLastActiveShareExits() public {
        hook.addLiquidity(_addParams(10 ether, 10 ether));
        hook.removeLiquidity(_removeParams(hook.totalSupply()));
        assertEq(hook.totalSupply(), 0);
        assertEq(hook.logicalReserve0(), 0);
        assertEq(hook.logicalReserve1(), 0);

        vm.roll(block.number + 1);
        (uint256 previewShares, uint256 amount0, uint256 amount1, uint256 refund0, uint256 refund1) =
            hook.previewPendingLiquidity(0);
        assertEq(previewShares, 10 ether);
        assertEq(amount0, 10 ether);
        assertEq(amount1, 10 ether);
        assertEq(refund0, 0);
        assertEq(refund1, 0);

        (uint256 shares, uint256 activatedRefund0, uint256 activatedRefund1) =
            hook.activatePendingLiquidity(0, previewShares);
        assertEq(shares, previewShares);
        assertEq(activatedRefund0, 0);
        assertEq(activatedRefund1, 0);
        assertEq(hook.logicalReserve0(), 10 ether);
        assertEq(hook.logicalReserve1(), 10 ether);
        _assertAccounted();
    }

    function test_customCurveSwapFeeIsExplicitlyZero() public {
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
                | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
        );
        MarginalClearingEpochCoverageHarness harness =
            MarginalClearingEpochCoverageHarness(payable(address(flags | uint160(0x15 << 80))));
        deployCodeTo(
            "test/unit/MarginalClearingEpoch.t.sol:MarginalClearingEpochCoverageHarness",
            abi.encode(address(manager), address(this)),
            address(harness)
        );
        SwapParams memory params =
            SwapParams({zeroForOne: true, amountSpecified: int256(1 ether), sqrtPriceLimitX96: SQRT_PRICE_1_2});
        assertEq(harness.exposedSwapFee(params, 1 ether), 0);
    }

    function test_onlyConfiguredProviderCanCreateTheInitialBook() public {
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
                | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
        );
        MarginalClearingEpoch secondary = MarginalClearingEpoch(payable(address(flags | uint160(1 << 80))));
        deployCodeTo(
            "src/core/MarginalClearingEpoch.sol:MarginalClearingEpoch",
            abi.encode(address(manager), 997, 1000, 1000, address(0xBEEF)),
            address(secondary)
        );
        vm.expectRevert();
        initPool(currency0, currency1, IHooks(address(secondary)), LPFeeLibrary.DYNAMIC_FEE_FLAG, SQRT_PRICE_1_1);
        vm.prank(address(0xBEEF));
        initPool(currency0, currency1, IHooks(address(secondary)), LPFeeLibrary.DYNAMIC_FEE_FLAG, SQRT_PRICE_1_1);

        vm.expectRevert(ClearingCreditEpoch.OnlyInitialLiquidityProvider.selector);
        secondary.addLiquidity(_addParams(1 ether, 1 ether));
        assertFalse(secondary.bookSeeded());
        assertEq(secondary.totalSupply(), 0);
    }

    function test_nativeCurrencyPoolIsRejectedBecauseSignedRouterUsesErc20Settlement() public {
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
                | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
        );
        MarginalClearingEpoch nativeHook = MarginalClearingEpoch(payable(address(flags | uint160(2 << 80))));
        deployCodeTo(
            "src/core/MarginalClearingEpoch.sol:MarginalClearingEpoch",
            abi.encode(address(manager), 997, 1000, 1000, address(this)),
            address(nativeHook)
        );
        PoolKey memory nativeKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(nativeHook))
        });

        vm.expectRevert();
        manager.initialize(nativeKey, SQRT_PRICE_1_1);
        assertEq(address(nativeHook.poolKey().hooks), address(0));
    }

    function test_balancedFlowDeliversNowAndAccruesOnlyRawUnitProtectionSlack() public {
        uint256 balance0 = currency0.balanceOf(address(this));
        uint256 balance1 = currency1.balanceOf(address(this));
        _place(false, 70 ether);
        assertGt(currency1.balanceOf(address(this)), balance1, "token1 output delivered synchronously");
        uint256 afterFirst0 = currency0.balanceOf(address(this));
        _place(true, 70 ether);
        assertGt(currency0.balanceOf(address(this)), afterFirst0, "token0 output delivered synchronously");
        assertLt(currency0.balanceOf(address(this)), balance0 + 70 ether, "input escrow is paid synchronously");

        vm.roll(block.number + 1);
        hook.settleExpiredEpoch();
        hook.claimRefund(1);
        hook.claimRefund(0);
        assertEq(hook.logicalReserve0(), 1000 ether);
        assertEq(hook.logicalReserve1(), 1000 ether);
        assertGt(hook.feeBucket0(), 0);
        assertGt(hook.feeBucket1(), 0);
        assertLt(hook.protectionReserve0(), 20);
        assertLt(hook.protectionReserve1(), 20);
        _assertAccounted();
    }

    function test_outputFundsSecondProtocolActionBeforeSetAndRefundFinalize() public {
        uint256 amountOut = 25 ether;
        uint256 maximumInput = hook.requiredMaximumInput(false, amountOut);
        AtomicCreditComposer composer = new AtomicCreditComposer();
        MockOutputVault vault = new MockOutputVault(ERC20(Currency.unwrap(currency1)));

        ERC20(Currency.unwrap(currency0)).approve(address(composer), maximumInput);
        composer.swapAndDeposit(swapRouter, key, vault, false, amountOut, maximumInput, address(this));

        assertEq(vault.balanceOf(address(this)), amountOut, "output was consumed by second protocol");
        assertEq(currency1.balanceOf(address(vault)), amountOut, "vault received underlying before close");
        (,,,,,,,, bool settled) = hook.settlements(1);
        assertFalse(settled, "set must still be open during downstream action");
        (,,,,, bool claimed) = hook.orders(0);
        assertFalse(claimed, "refund must not exist yet");
        _assertAccounted();
    }

    function test_sameSideFakeCannotProfitEvenWithAllPhysicalLpEconomics() public {
        uint256 victim = 50 ether;
        uint256 fake = 10 ether;
        _place(false, victim);
        _place(false, fake);
        vm.roll(block.number + 1);
        hook.settleExpiredEpoch();

        (,,,, uint256 grossInput0,,,,) = hook.settlements(1);
        uint256 baselineGross = _oneSidedGross(victim);
        (,,, uint128 fakeMaximum,,) = hook.orders(1);
        uint256 fakeRefund = hook.claimRefund(1);
        uint256 fakeCharge = uint256(fakeMaximum) - fakeRefund;

        // At the epoch-start price the fake's output cancels the physical
        // pool's extra output liability. What remains is gross-cost increment
        // minus its leave-one-out charge.
        assertGe(fakeCharge, grossInput0 - baselineGross);
        _assertAccounted();
    }

    function test_paidGriefCostsFakeAtLeastTheVictimChargeIncrease() public {
        uint256 victim = 50 ether;
        uint256 fake = 10 ether;
        _place(false, victim);
        _place(false, fake);
        vm.roll(block.number + 1);
        hook.settleExpiredEpoch();

        (,,, uint128 victimMaximum,,) = hook.orders(0);
        (,,, uint128 fakeMaximum,,) = hook.orders(1);
        uint256 victimCharge = uint256(victimMaximum) - hook.claimRefund(0);
        uint256 fakeCharge = uint256(fakeMaximum) - hook.claimRefund(1);
        uint256 baselineVictimCharge = _oneSidedGross(victim) + 8;
        uint256 victimHarm = victimCharge - baselineVictimCharge;
        uint256 fakeLoss = fakeCharge - fake;
        assertGe(fakeLoss, victimHarm);
        _assertAccounted();
    }

    function test_splitFakePaysAtLeastUnsplitLeaveOneOutCost() public {
        uint256 victim = 50 ether;
        _place(false, victim);
        _place(false, 5 ether);
        _place(false, 5 ether);
        vm.roll(block.number + 1);
        hook.settleExpiredEpoch();
        (,,, uint128 max1,,) = hook.orders(1);
        (,,, uint128 max2,,) = hook.orders(2);
        uint256 splitCharge = uint256(max1) - hook.claimRefund(1) + uint256(max2) - hook.claimRefund(2);
        uint256 unsplitCharge = _oneSidedGross(60 ether) - _oneSidedGross(50 ether) + 8;
        assertGe(splitCharge, unsplitCharge);
        _assertAccounted();
    }

    function test_multipleEpochClaimsRemainBackedAndSurplusIsNotLpFee() public {
        uint256 firstBoundary = block.number + 1;
        _place(false, 40 ether);
        vm.roll(firstBoundary);
        hook.settleExpiredEpoch();
        _place(true, 35 ether);
        vm.roll(firstBoundary + 1);
        hook.settleExpiredEpoch();
        _assertAccounted();

        hook.claimRefund(1);
        _assertAccounted();
        hook.claimRefund(0);
        assertEq(hook.refundLiability0(), 0);
        assertEq(hook.refundLiability1(), 0);
        assertGt(hook.protectionReserve0() + hook.protectionReserve1(), 0);
        _assertAccounted();
    }

    function test_postSettlementFullShareExitDoesNotConsumeOutstandingRefundBacking() public {
        _place(false, 40 ether);
        vm.roll(block.number + 1);
        hook.settleExpiredEpoch();
        uint256 refundLiabilityBefore = hook.refundLiability0();
        uint256 shares = hook.balanceOf(address(this));

        hook.removeLiquidity(_removeParams(shares));

        assertEq(hook.refundLiability0(), refundLiabilityBefore);
        _assertAccounted();
        hook.claimRefund(0);
        assertEq(hook.refundLiability0(), 0);
        _assertAccounted();
    }

    function test_pendingLiquidityCannotCaptureFeesBeforeItsCapitalBecomesActive() public {
        address justInTimeLp = address(0xBEEF);
        ERC20(Currency.unwrap(currency0)).transfer(justInTimeLp, 9_000 ether);
        ERC20(Currency.unwrap(currency1)).transfer(justInTimeLp, 9_000 ether);
        vm.startPrank(justInTimeLp);
        ERC20(Currency.unwrap(currency0)).approve(address(hook), type(uint256).max);
        ERC20(Currency.unwrap(currency1)).approve(address(hook), type(uint256).max);
        hook.addLiquidity(_addParams(9_000 ether, 9_000 ether));
        vm.stopPrank();

        assertEq(hook.logicalReserve0(), 1_000 ether, "pending capital is not active");
        assertEq(hook.balanceOf(justInTimeLp), 0, "pending capital has no active shares");

        _place(false, 50 ether);
        _place(true, 50 ether);
        vm.roll(block.number + 1);
        hook.settleExpiredEpoch();

        vm.prank(justInTimeLp);
        hook.activatePendingLiquidity(0, 0);
        uint256 activeShares = hook.balanceOf(justInTimeLp);
        assertLt(activeShares, 9_000 ether, "shares are priced after the fee-bearing set closes");
        vm.prank(justInTimeLp);
        hook.removeLiquidity(_removeParams(activeShares));
        assertLe(currency0.balanceOf(justInTimeLp), 9_000 ether, "cannot capture prior token0 fees");
        assertLe(currency1.balanceOf(justInTimeLp), 9_000 ether, "cannot capture prior token1 fees");
        _assertAccounted();
    }

    function test_maturedPendingLiquidityCannotActivateInsideAnOpenEpoch() public {
        hook.addLiquidity(_addParams(10 ether, 10 ether));
        uint256 maturityBlock = block.number + 1;
        vm.roll(maturityBlock);
        _place(false, 50 ether);

        vm.expectRevert(ClearingCreditEpoch.EpochStillOpen.selector);
        hook.activatePendingLiquidity(0, 0);

        assertEq(hook.totalSupply(), 1_000 ether, "no shares minted inside the set");
        assertEq(hook.logicalReserve0(), 1_000 ether, "active token0 reserve unchanged");
        assertEq(hook.logicalReserve1(), 1_000 ether, "active token1 reserve unchanged");
        assertEq(hook.pendingDeposit0(), 10 ether, "pending token0 remains recoverable");
        assertEq(hook.pendingDeposit1(), 10 ether, "pending token1 remains recoverable");
        _assertAccounted();

        vm.roll(maturityBlock + 1);
        hook.settleExpiredEpoch();
        hook.activatePendingLiquidity(0, 0);
        _assertAccounted();
    }

    function test_pendingDepositCannotBlockActiveLpExitSwapOrProviderCancellation() public {
        address provider = address(0xBEEF);
        ERC20(Currency.unwrap(currency0)).transfer(provider, 10 ether);
        ERC20(Currency.unwrap(currency1)).transfer(provider, 10 ether);
        vm.startPrank(provider);
        ERC20(Currency.unwrap(currency0)).approve(address(hook), type(uint256).max);
        ERC20(Currency.unwrap(currency1)).approve(address(hook), type(uint256).max);
        hook.addLiquidity(_addParams(10 ether, 10 ether));
        vm.stopPrank();

        hook.removeLiquidity(_removeParams(100 ether));
        _place(false, 10 ether);

        vm.prank(provider);
        hook.cancelPendingLiquidity(0);
        assertEq(currency0.balanceOf(provider), 10 ether, "provider recovers token0");
        assertEq(currency1.balanceOf(provider), 10 ether, "provider recovers token1");
        assertEq(hook.pendingDeposit0(), 0);
        assertEq(hook.pendingDeposit1(), 0);
        _assertAccounted();

        vm.roll(block.number + 1);
        hook.settleExpiredEpoch();
        hook.claimRefund(0);
        _assertAccounted();
    }

    function test_pendingReceiptEnforcesMaturityOwnershipAndMinimumShares() public {
        address provider = address(0xBEEF);
        ERC20(Currency.unwrap(currency0)).transfer(provider, 10 ether);
        ERC20(Currency.unwrap(currency1)).transfer(provider, 10 ether);
        vm.startPrank(provider);
        ERC20(Currency.unwrap(currency0)).approve(address(hook), type(uint256).max);
        ERC20(Currency.unwrap(currency1)).approve(address(hook), type(uint256).max);
        hook.addLiquidity(_addParams(10 ether, 10 ether));
        vm.expectRevert(ClearingCreditEpoch.DepositStillMaturing.selector);
        hook.activatePendingLiquidity(0, 0);
        vm.stopPrank();

        vm.roll(block.number + 1);
        vm.expectRevert(ClearingCreditEpoch.InvalidDepositOwner.selector);
        hook.activatePendingLiquidity(0, 0);
        vm.expectRevert(ClearingCreditEpoch.InvalidDepositOwner.selector);
        hook.cancelPendingLiquidity(0);

        vm.prank(provider);
        vm.expectRevert(ClearingCreditEpoch.InsufficientLiquidityShares.selector);
        hook.activatePendingLiquidity(0, 11 ether);
        assertEq(hook.pendingDeposit0(), 10 ether, "failed activation preserves token0 custody");
        assertEq(hook.pendingDeposit1(), 10 ether, "failed activation preserves token1 custody");

        vm.prank(provider);
        hook.cancelPendingLiquidity(0);
        assertEq(currency0.balanceOf(provider), 10 ether);
        assertEq(currency1.balanceOf(provider), 10 ether);
        _assertAccounted();
    }

    function test_activationRefundsRatioExcessAndMatchesTheMaturePreview() public {
        address provider = address(0xBEEF);
        ERC20(Currency.unwrap(currency0)).transfer(provider, 100 ether);
        ERC20(Currency.unwrap(currency1)).transfer(provider, 100 ether);
        vm.startPrank(provider);
        ERC20(Currency.unwrap(currency0)).approve(address(hook), type(uint256).max);
        ERC20(Currency.unwrap(currency1)).approve(address(hook), type(uint256).max);
        hook.addLiquidity(_addParams(100 ether, 100 ether));
        vm.stopPrank();

        _place(false, 50 ether);
        vm.roll(block.number + 1);
        hook.settleExpiredEpoch();
        (uint256 quotedShares,,, uint256 quotedRefund0, uint256 quotedRefund1) = hook.previewPendingLiquidity(0);
        assertGt(quotedRefund0 + quotedRefund1, 0, "reserve movement creates ratio excess");

        vm.prank(provider);
        (uint256 shares, uint256 refund0, uint256 refund1) = hook.activatePendingLiquidity(0, quotedShares);
        assertEq(shares, quotedShares);
        assertEq(refund0, quotedRefund0);
        assertEq(refund1, quotedRefund1);
        assertEq(hook.balanceOf(provider), shares);
        assertEq(currency0.balanceOf(provider), refund0);
        assertEq(currency1.balanceOf(provider), refund1);
        _assertAccounted();
    }

    function testFuzz_oneSidedClaimIsBackedAndMarginalChargeCoversPhysicalIncrement(uint96 rawVictim, uint96 rawFake)
        public
    {
        uint256 victim = bound(uint256(rawVictim), 1e6, 80 ether);
        uint256 fake = bound(uint256(rawFake), 1e6, 99 ether - victim);
        _place(false, victim);
        _place(false, fake);
        vm.roll(block.number + 1);
        hook.settleExpiredEpoch();
        (,,,, uint256 grossInput0,,,,) = hook.settlements(1);
        (,,, uint128 fakeMaximum,,) = hook.orders(1);
        uint256 charge = uint256(fakeMaximum) - hook.claimRefund(1);
        assertGe(charge, grossInput0 - _oneSidedGross(victim));
        _assertAccounted();
    }

    function testFuzz_twoSidedMultiOrderCoalitionChargesCoverBothResourceIncrements(
        uint64 rawHonest0,
        uint64 rawHonest1,
        uint64 rawAttack0,
        uint64 rawAttack1
    ) public {
        uint256 honest0 = bound(uint256(rawHonest0), 1e6, 30 ether);
        uint256 honest1 = bound(uint256(rawHonest1), 1e6, 30 ether);
        uint256 attack0 = bound(uint256(rawAttack0), 1e6, 90 ether - honest0);
        uint256 attack1 = bound(uint256(rawAttack1), 1e6, 90 ether - honest1);

        _place(true, honest0);
        _place(false, honest1);
        _place(true, attack0);
        _place(false, attack1);

        vm.roll(block.number + 1);
        hook.settleExpiredEpoch();
        (,,,, uint256 gross0, uint256 gross1,,,) = hook.settlements(1);
        (uint256 baseline0, uint256 baseline1) = _grossForTotals(honest0, honest1);

        (,,, uint128 maximum2,,) = hook.orders(2);
        (,,, uint128 maximum3,,) = hook.orders(3);
        uint256 attackCharge1 = uint256(maximum2) - hook.claimRefund(2);
        uint256 attackCharge0 = uint256(maximum3) - hook.claimRefund(3);

        if (gross0 > baseline0) assertGe(attackCharge0, gross0 - baseline0);
        if (gross1 > baseline1) assertGe(attackCharge1, gross1 - baseline1);

        hook.claimRefund(0);
        hook.claimRefund(1);
        _assertAccounted();
    }

    function test_dustOrderCannotReserveTheSideAndLaterOrdersUseTheGlobalCap() public {
        _place(false, 1);
        _place(false, 100 ether - 1);

        uint256 extraMaximum = hook.requiredMaximumInput(false, 1);
        vm.expectRevert();
        _placeWithTerms(false, 1, extraMaximum);

        vm.roll(block.number + 1);
        hook.settleExpiredEpoch();
        hook.claimRefund(0);
        hook.claimRefund(1);
        _assertAccounted();
    }

    function _place(bool tokenOut0, uint256 amountOut) internal {
        uint256 maximum = hook.requiredMaximumInput(tokenOut0, amountOut);
        _placeWithTerms(tokenOut0, amountOut, maximum);
    }

    function _expectInvalidDeployment(
        uint256 numerator,
        uint256 denominator,
        uint256 outputCapBps,
        address initialProvider,
        uint256 addressSalt
    ) internal {
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
                | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
        );
        address target = address(flags | uint160(addressSalt << 80));
        vm.expectRevert();
        deployCodeTo(
            "src/core/MarginalClearingEpoch.sol:MarginalClearingEpoch",
            abi.encode(address(manager), numerator, denominator, outputCapBps, initialProvider),
            target
        );
    }

    function _placeWithTerms(bool tokenOut0, uint256 amountOut, uint256 maximum) internal {
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: !tokenOut0,
                amountSpecified: int256(amountOut),
                sqrtPriceLimitX96: tokenOut0 ? SQRT_PRICE_2_1 : SQRT_PRICE_1_2
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            abi.encode(address(this), maximum, block.timestamp)
        );
    }

    function _oneSidedGross(uint256 output1) internal pure returns (uint256) {
        uint256 net = FullMath.mulDivRoundingUp(1000 ether, output1, 1000 ether - output1);
        return FullMath.mulDivRoundingUp(net, 1000, 997);
    }

    function _grossForTotals(uint256 output0, uint256 output1) internal pure returns (uint256 gross0, uint256 gross1) {
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
        (uint256 amount0, uint256 amount1) = hook.accountedMarginalClaims();
        assertEq(manager.balanceOf(address(hook), currency0.toId()), amount0, "token0 claims");
        assertEq(manager.balanceOf(address(hook), currency1.toId()), amount1, "token1 claims");
    }
}
