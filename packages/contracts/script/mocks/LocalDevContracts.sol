// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Local-only faucet token used by the browser and integration smoke test.
/// @dev Never deploy this contract as a production asset.
contract FirstlessDevToken is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function faucet(address recipient, uint256 amount) external {
        _mint(recipient, amount);
    }
}
