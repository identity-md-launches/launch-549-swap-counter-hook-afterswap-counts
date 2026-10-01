// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";
import {SwapCounterHook} from "../src/SwapCounterHook.sol";

/// @notice Read-only salt discovery. Pass the actual CREATE2 deployer and the target chain's manager.
/// @dev Does not broadcast, read environment variables, or hold keys. Compiler settings affect the salt.
contract FindHookSalt {
    function run(address deployer, IPoolManager manager) external view returns (address hook, bytes32 salt) {
        return HookMiner.find(
            deployer,
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG,
            type(SwapCounterHook).creationCode,
            abi.encode(manager)
        );
    }
}
