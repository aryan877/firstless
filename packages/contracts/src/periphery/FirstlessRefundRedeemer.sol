// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {CurrencySettler} from "ozhooks/utils/CurrencySettler.sol";

/// @notice Converts backed PoolManager refund claims into the underlying currency.
contract FirstlessRefundRedeemer is IUnlockCallback {
    using CurrencyLibrary for Currency;
    using CurrencySettler for Currency;

    struct Redemption {
        address owner;
        address recipient;
        Currency currency;
        uint256 amount;
    }

    IPoolManager public immutable poolManager;

    error OnlyPoolManager();
    error InvalidRecipient();
    error ZeroAmount();

    event RefundRedeemed(address indexed owner, address indexed recipient, Currency indexed currency, uint256 amount);

    constructor(IPoolManager manager) {
        poolManager = manager;
    }

    /// @notice Redeems caller-owned ERC-6909 claims after one-time PoolManager operator approval.
    function redeem(Currency currency, uint256 amount, address recipient) external {
        if (recipient == address(0)) revert InvalidRecipient();
        if (amount == 0) revert ZeroAmount();
        // PoolManager reverts if burning the claim or transferring underlying fails; the callback returns empty bytes.
        // slither-disable-next-line unused-return
        poolManager.unlock(abi.encode(Redemption(msg.sender, recipient, currency, amount)));
        emit RefundRedeemed(msg.sender, recipient, currency, amount);
    }

    /// @notice Burns approved refund claims and releases the underlying token.
    function unlockCallback(bytes calldata rawData) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
        Redemption memory redemption = abi.decode(rawData, (Redemption));
        poolManager.burn(redemption.owner, redemption.currency.toId(), redemption.amount);
        redemption.currency.take(poolManager, redemption.recipient, redemption.amount, false);
        return bytes("");
    }
}
