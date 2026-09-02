// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title Firstless Sepolia Test Token
/// @notice A valueless ERC-20 used only to exercise the public Firstless test deployment.
contract FirstlessSepoliaToken is ERC20 {
    uint256 public constant FAUCET_AMOUNT = 1_000 ether;

    mapping(address account => bool claimed) public faucetClaimed;

    error FaucetAlreadyClaimed();

    constructor(string memory name_, string memory symbol_, address initialHolder, uint256 initialSupply)
        ERC20(name_, symbol_)
    {
        _mint(initialHolder, initialSupply);
    }

    /// @notice Gives one wallet a single allotment of valueless Sepolia test tokens.
    function faucet() external {
        if (faucetClaimed[msg.sender]) revert FaucetAlreadyClaimed();
        faucetClaimed[msg.sender] = true;
        _mint(msg.sender, FAUCET_AMOUNT);
    }
}
