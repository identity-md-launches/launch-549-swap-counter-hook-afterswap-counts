// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {HookTestBase} from "./utils/HookTestBase.sol";
import {CounterTestRouter} from "./SwapCounterIntegration.t.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {SwapCounterHook} from "../src/SwapCounterHook.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

/// @dev Executes several real swaps in one unlock, then settles their net currency deltas.
contract CounterBatchRouter is IUnlockCallback {
    using TransientStateLibrary for IPoolManager;

    IPoolManager public immutable manager;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function batch(PoolKey[] memory keys, SwapParams[] memory params, bool settle)
        external
        returns (BalanceDelta[] memory)
    {
        require(keys.length == params.length, "length mismatch");
        return abi.decode(manager.unlock(abi.encode(msg.sender, keys, params, settle)), (BalanceDelta[]));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "not manager");
        (address payer, PoolKey[] memory keys, SwapParams[] memory params, bool settle) =
            abi.decode(data, (address, PoolKey[], SwapParams[], bool));
        BalanceDelta[] memory deltas = new BalanceDelta[](keys.length);
        for (uint256 i; i < keys.length; ++i) {
            deltas[i] = manager.swap(keys[i], params[i], abi.encode(payer));
        }
        if (settle) {
            for (uint256 i; i < keys.length; ++i) {
                _settle(keys[i].currency0, payer);
                _settle(keys[i].currency1, payer);
            }
        }
        return abi.encode(deltas);
    }

    function _settle(Currency currency, address payer) internal {
        int256 amount = manager.currencyDelta(address(this), currency);
        if (amount < 0) {
            manager.sync(currency);
            require(MockERC20(Currency.unwrap(currency)).transferFrom(payer, address(manager), uint256(-amount)));
            manager.settle();
        } else if (amount > 0) {
            manager.take(currency, payer, uint256(amount));
        }
    }
}

contract SwapCounterBatchTest is HookTestBase {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    IPoolManager internal manager;
    SwapCounterHook internal hook;
    MockERC20 internal token0;
    MockERC20 internal token1;
    CounterTestRouter internal seedRouter;
    CounterBatchRouter internal batchRouter;
    PoolKey[3] internal pools;

    function setUp() public {
        manager = IPoolManager(address(new PoolManager(address(this))));
        hook = _deployHook(manager);
        MockERC20 a = new MockERC20("A", "A", 1_000_000_000 ether);
        MockERC20 b = new MockERC20("B", "B", 1_000_000_000 ether);
        (token0, token1) = address(a) < address(b) ? (a, b) : (b, a);
        seedRouter = new CounterTestRouter(manager);
        batchRouter = new CounterBatchRouter(manager);
        token0.approve(address(seedRouter), type(uint256).max);
        token1.approve(address(seedRouter), type(uint256).max);
        token0.approve(address(batchRouter), type(uint256).max);
        token1.approve(address(batchRouter), type(uint256).max);
        for (uint256 i; i < pools.length; ++i) {
            pools[i] = PoolKey(
                Currency.wrap(address(token0)),
                Currency.wrap(address(token1)),
                i == 2 ? 500 : 3000,
                60,
                i == 1 ? IHooks(address(0)) : IHooks(hook)
            );
            manager.initialize(pools[i], uint160(1 << 96));
            seedRouter.modifyLiquidity(pools[i], ModifyLiquidityParams(-887220, 887220, 100_000 ether, bytes32(0)));
        }
        // Start with another sender's committed history so rollback must preserve existing data.
        seedRouter.swap(pools[0], _params(true, -1 ether), "", true);
    }

    function test_eachSwapInOneUnlockCountsAndEmitsOnceAcrossPools() public {
        _assertSuccessfulBatch();
    }

    function test_lastSwapFailureRollsBackEarlierSwapsAcrossPools() public {
        bytes32 beforeState = _stateDigest();
        (PoolKey[] memory keys, SwapParams[] memory params) = _batchInputs();
        params[3].amountSpecified = 0;
        vm.expectRevert(IPoolManager.SwapAmountCannotBeZero.selector);
        batchRouter.batch(keys, params, true);
        assertEq(_stateDigest(), beforeState, "late failure committed partial batch state");
        _assertSuccessfulBatch();
    }

    function test_finalSettlementFailureRollsBackAllBatchCounters() public {
        bytes32 beforeState = _stateDigest();
        (PoolKey[] memory keys, SwapParams[] memory params) = _batchInputs();
        vm.expectRevert(IPoolManager.CurrencyNotSettled.selector);
        batchRouter.batch(keys, params, false);
        assertEq(_stateDigest(), beforeState, "unsettled batch committed partial state");
        _assertSuccessfulBatch();
    }

    function _assertSuccessfulBatch() internal {
        (PoolKey[] memory keys, SwapParams[] memory params) = _batchInputs();
        uint256 balance0 = token0.balanceOf(address(this));
        uint256 balance1 = token1.balanceOf(address(this));
        vm.recordLogs();
        BalanceDelta[] memory deltas = batchRouter.batch(keys, params, true);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 hookEvents;
        int256 net0;
        int256 net1;
        for (uint256 i; i < deltas.length; ++i) {
            net0 += deltas[i].amount0();
            net1 += deltas[i].amount1();
        }
        assertEq(int256(token0.balanceOf(address(this))) - int256(balance0), net0, "token0 settlement changed");
        assertEq(int256(token1.balanceOf(address(this))) - int256(balance1), net1, "token1 settlement changed");
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(hook)) continue;
            assertLt(hookEvents, 3, "extra hook event");
            assertEq(logs[i].topics.length, 3);
            assertEq(logs[i].topics[0], keccak256("SwapCounted(address,bytes32,uint256,uint256)"));
            assertEq(logs[i].topics[1], bytes32(uint256(uint160(address(batchRouter)))));
            PoolKey memory expectedPool = hookEvents == 1 ? pools[2] : pools[0];
            assertEq(logs[i].topics[2], PoolId.unwrap(expectedPool.toId()));
            assertEq(logs[i].data, abi.encode(hookEvents + 1, hookEvents + 2));
            ++hookEvents;
        }
        assertEq(hookEvents, 3, "one event required for each hooked swap");
        assertEq(hook.totalSwaps(), 4);
        assertEq(hook.swapCount(address(batchRouter)), 3);
        assertEq(hook.swapCount(address(seedRouter)), 1);
        assertEq(hook.swapCount(address(this)), 0);
        assertEq(hook.swapCount(address(manager)), 0);
        assertEq(token0.balanceOf(address(hook)), 0);
        assertEq(token1.balanceOf(address(hook)), 0);
        assertEq(manager.getNonzeroDeltaCount(), 0);
        assertFalse(manager.isUnlocked());
    }

    function _batchInputs() internal view returns (PoolKey[] memory keys, SwapParams[] memory params) {
        keys = new PoolKey[](4);
        params = new SwapParams[](4);
        for (uint256 i; i < 4; ++i) {
            keys[i] = pools[i % 3];
            params[i] = _params(i % 2 == 0, i < 2 ? -int256(1 ether) : int256(1 ether));
        }
    }

    function _params(bool zeroForOne, int256 amount) internal pure returns (SwapParams memory) {
        return SwapParams(zeroForOne, amount, zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1);
    }

    function _stateDigest() internal view returns (bytes32 digest) {
        digest = keccak256(
            abi.encode(
                hook.totalSwaps(),
                hook.swapCount(address(seedRouter)),
                hook.swapCount(address(batchRouter)),
                token0.balanceOf(address(this)),
                token1.balanceOf(address(this)),
                token0.balanceOf(address(manager)),
                token1.balanceOf(address(manager)),
                manager.getNonzeroDeltaCount(),
                manager.isUnlocked()
            )
        );
        for (uint256 i; i < pools.length; ++i) {
            PoolKey memory key = pools[i];
            (uint160 price, int24 tick, uint24 protocolFee, uint24 lpFee) = manager.getSlot0(key.toId());
            (uint256 fee0, uint256 fee1) = manager.getFeeGrowthGlobals(key.toId());
            digest = keccak256(
                abi.encode(digest, price, tick, protocolFee, lpFee, fee0, fee1, manager.getLiquidity(key.toId()))
            );
        }
    }
}
