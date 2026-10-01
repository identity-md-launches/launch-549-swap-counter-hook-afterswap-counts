// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Fixed-supply token for the Swap Counter launch.
/// @dev The deploying factory receives the entire supply. There are no administrative powers.
contract SwapCounterToken is ERC20 {
    constructor() ERC20("Swap Counter", "SWAPC") {
        _mint(msg.sender, 1_000_000_000 ether);
    }
}
