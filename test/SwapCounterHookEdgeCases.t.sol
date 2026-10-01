// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {StdStorage, stdStorage} from "forge-std/StdStorage.sol";
import {stdError} from "forge-std/StdError.sol";
import {HookTestBase} from "./utils/HookTestBase.sol";
import {SwapCounterHook} from "../src/SwapCounterHook.sol";
import {ImmutableState} from "v4-periphery/src/base/ImmutableState.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";

/// @dev These tests exercise the callback ABI directly as the trusted manager. PoolManager's
/// validation of pool keys and swap parameters is covered separately by the integration suite.
contract SwapCounterHookEdgeCasesTest is HookTestBase {
    using stdStorage for StdStorage;

    bytes32 internal constant SWAP_COUNTED = keccak256("SwapCounted(address,bytes32,uint256,uint256)");
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);

    SwapCounterHook internal hook;
    IPoolManager internal manager;
    PoolKey internal key;

    function setUp() public {
        manager = IPoolManager(address(new PoolManager(address(this))));
        hook = _deployHook(manager);
        key = PoolKey(Currency.wrap(address(1)), Currency.wrap(address(2)), 3000, 60, hook);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_eachCallbackEmitsExactlyOneEventForTheEntirePoolKey(address sender, PoolKey memory arbitraryKey)
        public
    {
        // The expected ID uses the ABI encoding, independently of PoolIdLibrary.toId().
        bytes32 expectedPoolId = keccak256(abi.encode(arbitraryKey));
        for (uint256 count = 1; count <= 2; ++count) {
            vm.recordLogs();
            _observe(sender, arbitraryKey, SwapParams(false, 1, 1), 0, "");
            _assertSingleEvent(sender, expectedPoolId, count, count);
        }
        assertEq(hook.swapCount(sender), 2);
        assertEq(hook.totalSwaps(), 2);
    }

    function test_zeroAndMaximumSenderAndSwapValuesAreObservedWithoutArithmeticOnAmounts() public {
        address maximumSender = address(type(uint160).max);
        vm.recordLogs();
        _observe(address(0), key, SwapParams(false, 0, 0), 0, "");
        _assertSingleEvent(address(0), keccak256(abi.encode(key)), 1, 1);

        // Both packed signed delta extremes and both amountSpecified extremes are callback inputs.
        // The observer must neither negate nor narrow them.
        bytes memory largeHookData = new bytes(4096);
        largeHookData[0] = 0xff;
        largeHookData[4095] = 0xab;
        vm.recordLogs();
        _observe(
            maximumSender, key, SwapParams(true, type(int256).min, type(uint160).max), type(int256).min, largeHookData
        );
        _assertSingleEvent(maximumSender, keccak256(abi.encode(key)), 1, 2);
        vm.recordLogs();
        _observe(maximumSender, key, SwapParams(false, type(int256).max, 1), type(int256).max, hex"00ff");
        _assertSingleEvent(maximumSender, keccak256(abi.encode(key)), 2, 3);
        assertEq(hook.swapCount(address(0)), 1);
        assertEq(hook.swapCount(maximumSender), 2);
        assertEq(hook.totalSwaps(), 3);
    }

    function test_initializationAfterSwapsNeitherResetsCountsNorEmitsSwapEvents() public {
        _seedCounts();
        vm.recordLogs();
        vm.startPrank(address(manager));
        assertEq(hook.beforeInitialize(ALICE, key, 0), IHooks.beforeInitialize.selector);
        assertEq(hook.beforeInitialize(BOB, key, type(uint160).max), IHooks.beforeInitialize.selector);
        vm.stopPrank();
        assertEq(vm.getRecordedLogs().length, 0);
        _assertSeedCounts();
    }

    function test_countGettersWorkViaStaticcallForPopulatedAndAbsentSenders() public {
        _seedCounts();
        (bool totalOk, bytes memory total) = address(hook).staticcall(abi.encodeCall(hook.totalSwaps, ()));
        assertTrue(totalOk);
        assertEq(total, abi.encode(uint256(3)));

        address[3] memory senders = [ALICE, BOB, address(0)];
        uint256[3] memory expected = [uint256(2), uint256(1), uint256(0)];
        for (uint256 i; i < senders.length; ++i) {
            (bool ok, bytes memory result) = address(hook).staticcall(abi.encodeCall(hook.swapCount, (senders[i])));
            assertTrue(ok);
            assertEq(result, abi.encode(expected[i]));
        }
        _assertSeedCounts();
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_spoofingSenderAndOriginCannotChangeExistingCounts(address caller) public {
        // Construct an unauthorized caller without discarding fuzz runs.
        if (caller == address(manager)) caller = address(uint160(caller) ^ 1);
        _seedCounts();
        bytes memory payload = _swapCalldata(address(manager));
        vm.recordLogs();
        vm.prank(caller, address(manager));
        (bool success, bytes memory reason) = address(hook).call(payload);
        assertFalse(success);
        assertEq(reason, abi.encodeWithSelector(ImmutableState.NotPoolManager.selector));
        assertEq(vm.getRecordedLogs().length, 0);
        assertEq(hook.swapCount(address(manager)), 0);
        _assertSeedCounts();
    }

    function test_nonpayableSwapRejectsEtherWithoutChangingExistingCounts() public {
        _seedCounts();
        vm.deal(address(manager), 1);
        bytes memory payload = _swapCalldata(ALICE);
        vm.recordLogs();
        vm.prank(address(manager));
        (bool success,) = address(hook).call{value: 1}(payload);
        assertFalse(success);
        assertEq(address(hook).balance, 0);
        assertEq(address(manager).balance, 1);
        assertEq(vm.getRecordedLogs().length, 0);
        _assertSeedCounts();
    }

    function test_truncatedCallbackCannotCountASwap() public {
        _seedCounts();
        vm.recordLogs();
        vm.prank(address(manager));
        (bool success,) = address(hook).call(abi.encodePacked(IHooks.afterSwap.selector));
        assertFalse(success);
        assertEq(vm.getRecordedLogs().length, 0);
        _assertSeedCounts();
    }

    // Artificial storage boundaries: reaching 2**256 swaps is not a practical production
    // sequence. Discover slots through the getters so the tests do not depend on storage layout.
    function test_artificialCounterBoundaryReachesMaximumWithoutWrapping() public {
        _setSenderCount(ALICE, type(uint256).max - 1);
        _setTotal(type(uint256).max - 1);
        vm.recordLogs();
        _observe(ALICE, key, SwapParams(true, -1, 1), 0, "");
        _assertSingleEvent(ALICE, keccak256(abi.encode(key)), type(uint256).max, type(uint256).max);
        assertEq(hook.swapCount(ALICE), type(uint256).max);
        assertEq(hook.totalSwaps(), type(uint256).max);
    }

    function test_artificialSenderOverflowRevertsWithoutChangingEitherCount() public {
        _setSenderCount(ALICE, type(uint256).max);
        // Deliberately inconsistent injected state isolates the sender's overflow check: the
        // total counter must still have room, or its own overflow could mask a wrapping sender.
        _setTotal(type(uint256).max - 1);
        vm.recordLogs();
        vm.prank(address(manager));
        (bool success, bytes memory reason) = address(hook).call(_swapCalldata(ALICE));
        assertFalse(success);
        assertEq(reason, stdError.arithmeticError);
        assertEq(vm.getRecordedLogs().length, 0);
        assertEq(hook.swapCount(ALICE), type(uint256).max);
        assertEq(hook.totalSwaps(), type(uint256).max - 1);
    }

    function test_artificialTotalOverflowRollsBackTheEarlierSenderIncrement() public {
        _setSenderCount(ALICE, type(uint256).max);
        _setTotal(type(uint256).max);
        vm.recordLogs();
        vm.prank(address(manager));
        (bool success, bytes memory reason) = address(hook).call(_swapCalldata(BOB));
        assertFalse(success);
        assertEq(reason, stdError.arithmeticError);
        assertEq(vm.getRecordedLogs().length, 0);
        assertEq(hook.swapCount(BOB), 0);
        assertEq(hook.swapCount(ALICE), type(uint256).max);
        assertEq(hook.totalSwaps(), type(uint256).max);
    }

    function _observe(
        address sender,
        PoolKey memory poolKey,
        SwapParams memory params,
        int256 packedDelta,
        bytes memory hookData
    ) internal {
        vm.prank(address(manager));
        (bytes4 selector, int128 returnedDelta) =
            hook.afterSwap(sender, poolKey, params, BalanceDelta.wrap(packedDelta), hookData);
        assertEq(selector, IHooks.afterSwap.selector);
        assertEq(returnedDelta, 0);
    }

    function _assertSingleEvent(address sender, bytes32 poolId, uint256 senderCount, uint256 totalCount) internal {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1, "exactly one event per callback");
        assertEq(logs[0].emitter, address(hook));
        assertEq(logs[0].topics.length, 3);
        assertEq(logs[0].topics[0], SWAP_COUNTED);
        assertEq(logs[0].topics[1], bytes32(uint256(uint160(sender))));
        assertEq(logs[0].topics[2], poolId);
        assertEq(logs[0].data, abi.encode(senderCount, totalCount));
    }

    function _seedCounts() internal {
        _observe(ALICE, key, SwapParams(true, -1, 1), 0, "");
        _observe(BOB, key, SwapParams(false, 1, 1), 0, "");
        _observe(ALICE, key, SwapParams(true, -1, 1), 0, "");
    }

    function _assertSeedCounts() internal view {
        assertEq(hook.swapCount(ALICE), 2);
        assertEq(hook.swapCount(BOB), 1);
        assertEq(hook.totalSwaps(), 3);
    }

    function _swapCalldata(address sender) internal view returns (bytes memory) {
        return abi.encodeCall(IHooks.afterSwap, (sender, key, SwapParams(true, -1, 1), BalanceDelta.wrap(0), ""));
    }

    function _setSenderCount(address sender, uint256 value) internal {
        stdstore.target(address(hook)).sig("swapCount(address)").with_key(sender).checked_write(value);
    }

    function _setTotal(uint256 value) internal {
        stdstore.target(address(hook)).sig("totalSwaps()").checked_write(value);
    }
}
