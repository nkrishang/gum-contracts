// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Vm} from "lib/forge-std/src/Vm.sol";
import {ERC20} from "lib/solady/src/tokens/ERC20.sol";
import {Payment} from "src/Payment.sol";
import {Gate, PaymentCallsBase} from "test/utils/SettlementFixtures.sol";

/// @notice Properties of settlement calls over arbitrary amounts, splits,
/// calldata, timing and executors.
contract PaymentCallsFuzzTest is PaymentCallsBase {
    uint256 internal constant MAX_AMOUNT = 1e18;

    Gate internal gate;

    function setUp() public override {
        super.setUp();
        gate = new Gate();
        gate.setOpen(true);
    }

    /// @notice Any split of `amount` across any number of recipients settles
    /// exactly: each recipient gets its part, recovery gets exactly the excess,
    /// and the payment keeps nothing.
    function testFuzz_any_exact_split_settles(uint256 amount, uint256 excess, uint256 parts, uint256 seed) public {
        amount = bound(amount, 1, MAX_AMOUNT);
        excess = bound(excess, 0, MAX_AMOUNT);
        parts = bound(parts, 1, 8);

        Payment.Call[] memory calls = new Payment.Call[](parts);
        uint256[] memory shares = new uint256[](parts);
        uint256 left = amount;
        for (uint256 i; i < parts; ++i) {
            shares[i] = i == parts - 1 ? left : uint256(keccak256(abi.encode(seed, i))) % (left + 1);
            left -= shares[i];
            calls[i] = _transfer(_recipient(i), shares[i]);
        }
        address payment = _fund(amount, calls, amount + excess);

        vm.recordLogs();
        _execute(amount, calls);
        Vm.Log[] memory logs = _logsFrom(vm.getRecordedLogs(), payment);

        for (uint256 i; i < parts; ++i) {
            assertEq(token.balanceOf(_recipient(i)), shares[i], "each recipient gets its part");
        }
        assertEq(token.balanceOf(RECOVERY), excess, "recovery gets exactly the excess");
        assertEq(token.balanceOf(payment), 0, "the payment keeps nothing");
        assertTrue(Payment(payment).SETTLED());
        assertEq(logs.length, (excess == 0 ? 0 : 1) + parts + 1, "one Called per call, plus Recovered and Settled");
        assertEq(logs[logs.length - 1].topics[0], Settled.selector, "settlement is reported last");
    }

    /// @notice Spending anything other than exactly `amount` never settles.
    function testFuzz_any_spend_other_than_the_amount_reverts(uint256 amount, uint256 spend, uint256 excess) public {
        amount = bound(amount, 0, MAX_AMOUNT);
        spend = bound(spend, 0, 2 * MAX_AMOUNT);
        excess = bound(excess, 0, MAX_AMOUNT);
        vm.assume(spend != amount);

        _fundDirect(amount + excess);
        if (spend > amount) {
            // The excess has already gone to recovery, so the transfer itself fails.
            vm.expectRevert(
                abi.encodeWithSelector(
                    Payment.CallFailed.selector, 0, abi.encodeWithSelector(ERC20.InsufficientBalance.selector)
                )
            );
        } else {
            vm.expectRevert(abi.encodeWithSelector(Payment.AmountNotSpent.selector, amount - spend));
        }
        _deployDirect(amount, _list(_transfer(MERCHANT, spend)));
    }

    function testFuzz_underfunding_reverts_before_any_call(uint256 amount, uint256 funding) public {
        amount = bound(amount, 1, MAX_AMOUNT);
        funding = bound(funding, 0, amount - 1);

        _fundDirect(funding);
        vm.expectRevert(abi.encodeWithSelector(Payment.InsufficientTokenBalance.selector, funding, amount));
        _deployDirect(amount, _list(_call(address(0xE0A), ""), _transfer(MERCHANT, amount)));
    }

    /// @notice Changing any byte of a call's calldata, or its target,
    /// yields a different address.
    function testFuzz_any_change_to_a_call_moves_the_address(
        bytes memory data,
        uint256 position,
        uint8 mask,
        address otherTarget
    ) public view {
        vm.assume(data.length != 0 && mask != 0 && otherTarget != address(gate));
        position = bound(position, 0, data.length - 1);
        Payment.Call[] memory calls = _list(_transfer(MERCHANT, 10e6), _call(address(gate), data));
        address committed = _address(10e6, calls);

        bytes memory mutated = bytes.concat(data);
        mutated[position] = mutated[position] ^ bytes1(mask);
        assertNotEq(_address(10e6, _list(calls[0], _call(address(gate), mutated))), committed, "calldata");
        assertNotEq(_address(10e6, _list(calls[0], _call(otherTarget, data))), committed, "target");
    }

    /// @notice However late, an expired payment refunds everything and runs no call.
    function testFuzz_an_expired_payment_never_runs_its_calls(uint256 lateBy, uint256 funding) public {
        lateBy = bound(lateBy, 1, 10 * 365 days);
        funding = bound(funding, 0, MAX_AMOUNT);
        Payment.Call[] memory calls =
            _list(_transfer(MERCHANT, 10e6), _call(address(gate), abi.encodeCall(Gate.pass, ())));
        address payment = _fund(10e6, calls, funding);

        vm.warp(uint256(expiry) + lateBy);
        _execute(10e6, calls);

        assertEq(gate.passes(), 0);
        assertEq(token.balanceOf(MERCHANT), 0);
        assertEq(token.balanceOf(RECOVERY), funding);
        assertFalse(Payment(payment).SETTLED());
    }

    function testFuzz_a_wrong_chain_payment_never_runs_its_calls(uint256 committedChain) public {
        vm.assume(committedChain != block.chainid);
        Payment.Call[] memory calls =
            _list(_transfer(MERCHANT, 10e6), _call(address(gate), abi.encodeCall(Gate.pass, ())));
        address payment = factory.paymentAddress(address(token), 10e6, calls, expiry, RECOVERY, SALT, committedChain);
        token.mint(payment, 10e6);

        factory.execute(address(token), 10e6, calls, expiry, RECOVERY, SALT, committedChain);

        assertEq(gate.passes(), 0);
        assertEq(token.balanceOf(payment), 10e6);
        assertFalse(Payment(payment).SETTLED());
    }

    /// @notice Execution is permissionless and the executor has no say in the outcome.
    function testFuzz_the_executor_cannot_change_the_outcome(address executor, uint256 excess) public {
        vm.assume(executor != MERCHANT && executor != PLATFORM && executor != RECOVERY);
        excess = bound(excess, 0, MAX_AMOUNT);
        Payment.Call[] memory calls = _list(
            _transfer(MERCHANT, 9e6), _transfer(PLATFORM, 1e6), _call(address(gate), abi.encodeCall(Gate.pass, ()))
        );
        address payment = _fund(10e6, calls, 10e6 + excess);

        vm.prank(executor);
        _execute(10e6, calls);

        assertEq(token.balanceOf(MERCHANT), 9e6);
        assertEq(token.balanceOf(PLATFORM), 1e6);
        assertEq(token.balanceOf(RECOVERY), excess);
        assertEq(gate.passes(), 1);
        assertTrue(Payment(payment).SETTLED());
    }

    function _recipient(uint256 i) private pure returns (address) {
        return address(uint160(0x10000 + i));
    }
}
