// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test} from "lib/forge-std/src/Test.sol";
import {Vm} from "lib/forge-std/src/Vm.sol";
import {ERC20} from "lib/solady/src/tokens/ERC20.sol";
import {SafeTransferLib} from "lib/solady/src/utils/SafeTransferLib.sol";
import {BatchSweeper} from "src/BatchSweeper.sol";
import {MockStablecoin} from "src/mock/MockStablecoin.sol";
import {Payment} from "src/Payment.sol";
import {PaymentFactory} from "src/PaymentFactory.sol";
import {ERC4626} from "lib/solady/src/tokens/ERC4626.sol";
import {Gate, MockVault} from "test/utils/SettlementFixtures.sol";

contract BatchSweeperTest is Test {
    event SweepFailed(address indexed paymentAddress, address indexed token, bytes revertData);

    // /// @dev Must match `SWEEP_BATCH_BASE_GAS` / `SWEEP_GAS_PER_ITEM` in the indexer's chain client.
    // uint256 internal constant SWEEP_BATCH_BASE_GAS = 100_000;
    // uint256 internal constant SWEEP_GAS_PER_ITEM = 400_000;
    // uint256 internal constant SWEEP_BATCH_LIMIT = 20;

    MockStablecoin private token;
    PaymentFactory private factory;
    BatchSweeper private batchSweeper;

    function setUp() public {
        token = new MockStablecoin("Mock USD Coin", "USDC");
        factory = new PaymentFactory();
        batchSweeper = new BatchSweeper(factory);
    }

    function test_mixed_batch_sweeps_successes_and_reports_failure() public {
        BatchSweeper.Sweep[] memory sweeps = new BatchSweeper.Sweep[](3);
        sweeps[0] = _sweep(10e6, address(0xA1), bytes32(uint256(1)));
        sweeps[1] = _sweep(20e6, address(0xA2), bytes32(uint256(2)));
        sweeps[2] = _sweep(30e6, address(0xA3), bytes32(uint256(3)));

        address first = _paymentAddress(sweeps[0]);
        address failed = _paymentAddress(sweeps[1]);
        address third = _paymentAddress(sweeps[2]);
        token.mint(first, 11e6);
        token.mint(failed, 20e6 - 1);
        token.mint(third, 30e6);

        vm.expectEmit(true, true, false, true, address(batchSweeper));
        emit SweepFailed(
            failed, address(token), abi.encodeWithSelector(Payment.InsufficientTokenBalance.selector, 20e6 - 1, 20e6)
        );
        batchSweeper.executeBatch(sweeps);

        assertGt(first.code.length, 0);
        assertEq(failed.code.length, 0);
        assertGt(third.code.length, 0);
        assertEq(token.balanceOf(address(0xA1)), 10e6, "the receiver takes exactly the invoice amount");
        assertEq(token.balanceOf(address(0xCAFE)), 1e6, "the overpayment remainder goes to recovery");
        assertEq(token.balanceOf(first), 0, "an overpayment must not be stranded");
        assertEq(token.balanceOf(address(0xA2)), 0);
        assertEq(token.balanceOf(address(0xA3)), 30e6);
    }

    /// @notice A failed recovery leg reverts only its own deployment, and the
    /// receiver leg rolls back with it. Siblings with a zero remainder never
    /// touch the recovery wallet, so they settle as usual in the same batch.
    function test_overpayment_recovery_failure_does_not_rollback_sibling_sweeps() public {
        BatchSweeper.Sweep[] memory sweeps = new BatchSweeper.Sweep[](3);
        sweeps[0] = _sweep(10e6, address(0xA4), bytes32(uint256(1)));
        sweeps[1] = _sweep(20e6, address(0xA5), bytes32(uint256(2)));
        sweeps[2] = _sweep(30e6, address(0xA6), bytes32(uint256(3)));
        address overpaid = _paymentAddress(sweeps[0]);
        token.mint(overpaid, 11e6);
        token.mint(_paymentAddress(sweeps[1]), 20e6);
        token.mint(_paymentAddress(sweeps[2]), 30e6);
        token.setBlacklisted(address(0xCAFE), true);

        vm.expectEmit(true, true, false, true, address(batchSweeper));
        emit SweepFailed(overpaid, address(token), abi.encodeWithSelector(SafeTransferLib.TransferFailed.selector));
        batchSweeper.executeBatch(sweeps);

        assertEq(overpaid.code.length, 0);
        assertEq(token.balanceOf(overpaid), 11e6, "the overpaid item keeps its full balance for a later attempt");
        assertEq(token.balanceOf(address(0xA4)), 0, "the receiver leg rolls back with the failed recovery leg");
        assertGt(_paymentAddress(sweeps[1]).code.length, 0);
        assertGt(_paymentAddress(sweeps[2]).code.length, 0);
        assertEq(token.balanceOf(address(0xA5)), 20e6);
        assertEq(token.balanceOf(address(0xA6)), 30e6);
        assertEq(token.balanceOf(address(0xCAFE)), 0);
    }

    function test_already_deployed_item_is_recovered_instead_of_re_executed() public {
        BatchSweeper.Sweep[] memory sweeps = new BatchSweeper.Sweep[](2);
        sweeps[0] = _sweep(10e6, address(0xB1), bytes32(uint256(1)));
        sweeps[1] = _sweep(20e6, address(0xB2), bytes32(uint256(2)));
        address first = _paymentAddress(sweeps[0]);
        address second = _paymentAddress(sweeps[1]);
        token.mint(first, 10e6);
        token.mint(second, 20e6);
        _execute(sweeps[0]);

        batchSweeper.executeBatch(sweeps);

        assertGt(second.code.length, 0);
        assertEq(token.balanceOf(address(0xB1)), 10e6);
        assertEq(token.balanceOf(address(0xB2)), 20e6);
    }

    function test_already_deployed_item_with_late_funds_recovers_them() public {
        BatchSweeper.Sweep[] memory sweeps = new BatchSweeper.Sweep[](1);
        sweeps[0] = _sweep(10e6, address(0xC1), bytes32(uint256(1)));
        address paymentAddress = _paymentAddress(sweeps[0]);
        token.mint(paymentAddress, 10e6);
        _execute(sweeps[0]);
        token.mint(paymentAddress, 7e6);

        batchSweeper.executeBatch(sweeps);

        assertEq(token.balanceOf(paymentAddress), 0);
        assertEq(token.balanceOf(address(0xCAFE)), 7e6, "late funds go to the recovery wallet");
        assertEq(token.balanceOf(address(0xC1)), 10e6, "the settled payment is untouched");
    }

    function test_paused_token_fails_every_item_until_unpaused() public {
        BatchSweeper.Sweep[] memory sweeps = new BatchSweeper.Sweep[](2);
        sweeps[0] = _sweep(10e6, address(0xE1), bytes32(uint256(1)));
        sweeps[1] = _sweep(20e6, address(0xE2), bytes32(uint256(2)));
        token.mint(_paymentAddress(sweeps[0]), 10e6);
        token.mint(_paymentAddress(sweeps[1]), 20e6);

        token.setPaused(true);
        vm.expectEmit(true, true, false, true, address(batchSweeper));
        emit SweepFailed(
            _paymentAddress(sweeps[0]),
            address(token),
            _callFailed(0, abi.encodeWithSignature("Error(string)", "Pausable: paused"))
        );
        vm.expectEmit(true, true, false, true, address(batchSweeper));
        emit SweepFailed(
            _paymentAddress(sweeps[1]),
            address(token),
            _callFailed(0, abi.encodeWithSignature("Error(string)", "Pausable: paused"))
        );
        batchSweeper.executeBatch(sweeps);
        assertEq(_paymentAddress(sweeps[0]).code.length, 0, "a paused token must leave no deployment behind");

        token.setPaused(false);
        batchSweeper.executeBatch(sweeps);
        assertEq(token.balanceOf(address(0xE1)), 10e6);
        assertEq(token.balanceOf(address(0xE2)), 20e6);
    }

    /// @notice Expiry is decided per item: an expired item holding more than
    /// its invoice amount recovers the whole balance and pays its receiver
    /// nothing, while the live items in the same batch settle as usual.
    function test_expired_overfunded_item_recovers_everything_while_siblings_settle() public {
        BatchSweeper.Sweep[] memory sweeps = new BatchSweeper.Sweep[](3);
        sweeps[0] = _sweep(10e6, address(0xE3), bytes32(uint256(1)));
        sweeps[1] = _sweep(20e6, address(0xE4), bytes32(uint256(2)));
        sweeps[2] = _sweep(30e6, address(0xE5), bytes32(uint256(3)));
        // Only the first item expires; its siblings keep the helper's one-day expiry.
        sweeps[0].expirationTimestamp = uint64(block.timestamp + 1 hours);
        address expired = _paymentAddress(sweeps[0]);
        token.mint(expired, 12e6);
        token.mint(_paymentAddress(sweeps[1]), 20e6);
        token.mint(_paymentAddress(sweeps[2]), 30e6);

        vm.warp(sweeps[0].expirationTimestamp + 1);
        vm.recordLogs();
        batchSweeper.executeBatch(sweeps);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(logs[i].topics[0] != SweepFailed.selector, "no item in the batch may fail");
        }

        assertGt(expired.code.length, 0);
        assertFalse(Payment(expired).SETTLED(), "the expired item must record a recovery, not a settlement");
        assertEq(token.balanceOf(address(0xE3)), 0, "an expired item never pays its receiver");
        assertEq(token.balanceOf(expired), 0, "an expired item must not strand its balance");
        assertEq(token.balanceOf(address(0xCAFE)), 12e6, "the expired item's whole balance goes to recovery");
        assertGt(_paymentAddress(sweeps[1]).code.length, 0);
        assertGt(_paymentAddress(sweeps[2]).code.length, 0);
        assertEq(token.balanceOf(address(0xE4)), 20e6);
        assertEq(token.balanceOf(address(0xE5)), 30e6);
    }

    function test_blacklisted_receiver_fails_only_its_item() public {
        BatchSweeper.Sweep[] memory sweeps = new BatchSweeper.Sweep[](2);
        sweeps[0] = _sweep(10e6, address(0xF1), bytes32(uint256(1)));
        sweeps[1] = _sweep(20e6, address(0xF2), bytes32(uint256(2)));
        token.mint(_paymentAddress(sweeps[0]), 10e6);
        token.mint(_paymentAddress(sweeps[1]), 20e6);
        token.setBlacklisted(address(0xF2), true);

        vm.expectEmit(true, true, false, true, address(batchSweeper));
        emit SweepFailed(
            _paymentAddress(sweeps[1]),
            address(token),
            _callFailed(0, abi.encodeWithSignature("Error(string)", "Blacklistable: account is blacklisted"))
        );
        batchSweeper.executeBatch(sweeps);

        assertEq(token.balanceOf(address(0xF1)), 10e6);
        assertEq(_paymentAddress(sweeps[1]).code.length, 0);
        assertEq(token.balanceOf(_paymentAddress(sweeps[1])), 20e6, "funds stay at the address for later recovery");
    }

    function test_failed_recovery_is_reported_with_the_token_revert() public {
        BatchSweeper.Sweep[] memory sweeps = new BatchSweeper.Sweep[](1);
        sweeps[0] = _sweep(10e6, address(0xF3), bytes32(uint256(1)));
        address paymentAddress = _paymentAddress(sweeps[0]);
        token.mint(paymentAddress, 10e6);
        _execute(sweeps[0]);
        token.mint(paymentAddress, 1e6);
        token.setBlacklisted(address(0xCAFE), true);

        vm.expectEmit(true, true, false, true, address(batchSweeper));
        emit SweepFailed(
            paymentAddress, address(token), abi.encodeWithSelector(SafeTransferLib.TransferFailed.selector)
        );
        batchSweeper.executeBatch(sweeps);
        assertEq(token.balanceOf(paymentAddress), 1e6);
    }

    /// @notice An item committed to another chain deploys (the guard is in the
    /// constructor) but moves nothing; its siblings settle. The item is then a
    /// deployed `Payment` whose balance the next batch forwards with `recover`.
    function test_item_for_another_chain_moves_nothing_and_settles_siblings() public {
        BatchSweeper.Sweep[] memory sweeps = new BatchSweeper.Sweep[](2);
        sweeps[0] = _sweep(10e6, address(0xF4), bytes32(uint256(1)));
        sweeps[1] = _sweep(20e6, address(0xF5), bytes32(uint256(2)));
        sweeps[0].chainId = block.chainid + 1;
        address wrongChain = _paymentAddress(sweeps[0]);
        token.mint(wrongChain, 10e6);
        token.mint(_paymentAddress(sweeps[1]), 20e6);

        vm.recordLogs();
        batchSweeper.executeBatch(sweeps);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(logs[i].topics[0] != SweepFailed.selector, "a wrong-chain item is not a failure");
        }

        assertGt(wrongChain.code.length, 0);
        assertFalse(Payment(wrongChain).SETTLED());
        assertEq(token.balanceOf(address(0xF4)), 0, "a wrong-chain item never pays its receiver");
        assertEq(token.balanceOf(wrongChain), 10e6);
        assertEq(token.balanceOf(address(0xF5)), 20e6);

        batchSweeper.executeBatch(sweeps);
        assertEq(token.balanceOf(address(0xCAFE)), 10e6, "the rescue returns the balance to the payer's wallet");
    }

    //---------- Settlement calls ----------//

    /// @notice An item whose action fails is reported and keeps its funds; its
    /// siblings settle, and a later batch settles it once the target recovers.
    function test_item_whose_call_fails_is_reported_and_settles_in_a_later_batch() public {
        Gate gate = new Gate();
        Payment.Call[] memory gated = new Payment.Call[](2);
        gated[0] = _transferCall(address(0xD1), 10e6);
        gated[1] = Payment.Call({target: address(gate), data: abi.encodeCall(Gate.pass, ())});
        BatchSweeper.Sweep[] memory sweeps = new BatchSweeper.Sweep[](2);
        sweeps[0] = _sweepWith(10e6, gated, bytes32(uint256(1)));
        sweeps[1] = _sweep(20e6, address(0xD2), bytes32(uint256(2)));
        address gatedPayment = _paymentAddress(sweeps[0]);
        token.mint(gatedPayment, 11e6);
        token.mint(_paymentAddress(sweeps[1]), 20e6);

        vm.expectEmit(true, true, false, true, address(batchSweeper));
        emit SweepFailed(
            gatedPayment, address(token), _callFailed(1, abi.encodeWithSignature("Error(string)", "closed"))
        );
        batchSweeper.executeBatch(sweeps);

        assertEq(gatedPayment.code.length, 0);
        assertEq(token.balanceOf(gatedPayment), 11e6, "the failed item keeps its whole balance");
        assertEq(token.balanceOf(address(0xD1)), 0);
        assertEq(token.balanceOf(address(0xD2)), 20e6, "the sibling settles");

        gate.setOpen(true);
        batchSweeper.executeBatch(sweeps);
        assertEq(gate.passes(), 1);
        assertEq(token.balanceOf(address(0xD1)), 10e6);
        assertEq(token.balanceOf(address(0xCAFE)), 1e6);
    }

    function test_multi_call_items_settle_in_one_batch() public {
        MockVault vault = new MockVault(address(token));
        Payment.Call[] memory deposit = new Payment.Call[](2);
        deposit[0] = Payment.Call({target: address(token), data: abi.encodeCall(ERC20.approve, (address(vault), 10e6))});
        deposit[1] =
            Payment.Call({target: address(vault), data: abi.encodeCall(ERC4626.deposit, (10e6, address(0xD3)))});
        Payment.Call[] memory split = new Payment.Call[](2);
        split[0] = _transferCall(address(0xD4), 19e6);
        split[1] = _transferCall(address(0xD5), 1e6);
        BatchSweeper.Sweep[] memory sweeps = new BatchSweeper.Sweep[](2);
        sweeps[0] = _sweepWith(10e6, deposit, bytes32(uint256(1)));
        sweeps[1] = _sweepWith(20e6, split, bytes32(uint256(2)));
        token.mint(_paymentAddress(sweeps[0]), 10e6);
        token.mint(_paymentAddress(sweeps[1]), 20e6);

        vm.recordLogs();
        batchSweeper.executeBatch(sweeps);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(logs[i].topics[0] != SweepFailed.selector, "no item may fail");
        }

        assertEq(vault.balanceOf(address(0xD3)), 10e6);
        assertEq(token.balanceOf(address(0xD4)), 19e6);
        assertEq(token.balanceOf(address(0xD5)), 1e6);
    }

    /// @notice Two items with identical calls but different salts are distinct
    /// payments: each settles from its own balance.
    function test_items_with_identical_calls_settle_independently() public {
        BatchSweeper.Sweep[] memory sweeps = new BatchSweeper.Sweep[](2);
        sweeps[0] = _sweep(10e6, address(0xD6), bytes32(uint256(1)));
        sweeps[1] = _sweep(10e6, address(0xD6), bytes32(uint256(2)));
        assertNotEq(_paymentAddress(sweeps[0]), _paymentAddress(sweeps[1]));
        token.mint(_paymentAddress(sweeps[0]), 10e6);

        vm.expectEmit(true, true, false, true, address(batchSweeper));
        emit SweepFailed(
            _paymentAddress(sweeps[1]),
            address(token),
            abi.encodeWithSelector(Payment.InsufficientTokenBalance.selector, 0, 10e6)
        );
        batchSweeper.executeBatch(sweeps);
        assertEq(token.balanceOf(address(0xD6)), 10e6, "only the funded item paid");

        token.mint(_paymentAddress(sweeps[1]), 10e6);
        batchSweeper.executeBatch(sweeps);
        assertEq(token.balanceOf(address(0xD6)), 20e6);
    }

    /// @notice An item whose init code would exceed EIP-3860's 49,152-byte
    /// limit has no derivable address at all: `paymentAddress` reverts, which
    /// reverts the whole batch rather than sweep items that cannot be named.
    function test_an_oversized_item_reverts_the_batch_with_init_code_too_large() public {
        BatchSweeper.Sweep[] memory sweeps = new BatchSweeper.Sweep[](2);
        sweeps[0] = _sweep(10e6, address(0xD7), bytes32(uint256(1)));
        sweeps[1] = _sweep(10e6, address(0xD7), bytes32(uint256(2)));
        sweeps[1].calls[0].data = abi.encodePacked(sweeps[1].calls[0].data, new bytes(49152));

        vm.expectRevert();
        batchSweeper.executeBatch(sweeps);
        assertEq(token.balanceOf(address(0xD7)), 0);
    }

    function _transferCall(address to, uint256 amount) private view returns (Payment.Call memory) {
        return Payment.Call({target: address(token), data: abi.encodeCall(ERC20.transfer, (to, amount))});
    }

    function _sweepWith(uint256 amount, Payment.Call[] memory calls, bytes32 salt)
        private
        view
        returns (BatchSweeper.Sweep memory sweep)
    {
        sweep = _sweep(amount, address(0), salt);
        sweep.calls = calls;
    }

    function _execute(BatchSweeper.Sweep memory sweep) private {
        factory.execute(
            sweep.token, sweep.amount, sweep.calls, sweep.expirationTimestamp, sweep.recovery, sweep.salt, sweep.chainId
        );
    }

    function _sweep(uint256 amount, address receiver, bytes32 salt) private view returns (BatchSweeper.Sweep memory) {
        Payment.Call[] memory calls = new Payment.Call[](1);
        calls[0] = Payment.Call({target: address(token), data: abi.encodeCall(ERC20.transfer, (receiver, amount))});
        return BatchSweeper.Sweep({
            token: address(token),
            amount: amount,
            calls: calls,
            expirationTimestamp: uint64(block.timestamp + 1 days),
            recovery: address(0xCAFE),
            salt: salt,
            chainId: block.chainid
        });
    }

    function _paymentAddress(BatchSweeper.Sweep memory sweep) private view returns (address) {
        return factory.paymentAddress(
            sweep.token, sweep.amount, sweep.calls, sweep.expirationTimestamp, sweep.recovery, sweep.salt, sweep.chainId
        );
    }

    function _callFailed(uint256 index, bytes memory revertData) private pure returns (bytes memory) {
        return abi.encodeWithSelector(Payment.CallFailed.selector, index, revertData);
    }
}
