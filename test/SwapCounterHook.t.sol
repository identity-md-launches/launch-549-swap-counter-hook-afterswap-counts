// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookTestBase} from "./utils/HookTestBase.sol";
import {SwapCounterHook} from "../src/SwapCounterHook.sol";
import {FindHookSalt} from "../script/FindHookSalt.s.sol";
import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {ImmutableState} from "v4-periphery/src/base/ImmutableState.sol";
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";

contract SwapCounterHookTest is HookTestBase {
    using PoolIdLibrary for PoolKey;

    SwapCounterHook internal hook;
    IPoolManager internal manager;
    PoolKey internal key;

    event SwapCounted(address indexed sender, PoolId indexed poolId, uint256 senderCount, uint256 totalCount);

    function setUp() public {
        manager = IPoolManager(address(new PoolManager(address(this))));
        hook = _deployHook(manager);
        key = PoolKey(Currency.wrap(address(1)), Currency.wrap(address(2)), 3000, 60, hook);
    }

    function test_initialStateAndExactPermissions() public view {
        assertEq(address(hook.poolManager()), address(manager));
        assertEq(hook.totalSwaps(), 0);
        assertEq(hook.swapCount(address(this)), 0);
        Hooks.Permissions memory expected;
        expected.beforeInitialize = true;
        expected.afterSwap = true;
        assertEq(abi.encode(hook.getHookPermissions()), abi.encode(expected));
        assertEq(uint160(address(hook)) & Hooks.ALL_HOOK_MASK, 0x2040);
    }

    function test_initializationReturnsSelectorWithoutCounting() public {
        vm.prank(address(manager));
        assertEq(hook.beforeInitialize(address(this), key, uint160(1 << 96)), IHooks.beforeInitialize.selector);
        assertEq(hook.totalSwaps(), 0);
    }

    function test_countsSenderAndEmitsUpdatedCounts() public {
        address alice = address(0xA11CE);
        address bob = address(0xB0B);
        address[3] memory senders = [alice, bob, alice];
        for (uint256 i; i < senders.length; ++i) {
            vm.expectEmit(true, true, false, true, address(hook));
            emit SwapCounted(senders[i], key.toId(), i == 2 ? 2 : 1, i + 1);
            vm.prank(address(manager));
            (bytes4 selector, int128 delta) = hook.afterSwap(
                senders[i], key, SwapParams(true, -1 ether, uint160(1 << 95)), BalanceDelta.wrap(-1), hex"ff"
            );
            assertEq(selector, IHooks.afterSwap.selector);
            assertEq(delta, 0);
        }
        assertEq(hook.swapCount(alice), 2);
        assertEq(hook.swapCount(bob), 1);
        assertEq(hook.swapCount(address(manager)), 0);
        assertEq(hook.swapCount(address(this)), 0);
        assertEq(hook.totalSwaps(), 3);
    }

    function testFuzz_observationDoesNotDependOnSwapData(
        address sender,
        SwapParams calldata params,
        int256 packedDelta,
        bytes calldata hookData,
        uint8 calls
    ) public {
        uint256 count = bound(calls, 1, 32);
        for (uint256 i; i < count; ++i) {
            vm.prank(address(manager));
            (bytes4 selector, int128 delta) =
                hook.afterSwap(sender, key, params, BalanceDelta.wrap(packedDelta), hookData);
            assertEq(selector, IHooks.afterSwap.selector);
            assertEq(delta, 0);
        }
        assertEq(hook.swapCount(sender), count);
        assertEq(hook.totalSwaps(), count);
    }

    function testFuzz_allCallbacksRejectUnauthorizedCaller(address caller) public {
        vm.assume(caller != address(manager));
        bytes[] memory calls = _callbacks();
        for (uint256 i; i < calls.length; ++i) {
            vm.prank(caller);
            (bool success, bytes memory reason) = address(hook).call(calls[i]);
            assertFalse(success);
            assertEq(reason, abi.encodeWithSelector(ImmutableState.NotPoolManager.selector));
        }
        assertEq(hook.totalSwaps(), 0);
        assertEq(hook.swapCount(address(this)), 0);
    }

    function test_disabledCallbacksRejectEvenTheManager() public {
        bytes[] memory calls = _callbacks();
        for (uint256 i = 2; i < calls.length; ++i) {
            vm.prank(address(manager));
            (bool success, bytes memory reason) = address(hook).call(calls[i]);
            assertFalse(success);
            assertEq(reason, abi.encodeWithSelector(BaseHook.HookNotImplemented.selector));
        }
        assertEq(hook.totalSwaps(), 0);
    }

    function test_saltPreviewDeploysProductionBytecode() public {
        FindHookSalt finder = new FindHookSalt();
        (address predicted, bytes32 salt) = finder.run(address(this), manager);
        SwapCounterHook deployed = new SwapCounterHook{salt: salt}(manager);
        assertEq(address(deployed), predicted);
        assertEq(address(deployed.poolManager()), address(manager));
        assertEq(uint160(predicted) & Hooks.ALL_HOOK_MASK, 0x2040);
    }

    function test_constructorRejectsIncorrectPermissionBits() public {
        bytes memory initCode = abi.encodePacked(type(SwapCounterHook).creationCode, abi.encode(manager));
        uint256 salt;
        address predicted = HookMiner.computeAddress(address(this), salt, initCode);
        while ((uint160(predicted) & Hooks.ALL_HOOK_MASK) == 0x2040) {
            predicted = HookMiner.computeAddress(address(this), ++salt, initCode);
        }
        vm.expectRevert(abi.encodeWithSelector(Hooks.HookAddressNotValid.selector, predicted));
        new SwapCounterHook{salt: bytes32(salt)}(manager);
    }

    function test_constructorRejectsMissingManagerCode() public {
        address[2] memory invalidManagers = [address(0), address(0xBAD)];
        for (uint256 i; i < invalidManagers.length; ++i) {
            IPoolManager invalid = IPoolManager(invalidManagers[i]);
            (, bytes32 salt) =
                HookMiner.find(address(this), 0x2040, type(SwapCounterHook).creationCode, abi.encode(invalid));
            vm.expectRevert(SwapCounterHook.InvalidPoolManager.selector);
            new SwapCounterHook{salt: salt}(invalid);
        }
    }

    function test_runtimeHasNoEscapeHatch() public view {
        bytes memory code = address(hook).code;
        assertGt(code.length, 0);
        assertLe(code.length, 24_576);
        for (uint256 i; i < code.length; ++i) {
            uint8 opcode = uint8(code[i]);
            if (opcode >= 0x60 && opcode <= 0x7f) {
                i += opcode - 0x5f;
            } else {
                assertTrue(opcode != 0xff && opcode != 0xf4 && opcode != 0xf2);
            }
        }
    }

    function _callbacks() internal view returns (bytes[] memory calls) {
        calls = new bytes[](10);
        ModifyLiquidityParams memory liquidity = ModifyLiquidityParams(-60, 60, 1 ether, bytes32(0));
        SwapParams memory swap = SwapParams(true, -1 ether, uint160(1 << 95));
        BalanceDelta delta = BalanceDelta.wrap(0);
        calls[0] = abi.encodeCall(IHooks.beforeInitialize, (address(this), key, uint160(1 << 96)));
        calls[1] = abi.encodeCall(IHooks.afterSwap, (address(this), key, swap, delta, ""));
        calls[2] = abi.encodeCall(IHooks.afterInitialize, (address(this), key, uint160(1 << 96), int24(0)));
        calls[3] = abi.encodeCall(IHooks.beforeAddLiquidity, (address(this), key, liquidity, ""));
        calls[4] = abi.encodeCall(IHooks.afterAddLiquidity, (address(this), key, liquidity, delta, delta, ""));
        calls[5] = abi.encodeCall(IHooks.beforeRemoveLiquidity, (address(this), key, liquidity, ""));
        calls[6] = abi.encodeCall(IHooks.afterRemoveLiquidity, (address(this), key, liquidity, delta, delta, ""));
        calls[7] = abi.encodeCall(IHooks.beforeSwap, (address(this), key, swap, ""));
        calls[8] = abi.encodeCall(IHooks.beforeDonate, (address(this), key, 1, 1, ""));
        calls[9] = abi.encodeCall(IHooks.afterDonate, (address(this), key, 1, 1, ""));
    }
}
