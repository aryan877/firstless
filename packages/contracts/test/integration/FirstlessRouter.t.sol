// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BaseCustomAccounting} from "ozhooks/base/BaseCustomAccounting.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {console2} from "forge-std/console2.sol";
import {HookTest} from "oztest/utils/HookTest.sol";
import {FirstlessHook} from "firstless/hooks/FirstlessHook.sol";
import {AuthenticatedMarginalClearingEpoch} from "firstless/hooks/AuthenticatedMarginalClearingEpoch.sol";
import {FirstlessRefundRedeemer} from "firstless/periphery/FirstlessRefundRedeemer.sol";
import {FirstlessRouter} from "firstless/periphery/FirstlessRouter.sol";

contract SignedOutputConsumer {
    ERC20 public immutable asset;
    address public immutable router;
    uint256 public accountedAssets;
    mapping(address beneficiary => uint256 shares) public balanceOf;

    error OnlyRouter();
    error OutputNotReceived();

    constructor(ERC20 token, address trustedRouter) {
        asset = token;
        router = trustedRouter;
    }

    function consume(address beneficiary, uint256 amount) external {
        if (msg.sender != router) revert OnlyRouter();
        if (asset.balanceOf(address(this)) < accountedAssets + amount) revert OutputNotReceived();
        accountedAssets += amount;
        balanceOf[beneficiary] += amount;
    }
}

contract RevertingSignedConsumer {
    function fail() external pure {
        revert("DOWNSTREAM_REVERT");
    }
}

contract ReentrantSignedConsumer {
    FirstlessRouter public immutable router;
    bool public reentered;

    error OnlyRouter();

    constructor(FirstlessRouter trustedRouter) {
        router = trustedRouter;
    }

    function reenter(PoolKey calldata key, FirstlessRouter.CreditOrder calldata order, bytes calldata signature)
        external
    {
        if (msg.sender != address(router)) revert OnlyRouter();
        router.execute(key, order, signature, bytes(""));
        reentered = true;
    }
}

contract FirstlessRouterTest is HookTest {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;

    uint256 constant PAYER_A_KEY = 0xA11CE;
    uint256 constant PAYER_B_KEY = 0xB0B;
    uint256 constant MAX_DEADLINE = 12_329_839_823;
    int24 constant MIN_TICK = -887220;
    int24 constant MAX_TICK = 887220;

    FirstlessHook hook;
    FirstlessRouter signedRouter;
    FirstlessRefundRedeemer refundRedeemer;
    address payerA;
    address payerB;

    function setUp() public {
        vm.chainId(11_155_111);
        vm.roll(100);

        deployFreshManagerAndRouters();
        signedRouter = new FirstlessRouter(manager);
        refundRedeemer = new FirstlessRefundRedeemer(manager);
        hook = FirstlessHook(
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
            "src/hooks/FirstlessHook.sol:FirstlessHook",
            abi.encode(address(manager), 997, 1000, 1000, address(signedRouter), address(this)),
            address(hook)
        );

        deployMintAndApprove2Currencies();
        (key,) = initPool(currency0, currency1, IHooks(address(hook)), LPFeeLibrary.DYNAMIC_FEE_FLAG, SQRT_PRICE_1_1);
        ERC20(Currency.unwrap(currency0)).approve(address(hook), type(uint256).max);
        ERC20(Currency.unwrap(currency1)).approve(address(hook), type(uint256).max);
        hook.addLiquidity(_addParams(1000 ether, 1000 ether));

        payerA = vm.addr(PAYER_A_KEY);
        payerB = vm.addr(PAYER_B_KEY);
        _fundAndApprove(payerA);
        _fundAndApprove(payerB);
    }

    function test_signedOrderDeliversUnderlyingIntoSecondProtocolAndRefundStaysBoundToPayer() public {
        uint128 amountOut = 25 ether;
        uint128 maximumInput = uint128(hook.requiredMaximumInput(false, amountOut));
        SignedOutputConsumer consumer =
            new SignedOutputConsumer(ERC20(Currency.unwrap(currency1)), address(signedRouter));
        bytes memory callData = abi.encodeCall(consumer.consume, (payerA, amountOut));
        FirstlessRouter.CreditOrder memory order =
            _order(payerA, address(consumer), address(consumer), true, amountOut, maximumInput, callData);

        uint256 payerInputBefore = currency0.balanceOf(payerA);
        uint256 delivered = signedRouter.execute(key, order, _sign(PAYER_A_KEY, order), callData);

        assertEq(delivered, amountOut);
        assertEq(consumer.balanceOf(payerA), amountOut, "downstream action consumed output now");
        assertEq(currency1.balanceOf(address(consumer)), amountOut, "consumer received underlying");
        assertEq(currency0.balanceOf(payerA), payerInputBefore - maximumInput, "maximum input escrowed now");
        (address refundOwner,,,,,) = hook.orders(0);
        assertEq(refundOwner, payerA, "refund cannot be redirected by relayer");
        (,,,,,,,, bool settled) = hook.settlements(1);
        assertFalse(settled, "settlement remains deferred");

        vm.roll(101);
        hook.settleExpiredEpoch();
        uint256 claimsBefore = manager.balanceOf(payerA, currency0.toId());
        vm.prank(payerA);
        uint256 refund = hook.claimRefund(0);
        assertEq(manager.balanceOf(payerA, currency0.toId()), claimsBefore + refund);
        uint256 underlyingBefore = currency0.balanceOf(payerA);
        vm.prank(payerA);
        manager.setOperator(address(refundRedeemer), true);
        vm.prank(payerA);
        refundRedeemer.redeem(currency0, refund, payerA);
        assertEq(manager.balanceOf(payerA, currency0.toId()), claimsBefore);
        assertEq(currency0.balanceOf(payerA), underlyingBefore + refund);
        _assertAccounted();
    }

    function test_demoReceiveNowSettleLaterAndRedeemRefund() public {
        uint128 amountOut = 25 ether;
        uint128 maximumInput = uint128(hook.requiredMaximumInput(false, amountOut));
        SignedOutputConsumer consumer =
            new SignedOutputConsumer(ERC20(Currency.unwrap(currency1)), address(signedRouter));
        bytes memory callData = abi.encodeCall(consumer.consume, (payerA, amountOut));
        FirstlessRouter.CreditOrder memory order =
            _order(payerA, address(consumer), address(consumer), true, amountOut, maximumInput, callData);

        signedRouter.execute(key, order, _sign(PAYER_A_KEY, order), callData);

        bytes memory emptyCallData;
        FirstlessRouter.CreditOrder memory opposingOrder = _plainOrder(payerB, false, 15 ether, payerB, emptyCallData);
        signedRouter.execute(key, opposingOrder, _sign(PAYER_B_KEY, opposingOrder), emptyCallData);

        (,,,,,,,, bool settledBeforeClose) = hook.settlements(1);
        console2.log("Ethereum block before close", block.number);
        console2.log("Requested output delivered now (token wei)", uint256(amountOut));
        console2.log("Output already consumed downstream (token wei)", consumer.balanceOf(payerA));
        console2.log("Conservative input escrow (token wei)", uint256(maximumInput));
        console2.log("Set settled during either order", settledBeforeClose);

        vm.roll(101);
        hook.settleExpiredEpoch();
        vm.prank(payerA);
        uint256 refund = hook.claimRefund(0);
        uint256 finalCharge = uint256(maximumInput) - refund;

        uint256 underlyingBefore = currency0.balanceOf(payerA);
        vm.prank(payerA);
        manager.setOperator(address(refundRedeemer), true);
        vm.prank(payerA);
        refundRedeemer.redeem(currency0, refund, payerA);

        console2.log("Ethereum block after close", block.number);
        console2.log("Final input bill (token wei)", finalCharge);
        console2.log("Refund redeemed as underlying (token wei)", refund);
        console2.log("Refund reached the signed payer", currency0.balanceOf(payerA) - underlyingBefore);

        assertEq(consumer.balanceOf(payerA), amountOut, "downstream position remains funded");
        assertEq(currency0.balanceOf(payerA) - underlyingBefore, refund, "refund redeemed to payer");
        _assertAccounted();
    }

    function test_directPoolSwapRouterCannotBypassAuthenticatedOrderBoundary() public {
        uint256 amountOut = 10 ether;
        uint256 maximumInput = hook.requiredMaximumInput(false, amountOut);
        uint64 currentBlock = uint64(block.number);
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeSwap.selector,
                abi.encodeWithSelector(AuthenticatedMarginalClearingEpoch.UntrustedRouter.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        swapRouter.swap(
            key,
            SwapParams({zeroForOne: true, amountSpecified: int256(amountOut), sqrtPriceLimitX96: SQRT_PRICE_1_2}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            abi.encode(address(this), maximumInput, block.timestamp, currentBlock, currentBlock)
        );
    }

    function test_signatureReplayIsRejectedBeforeCreatingAnotherHookOrder() public {
        bytes memory callData;
        FirstlessRouter.CreditOrder memory order = _plainOrder(payerA, true, 10 ether, address(payerA), callData);
        bytes memory signature = _sign(PAYER_A_KEY, order);
        signedRouter.execute(key, order, signature, callData);

        vm.expectRevert(FirstlessRouter.InvalidNonce.selector);
        signedRouter.execute(key, order, signature, callData);
        assertEq(hook.nextOrderId(), 1);
    }

    function test_payerCanInvalidateUnsubmittedSignaturesWithoutCreatingAnOrder() public {
        bytes memory callData;
        FirstlessRouter.CreditOrder memory order = _plainOrder(payerA, true, 10 ether, payerA, callData);
        bytes memory signature = _sign(PAYER_A_KEY, order);

        vm.prank(payerA);
        signedRouter.invalidateNonce(1);
        vm.expectRevert(FirstlessRouter.InvalidNonce.selector);
        signedRouter.execute(key, order, signature, callData);
        assertEq(signedRouter.nonces(payerA), 1);
        assertEq(hook.nextOrderId(), 0);
    }

    function test_signedMaximumIsAnUpperBoundAndOnlyActualHookEscrowIsTransferred() public {
        uint128 amountOut = 10 ether;
        uint128 actualMaximum = uint128(hook.requiredMaximumInput(false, amountOut));
        uint128 signedMaximum = actualMaximum + 1 ether;
        bytes memory callData;
        FirstlessRouter.CreditOrder memory order =
            _order(payerA, payerA, address(0), true, amountOut, signedMaximum, callData);
        uint256 balanceBefore = currency0.balanceOf(payerA);

        signedRouter.execute(key, order, _sign(PAYER_A_KEY, order), callData);

        assertEq(currency0.balanceOf(payerA), balanceBefore - actualMaximum);
        (,,, uint128 storedMaximum,,) = hook.orders(0);
        assertEq(storedMaximum, actualMaximum);
    }

    function test_downstreamRevertRollsBackNonceOrderOutputAndInputAtomically() public {
        RevertingSignedConsumer consumer = new RevertingSignedConsumer();
        bytes memory callData = abi.encodeCall(consumer.fail, ());
        FirstlessRouter.CreditOrder memory order =
            _order(payerA, payerA, address(consumer), true, 10 ether, _maximum(false, 10 ether), callData);
        bytes memory signature = _sign(PAYER_A_KEY, order);
        uint256 inputBefore = currency0.balanceOf(payerA);
        uint256 outputBefore = currency1.balanceOf(payerA);

        vm.expectPartialRevert(FirstlessRouter.DownstreamCallFailed.selector);
        signedRouter.execute(key, order, signature, callData);

        assertEq(signedRouter.nonces(payerA), 0);
        assertEq(hook.nextOrderId(), 0);
        assertEq(currency0.balanceOf(payerA), inputBefore);
        assertEq(currency1.balanceOf(payerA), outputBefore);
    }

    function test_downstreamReentrancyCanOnlyExecuteASecondSeparatelySignedOrder() public {
        ReentrantSignedConsumer consumer = new ReentrantSignedConsumer(signedRouter);
        bytes memory emptyCallData;
        FirstlessRouter.CreditOrder memory second = _plainOrder(payerA, true, 11 ether, payerA, emptyCallData);
        second.nonce = 1;
        bytes memory secondSignature = _sign(PAYER_A_KEY, second);

        bytes memory firstCallData = abi.encodeCall(consumer.reenter, (key, second, secondSignature));
        FirstlessRouter.CreditOrder memory first =
            _order(payerA, payerA, address(consumer), true, 10 ether, _maximum(false, 10 ether), firstCallData);

        signedRouter.execute(key, first, _sign(PAYER_A_KEY, first), firstCallData);

        assertTrue(consumer.reentered());
        assertEq(signedRouter.nonces(payerA), 2);
        assertEq(hook.nextOrderId(), 2, "reentrancy cannot merge signatures into one order");
        (address owner0,, uint128 output0,,,) = hook.orders(0);
        (address owner1,, uint128 output1,,,) = hook.orders(1);
        assertEq(owner0, payerA);
        assertEq(owner1, payerA);
        assertEq(output0 + output1, 21 ether);
    }

    function test_recipientAmountAndCallPlanTamperingAreRejected() public {
        bytes memory callData;
        FirstlessRouter.CreditOrder memory order = _plainOrder(payerA, true, 10 ether, payerA, callData);
        bytes memory signature = _sign(PAYER_A_KEY, order);

        order.recipient = payerB;
        vm.expectRevert(FirstlessRouter.InvalidSignature.selector);
        signedRouter.execute(key, order, signature, callData);
        order.recipient = payerA;

        order.amountOut += 1;
        vm.expectRevert(FirstlessRouter.InvalidSignature.selector);
        signedRouter.execute(key, order, signature, callData);
        order.amountOut -= 1;

        vm.expectRevert(FirstlessRouter.InvalidCallPlan.selector);
        signedRouter.execute(key, order, signature, hex"01");
        assertEq(hook.nextOrderId(), 0);
        assertEq(signedRouter.nonces(payerA), 0);
    }

    function test_invalidClockWindowRollsBackNonceAndCreatesNoOrder() public {
        bytes memory callData;
        FirstlessRouter.CreditOrder memory order = _plainOrder(payerA, true, 10 ether, payerA, callData);
        order.validAfter = uint64(block.number + 1);
        order.validBefore = uint64(block.number + 2);
        bytes memory signature = _sign(PAYER_A_KEY, order);

        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeSwap.selector,
                abi.encodeWithSelector(AuthenticatedMarginalClearingEpoch.InvalidClockWindow.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        signedRouter.execute(key, order, signature, callData);
        assertEq(signedRouter.nonces(payerA), 0);
        assertEq(hook.nextOrderId(), 0);
    }

    function test_nextEthereumBlockClosesTheSetAndOpensTheNextSet() public {
        bytes memory callData;
        FirstlessRouter.CreditOrder memory order = _plainOrder(payerA, true, 10 ether, payerA, callData);
        signedRouter.execute(key, order, _sign(PAYER_A_KEY, order), callData);

        vm.expectRevert();
        hook.settleExpiredEpoch();
        vm.roll(101);
        hook.settleExpiredEpoch();
        (,,,,,,,, bool settled) = hook.settlements(1);
        assertTrue(settled);

        FirstlessRouter.CreditOrder memory second = _plainOrder(payerA, true, 10 ether, payerA, callData);
        signedRouter.execute(key, second, _sign(PAYER_A_KEY, second), callData);

        assertEq(hook.currentEpochId(), 2);
        vm.roll(102);
        hook.settleExpiredEpoch();
        (,,,,,,,, bool secondSettled) = hook.settlements(2);
        assertTrue(secondSettled);
    }

    function test_twoIndependentSignaturesRemainTwoOrdersAndCannotBeMergedByRelayer() public {
        bytes memory callData;
        address sharedRecipient = address(0xA66);
        FirstlessRouter.CreditOrder memory first = _plainOrder(payerA, true, 10 ether, sharedRecipient, callData);
        FirstlessRouter.CreditOrder memory second = _plainOrder(payerB, true, 15 ether, sharedRecipient, callData);

        vm.prank(address(0xCAFE));
        signedRouter.execute(key, first, _sign(PAYER_A_KEY, first), callData);
        vm.prank(address(0xCAFE));
        signedRouter.execute(key, second, _sign(PAYER_B_KEY, second), callData);

        assertEq(hook.nextOrderId(), 2, "one signature must map to one hook order");
        (address firstOwner,, uint128 firstOutput,,,) = hook.orders(0);
        (address secondOwner,, uint128 secondOutput,,,) = hook.orders(1);
        assertEq(firstOwner, payerA);
        assertEq(secondOwner, payerB);
        assertEq(firstOutput, 10 ether);
        assertEq(secondOutput, 15 ether);
        assertEq(currency1.balanceOf(sharedRecipient), 25 ether, "shared recipient does not merge payer records");
    }

    function testFuzz_signedExecutionPreservesOneOrderOnePayerAcrossBothDirections(bool zeroForOne, uint64 rawAmount)
        public
    {
        uint128 amountOut = uint128(bound(uint256(rawAmount), 1e6, 90 ether));
        bytes memory callData;
        FirstlessRouter.CreditOrder memory order = _plainOrder(payerA, zeroForOne, amountOut, payerA, callData);
        Currency output = zeroForOne ? currency1 : currency0;
        uint256 outputBefore = output.balanceOf(payerA);

        signedRouter.execute(key, order, _sign(PAYER_A_KEY, order), callData);

        assertEq(output.balanceOf(payerA), outputBefore + amountOut);
        assertEq(hook.nextOrderId(), 1);
        (address refundOwner,, uint128 storedOutput,, bool tokenOut0,) = hook.orders(0);
        assertEq(refundOwner, payerA);
        assertEq(storedOutput, amountOut);
        assertEq(tokenOut0, !zeroForOne);
        _assertAccounted();
    }

    function _plainOrder(address payer, bool zeroForOne, uint128 amountOut, address recipient, bytes memory callData)
        internal
        view
        returns (FirstlessRouter.CreditOrder memory order)
    {
        uint128 maximumInput = _maximum(!zeroForOne, amountOut);
        return _order(payer, recipient, address(0), zeroForOne, amountOut, maximumInput, callData);
    }

    function _maximum(bool tokenOut0, uint128 amountOut) internal view returns (uint128) {
        return uint128(hook.requiredMaximumInput(tokenOut0, amountOut));
    }

    function _order(
        address payer,
        address recipient,
        address callTarget,
        bool zeroForOne,
        uint128 amountOut,
        uint128 maximumInput,
        bytes memory callData
    ) internal view returns (FirstlessRouter.CreditOrder memory order) {
        order = FirstlessRouter.CreditOrder({
            poolId: key.toId(),
            payer: payer,
            recipient: recipient,
            callTarget: callTarget,
            callDataHash: keccak256(callData),
            zeroForOne: zeroForOne,
            amountOut: amountOut,
            maximumInput: maximumInput,
            validAfter: uint64(block.number),
            validBefore: uint64(block.number),
            nonce: signedRouter.nonces(payer),
            deadline: block.timestamp + 1 days
        });
    }

    function _sign(uint256 privateKey, FirstlessRouter.CreditOrder memory order)
        internal
        view
        returns (bytes memory signature)
    {
        bytes32 digest = signedRouter.hashOrder(order);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        return abi.encodePacked(r, s, v);
    }

    function _fundAndApprove(address payer) internal {
        ERC20(Currency.unwrap(currency0)).transfer(payer, 1000 ether);
        ERC20(Currency.unwrap(currency1)).transfer(payer, 1000 ether);
        vm.startPrank(payer);
        ERC20(Currency.unwrap(currency0)).approve(address(signedRouter), type(uint256).max);
        ERC20(Currency.unwrap(currency1)).approve(address(signedRouter), type(uint256).max);
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

    function _assertAccounted() internal view {
        (uint256 amount0, uint256 amount1) = hook.accountedMarginalClaims();
        assertEq(manager.balanceOf(address(hook), currency0.toId()), amount0, "token0 claims");
        assertEq(manager.balanceOf(address(hook), currency1.toId()), amount1, "token1 claims");
    }
}
