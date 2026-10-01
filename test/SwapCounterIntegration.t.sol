// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {SwapCounterHook} from "../src/SwapCounterHook.sol";
import {HookTestBase} from "./utils/HookTestBase.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @dev Test-only router. Deliberately omitting settlement exercises rollback after afterSwap.
contract CounterTestRouter is IUnlockCallback {
    IPoolManager public immutable manager;

    struct Request {
        address payer;
        PoolKey key;
        bool isSwap;
        bool settle;
        SwapParams swapParams;
        ModifyLiquidityParams liquidityParams;
        bytes hookData;
    }

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function swap(PoolKey memory key, SwapParams memory params, bytes memory hookData, bool settle)
        external
        returns (BalanceDelta)
    {
        Request memory request;
        request.payer = msg.sender;
        request.key = key;
        request.isSwap = true;
        request.settle = settle;
        request.swapParams = params;
        request.hookData = hookData;
        return abi.decode(manager.unlock(abi.encode(request)), (BalanceDelta));
    }

    function modifyLiquidity(PoolKey memory key, ModifyLiquidityParams memory params) external returns (BalanceDelta) {
        Request memory request;
        request.payer = msg.sender;
        request.key = key;
        request.settle = true;
        request.liquidityParams = params;
        return abi.decode(manager.unlock(abi.encode(request)), (BalanceDelta));
    }

    function unlockCallback(bytes calldata rawData) external returns (bytes memory) {
        require(msg.sender == address(manager), "not manager");
        Request memory request = abi.decode(rawData, (Request));
        BalanceDelta delta;
        if (request.isSwap) {
            delta = manager.swap(request.key, request.swapParams, request.hookData);
        } else {
            (delta,) = manager.modifyLiquidity(request.key, request.liquidityParams, "");
        }
        if (request.settle) {
            _settle(request.key.currency0, request.payer, delta.amount0());
            _settle(request.key.currency1, request.payer, delta.amount1());
        }
        return abi.encode(delta);
    }

    function _settle(Currency currency, address payer, int128 amount) internal {
        if (amount < 0) {
            manager.sync(currency);
            require(
                MockERC20(Currency.unwrap(currency)).transferFrom(payer, address(manager), uint256(-int256(amount))),
                "transfer failed"
            );
            manager.settle();
        } else if (amount > 0) {
            manager.take(currency, payer, uint256(int256(amount)));
        }
    }
}

contract SwapCounterIntegrationTest is HookTestBase {
    using StateLibrary for IPoolManager;

    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    int256 internal constant LIQUIDITY = 100_000 ether;
    int24 internal constant MIN_TICK = -887220;
    int24 internal constant MAX_TICK = 887220;
    IPoolManager internal manager;
    SwapCounterHook internal hook;
    MockERC20 internal token0;
    MockERC20 internal token1;
    CounterTestRouter internal router;
    CounterTestRouter internal secondRouter;
    PoolKey internal key;

    event SwapCounted(address indexed sender, PoolId indexed poolId, uint256 senderCount, uint256 totalCount);

    function setUp() public {
        manager = IPoolManager(address(new PoolManager(address(this))));
        hook = _deployHook(manager);
        MockERC20 a = new MockERC20("A", "A", 1_000_000_000 ether);
        MockERC20 b = new MockERC20("B", "B", 1_000_000_000 ether);
        (token0, token1) = address(a) < address(b) ? (a, b) : (b, a);
        router = new CounterTestRouter(manager);
        secondRouter = new CounterTestRouter(manager);
        _approve(router);
        _approve(secondRouter);
        key = PoolKey(Currency.wrap(address(token0)), Currency.wrap(address(token1)), 3000, 60, IHooks(hook));
        manager.initialize(key, SQRT_PRICE_1_1);
        _addLiquidity(key);
    }

    function test_lifecycleCountsOnlySwapsAndAllowsFullWithdrawal() public {
        assertEq(hook.totalSwaps(), 0);
        assertEq(manager.getLiquidity(key.toId()), uint128(uint256(LIQUIDITY)));

        // Both swap directions and both exact-input/output modes must settle normally.
        for (uint256 i; i < 4; ++i) {
            bool zeroForOne = i % 2 == 0;
            int256 amount = i < 2 ? -int256(1 ether) : int256(1 ether);
            vm.expectEmit(true, true, false, true, address(hook));
            emit SwapCounted(address(router), key.toId(), i + 1, i + 1);
            BalanceDelta delta = router.swap(key, _params(zeroForOne, amount), hex"deadbeef", true);
            assertLt(zeroForOne ? delta.amount0() : delta.amount1(), 0);
            assertGt(zeroForOne ? delta.amount1() : delta.amount0(), 0);
            assertEq(hook.totalSwaps(), i + 1);
            assertEq(hook.swapCount(address(router)), i + 1);
        }

        BalanceDelta withdrawn = router.modifyLiquidity(key, _liquidity(-LIQUIDITY));
        assertGt(withdrawn.amount0(), 0);
        assertGt(withdrawn.amount1(), 0);
        assertEq(manager.getLiquidity(key.toId()), 0);
        assertEq(hook.totalSwaps(), 4);
        assertEq(hook.swapCount(address(this)), 0);
        assertEq(hook.swapCount(address(manager)), 0);
        assertEq(token0.balanceOf(address(hook)), 0);
        assertEq(token1.balanceOf(address(hook)), 0);
    }

    function test_countsRouterSendersAndIgnoresSpoofedHookData() public {
        address alice = address(0xA11CE);
        token0.transfer(alice, 10 ether);
        token1.transfer(alice, 10 ether);

        router.swap(key, _params(true, -1 ether), abi.encode(alice), true);
        vm.startPrank(alice);
        token0.approve(address(router), type(uint256).max);
        token1.approve(address(router), type(uint256).max);
        router.swap(key, _params(false, -1 ether), abi.encode(address(this)), true);
        vm.stopPrank();
        secondRouter.swap(key, _params(true, 1 ether), abi.encode(alice), true);

        assertEq(hook.totalSwaps(), 3);
        assertEq(hook.swapCount(address(router)), 2);
        assertEq(hook.swapCount(address(secondRouter)), 1);
        assertEq(hook.swapCount(alice), 0);
        assertEq(hook.swapCount(address(this)), 0);
        assertEq(hook.swapCount(address(manager)), 0);
    }

    function test_countsAggregateAcrossPoolsAndEventIdentifiesPool() public {
        PoolKey memory other = key;
        other.fee = 500;
        manager.initialize(other, SQRT_PRICE_1_1);
        _addLiquidity(other);

        vm.expectEmit(true, true, false, true, address(hook));
        emit SwapCounted(address(router), key.toId(), 1, 1);
        router.swap(key, _params(true, -1 ether), "", true);
        vm.expectEmit(true, true, false, true, address(hook));
        emit SwapCounted(address(router), other.toId(), 2, 2);
        router.swap(other, _params(false, -1 ether), "", true);

        assertEq(hook.totalSwaps(), 2);
        assertEq(hook.swapCount(address(router)), 2);
    }

    function test_amountsFeesAndPoolStateMatchHooklessPool() public {
        PoolKey memory plain = key;
        plain.hooks = IHooks(address(0));
        manager.initialize(plain, SQRT_PRICE_1_1);
        _addLiquidity(plain);

        for (uint256 i; i < 4; ++i) {
            SwapParams memory params = _params(i % 2 == 0, i < 2 ? -int256(1 ether) : int256(1 ether));
            BalanceDelta hookedDelta = router.swap(key, params, hex"1234", true);
            BalanceDelta plainDelta = router.swap(plain, params, "", true);
            assertEq(BalanceDelta.unwrap(hookedDelta), BalanceDelta.unwrap(plainDelta), "swap amounts changed");
            _assertSamePoolState(key, plain);
        }

        BalanceDelta hookedWithdrawal = router.modifyLiquidity(key, _liquidity(-LIQUIDITY));
        BalanceDelta plainWithdrawal = router.modifyLiquidity(plain, _liquidity(-LIQUIDITY));
        assertEq(BalanceDelta.unwrap(hookedWithdrawal), BalanceDelta.unwrap(plainWithdrawal), "LP proceeds changed");
        assertEq(hook.totalSwaps(), 4);
    }

    function test_settlementFailureRollsBackCountersAndPoolState() public {
        router.swap(key, _params(true, -1 ether), "", true);
        (uint160 priceBefore, int24 tickBefore,,) = manager.getSlot0(key.toId());
        (uint256 fees0Before, uint256 fees1Before) = manager.getFeeGrowthGlobals(key.toId());

        vm.expectRevert(IPoolManager.CurrencyNotSettled.selector);
        router.swap(key, _params(false, -1 ether), "", false);

        assertEq(hook.totalSwaps(), 1);
        assertEq(hook.swapCount(address(router)), 1);
        (uint160 priceAfter, int24 tickAfter,,) = manager.getSlot0(key.toId());
        (uint256 fees0After, uint256 fees1After) = manager.getFeeGrowthGlobals(key.toId());
        assertEq(priceAfter, priceBefore);
        assertEq(tickAfter, tickBefore);
        assertEq(fees0After, fees0Before);
        assertEq(fees1After, fees1Before);
    }

    function test_zeroAmountRejectedWithoutCounting() public {
        vm.expectRevert(IPoolManager.SwapAmountCannotBeZero.selector);
        router.swap(key, _params(true, 0), "", true);
        assertEq(hook.totalSwaps(), 0);
        assertEq(hook.swapCount(address(router)), 0);
    }

    function test_uninitializedPoolRejectedWithoutCounting() public {
        PoolKey memory absent = key;
        absent.fee = 999;
        vm.expectRevert(IPoolManager.PoolNotInitialized.selector);
        router.swap(absent, _params(true, -1 ether), "", true);
        assertEq(hook.totalSwaps(), 0);
        assertEq(hook.swapCount(address(router)), 0);
    }

    function test_routerRejectsUnauthorizedUnlockCallback() public {
        vm.expectRevert("not manager");
        router.unlockCallback("");
    }

    function testFuzz_realSwapAmountsMatchHooklessPool(bool zeroForOne, bool exactInput, uint96 rawAmount) public {
        PoolKey memory plain = key;
        plain.hooks = IHooks(address(0));
        manager.initialize(plain, SQRT_PRICE_1_1);
        _addLiquidity(plain);
        int256 amount = int256(bound(uint256(rawAmount), 1e9, 1_000 ether));
        SwapParams memory params = _params(zeroForOne, exactInput ? -amount : amount);

        BalanceDelta hookedDelta = router.swap(key, params, "", true);
        BalanceDelta plainDelta = router.swap(plain, params, "", true);
        assertEq(BalanceDelta.unwrap(hookedDelta), BalanceDelta.unwrap(plainDelta));
        _assertSamePoolState(key, plain);
        assertEq(hook.totalSwaps(), 1);
        assertEq(hook.swapCount(address(router)), 1);
    }

    function _params(bool zeroForOne, int256 amount) internal pure returns (SwapParams memory) {
        return SwapParams(zeroForOne, amount, zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1);
    }

    function _liquidity(int256 amount) internal pure returns (ModifyLiquidityParams memory) {
        return ModifyLiquidityParams(MIN_TICK, MAX_TICK, amount, bytes32(0));
    }

    function _addLiquidity(PoolKey memory pool) internal {
        router.modifyLiquidity(pool, _liquidity(LIQUIDITY));
    }

    function _approve(CounterTestRouter target) internal {
        token0.approve(address(target), type(uint256).max);
        token1.approve(address(target), type(uint256).max);
    }

    function _assertSamePoolState(PoolKey memory first, PoolKey memory second) internal view {
        (uint160 priceA, int24 tickA, uint24 protocolFeeA, uint24 lpFeeA) = manager.getSlot0(first.toId());
        (uint160 priceB, int24 tickB, uint24 protocolFeeB, uint24 lpFeeB) = manager.getSlot0(second.toId());
        assertEq(priceA, priceB, "price changed");
        assertEq(tickA, tickB, "tick changed");
        assertEq(protocolFeeA, protocolFeeB, "protocol fee changed");
        assertEq(lpFeeA, lpFeeB, "LP fee changed");
        assertEq(manager.getLiquidity(first.toId()), manager.getLiquidity(second.toId()), "liquidity changed");
        (uint256 growth0A, uint256 growth1A) = manager.getFeeGrowthGlobals(first.toId());
        (uint256 growth0B, uint256 growth1B) = manager.getFeeGrowthGlobals(second.toId());
        assertEq(growth0A, growth0B, "token0 fee growth changed");
        assertEq(growth1A, growth1B, "token1 fee growth changed");
    }
}
