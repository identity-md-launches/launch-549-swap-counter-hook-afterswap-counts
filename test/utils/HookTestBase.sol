// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {SwapCounterHook} from "../../src/SwapCounterHook.sol";

/// @dev Deploy the actual constructor at its required address, without overriding validation.
abstract contract HookTestBase is Test {
    function _deployHook(IPoolManager manager) internal returns (SwapCounterHook hook) {
        bytes memory creationCode = abi.encodePacked(type(SwapCounterHook).creationCode, abi.encode(manager));
        bytes32 initCodeHash = keccak256(creationCode);
        for (uint256 i; i < 200_000; ++i) {
            bytes32 salt = bytes32(i);
            address predicted =
                address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, initCodeHash)))));
            if (uint160(predicted) & uint160(0x3fff) != uint160(0x2040)) continue;
            address deployed;
            assembly ("memory-safe") {
                deployed := create2(0, add(creationCode, 0x20), mload(creationCode), salt)
            }
            require(deployed == predicted, "CREATE2 deployment failed");
            return SwapCounterHook(deployed);
        }
        revert("no compatible CREATE2 salt found");
    }
}
