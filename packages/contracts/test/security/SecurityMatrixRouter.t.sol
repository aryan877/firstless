// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {BaseCustomAccounting} from "ozhooks/base/BaseCustomAccounting.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {HookTest} from "oztest/utils/HookTest.sol";
import {AuthenticatedMarginalClearingEpoch} from "firstless/hooks/AuthenticatedMarginalClearingEpoch.sol";
import {FirstlessHook} from "firstless/hooks/FirstlessHook.sol";
import {FirstlessRefundRedeemer} from "firstless/periphery/FirstlessRefundRedeemer.sol";
import {FirstlessRouter} from "firstless/periphery/FirstlessRouter.sol";

// ── EIP-1271 mock wallets ──────────────────────────────────────────────────────

contract EIP1271WalletValid {
    bytes4 constant MAGIC = 0x1626ba7e;
    address public owner;

    constructor(address _owner) {
        owner = _owner;
    }

    function isValidSignature(bytes32, bytes memory) external pure returns (bytes4) {
        return MAGIC;
    }
}

contract EIP1271WalletInvalid {
    function isValidSignature(bytes32, bytes memory) external pure returns (bytes4) {
        return 0xffffffff;
    }
}

contract EIP1271WalletRevert {
    function isValidSignature(bytes32, bytes memory) external pure returns (bytes4) {
        revert("eip1271 revert");
    }
}

/// @notice Section 3 — Signed-order security. Every test uses the judged FirstlessHook
/// (AuthenticatedMarginalClearingEpoch + block-number clock) and the FirstlessRouter.
contract SecurityMatrixRouterTest is HookTest {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;

    uint256 constant PAYER_A_KEY = 0xA11CE;
    uint256 constant PAYER_B_KEY = 0xB0B;
    uint256 constant ATTACKER_KEY = 0xDEAD;
    uint256 constant MAX_DEADLINE = 12_329_839_823;
    int24 constant MIN_TICK = -887220;
    int24 constant MAX_TICK = 887220;

    FirstlessHook hook;
    FirstlessRouter router;
    FirstlessRefundRedeemer redeemer;
    address payerA;
    address payerB;
    address attacker;

    function setUp() public {
        vm.chainId(11_155_111);
        vm.roll(100);
        deployFreshManagerAndRouters();
        router = new FirstlessRouter(manager);
        redeemer = new FirstlessRefundRedeemer(manager);
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
            abi.encode(address(manager), 997, 1000, 1000, address(router), address(this)),
            address(hook)
        );
        deployMintAndApprove2Currencies();
        (key,) = initPool(currency0, currency1, IHooks(address(hook)), LPFeeLibrary.DYNAMIC_FEE_FLAG, SQRT_PRICE_1_1);
        ERC20(Currency.unwrap(currency0)).approve(address(hook), type(uint256).max);
        ERC20(Currency.unwrap(currency1)).approve(address(hook), type(uint256).max);
        hook.addLiquidity(_addParams(1000 ether, 1000 ether));
        payerA = vm.addr(PAYER_A_KEY);
        payerB = vm.addr(PAYER_B_KEY);
        attacker = vm.addr(ATTACKER_KEY);
        _fundAndApprove(payerA);
        _fundAndApprove(payerB);
        _fundAndApprove(attacker);
    }

    // ── Reusing same signature ─────────────────────────────────────────────────

    function test_replaySameSignatureReverts() public {
        bytes memory callData;
        FirstlessRouter.CreditOrder memory order = _plainOrder(payerA, true, 10 ether, payerA, callData);
        bytes memory sig = _sign(PAYER_A_KEY, order);
        router.execute(key, order, sig, callData);
        vm.expectRevert(FirstlessRouter.InvalidNonce.selector);
        router.execute(key, order, sig, callData);
    }

    function test_replayAfterOneValidStillFails() public {
        bytes memory callData;
        FirstlessRouter.CreditOrder memory o1 = _plainOrder(payerA, true, 10 ether, payerA, callData);
        FirstlessRouter.CreditOrder memory o2 = _plainOrder(payerA, true, 11 ether, payerA, callData);
        o2.nonce = 1;
        bytes memory s1 = _sign(PAYER_A_KEY, o1);
        bytes memory s2 = _sign(PAYER_A_KEY, o2);
        router.execute(key, o1, s1, callData);
        router.execute(key, o2, s2, callData);
        // Replay o1 again — nonce 0 already consumed
        vm.expectRevert(FirstlessRouter.InvalidNonce.selector);
        router.execute(key, o1, s1, callData);
    }

    // ── Cross-chain replay ─────────────────────────────────────────────────────

    function test_crossChainReplayRejectedByDomainSeparator() public {
        bytes memory callData;
        FirstlessRouter.CreditOrder memory order = _plainOrder(payerA, true, 10 ether, payerA, callData);
        bytes memory sig = _sign(PAYER_A_KEY, order);
        // Execute on correct chain succeeds
        router.execute(key, order, sig, callData);
        // Now simulating same signature on a different chainId: domain separator includes chainId, so hash differs.
        // Deploy a second router on a different chainId and try to replay.
        vm.chainId(1);
        FirstlessRouter routerL1 = new FirstlessRouter(manager);
        // Need a hook trusted to routerL1 — but even without, the signature check itself should fail before hook.
        // Use same order struct (payer, etc) but routerL1's hashOrder will be different (different verifying contract + chainId).
        vm.expectRevert(FirstlessRouter.InvalidSignature.selector);
        routerL1.execute(key, order, sig, callData);
        vm.chainId(11_155_111);
    }

    // ── Replay against another router or hook ──────────────────────────────────

    function test_replayAgainstAnotherRouterRejected() public {
        bytes memory callData;
        FirstlessRouter.CreditOrder memory order = _plainOrder(payerA, true, 10 ether, payerA, callData);
        bytes memory sig = _sign(PAYER_A_KEY, order);
        FirstlessRouter router2 = new FirstlessRouter(manager);
        // Order was signed for router's domain (verifying contract = router address). router2 has different address.
        vm.expectRevert(FirstlessRouter.InvalidSignature.selector);
        router2.execute(key, order, sig, callData);
        // Original router still works with original sig for that order hasn't been consumed on router (router2 didn't consume)
        router.execute(key, order, sig, callData);
    }

    function test_wrongPoolRejected() public {
        bytes memory callData;
        FirstlessRouter.CreditOrder memory order = _plainOrder(payerA, true, 10 ether, payerA, callData);
        bytes memory sig = _sign(PAYER_A_KEY, order);
        // Construct a fake key with different hook (poolId mismatch) without initializing a second pool
        PoolKey memory fakeKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: key.fee,
            tickSpacing: key.tickSpacing,
            hooks: IHooks(address(0x1234567890123456789012345678901234567890))
        });
        vm.expectRevert(FirstlessRouter.InvalidPool.selector);
        router.execute(fakeKey, order, sig, callData);
        // Also test with same currencies but order's poolId is for key, key2 is for different hook
        // The router should reject poolId mismatch before any hook call
    }

    // ── Wrong fields ────────────────────────────────────────────────────────────

    function test_wrongPayerRejected() public {
        bytes memory callData;
        FirstlessRouter.CreditOrder memory order = _plainOrder(payerA, true, 10 ether, payerA, callData);
        bytes memory sig = _sign(PAYER_A_KEY, order);
        order.payer = payerB; // tamper payer but keep sig from A
        vm.expectRevert(FirstlessRouter.InvalidSignature.selector);
        router.execute(key, order, sig, callData);
    }

    function test_wrongRecipientRejected() public {
        bytes memory callData;
        FirstlessRouter.CreditOrder memory order = _plainOrder(payerA, true, 10 ether, payerA, callData);
        bytes memory sig = _sign(PAYER_A_KEY, order);
        order.recipient = payerB;
        vm.expectRevert(FirstlessRouter.InvalidSignature.selector);
        router.execute(key, order, sig, callData);
    }

    function test_wrongPoolIdRejected() public {
        bytes memory callData;
        // Now execute with key that doesn't match order.poolId
        FirstlessRouter.CreditOrder memory good = _plainOrder(payerA, true, 10 ether, payerA, callData);
        bytes memory goodSig = _sign(PAYER_A_KEY, good);
        good.poolId = PoolId.wrap(bytes32(uint256(0xdead)));
        vm.expectRevert(FirstlessRouter.InvalidPool.selector);
        router.execute(key, good, goodSig, callData);
        // Also tampering poolId after signing
        FirstlessRouter.CreditOrder memory tampered = _plainOrder(payerA, true, 10 ether, payerA, callData);
        bytes memory tamperedSig = _sign(PAYER_A_KEY, tampered);
        tampered.poolId = PoolId.wrap(bytes32(uint256(0xbeef)));
        vm.expectRevert();
        router.execute(key, tampered, tamperedSig, callData);
    }

    function test_wrongDirectionRejected() public {
        bytes memory callData;
        FirstlessRouter.CreditOrder memory order = _plainOrder(payerA, true, 10 ether, payerA, callData);
        bytes memory sig = _sign(PAYER_A_KEY, order);
        order.zeroForOne = !order.zeroForOne;
        vm.expectRevert(FirstlessRouter.InvalidSignature.selector);
        router.execute(key, order, sig, callData);
    }

    function test_wrongAmountRejected() public {
        bytes memory callData;
        FirstlessRouter.CreditOrder memory order = _plainOrder(payerA, true, 10 ether, payerA, callData);
        bytes memory sig = _sign(PAYER_A_KEY, order);
        order.amountOut += 1;
        vm.expectRevert(FirstlessRouter.InvalidSignature.selector);
        router.execute(key, order, sig, callData);
    }

    function test_wrongMaximumInputRejected() public {
        bytes memory callData;
        FirstlessRouter.CreditOrder memory o2 = _plainOrder(payerA, true, 10 ether, payerA, callData);
        bytes memory s2 = _sign(PAYER_A_KEY, o2);
        o2.maximumInput += 1;
        vm.expectRevert(FirstlessRouter.InvalidSignature.selector);
        router.execute(key, o2, s2, callData);
    }

    function test_wrongDeadlineRejected() public {
        bytes memory callData;
        FirstlessRouter.CreditOrder memory order = _plainOrder(payerA, true, 10 ether, payerA, callData);
        bytes memory sig = _sign(PAYER_A_KEY, order);
        order.deadline += 1;
        vm.expectRevert(FirstlessRouter.InvalidSignature.selector);
        router.execute(key, order, sig, callData);
    }

    function test_wrongNonceRejected() public {
        bytes memory callData;
        FirstlessRouter.CreditOrder memory order = _plainOrder(payerA, true, 10 ether, payerA, callData);
        order.nonce = 1; // next nonce is 0
        bytes memory sig = _sign(PAYER_A_KEY, order);
        vm.expectRevert(FirstlessRouter.InvalidNonce.selector);
        router.execute(key, order, sig, callData);
    }

    function test_wrongCallTargetAndDataHashRejected() public {
        bytes memory callData = abi.encodeWithSignature("consume(address,uint256)", payerA, 10 ether);
        bytes memory wrongCallData = abi.encodeWithSignature("consume(address,uint256)", payerB, 10 ether);
        FirstlessRouter.CreditOrder memory order =
            _order(payerA, payerA, address(0x1234), true, 10 ether, _max(true, 10 ether), callData);
        bytes memory sig = _sign(PAYER_A_KEY, order);
        // callData mismatch
        vm.expectRevert(FirstlessRouter.InvalidCallPlan.selector);
        router.execute(key, order, sig, wrongCallData);
        // callTarget mismatch via data hash tamper
        order.callTarget = address(0x5678);
        vm.expectRevert(FirstlessRouter.InvalidSignature.selector);
        router.execute(key, order, sig, callData);
    }

    // ── Expired, not-yet-valid, exact-boundary ──────────────────────────────────

    function test_expiredDeadlineReverts() public {
        bytes memory callData;
        FirstlessRouter.CreditOrder memory order = _plainOrder(payerA, true, 10 ether, payerA, callData);
        order.deadline = block.timestamp - 1;
        bytes memory sig = _sign(PAYER_A_KEY, order);
        vm.expectRevert(FirstlessRouter.OrderExpired.selector);
        router.execute(key, order, sig, callData);
    }

    function test_exactDeadlineBoundarySucceeds() public {
        bytes memory callData;
        FirstlessRouter.CreditOrder memory order = _plainOrder(payerA, true, 10 ether, payerA, callData);
        order.deadline = block.timestamp;
        bytes memory sig = _sign(PAYER_A_KEY, order);
        router.execute(key, order, sig, callData); // should succeed at exact boundary
        assertEq(hook.nextOrderId(), 1);
    }

    function test_notYetValidBlockWindowReverts() public {
        bytes memory callData;
        FirstlessRouter.CreditOrder memory order = _plainOrder(payerA, true, 10 ether, payerA, callData);
        order.validAfter = uint64(block.number + 1);
        order.validBefore = uint64(block.number + 2);
        bytes memory sig = _sign(PAYER_A_KEY, order);
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeSwap.selector,
                abi.encodeWithSelector(AuthenticatedMarginalClearingEpoch.InvalidClockWindow.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        router.execute(key, order, sig, callData);
    }

    function test_expiredBlockWindowReverts() public {
        bytes memory callData;
        FirstlessRouter.CreditOrder memory order = _plainOrder(payerA, true, 10 ether, payerA, callData);
        order.validAfter = uint64(block.number - 2);
        order.validBefore = uint64(block.number - 1);
        bytes memory sig = _sign(PAYER_A_KEY, order);
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeSwap.selector,
                abi.encodeWithSelector(AuthenticatedMarginalClearingEpoch.InvalidClockWindow.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        router.execute(key, order, sig, callData);
    }

    function test_exactBlockBoundarySucceeds() public {
        bytes memory callData;
        FirstlessRouter.CreditOrder memory order = _plainOrder(payerA, true, 10 ether, payerA, callData);
        order.validAfter = uint64(block.number);
        order.validBefore = uint64(block.number);
        bytes memory sig = _sign(PAYER_A_KEY, order);
        router.execute(key, order, sig, callData);
        assertEq(hook.nextOrderId(), 1);
    }

    function test_invalidClockWindowWhereAfterGreaterThanBeforeReverts() public {
        bytes memory callData;
        FirstlessRouter.CreditOrder memory order = _plainOrder(payerA, true, 10 ether, payerA, callData);
        order.validAfter = uint64(block.number + 2);
        order.validBefore = uint64(block.number + 1);
        bytes memory sig = _sign(PAYER_A_KEY, order);
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeSwap.selector,
                abi.encodeWithSelector(AuthenticatedMarginalClearingEpoch.InvalidClockWindow.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        router.execute(key, order, sig, callData);
    }

    // ── Signature malleability and malformed signatures ───────────────────────────

    function test_malformedSignatureShortReverts() public {
        bytes memory callData;
        FirstlessRouter.CreditOrder memory order = _plainOrder(payerA, true, 10 ether, payerA, callData);
        bytes memory badSig = hex"1234";
        vm.expectRevert(FirstlessRouter.InvalidSignature.selector);
        router.execute(key, order, badSig, callData);
    }

    function test_malformedSignatureEmptyReverts() public {
        bytes memory callData;
        FirstlessRouter.CreditOrder memory order = _plainOrder(payerA, true, 10 ether, payerA, callData);
        vm.expectRevert(FirstlessRouter.InvalidSignature.selector);
        router.execute(key, order, hex"", callData);
    }

    function test_malleableSValueRejected() public {
        // ECDSA malleability: s > n/2 should be rejected by OpenZeppelin ECDSA
        bytes memory callData;
        FirstlessRouter.CreditOrder memory order = _plainOrder(payerA, true, 10 ether, payerA, callData);
        bytes32 digest = router.hashOrder(order);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(PAYER_A_KEY, digest);
        // s malleability: s' = n - s, v' = 27/28 flipped
        uint256 n = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
        bytes32 sMalleable = bytes32(n - uint256(s));
        uint8 vMalleable = v == 27 ? 28 : 27;
        bytes memory malleableSig = abi.encodePacked(r, sMalleable, vMalleable);
        vm.expectRevert(FirstlessRouter.InvalidSignature.selector);
        router.execute(key, order, malleableSig, callData);
    }

    function test_wrongSignerRejected() public {
        bytes memory callData;
        FirstlessRouter.CreditOrder memory order = _plainOrder(payerA, true, 10 ether, payerA, callData);
        bytes memory sigFromB = _sign(PAYER_B_KEY, order); // signed by B but payer is A
        vm.expectRevert(FirstlessRouter.InvalidSignature.selector);
        router.execute(key, order, sigFromB, callData);
    }

    // ── Zero addresses and invalid order fields ───────────────────────────────────

    function test_zeroPayerHasNoKnownSignerAndFails() public {
        bytes memory callData;
        FirstlessRouter.CreditOrder memory order = _plainOrder(payerA, true, 10 ether, payerA, callData);
        order.payer = address(0);
        // Need to sign with zero key? Can't. Just use payerA sig with zero payer field — should be invalidSig
        bytes memory sig = _sign(PAYER_A_KEY, order);
        vm.expectRevert(FirstlessRouter.InvalidSignature.selector);
        router.execute(key, order, sig, callData);
    }

    function test_zeroAmountOutRevertsAtHook() public {
        bytes memory callData;
        FirstlessRouter.CreditOrder memory order = FirstlessRouter.CreditOrder({
            poolId: key.toId(),
            payer: payerA,
            recipient: payerA,
            callTarget: address(0),
            callDataHash: keccak256(callData),
            zeroForOne: true,
            amountOut: 0,
            maximumInput: 0,
            validAfter: uint64(block.number),
            validBefore: uint64(block.number),
            nonce: router.nonces(payerA),
            deadline: block.timestamp + 1 days
        });
        bytes memory sig = _sign(PAYER_A_KEY, order);
        vm.expectRevert();
        router.execute(key, order, sig, callData);
    }

    function test_amountTooLargeReverts() public {
        bytes memory callData;
        uint128 overflowAmt = uint128(uint256(uint128(type(int128).max)) + 1);
        // Construct order manually to avoid _plainOrder's requiredMaximumInput revert
        FirstlessRouter.CreditOrder memory order = FirstlessRouter.CreditOrder({
            poolId: key.toId(),
            payer: payerA,
            recipient: payerA,
            callTarget: address(0),
            callDataHash: keccak256(callData),
            zeroForOne: true,
            amountOut: overflowAmt,
            maximumInput: overflowAmt,
            validAfter: uint64(block.number),
            validBefore: uint64(block.number),
            nonce: router.nonces(payerA),
            deadline: block.timestamp + 1 days
        });
        bytes memory sig = _sign(PAYER_A_KEY, order);
        vm.expectRevert();
        router.execute(key, order, sig, callData);
    }

    // ── Nonce cancellation and reuse ──────────────────────────────────────────────

    function test_nonceCancellationInvalidatesOldSignatures() public {
        bytes memory callData;
        FirstlessRouter.CreditOrder memory order = _plainOrder(payerA, true, 10 ether, payerA, callData);
        bytes memory sig = _sign(PAYER_A_KEY, order);
        vm.prank(payerA);
        router.invalidateNonce(5);
        assertEq(router.nonces(payerA), 5);
        vm.expectRevert(FirstlessRouter.InvalidNonce.selector);
        router.execute(key, order, sig, callData);
    }

    function test_nonceReuseAfterCancellationAlsoFails() public {
        bytes memory callData;
        FirstlessRouter.CreditOrder memory o0 = _plainOrder(payerA, true, 10 ether, payerA, callData);
        bytes memory s0 = _sign(PAYER_A_KEY, o0);
        vm.prank(payerA);
        router.invalidateNonce(1);
        // o0 nonce 0 < 1 -> invalid
        vm.expectRevert(FirstlessRouter.InvalidNonce.selector);
        router.execute(key, o0, s0, callData);
        // Correct nonce 1 should work
        FirstlessRouter.CreditOrder memory o1 = _plainOrder(payerA, true, 10 ether, payerA, callData);
        o1.nonce = 1;
        bytes memory s1 = _sign(PAYER_A_KEY, o1);
        router.execute(key, o1, s1, callData);
        assertEq(router.nonces(payerA), 2);
        // Replay o1
        vm.expectRevert(FirstlessRouter.InvalidNonce.selector);
        router.execute(key, o1, s1, callData);
    }

    function test_invalidateNonceMustIncrease() public {
        vm.prank(payerA);
        router.invalidateNonce(1);
        vm.prank(payerA);
        vm.expectRevert(FirstlessRouter.InvalidNonce.selector);
        router.invalidateNonce(1);
        vm.prank(payerA);
        vm.expectRevert(FirstlessRouter.InvalidNonce.selector);
        router.invalidateNonce(0);
    }

    // ── EIP-1271 behavior ─────────────────────────────────────────────────────────

    function test_eip1271ValidContractWalletSucceeds() public {
        EIP1271WalletValid wallet = new EIP1271WalletValid(payerA);
        // Fund wallet
        ERC20(Currency.unwrap(currency0)).transfer(address(wallet), 100 ether);
        ERC20(Currency.unwrap(currency1)).transfer(address(wallet), 100 ether);
        vm.startPrank(address(wallet));
        ERC20(Currency.unwrap(currency0)).approve(address(router), type(uint256).max);
        ERC20(Currency.unwrap(currency1)).approve(address(router), type(uint256).max);
        vm.stopPrank();
        bytes memory callData;
        FirstlessRouter.CreditOrder memory order =
            _plainOrder(address(wallet), true, 10 ether, address(wallet), callData);
        // Signature can be anything since wallet returns MAGIC; use empty
        bytes memory sig = hex"";
        // Should succeed because isValidSignature returns magic
        router.execute(key, order, sig, callData);
        assertEq(hook.nextOrderId(), 1);
        (address owner,,,,,) = hook.orders(0);
        assertEq(owner, address(wallet));
    }

    function test_eip1271InvalidContractWalletRejected() public {
        EIP1271WalletInvalid wallet = new EIP1271WalletInvalid();
        ERC20(Currency.unwrap(currency0)).transfer(address(wallet), 100 ether);
        ERC20(Currency.unwrap(currency1)).transfer(address(wallet), 100 ether);
        vm.startPrank(address(wallet));
        ERC20(Currency.unwrap(currency0)).approve(address(router), type(uint256).max);
        ERC20(Currency.unwrap(currency1)).approve(address(router), type(uint256).max);
        vm.stopPrank();
        bytes memory callData;
        FirstlessRouter.CreditOrder memory order =
            _plainOrder(address(wallet), true, 10 ether, address(wallet), callData);
        bytes memory sig = hex"1234";
        vm.expectRevert(FirstlessRouter.InvalidSignature.selector);
        router.execute(key, order, sig, callData);
    }

    function test_eip1271RevertingWalletRejected() public {
        EIP1271WalletRevert wallet = new EIP1271WalletRevert();
        ERC20(Currency.unwrap(currency0)).transfer(address(wallet), 100 ether);
        vm.startPrank(address(wallet));
        ERC20(Currency.unwrap(currency0)).approve(address(router), type(uint256).max);
        vm.stopPrank();
        bytes memory callData;
        FirstlessRouter.CreditOrder memory order =
            _plainOrder(address(wallet), true, 10 ether, address(wallet), callData);
        vm.expectRevert(FirstlessRouter.InvalidSignature.selector);
        router.execute(key, order, hex"", callData);
    }

    function test_eoaSignatureStillWorksAfterEIP1271Tests() public {
        bytes memory callData;
        FirstlessRouter.CreditOrder memory order = _plainOrder(payerA, true, 10 ether, payerA, callData);
        bytes memory sig = _sign(PAYER_A_KEY, order);
        router.execute(key, order, sig, callData);
        assertEq(hook.nextOrderId(), 1);
    }

    // ── Downstream call plan tampering already tested, but also zero-address cases ──

    function test_callTargetZeroWithNonEmptyCallDataReverts() public {
        bytes memory callData = hex"1234";
        FirstlessRouter.CreditOrder memory order =
            _order(payerA, payerA, address(0), true, 10 ether, _max(true, 10 ether), callData);
        // callDataHash matches, but router checks if callTarget==0 then callData must be empty
        bytes memory sig = _sign(PAYER_A_KEY, order);
        vm.expectRevert(FirstlessRouter.InvalidCallPlan.selector);
        router.execute(key, order, sig, callData);
    }

    function test_callTargetNonZeroWithEmptyCallDataSucceedsIfHashMatches() public {
        bytes memory callData = hex"";
        FirstlessRouter.CreditOrder memory order =
            _order(payerA, payerA, address(0x1234), true, 10 ether, _max(true, 10 ether), callData);
        bytes memory sig = _sign(PAYER_A_KEY, order);
        // callTarget !=0 but callData empty -> hash of empty, router will call target with empty data (may succeed if target has fallback)
        // Our 0x1234 is not a contract, call will succeed (no code) — but router checks callTarget !=0 then does call, which on EOA succeeds with empty return
        // This is technically allowed? Let's see — router does if (callTarget!=0) { success = callTarget.call(callData) } — empty call to EOA succeeds.
        router.execute(key, order, sig, callData);
        assertEq(hook.nextOrderId(), 1);
    }

    // ── Helpers ──────────────────────────────────────────────────────────────────

    function _plainOrder(address payer, bool zeroForOne, uint128 amountOut, address recipient, bytes memory callData)
        internal
        view
        returns (FirstlessRouter.CreditOrder memory order)
    {
        uint128 maximumInput = _max(!zeroForOne, amountOut);
        return _order(payer, recipient, address(0), zeroForOne, amountOut, maximumInput, callData);
    }

    function _max(bool tokenOut0, uint128 amountOut) internal view returns (uint128) {
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
            nonce: router.nonces(payer),
            deadline: block.timestamp + 1 days
        });
    }

    function _sign(uint256 pk, FirstlessRouter.CreditOrder memory order) internal view returns (bytes memory sig) {
        bytes32 digest = router.hashOrder(order);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        sig = abi.encodePacked(r, s, v);
    }

    function _fundAndApprove(address who) internal {
        ERC20(Currency.unwrap(currency0)).transfer(who, 1000 ether);
        ERC20(Currency.unwrap(currency1)).transfer(who, 1000 ether);
        vm.startPrank(who);
        ERC20(Currency.unwrap(currency0)).approve(address(router), type(uint256).max);
        ERC20(Currency.unwrap(currency1)).approve(address(router), type(uint256).max);
        ERC20(Currency.unwrap(currency0)).approve(address(hook), type(uint256).max);
        ERC20(Currency.unwrap(currency1)).approve(address(hook), type(uint256).max);
        vm.stopPrank();
    }

    function _addParams(uint256 a0, uint256 a1)
        internal
        pure
        returns (BaseCustomAccounting.AddLiquidityParams memory)
    {
        return BaseCustomAccounting.AddLiquidityParams(a0, a1, a0, a1, MAX_DEADLINE, MIN_TICK, MAX_TICK, bytes32(0));
    }
}
