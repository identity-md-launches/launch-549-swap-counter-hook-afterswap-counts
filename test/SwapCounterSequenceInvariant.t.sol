// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {Pool} from "v4-core/src/libraries/Pool.sol";
import {SwapCounterHook} from "../src/SwapCounterHook.sol";
import {HookTestBase} from "./utils/HookTestBase.sol";
import {CounterTestRouter} from "./SwapCounterIntegration.t.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @dev The oracle runs the same settled operations against a separate hookless pool.
/// Ghost counts derive from completed router calls, without reading the hook's counters.
contract SwapCounterSequenceHandler is Test {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    uint256 internal constant MIN_LIQUIDITY = 100_000 ether;
    bytes32 internal constant COUNTED_TOPIC = keccak256("SwapCounted(address,bytes32,uint256,uint256)");

    IPoolManager public immutable manager;
    SwapCounterHook public immutable hook;
    MockERC20 public immutable token0;
    MockERC20 public immutable token1;
    CounterTestRouter[3] public routers;
    PoolKey internal hooked;
    PoolKey internal plain;
    uint256[3] public expectedSenderCounts;
    uint256 public successfulSwaps;
    uint256 public successfulLiquidityChanges;
    uint256 public rejectedSwaps;
    uint256 public expectedLiquidity;

    constructor(IPoolManager manager_, SwapCounterHook hook_, PoolKey memory key_) {
        manager = manager_;
        hook = hook_;
        hooked = key_;
        plain = key_;
        plain.hooks = IHooks(address(0));
        token0 = MockERC20(Currency.unwrap(key_.currency0));
        token1 = MockERC20(Currency.unwrap(key_.currency1));
        for (uint256 i; i < routers.length; ++i) {
            routers[i] = new CounterTestRouter(manager_);
            token0.approve(address(routers[i]), type(uint256).max);
            token1.approve(address(routers[i]), type(uint256).max);
        }
    }

    function seedLiquidity() external {
        require(expectedLiquidity == 0, "already seeded");
        _modifyLiquidity(int256(MIN_LIQUIDITY));
    }

    function swap(uint8 rawRouter, bool zeroForOne, bool exactInput, uint96 rawAmount, bytes32 hookData) external {
        uint256 index = uint256(rawRouter) % routers.length;
        int256 amount = int256(bound(uint256(rawAmount), 1, 10 ether));
        SwapParams memory params = _params(zeroForOne, exactInput ? -amount : amount);
        vm.recordLogs();
        BalanceDelta actual = routers[index].swap(hooked, params, abi.encode(hookData), true);
        Vm.Log[] memory entries = vm.getRecordedLogs();

        ++successfulSwaps;
        ++expectedSenderCounts[index];
        _checkSwapEvent(entries, index);

        BalanceDelta referenceDelta = routers[index].swap(plain, params, abi.encode(hookData), true);
        assertEq(BalanceDelta.unwrap(actual), BalanceDelta.unwrap(referenceDelta), "hook changed settled amounts");
        assertEq(hook.totalSwaps(), successfulSwaps, "hookless swap was counted");
    }

    function changeLiquidity(bool add, uint96 rawAmount) external {
        // Retain enough baseline liquidity that every generated swap can settle.
        uint256 removable = expectedLiquidity - MIN_LIQUIDITY;
        if (add || removable == 0) {
            _modifyLiquidity(int256(bound(uint256(rawAmount), 1, 1_000 ether)));
        } else {
            _modifyLiquidity(-int256(bound(uint256(rawAmount), 1, removable)));
        }
        ++successfulLiquidityChanges;
        assertEq(hook.totalSwaps(), successfulSwaps, "liquidity change counted as swap");
    }

    function rejectedSwap(uint8 rawRouter, uint8 rawMode, bool zeroForOne, uint96 rawAmount) external {
        uint256 index = uint256(rawRouter) % routers.length;
        uint256 mode = uint256(rawMode) % 3;
        int256 amount = int256(bound(uint256(rawAmount), 1, 10 ether));
        SwapParams memory params = _params(zeroForOne, -amount);
        bytes32 stateBefore = _poolFingerprint(hooked);
        uint256 balance0Before = token0.balanceOf(address(this));
        uint256 balance1Before = token1.balanceOf(address(this));

        if (mode == 0) {
            params.amountSpecified = 0;
            vm.expectRevert(IPoolManager.SwapAmountCannotBeZero.selector);
        } else if (mode == 1) {
            (uint160 currentPrice,,,) = manager.getSlot0(hooked.toId());
            params.sqrtPriceLimitX96 = currentPrice;
            vm.expectRevert(abi.encodeWithSelector(Pool.PriceLimitAlreadyExceeded.selector, currentPrice, currentPrice));
        } else {
            // afterSwap executes, but the enclosing unlock must roll back its writes.
            vm.expectRevert(IPoolManager.CurrencyNotSettled.selector);
        }
        routers[index].swap(hooked, params, "", mode != 2);

        ++rejectedSwaps;
        assertEq(hook.totalSwaps(), successfulSwaps, "rejected swap changed total count");
        assertEq(
            hook.swapCount(address(routers[index])), expectedSenderCounts[index], "rejected swap changed sender count"
        );
        assertEq(_poolFingerprint(hooked), stateBefore, "rejected swap changed pool state");
        assertEq(token0.balanceOf(address(this)), balance0Before, "rejected swap moved token0");
        assertEq(token1.balanceOf(address(this)), balance1Before, "rejected swap moved token1");
    }

    function assertPoolParity() external view {
        assertEq(_poolFingerprint(hooked), _poolFingerprint(plain), "hook changed prices, liquidity, or fees");
        assertEq(manager.getLiquidity(hooked.toId()), expectedLiquidity, "liquidity accounting differs");
    }

    function _modifyLiquidity(int256 amount) internal {
        ModifyLiquidityParams memory params = ModifyLiquidityParams(-887220, 887220, amount, bytes32(0));
        BalanceDelta actual = routers[0].modifyLiquidity(hooked, params);
        BalanceDelta referenceDelta = routers[0].modifyLiquidity(plain, params);
        assertEq(BalanceDelta.unwrap(actual), BalanceDelta.unwrap(referenceDelta), "hook changed LP proceeds");
        expectedLiquidity = amount < 0 ? expectedLiquidity - uint256(-amount) : expectedLiquidity + uint256(amount);
    }

    function _checkSwapEvent(Vm.Log[] memory entries, uint256 index) internal view {
        uint256 count;
        for (uint256 i; i < entries.length; ++i) {
            if (entries[i].emitter != address(hook)) continue;
            ++count;
            assertEq(entries[i].topics.length, 3, "incorrect event indexing");
            assertEq(entries[i].topics[0], COUNTED_TOPIC, "unexpected hook event");
            assertEq(entries[i].topics[1], bytes32(uint256(uint160(address(routers[index])))), "wrong event sender");
            assertEq(entries[i].topics[2], PoolId.unwrap(hooked.toId()), "wrong event pool");
            assertEq(entries[i].data, abi.encode(expectedSenderCounts[index], successfulSwaps), "wrong event counts");
        }
        assertEq(count, 1, "expected exactly one event per swap");
    }

    function _poolFingerprint(PoolKey memory key) internal view returns (bytes32) {
        (uint160 price, int24 tick, uint24 protocolFee, uint24 lpFee) = manager.getSlot0(key.toId());
        (uint256 growth0, uint256 growth1) = manager.getFeeGrowthGlobals(key.toId());
        return
            keccak256(abi.encode(price, tick, protocolFee, lpFee, manager.getLiquidity(key.toId()), growth0, growth1));
    }

    function _params(bool zeroForOne, int256 amount) internal pure returns (SwapParams memory) {
        return SwapParams(zeroForOne, amount, zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1);
    }
}

/// forge-config: default.invariant.runs = 128
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract SwapCounterSequenceInvariantTest is HookTestBase {
    uint256 internal constant SUPPLY = 10_000_000 ether;
    IPoolManager internal manager;
    SwapCounterHook internal hook;
    MockERC20 internal token0;
    MockERC20 internal token1;
    SwapCounterSequenceHandler internal handler;

    function setUp() public {
        manager = IPoolManager(address(new PoolManager(address(this))));
        hook = _deployHook(manager);
        MockERC20 first = new MockERC20("Sequence A", "A", SUPPLY);
        MockERC20 second = new MockERC20("Sequence B", "B", SUPPLY);
        (token0, token1) = address(first) < address(second) ? (first, second) : (second, first);
        PoolKey memory key = PoolKey(Currency.wrap(address(token0)), Currency.wrap(address(token1)), 3000, 60, hook);
        manager.initialize(key, uint160(1 << 96));
        handler = new SwapCounterSequenceHandler(manager, hook, key);
        key.hooks = IHooks(address(0));
        manager.initialize(key, uint160(1 << 96));
        token0.transfer(address(handler), SUPPLY);
        token1.transfer(address(handler), SUPPLY);
        handler.seedLiquidity();

        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = handler.swap.selector;
        selectors[1] = handler.changeLiquidity.selector;
        selectors[2] = handler.rejectedSwap.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_countersMatchOnlySuccessfulRouterCalls() public view {
        uint256 sum;
        for (uint256 i; i < 3; ++i) {
            uint256 count = hook.swapCount(address(handler.routers(i)));
            assertEq(count, handler.expectedSenderCounts(i), "sender count diverged");
            sum += count;
        }
        assertEq(hook.totalSwaps(), handler.successfulSwaps(), "total count diverged");
        assertEq(sum, hook.totalSwaps(), "per-sender sum diverged");
        assertEq(hook.swapCount(address(handler)), 0, "payer was counted instead of router");
        assertEq(hook.swapCount(address(manager)), 0, "manager was counted instead of router");
    }

    function invariant_hookIsEconomicallyTransparent() public view {
        handler.assertPoolParity();
        assertEq(token0.balanceOf(address(hook)), 0, "hook retained token0");
        assertEq(token1.balanceOf(address(hook)), 0, "hook retained token1");
        assertEq(address(hook).balance, 0, "hook retained ETH");
        assertEq(token0.balanceOf(address(manager)) + token0.balanceOf(address(handler)), SUPPLY, "token0 lost");
        assertEq(token1.balanceOf(address(manager)) + token1.balanceOf(address(handler)), SUPPLY, "token1 lost");
        for (uint256 i; i < 3; ++i) {
            assertEq(token0.balanceOf(address(handler.routers(i))), 0, "router retained token0");
            assertEq(token1.balanceOf(address(handler.routers(i))), 0, "router retained token1");
        }
    }

    function test_sequenceIncludesDustAllSwapModesAndRollback() public {
        // Pin dust and maximum generated trades; random sequences then explore ordering.
        for (uint8 i; i < 4; ++i) {
            handler.swap(i, i % 2 == 0, i < 2, 1, bytes32(uint256(i)));
            handler.swap(i, i % 2 == 0, i < 2, uint96(10 ether), bytes32(uint256(i)));
            handler.rejectedSwap(i, i % 3, i % 2 == 0, 1);
            handler.changeLiquidity(true, uint96(1 ether));
            handler.changeLiquidity(false, uint96(1 ether));
        }
        assertEq(handler.successfulSwaps(), 8);
        assertEq(handler.rejectedSwaps(), 4);
        assertEq(handler.successfulLiquidityChanges(), 8);
        invariant_countersMatchOnlySuccessfulRouterCalls();
        invariant_hookIsEconomicallyTransparent();
    }
}
