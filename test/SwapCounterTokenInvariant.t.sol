// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {SwapCounterToken} from "src/SwapCounterToken.sol";

/// @dev Closed actor set: every successful transfer stays within these four balances.
/// The model starts from the specified initial allocation, never from balanceOf/allowance.
contract SwapCounterTokenHandler is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 ether;
    SwapCounterToken public immutable token;
    address[4] public actors = [address(0xA11CE), address(0xB0B), address(0xCA401), address(0xDA7E)];
    mapping(address => uint256) public expectedBalance;
    mapping(address => mapping(address => uint256)) public expectedAllowance;

    constructor(SwapCounterToken token_) {
        token = token_;
        expectedBalance[actors[0]] = SUPPLY;
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amountSeed) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint256 amount = bound(amountSeed, 0, expectedBalance[from]);
        vm.prank(from);
        assertTrue(token.transfer(to, amount), "transfer returned false");
        _move(from, to, amount);
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amountSeed, uint8 mode) external {
        uint256 amount = mode % 3 == 0 ? 0 : mode % 3 == 1 ? type(uint256).max : bound(amountSeed, 0, SUPPLY);
        _approve(_actor(ownerSeed), _actor(spenderSeed), amount);
    }

    function transferFrom(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 amountSeed) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        address to = _actor(toSeed);
        uint256 allowance = expectedAllowance[owner][spender];
        uint256 maximum = expectedBalance[owner] < allowance ? expectedBalance[owner] : allowance;
        uint256 amount = bound(amountSeed, 0, maximum);
        vm.prank(spender);
        assertTrue(token.transferFrom(owner, to, amount), "transferFrom returned false");
        _move(owner, to, amount);
        if (allowance != type(uint256).max) expectedAllowance[owner][spender] -= amount;
    }

    function rejectTransferAboveBalance(uint256 fromSeed, uint256 toSeed) external {
        address from = _actor(fromSeed);
        uint256 balance = expectedBalance[from];
        _rejectAs(
            from,
            abi.encodeCall(token.transfer, (_actor(toSeed), balance + 1)),
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, from, balance, balance + 1)
        );
    }

    function rejectTransferFromAboveAllowance(uint256 ownerSeed, uint256 spenderSeed, uint256 amountSeed) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        uint256 allowance = bound(amountSeed, 0, SUPPLY);
        _approve(owner, spender, allowance);
        _rejectAs(
            spender,
            abi.encodeCall(token.transferFrom, (owner, spender, allowance + 1)),
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, allowance, allowance + 1)
        );
    }

    function rejectTransferFromAboveBalance(uint256 ownerSeed, uint256 spenderSeed) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        uint256 balance = expectedBalance[owner];
        // A finite allowance would be consumed before the balance check; it must roll back.
        _approve(owner, spender, balance + 1);
        _rejectAs(
            spender,
            abi.encodeCall(token.transferFrom, (owner, spender, balance + 1)),
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, owner, balance, balance + 1)
        );
    }

    function rejectZeroRecipient(uint256 ownerSeed, uint256 spenderSeed, uint256 amountSeed, bool delegated) external {
        address owner = _actor(ownerSeed);
        uint256 amount = bound(amountSeed, 0, expectedBalance[owner]);
        bytes memory error = abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0));
        if (delegated) {
            address spender = _actor(spenderSeed);
            _approve(owner, spender, amount);
            _rejectAs(spender, abi.encodeCall(token.transferFrom, (owner, address(0), amount)), error);
        } else {
            _rejectAs(owner, abi.encodeCall(token.transfer, (address(0), amount)), error);
        }
    }

    function rejectZeroSpender(uint256 ownerSeed, uint256 amount) external {
        _rejectAs(
            _actor(ownerSeed),
            abi.encodeCall(token.approve, (address(0), amount)),
            abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0))
        );
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function _approve(address owner, address spender, uint256 amount) internal {
        vm.prank(owner);
        assertTrue(token.approve(spender, amount), "approve returned false");
        expectedAllowance[owner][spender] = amount;
    }

    function _move(address from, address to, uint256 amount) internal {
        expectedBalance[from] -= amount;
        expectedBalance[to] += amount;
    }

    function _rejectAs(address caller, bytes memory data, bytes memory expectedError) internal {
        vm.prank(caller);
        (bool success, bytes memory error) = address(token).call(data);
        assertFalse(success, "invalid ERC20 operation succeeded");
        assertEq(error, expectedError, "unexpected ERC20 revert");
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 32
/// forge-config: default.invariant.fail-on-revert = true
contract SwapCounterTokenInvariantTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 ether;
    SwapCounterToken internal token;
    SwapCounterTokenHandler internal handler;

    function setUp() public {
        vm.prank(address(0xA11CE));
        token = new SwapCounterToken();
        handler = new SwapCounterTokenHandler(token);
        for (uint256 i = 1; i < 4; ++i) {
            handler.transfer(0, i, SUPPLY / 4);
        }
        // Begin with funded actors and usable finite allowances in both directions.
        for (uint256 i; i < 4; ++i) {
            for (uint256 j; j < 4; ++j) {
                handler.approve(i, j, SUPPLY / 4, 2);
            }
        }

        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = handler.transfer.selector;
        selectors[1] = handler.approve.selector;
        selectors[2] = handler.transferFrom.selector;
        selectors[3] = handler.rejectTransferAboveBalance.selector;
        selectors[4] = handler.rejectTransferFromAboveAllowance.selector;
        selectors[5] = handler.rejectTransferFromAboveBalance.selector;
        selectors[6] = handler.rejectZeroRecipient.selector;
        selectors[7] = handler.rejectZeroSpender.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_fixedSupplyAndExactBalances() public view {
        uint256 sum;
        for (uint256 i; i < 4; ++i) {
            address actor = handler.actors(i);
            uint256 balance = token.balanceOf(actor);
            assertEq(balance, handler.expectedBalance(actor), "balance differs from requested transfers");
            sum += balance;
        }
        assertEq(token.totalSupply(), SUPPLY, "fixed supply changed");
        assertEq(sum, SUPPLY, "balances do not conserve supply");
        assertEq(token.balanceOf(address(0)), 0, "tokens burned");
        assertEq(token.balanceOf(address(handler)), 0, "handler acquired tokens");
    }

    function invariant_allowancesMatchApprovalsAndSuccessfulSpending() public view {
        for (uint256 i; i < 4; ++i) {
            address owner = handler.actors(i);
            assertEq(token.allowance(owner, address(0)), 0, "zero spender acquired allowance");
            for (uint256 j; j < 4; ++j) {
                address spender = handler.actors(j);
                assertEq(
                    token.allowance(owner, spender),
                    handler.expectedAllowance(owner, spender),
                    "allowance changed incorrectly, including after rejected calls"
                );
            }
        }
    }

    function test_edgeSequenceFullSupplySelfTransferAndZero() public {
        for (uint256 i = 1; i < 4; ++i) {
            handler.transfer(i, 0, SUPPLY / 4);
        }
        handler.transfer(0, 0, SUPPLY);
        handler.transfer(0, 1, SUPPLY);
        handler.transfer(0, 1, 0);
        handler.transfer(1, 0, 1);
        handler.transfer(1, 0, SUPPLY - 1);
        invariant_fixedSupplyAndExactBalances();
        invariant_allowancesMatchApprovalsAndSuccessfulSpending();
    }

    function test_edgeSequenceInfiniteApprovalRevocationAndReverts() public {
        handler.approve(0, 1, 0, 1);
        handler.transferFrom(0, 1, 2, 1);
        handler.transferFrom(0, 1, 0, SUPPLY / 4 - 1);
        assertEq(token.allowance(handler.actors(0), handler.actors(1)), type(uint256).max);
        handler.approve(0, 1, 0, 0);
        handler.rejectTransferFromAboveAllowance(0, 1, 0);
        handler.rejectTransferFromAboveBalance(0, 1);
        handler.rejectZeroRecipient(0, 1, 1, true);
        handler.rejectZeroRecipient(0, 1, 0, false);
        handler.rejectZeroSpender(0, type(uint256).max);
        invariant_fixedSupplyAndExactBalances();
        invariant_allowancesMatchApprovalsAndSuccessfulSpending();
    }
}
