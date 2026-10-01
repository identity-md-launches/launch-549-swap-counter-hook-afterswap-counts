// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";

/// @title Swap Counter
/// @notice Observes swaps across every pool using this hook, without changing swap accounting.
/// @dev `sender` is the address that called PoolManager.swap (usually a router), not its end user.
contract SwapCounterHook is BaseHook {
    using PoolIdLibrary for PoolKey;

    error InvalidPoolManager();

    /// @notice Number of successful swap callbacks attributed to each PoolManager sender.
    mapping(address sender => uint256 count) public swapCount;

    /// @notice Number of successful swap callbacks across all senders and pools using this hook.
    uint256 public totalSwaps;

    /// @notice Emitted once per swap callback, with the updated counts.
    event SwapCounted(address indexed sender, PoolId indexed poolId, uint256 senderCount, uint256 totalCount);

    /// @param manager The chain's trusted Uniswap v4 PoolManager; must already have deployed code.
    constructor(IPoolManager manager) BaseHook(manager) {
        if (address(manager).code.length == 0) revert InvalidPoolManager();
    }

    /// @notice Requires address permission bits 0x2040; all delta-return permissions are disabled.
    function getHookPermissions() public pure override returns (Hooks.Permissions memory permissions) {
        permissions.beforeInitialize = true;
        permissions.afterSwap = true;
    }

    /// @dev BaseHook permits only PoolManager. The initialization callback requires live hook code.
    function _beforeInitialize(address, PoolKey calldata, uint160) internal pure override returns (bytes4) {
        return IHooks.beforeInitialize.selector;
    }

    /// @dev BaseHook permits only PoolManager. No external calls, settlement, or fee updates occur.
    function _afterSwap(address sender, PoolKey calldata key, SwapParams calldata, BalanceDelta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        uint256 senderCount = ++swapCount[sender];
        uint256 totalCount = ++totalSwaps;
        emit SwapCounted(sender, key.toId(), senderCount, totalCount);
        return (IHooks.afterSwap.selector, 0);
    }
}
