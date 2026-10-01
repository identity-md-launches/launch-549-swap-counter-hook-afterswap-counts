// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SwapCounterToken} from "../src/SwapCounterToken.sol";

contract SwapCounterTokenTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 ether;
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);

    SwapCounterToken internal token;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function setUp() public {
        token = new SwapCounterToken();
    }

    function test_metadataAndFixedSupply() public view {
        assertEq(token.name(), "Swap Counter");
        assertEq(token.symbol(), "SWAPC");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(ALICE), 0);
    }

    function test_wholeSupplyGoesToActualDeployer() public {
        vm.prank(ALICE);
        SwapCounterToken other = new SwapCounterToken();
        assertEq(other.totalSupply(), SUPPLY);
        assertEq(other.balanceOf(ALICE), SUPPLY);
        assertEq(other.balanceOf(address(this)), 0);
    }

    function testFuzz_transferMovesExactAmountAndPreservesSupply(uint256 amount) public {
        amount = bound(amount, 0, SUPPLY);
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(address(this), ALICE, amount);
        assertTrue(token.transfer(ALICE, amount));
        assertEq(token.balanceOf(address(this)), SUPPLY - amount);
        assertEq(token.balanceOf(ALICE), amount);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_approvalAndTransferFromConsumeAllowance() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit Approval(address(this), ALICE, 100 ether);
        assertTrue(token.approve(ALICE, 100 ether));

        vm.prank(ALICE);
        assertTrue(token.transferFrom(address(this), BOB, 40 ether));
        assertEq(token.allowance(address(this), ALICE), 60 ether);
        assertEq(token.balanceOf(address(this)), SUPPLY - 40 ether);
        assertEq(token.balanceOf(BOB), 40 ether);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_transferAboveBalanceRevertsWithoutChangingBalances() public {
        token.transfer(ALICE, 10 ether);
        vm.expectRevert(
            abi.encodeWithSignature("ERC20InsufficientBalance(address,uint256,uint256)", ALICE, 10 ether, 11 ether)
        );
        vm.prank(ALICE);
        token.transfer(BOB, 11 ether);

        assertEq(token.balanceOf(ALICE), 10 ether);
        assertEq(token.balanceOf(BOB), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_transferFromAboveAllowanceRevertsAtomically() public {
        token.approve(ALICE, 5 ether);
        vm.expectRevert(
            abi.encodeWithSignature("ERC20InsufficientAllowance(address,uint256,uint256)", ALICE, 5 ether, 6 ether)
        );
        vm.prank(ALICE);
        token.transferFrom(address(this), BOB, 6 ether);

        assertEq(token.allowance(address(this), ALICE), 5 ether);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(BOB), 0);
    }

    function test_approvalRevocationPreventsSpending() public {
        token.approve(ALICE, 100 ether);
        token.approve(ALICE, 0);
        vm.expectRevert(abi.encodeWithSignature("ERC20InsufficientAllowance(address,uint256,uint256)", ALICE, 0, 1));
        vm.prank(ALICE);
        token.transferFrom(address(this), BOB, 1);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(BOB), 0);
    }

    function test_zeroRecipientCannotBurnSupply() public {
        vm.expectRevert(abi.encodeWithSignature("ERC20InvalidReceiver(address)", address(0)));
        token.transfer(address(0), 1);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(this)), SUPPLY);
    }

    function test_zeroSpenderIsRejected() public {
        vm.expectRevert(abi.encodeWithSignature("ERC20InvalidSpender(address)", address(0)));
        token.approve(address(0), 1);
    }

    function test_commonMintAndAdminCallsAreAbsentForDeployerAndOthers() public {
        bytes[] memory calls = new bytes[](8);
        calls[0] = abi.encodeWithSignature("mint(address,uint256)", ALICE, 1 ether);
        calls[1] = abi.encodeWithSignature("mint(uint256)", 1 ether);
        calls[2] = abi.encodeWithSignature("burn(uint256)", 1 ether);
        calls[3] = abi.encodeWithSignature("transferOwnership(address)", ALICE);
        calls[4] = abi.encodeWithSignature("upgradeTo(address)", ALICE);
        calls[5] = abi.encodeWithSignature("initialize(address)", ALICE);
        calls[6] = abi.encodeWithSignature("pause()");
        calls[7] = abi.encodeWithSignature("setMinter(address)", ALICE);

        for (uint256 i; i < calls.length; ++i) {
            (bool deployerSuccess,) = address(token).call(calls[i]);
            assertFalse(deployerSuccess);
            vm.prank(ALICE);
            (bool outsiderSuccess,) = address(token).call(calls[i]);
            assertFalse(outsiderSuccess);
        }
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(ALICE), 0);
    }
}
