// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {BaseCustomAccounting} from "ozhooks/base/BaseCustomAccounting.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {HookTest} from "oztest/utils/HookTest.sol";
import {ClearingCreditEpoch} from "firstless/core/ClearingCreditEpoch.sol";
import {MarginalClearingEpoch} from "firstless/core/MarginalClearingEpoch.sol";
import {FirstlessHook} from "firstless/hooks/FirstlessHook.sol";
import {FirstlessRefundRedeemer} from "firstless/periphery/FirstlessRefundRedeemer.sol";
import {FirstlessRouter} from "firstless/periphery/FirstlessRouter.sol";

// ── Hostile token mocks ────────────────────────────────────────────────────────
contract FeeOnTransferMock is ERC20 {
    uint256 public feeBps = 100; // 1%

    constructor() ERC20("FeeOnTransfer", "FOT") {}

    function mint(address to, uint256 amt) external {
        _mint(to, amt);
    }

    function transfer(address to, uint256 amt) public override returns (bool) {
        uint256 fee = amt * feeBps / 10000;
        super.transfer(to, amt - fee);
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) public override returns (bool) {
        uint256 fee = amt * feeBps / 10000;
        // take fee via burn
        super.transferFrom(from, to, amt - fee);
        // fee is kept as extra (simulates fee-on-transfer)
        return true;
    }
}

contract ReentrantCallTarget {
    FirstlessRouter public router;
    bool public attacked;

    constructor(FirstlessRouter r) {
        router = r;
    }

    function attack(PoolKey calldata key, FirstlessRouter.CreditOrder calldata order, bytes calldata sig) external {
        if (attacked) return;
        attacked = true;
        router.execute(key, order, sig, bytes(""));
    }
}

// ── Extended surfaces 5-16 ───────────────────────────────────────────────────
contract SecurityMatrixExtendedTest is HookTest {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;

    uint256 constant PAYER_KEY = 0xA11CE;
    uint256 constant MAX_DEADLINE = 12_329_839_823;
    int24 constant MIN_TICK = -887220;
    int24 constant MAX_TICK = 887220;

    FirstlessHook firstlessHook;
    FirstlessRouter router;
    FirstlessRefundRedeemer redeemer;
    MarginalClearingEpoch marginalHook;
    address payer;

    function setUp() public {
        vm.chainId(11_155_111);
        vm.roll(1000);
        deployFreshManagerAndRouters();
        router = new FirstlessRouter(manager);
        redeemer = new FirstlessRefundRedeemer(manager);
        // FirstlessHook (judged)
        firstlessHook = FirstlessHook(
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
            abi.encode(address(manager), 997, 1000, 1000, address(router), address(this)),
            address(firstlessHook)
        );
        // Marginal hook for direct math tests
        marginalHook = MarginalClearingEpoch(
            payable(
                address(
                    uint160(
                        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
                            | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                    ) | uint160(1 << 80)
                )
            )
        );
        deployCodeTo(
            "src/core/MarginalClearingEpoch.sol:MarginalClearingEpoch",
            abi.encode(address(manager), 997, 1000, 1000, address(this)),
            address(marginalHook)
        );

        deployMintAndApprove2Currencies();
        (key,) = initPool(
            currency0, currency1, IHooks(address(firstlessHook)), LPFeeLibrary.DYNAMIC_FEE_FLAG, SQRT_PRICE_1_1
        );
        ERC20(Currency.unwrap(currency0)).approve(address(firstlessHook), type(uint256).max);
        ERC20(Currency.unwrap(currency1)).approve(address(firstlessHook), type(uint256).max);
        firstlessHook.addLiquidity(_addParams(1000 ether, 1000 ether));

        // Init marginal pool with same currencies but different hook
        PoolKey memory mKey;
        (mKey,) =
            initPool(currency0, currency1, IHooks(address(marginalHook)), LPFeeLibrary.DYNAMIC_FEE_FLAG, SQRT_PRICE_1_1);
        ERC20(Currency.unwrap(currency0)).approve(address(marginalHook), type(uint256).max);
        ERC20(Currency.unwrap(currency1)).approve(address(marginalHook), type(uint256).max);
        marginalHook.addLiquidity(_addParams(1000 ether, 1000 ether));

        payer = vm.addr(PAYER_KEY);
        _fundAndApprove(payer);
    }

    // ── 5. Router execution ────────────────────────────────────────────────────
    function test_permissionlessRelayerCannotChangeSignedPayerOrRecipient() public {
        address relayer = makeAddr("relayer");
        _fundAndApprove(relayer);
        bytes memory callData;
        FirstlessRouter.CreditOrder memory order =
            _order(payer, payer, address(0), true, 10 ether, _max(true, 10 ether), callData);
        bytes memory sig = _sign(order);
        uint256 payerInputBefore = ERC20(Currency.unwrap(currency0)).balanceOf(payer);
        uint256 payerOutputBefore = ERC20(Currency.unwrap(currency1)).balanceOf(payer);
        uint256 relayerInputBefore = ERC20(Currency.unwrap(currency0)).balanceOf(relayer);
        vm.prank(relayer);
        router.execute(key, order, sig, callData);
        assertLt(ERC20(Currency.unwrap(currency0)).balanceOf(payer), payerInputBefore);
        assertEq(ERC20(Currency.unwrap(currency1)).balanceOf(payer), payerOutputBefore + 10 ether);
        assertEq(ERC20(Currency.unwrap(currency0)).balanceOf(relayer), relayerInputBefore);
    }

    function test_routerInvalidCallbackDataReverts() public {
        bytes memory callData = hex"deadbeef";
        FirstlessRouter.CreditOrder memory order =
            _order(payer, payer, address(0x1234), true, 10 ether, _max(true, 10 ether), callData);
        // callDataHash is for deadbeef, but we pass different callData
        bytes memory sig = _sign(order);
        vm.expectRevert(FirstlessRouter.InvalidCallPlan.selector);
        router.execute(key, order, sig, hex"cafebeef");
    }

    function test_routerBadCallPlanTargetRevertsAtomically() public {
        // A downstream revert must roll back the order and nonce atomically.
        address reverting = address(new RevertingTarget());
        bytes memory c2 = abi.encodeWithSelector(RevertingTarget.fail.selector);
        FirstlessRouter.CreditOrder memory order =
            _order(payer, payer, reverting, true, 10 ether, _max(true, 10 ether), c2);
        bytes memory sig = _sign(order);
        uint256 nonceBefore = router.nonces(payer);
        bytes memory reason = abi.encodeWithSignature("Error(string)", "fail");
        vm.expectRevert(abi.encodeWithSelector(FirstlessRouter.DownstreamCallFailed.selector, reason));
        router.execute(key, order, sig, c2);
        assertEq(router.nonces(payer), nonceBefore, "nonce not consumed on downstream revert");
        assertEq(firstlessHook.nextOrderId(), 0, "no order created on downstream revert");
    }

    // ── 6. PoolManager callbacks ───────────────────────────────────────────────
    function test_unauthorizedUnlockCallbackReverts() public {
        FirstlessRouter.CreditOrder memory order =
            _order(payer, payer, address(0), true, 1 ether, _max(true, 1 ether), bytes(""));
        vm.expectRevert(FirstlessRouter.OnlyPoolManager.selector);
        router.unlockCallback(abi.encode(FirstlessRouter.CallbackData(key, order)));
    }

    // ── 7. Refunds ─────────────────────────────────────────────────────────────
    function test_doubleRefundReverts() public {
        bytes memory callData;
        FirstlessRouter.CreditOrder memory order =
            _order(payer, payer, address(0), true, 10 ether, _max(true, 10 ether), callData);
        router.execute(key, order, _sign(order), callData);
        vm.roll(block.number + 10);
        firstlessHook.settleExpiredEpoch();
        vm.prank(payer);
        firstlessHook.claimRefund(0);
        vm.prank(payer);
        vm.expectRevert(ClearingCreditEpoch.AlreadyClaimed.selector);
        firstlessHook.claimRefund(0);
    }

    function test_unbackedRefundReverts() public {
        vm.prank(payer);
        vm.expectRevert(ClearingCreditEpoch.UnknownOrder.selector);
        firstlessHook.claimRefund(999);
    }

    function test_wrongRefundOwnerReverts() public {
        bytes memory callData;
        FirstlessRouter.CreditOrder memory order =
            _order(payer, payer, address(0), true, 10 ether, _max(true, 10 ether), callData);
        router.execute(key, order, _sign(order), callData);
        vm.roll(block.number + 10);
        firstlessHook.settleExpiredEpoch();
        address attacker2 = makeAddr("attackerRefund");
        vm.prank(attacker2);
        vm.expectRevert(ClearingCreditEpoch.InvalidRefundOwner.selector);
        firstlessHook.claimRefund(0);
    }

    function test_refundZeroRecipientRevertsInRedeemer() public {
        bytes memory callData;
        FirstlessRouter.CreditOrder memory order =
            _order(payer, payer, address(0), true, 10 ether, _max(true, 10 ether), callData);
        router.execute(key, order, _sign(order), callData);
        vm.roll(block.number + 10);
        firstlessHook.settleExpiredEpoch();
        vm.prank(payer);
        uint256 refund = firstlessHook.claimRefund(0);
        // Try to redeem to zero address via redeemer
        vm.prank(payer);
        manager.setOperator(address(redeemer), true);
        vm.prank(payer);
        vm.expectRevert(FirstlessRefundRedeemer.InvalidRecipient.selector);
        redeemer.redeem(Currency.wrap(Currency.unwrap(currency0)), refund, address(0));
    }

    function test_operatorAbuseCannotStealRefund() public {
        bytes memory callData;
        FirstlessRouter.CreditOrder memory order =
            _order(payer, payer, address(0), true, 10 ether, _max(true, 10 ether), callData);
        router.execute(key, order, _sign(order), callData);
        vm.roll(block.number + 10);
        firstlessHook.settleExpiredEpoch();
        // Attacker tries to claim without being owner, even with operator approval
        address attacker3 = makeAddr("attacker3");
        vm.prank(attacker3);
        manager.setOperator(address(redeemer), true);
        vm.prank(payer);
        uint256 refund = firstlessHook.claimRefund(0);
        // Refund is now a claim in PoolManager for payer
        assertEq(manager.balanceOf(payer, Currency.wrap(Currency.unwrap(currency0)).toId()), refund);
        // Attacker tries to redeem payer's claim
        vm.prank(attacker3);
        vm.expectRevert(); // Should revert because claim is owned by payer, not attacker
        redeemer.redeem(Currency.wrap(Currency.unwrap(currency0)), refund, attacker3);
    }

    // ── 8. LP accounting ───────────────────────────────────────────────────────
    function test_firstLPCannotBeZero() public {
        // Try to seed with zero amount
        vm.expectRevert();
        firstlessHook.addLiquidity(_addParams(0, 1000 ether));
    }

    function test_lastLPWithdrawalPreservesLiabilities() public {
        // Place an order, settle, then withdraw all LP, ensure refund liability still backed
        bytes memory callData;
        FirstlessRouter.CreditOrder memory order =
            _order(payer, payer, address(0), true, 10 ether, _max(true, 10 ether), callData);
        router.execute(key, order, _sign(order), callData);
        vm.roll(block.number + 10);
        firstlessHook.settleExpiredEpoch();
        uint256 liabilityBefore = firstlessHook.refundLiability0();
        assertGt(liabilityBefore, 0);
        uint256 shares = firstlessHook.balanceOf(address(this));
        firstlessHook.removeLiquidity(_removeParams(shares));
        assertEq(firstlessHook.refundLiability0(), liabilityBefore, "liability not consumed by LP exit");
        (uint256 a0, uint256 a1) = firstlessHook.accountedMarginalClaims();
        assertEq(manager.balanceOf(address(firstlessHook), Currency.wrap(Currency.unwrap(currency0)).toId()), a0);
        assertEq(manager.balanceOf(address(firstlessHook), Currency.wrap(Currency.unwrap(currency1)).toId()), a1);
    }

    function test_shareRoundingCannotBeExploited() public {
        // A one-wei proportional deposit may mint at most one share after maturity.
        address tiny = makeAddr("tiny");
        _fundAndApprove(tiny);
        // Give tiny some tokens
        ERC20(Currency.unwrap(currency0)).transfer(tiny, 10 ether);
        ERC20(Currency.unwrap(currency1)).transfer(tiny, 10 ether);
        vm.startPrank(tiny);
        ERC20(Currency.unwrap(currency0)).approve(address(firstlessHook), type(uint256).max);
        ERC20(Currency.unwrap(currency1)).approve(address(firstlessHook), type(uint256).max);
        firstlessHook.addLiquidity(_addParams(1, 1));
        vm.stopPrank();
        uint256 depositId = firstlessHook.nextDepositId() - 1;
        vm.roll(block.number + 1);
        vm.prank(tiny);
        (uint256 shares,,) = firstlessHook.activatePendingLiquidity(depositId, 1);
        assertEq(shares, 1, "one wei of proportional equity mints one share");
    }

    function test_dormantLiquidityNotUsedInCurve() public {
        address newLP = makeAddr("newLP2");
        _fundAndApprove(newLP);
        ERC20(Currency.unwrap(currency0)).transfer(newLP, 100 ether);
        ERC20(Currency.unwrap(currency1)).transfer(newLP, 100 ether);
        vm.startPrank(newLP);
        ERC20(Currency.unwrap(currency0)).approve(address(firstlessHook), type(uint256).max);
        ERC20(Currency.unwrap(currency1)).approve(address(firstlessHook), type(uint256).max);
        firstlessHook.addLiquidity(_addParams(100 ether, 100 ether));
        vm.stopPrank();
        assertEq(firstlessHook.balanceOf(newLP), 0, "pending not active");
        assertEq(firstlessHook.pendingDeposit0(), 100 ether, "pending recorded");
        // Place order, should use only active reserves (1000 ether), not pending (100 ether)
        bytes memory callData;
        FirstlessRouter.CreditOrder memory order =
            _order(payer, payer, address(0), true, 10 ether, _max(true, 10 ether), callData);
        router.execute(key, order, _sign(order), callData);
        vm.roll(block.number + 10);
        firstlessHook.settleExpiredEpoch();
        // Pending should still be pending, not active, so reserve increase should be only from swap, not +100
        assertEq(firstlessHook.pendingDeposit0(), 100 ether, "pending still not active");
        assertEq(firstlessHook.balanceOf(newLP), 0, "still no shares");
    }

    // ── 9. Solvency invariants ─────────────────────────────────────────────────
    function test_solvencyAssetsCoverLiabilities() public {
        // Invariant: manager claims >= logicalReserve + feeBucket + refundLiability + escrow + pending
        (uint256 a0, uint256 a1) = firstlessHook.accountedMarginalClaims();
        assertEq(manager.balanceOf(address(firstlessHook), Currency.wrap(Currency.unwrap(currency0)).toId()), a0);
        assertEq(manager.balanceOf(address(firstlessHook), Currency.wrap(Currency.unwrap(currency1)).toId()), a1);
        // Also check after random ops
        bytes memory callData;
        FirstlessRouter.CreditOrder memory order =
            _order(payer, payer, address(0), true, 20 ether, _max(true, 20 ether), callData);
        router.execute(key, order, _sign(order), callData);
        (uint256 b0, uint256 b1) = firstlessHook.accountedMarginalClaims();
        assertEq(manager.balanceOf(address(firstlessHook), Currency.wrap(Currency.unwrap(currency0)).toId()), b0);
        assertEq(manager.balanceOf(address(firstlessHook), Currency.wrap(Currency.unwrap(currency1)).toId()), b1);
    }

    function test_unlockLeavesNoDelta() public {
        // Every unlock via router should end with zero delta (settled)
        bytes memory callData;
        FirstlessRouter.CreditOrder memory order =
            _order(payer, payer, address(0), true, 5 ether, _max(true, 5 ether), callData);
        uint256 balBefore = ERC20(Currency.unwrap(currency1)).balanceOf(payer);
        router.execute(key, order, _sign(order), callData);
        assertEq(
            ERC20(Currency.unwrap(currency1)).balanceOf(payer), balBefore + 5 ether, "output delivered, delta settled"
        );
    }

    // ── 11. Epoch timing ───────────────────────────────────────────────────────
    function test_sameBlockMultipleOrdersSameEpoch() public {
        bytes memory c1;
        bytes memory c2;
        FirstlessRouter.CreditOrder memory o1 =
            _order(payer, payer, address(0), true, 10 ether, _max(true, 10 ether), c1);
        FirstlessRouter.CreditOrder memory o2 =
            _order(payer, payer, address(0), true, 10 ether, _max(true, 10 ether), c2);
        o2.nonce = 1;
        router.execute(key, o1, _sign(o1), c1);
        router.execute(key, o2, _sign(o2), c2);
        assertEq(firstlessHook.currentEpochId(), 1, "same block same epoch");
        (,,,,,,,, bool settled) = firstlessHook.settlements(1);
        assertFalse(settled, "not settled same block");
        vm.roll(block.number + 10);
        firstlessHook.settleExpiredEpoch();
        (,,,,,,,, bool settledAfter) = firstlessHook.settlements(1);
        assertTrue(settledAfter);
    }

    function test_earlySettlementReverts() public {
        bytes memory callData;
        FirstlessRouter.CreditOrder memory order =
            _order(payer, payer, address(0), true, 10 ether, _max(true, 10 ether), callData);
        router.execute(key, order, _sign(order), callData);
        vm.expectRevert(ClearingCreditEpoch.NoExpiredEpoch.selector);
        firstlessHook.settleExpiredEpoch();
    }

    function test_doubleSettlementReverts() public {
        bytes memory callData;
        FirstlessRouter.CreditOrder memory order =
            _order(payer, payer, address(0), true, 10 ether, _max(true, 10 ether), callData);
        router.execute(key, order, _sign(order), callData);
        vm.roll(block.number + 10);
        firstlessHook.settleExpiredEpoch();
        vm.expectRevert(ClearingCreditEpoch.NoExpiredEpoch.selector);
        firstlessHook.settleExpiredEpoch();
    }

    function test_skippedBlocksStillSettle() public {
        bytes memory callData;
        FirstlessRouter.CreditOrder memory order =
            _order(payer, payer, address(0), true, 10 ether, _max(true, 10 ether), callData);
        router.execute(key, order, _sign(order), callData);
        vm.roll(block.number + 100);
        firstlessHook.settleExpiredEpoch();
        (,,,,,,,, bool settled) = firstlessHook.settlements(1);
        assertTrue(settled);
    }

    // ── 12. Reentrancy/external calls ──────────────────────────────────────────
    function test_downstreamCompositionCanExecuteOnlyAnotherValidSignedOrder() public {
        ReentrantCallTarget target = new ReentrantCallTarget(router);
        // A callback can compose another order only when that order has its own valid signature and nonce.
        bytes memory empty;
        FirstlessRouter.CreditOrder memory second =
            _order(payer, payer, address(0), true, 5 ether, _max(true, 5 ether), empty);
        second.nonce = 1;
        bytes memory sig2 = _sign(second);
        bytes memory attackCall = abi.encodeWithSelector(target.attack.selector, key, second, sig2);
        FirstlessRouter.CreditOrder memory first =
            _order(payer, payer, address(target), true, 10 ether, _max(true, 10 ether), attackCall);
        router.execute(key, first, _sign(first), attackCall);
        assertTrue(target.attacked(), "composition target was called");
        assertEq(firstlessHook.nextOrderId(), 2, "second authorization creates a separate order");
    }

    function test_downstreamRevertRollsBack() public {
        address reverting = address(new RevertingTarget());
        bytes memory c = abi.encodeWithSelector(RevertingTarget.fail.selector);
        FirstlessRouter.CreditOrder memory order =
            _order(payer, payer, reverting, true, 10 ether, _max(true, 10 ether), c);
        uint256 nonceBefore = router.nonces(payer);
        bytes memory sig = _sign(order);
        bytes memory reason = abi.encodeWithSignature("Error(string)", "fail");
        vm.expectRevert(abi.encodeWithSelector(FirstlessRouter.DownstreamCallFailed.selector, reason));
        router.execute(key, order, sig, c);
        assertEq(router.nonces(payer), nonceBefore, "nonce not consumed on revert");
    }

    // ── 13. Hostile tokens ─────────────────────────────────────────────────────
    function test_feeOnTransferTokenRevertsSafely() public {
        FeeOnTransferMock fot = new FeeOnTransferMock();
        fot.mint(address(this), 10000 ether);
        fot.mint(payer, 10000 ether);
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
                | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
        );
        MarginalClearingEpoch h = MarginalClearingEpoch(payable(address(flags | uint160(0xF0 << 80))));
        deployCodeTo(
            "src/core/MarginalClearingEpoch.sol:MarginalClearingEpoch",
            abi.encode(address(manager), 997, 1000, 1000, address(this)),
            address(h)
        );
        Currency c0 = Currency.wrap(address(fot));
        Currency c1 = currency1;
        (Currency sorted0, Currency sorted1) = c0 < c1 ? (c0, c1) : (c1, c0);
        PoolKey memory k = PoolKey(sorted0, sorted1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(address(h)));
        manager.initialize(k, SQRT_PRICE_1_1);
        ERC20(Currency.unwrap(sorted0)).approve(address(h), type(uint256).max);
        ERC20(Currency.unwrap(sorted1)).approve(address(h), type(uint256).max);
        // FOT delivery shortfalls must never settle silently: seeding the book
        // with a fee-on-transfer token must revert atomically.
        vm.expectRevert();
        h.addLiquidity(
            BaseCustomAccounting.AddLiquidityParams(
                100 ether, 100 ether, 100 ether, 100 ether, MAX_DEADLINE, MIN_TICK, MAX_TICK, bytes32(0)
            )
        );
        assertFalse(h.bookSeeded(), "FOT seed did not settle");
    }

    function test_nativeCurrencyPoolRejected() public {
        PoolKey memory nativeKey = PoolKey(
            Currency.wrap(address(0)), currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(address(firstlessHook))
        );
        vm.expectRevert();
        manager.initialize(nativeKey, SQRT_PRICE_1_1);
    }

    // ── 14. DoS ────────────────────────────────────────────────────────────────
    function test_maxOrderCountGas() public {
        // Fill the epoch all the way to its side cap, then bound settlement gas.
        uint256 cap = firstlessHook.logicalReserve0() * firstlessHook.capBps() / 10000;
        uint256 perOrder = 1 ether;
        uint256 count = cap / perOrder;
        assertGe(count, 90, "harness reserve gives a meaningful order count");
        assertLe(count, 1000, "order count stays in a realistic bounded range");
        for (uint256 i = 0; i < count; i++) {
            bytes memory c;
            FirstlessRouter.CreditOrder memory order =
                _order(payer, payer, address(0), true, uint128(perOrder), _max(true, uint128(perOrder)), c);
            order.nonce = router.nonces(payer);
            router.execute(key, order, _sign(order), c);
        }
        vm.roll(block.number + 10);
        uint256 gasBefore = gasleft();
        firstlessHook.settleExpiredEpoch();
        uint256 gasUsed = gasBefore - gasleft();
        assertLt(gasUsed, 5_000_000, "settlement gas bounded");
        // Claim every refund; each must be single-use and fully backed.
        for (uint256 i = 0; i < count; i++) {
            vm.prank(payer);
            firstlessHook.claimRefund(i);
        }
        assertEq(firstlessHook.refundLiability0(), 0, "all refunds claimed");
    }

    function test_storageGriefingViaLargeCallData() public {
        bytes memory largeCallData = new bytes(10000);
        for (uint256 i = 0; i < 10000; i++) {
            largeCallData[i] = 0xFF;
        }
        // callTarget 0 with non-empty callData must be rejected; the 10 kB blob
        // is only hashed, never stored, and the whole execution reverts
        // atomically (nonce included).
        uint256 nonceBefore = router.nonces(payer);
        uint256 ordersBefore = firstlessHook.nextOrderId();
        FirstlessRouter.CreditOrder memory order =
            _order(payer, payer, address(0), true, 10 ether, _max(true, 10 ether), largeCallData);
        bytes memory sig = _sign(order);
        vm.expectRevert(FirstlessRouter.InvalidCallPlan.selector);
        router.execute(key, order, sig, largeCallData);
        assertEq(router.nonces(payer), nonceBefore, "nonce not consumed on revert");
        assertEq(firstlessHook.nextOrderId(), ordersBefore, "hook storage untouched");
    }

    // ── 15. Deployment integrity ───────────────────────────────────────────────
    function test_hookPermissionBitsCorrect() public view {
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
                | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
        );
        assertEq(uint160(address(firstlessHook)) & flags, flags, "hook address encodes correct flags");
        assertEq(uint160(address(marginalHook)) & flags, flags, "marginal hook flags correct");
    }

    function test_bytecodeSizeBelowEIP170() public view {
        uint256 size;
        address hookAddr = address(firstlessHook);
        assembly {
            size := extcodesize(hookAddr)
        }
        assertLt(size, 24576, "hook bytecode below EIP-170 limit");
        assertGt(size, 5000, "hook bytecode not trivially small");
    }

    // ── 16. Frontend/wallet safety (simulated) ────────────────────────────────
    function test_wrongNetworkStaleDeploymentReverts() public {
        // Domain separator includes chainId, so signature from one chain should not be valid on another
        bytes memory callData;
        FirstlessRouter.CreditOrder memory order =
            _order(payer, payer, address(0), true, 10 ether, _max(true, 10 ether), callData);
        bytes memory sigSepolia = _sign(order);
        bytes32 hashSepolia = router.hashOrder(order);
        vm.chainId(1);
        bytes32 hashMainnet = router.hashOrder(order);
        assertTrue(hashSepolia != hashMainnet, "domain separator changes with chainId");
        vm.expectRevert(FirstlessRouter.InvalidSignature.selector);
        router.execute(key, order, sigSepolia, callData);
        vm.chainId(11_155_111);
    }

    function test_duplicateSubmissionSameNonceReverts() public {
        bytes memory callData;
        FirstlessRouter.CreditOrder memory order =
            _order(payer, payer, address(0), true, 10 ether, _max(true, 10 ether), callData);
        bytes memory sig = _sign(order);
        router.execute(key, order, sig, callData);
        vm.expectRevert(FirstlessRouter.InvalidNonce.selector);
        router.execute(key, order, sig, callData);
    }

    // ── Helpers ────────────────────────────────────────────────────────────────
    function _order(
        address payer_,
        address recipient,
        address target,
        bool zeroForOne,
        uint128 amt,
        uint128 max,
        bytes memory data
    ) internal view returns (FirstlessRouter.CreditOrder memory o) {
        o = FirstlessRouter.CreditOrder({
            poolId: key.toId(),
            payer: payer_,
            recipient: recipient,
            callTarget: target,
            callDataHash: keccak256(data),
            zeroForOne: zeroForOne,
            amountOut: amt,
            maximumInput: max,
            validAfter: uint64(block.number),
            validBefore: uint64(block.number),
            nonce: router.nonces(payer_),
            deadline: block.timestamp + 1 days
        });
    }

    function _max(bool tokenOut0, uint128 amt) internal view returns (uint128) {
        return uint128(firstlessHook.requiredMaximumInput(tokenOut0, amt));
    }

    function _sign(FirstlessRouter.CreditOrder memory o) internal view returns (bytes memory s) {
        bytes32 digest = router.hashOrder(o);
        (uint8 v, bytes32 r, bytes32 s2) = vm.sign(PAYER_KEY, digest);
        s = abi.encodePacked(r, s2, v);
    }

    function _fundAndApprove(address who) internal {
        ERC20(Currency.unwrap(currency0)).transfer(who, 1000 ether);
        ERC20(Currency.unwrap(currency1)).transfer(who, 1000 ether);
        vm.startPrank(who);
        ERC20(Currency.unwrap(currency0)).approve(address(router), type(uint256).max);
        ERC20(Currency.unwrap(currency1)).approve(address(router), type(uint256).max);
        vm.stopPrank();
    }

    function _addParams(uint256 a0, uint256 a1)
        internal
        pure
        returns (BaseCustomAccounting.AddLiquidityParams memory)
    {
        return BaseCustomAccounting.AddLiquidityParams(a0, a1, a0, a1, MAX_DEADLINE, MIN_TICK, MAX_TICK, bytes32(0));
    }

    function _removeParams(uint256 s) internal pure returns (BaseCustomAccounting.RemoveLiquidityParams memory) {
        return BaseCustomAccounting.RemoveLiquidityParams(s, 0, 0, MAX_DEADLINE, MIN_TICK, MAX_TICK, bytes32(0));
    }
}

contract RevertingTarget {
    function fail() external pure {
        revert("fail");
    }
}
