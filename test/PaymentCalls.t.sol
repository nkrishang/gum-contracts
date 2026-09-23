// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Vm} from "lib/forge-std/src/Vm.sol";
import {stdError} from "lib/forge-std/src/StdError.sol";
import {ERC20} from "lib/solady/src/tokens/ERC20.sol";
import {ERC4626} from "lib/solady/src/tokens/ERC4626.sol";
import {SafeTransferLib} from "lib/solady/src/utils/SafeTransferLib.sol";
import {MockStablecoin} from "src/mock/MockStablecoin.sol";
import {Payment} from "src/Payment.sol";
import {PaymentFactory} from "src/PaymentFactory.sol";
import {ITokenMessengerV2} from "src/WithdrawalForwarder.sol";
import {BubblingCREATE3} from "src/utils/BubblingCREATE3.sol";
import {MockTokenMessenger} from "test/WithdrawalForwarder.t.sol";
import {
    AuthenticatedOrderBook,
    Boomerang,
    Checkout,
    FalseReturningToken,
    Gate,
    GasBurner,
    MockVault,
    OpenSpender,
    OrderBook,
    PaymentCallsBase,
    Reentrant,
    Reverter
} from "test/utils/SettlementFixtures.sol";

/// @notice Settlement calls: what a payment may do on settlement, and every way
/// the constructor holds it to exactly the committed calls and exactly `amount`.
contract PaymentCallsTest is PaymentCallsBase {
    MockVault internal vault;
    Gate internal gate;
    Reverter internal reverter;

    function setUp() public override {
        super.setUp();
        vault = new MockVault(address(token));
        gate = new Gate();
        reverter = new Reverter();
    }

    //---------- Commitment ----------//

    /// @notice The address is the documented hash of the terms, so gum-server
    /// can derive it without calling the factory.
    function test_address_derivation_matches_the_documented_formula() public view {
        Payment.Call[] memory calls = _list(_approve(address(vault), 10e6), _call(address(vault), hex"c0ffee"));
        bytes32 salt = keccak256(abi.encode(address(token), 10e6, calls, expiry, RECOVERY, SALT, block.chainid));
        assertEq(_address(10e6, calls), BubblingCREATE3.predictDeterministicAddress(salt, address(factory)));
    }

    /// @notice A fixed vector for other implementations of the derivation,
    /// cross-checked with `cast abi-encode` + `cast keccak`. The CREATE3 salt
    /// depends only on the terms; the address then depends on the factory.
    function test_deployment_salt_vector() public view {
        Payment.Call[] memory calls = new Payment.Call[](2);
        calls[0] = Payment.Call({
            target: 0x1111111111111111111111111111111111111111,
            data: abi.encodeWithSignature("transfer(address,uint256)", address(0xBEEF), uint256(10e6))
        });
        calls[1] = Payment.Call({target: 0x2222222222222222222222222222222222222222, data: hex"01"});
        bytes32 salt = keccak256(
            abi.encode(
                0x1111111111111111111111111111111111111111,
                uint256(10e6),
                calls,
                uint64(1_700_000_000),
                address(0xCAFE),
                bytes32(uint256(7)),
                uint256(8453)
            )
        );
        assertEq(salt, 0x3ef67ee909666dc854602dc4af5e8bf318c0737e8653d1659d0b51259f339799, "salt vector");
        assertEq(
            factory.paymentAddress(
                0x1111111111111111111111111111111111111111,
                10e6,
                calls,
                1_700_000_000,
                address(0xCAFE),
                bytes32(uint256(7)),
                8453
            ),
            BubblingCREATE3.predictDeterministicAddress(salt, address(factory)),
            "the factory uses exactly this salt"
        );
    }

    /// @notice Every target, every byte of calldata, their order and their count
    /// are committed, so no executor can alter what a payment does.
    function test_address_commits_to_every_call_field() public view {
        Payment.Call[] memory calls = _list(_transfer(MERCHANT, 10e6), _call(address(gate), hex"01"));
        address committed = _address(10e6, calls);

        assertNotEq(_address(10e6, _list(_transfer(PLATFORM, 10e6), calls[1])), committed, "the recipient in calldata");
        assertNotEq(_address(10e6, _list(calls[0], _call(address(vault), hex"01"))), committed, "a target");
        assertNotEq(_address(10e6, _list(calls[0], _call(address(gate), hex"02"))), committed, "a calldata byte");
        assertNotEq(_address(10e6, _list(calls[0], _call(address(gate), ""))), committed, "calldata length");
        assertNotEq(_address(10e6, _list(calls[1], calls[0])), committed, "the order");
        assertNotEq(_address(10e6, _list(calls[0])), committed, "a dropped call");
        assertNotEq(_address(10e6, _list(calls[0], calls[1], calls[1])), committed, "a repeated call");
        assertNotEq(_address(10e6, _list()), _address(10e6, _list(_call(address(gate), ""))), "an empty call");
    }

    /// @notice An executor that submits different calls deploys a different,
    /// empty payment; the funded one is untouched and still settles as committed.
    function test_executing_other_calls_cannot_touch_a_funded_payment() public {
        Payment.Call[] memory calls = _list(_transfer(MERCHANT, 10e6));
        address payment = _fund(10e6, calls, 10e6);
        Payment.Call[] memory redirected = _list(_transfer(address(0xBAD), 10e6));

        vm.expectRevert(abi.encodeWithSelector(Payment.InsufficientTokenBalance.selector, 0, 10e6));
        _execute(10e6, redirected);
        assertEq(token.balanceOf(payment), 10e6);
        assertEq(payment.code.length, 0);

        _execute(10e6, calls);
        assertEq(token.balanceOf(MERCHANT), 10e6);
        assertEq(token.balanceOf(address(0xBAD)), 0);
    }

    //---------- Settlement shapes ----------//

    function test_single_transfer_is_a_plain_payment() public {
        Payment.Call[] memory calls = _list(_transfer(MERCHANT, 10e6));
        address payment = _fund(10e6, calls, 10e6);

        _execute(10e6, calls);

        assertEq(token.balanceOf(MERCHANT), 10e6);
        assertEq(token.balanceOf(RECOVERY), 0);
        assertEq(token.balanceOf(payment), 0);
        assertTrue(Payment(payment).SETTLED());
    }

    function test_calls_split_the_amount_between_recipients() public {
        Payment.Call[] memory calls =
            _list(_transfer(MERCHANT, 9.7e6), _transfer(PLATFORM, 0.25e6), _transfer(address(0xA11CE), 0.05e6));
        _fund(10e6, calls, 10e6);

        _execute(10e6, calls);

        assertEq(token.balanceOf(MERCHANT), 9.7e6);
        assertEq(token.balanceOf(PLATFORM), 0.25e6);
        assertEq(token.balanceOf(address(0xA11CE)), 0.05e6);
    }

    function test_approve_and_deposit_settles_into_a_vault() public {
        Payment.Call[] memory calls = _list(
            _approve(address(vault), 10e6), _call(address(vault), abi.encodeCall(ERC4626.deposit, (10e6, MERCHANT)))
        );
        address payment = _fund(10e6, calls, 10e6);

        _execute(10e6, calls);

        assertEq(vault.balanceOf(MERCHANT), 10e6, "the merchant holds the shares");
        assertEq(vault.totalAssets(), 10e6);
        assertEq(token.allowance(payment, address(vault)), 0, "an exact approval is fully used");
        assertTrue(Payment(payment).SETTLED());
    }

    /// @notice A merchant contract that pulls its price learns it was paid
    /// from the pull itself, and records the payment address as the payer.
    function test_pull_based_checkout_records_the_payment_as_payer() public {
        Checkout checkout = new Checkout(address(token), MERCHANT);
        bytes32 orderId = keccak256("order-1");
        Payment.Call[] memory calls = _list(
            _approve(address(checkout), 10e6), _call(address(checkout), abi.encodeCall(Checkout.pay, (orderId, 10e6)))
        );
        address payment = _fund(10e6, calls, 10e6);

        vm.expectEmit(true, true, true, true, address(checkout));
        emit Checkout.OrderPaid(orderId, payment, 10e6);
        _execute(10e6, calls);

        assertEq(checkout.paidBy(orderId), payment);
        assertEq(token.balanceOf(MERCHANT), 10e6, "the checkout forwarded the price to its treasury");
    }

    function test_transfer_then_notify_a_merchant_contract() public {
        OrderBook book = new OrderBook();
        bytes32 orderId = keccak256("order-2");
        Payment.Call[] memory calls =
            _list(_transfer(MERCHANT, 10e6), _call(address(book), abi.encodeCall(OrderBook.markPaid, (orderId))));
        address payment = _fund(10e6, calls, 10e6);

        _execute(10e6, calls);

        assertEq(book.notifiedBy(orderId), payment, "the target sees the payment address as the caller");
        assertEq(token.balanceOf(MERCHANT), 10e6);
    }

    /// @notice A call that moves no tokens may come before the transfer.
    function test_notify_may_precede_the_transfer() public {
        OrderBook book = new OrderBook();
        bytes32 orderId = keccak256("order-3");
        Payment.Call[] memory calls =
            _list(_call(address(book), abi.encodeCall(OrderBook.markPaid, (orderId))), _transfer(MERCHANT, 10e6));
        address payment = _fund(10e6, calls, 10e6);

        _execute(10e6, calls);

        assertEq(book.notifiedBy(orderId), payment);
        assertEq(token.balanceOf(MERCHANT), 10e6);
    }

    /// @notice Settling straight into a CCTP burn: approve the messenger and
    /// burn towards a recipient on another chain.
    function test_approve_and_cctp_burn_settles_cross_chain() public {
        MockTokenMessenger messenger = new MockTokenMessenger();
        bytes32 recipient = bytes32(uint256(uint160(MERCHANT)));
        Payment.Call[] memory calls = _list(
            _approve(address(messenger), 10e6),
            _call(
                address(messenger),
                abi.encodeCall(
                    ITokenMessengerV2.depositForBurn, (10e6, 3, recipient, address(token), bytes32(0), 0, 2000)
                )
            )
        );
        address payment = _fund(10e6, calls, 10e6);

        vm.expectEmit(true, true, true, true, address(messenger));
        emit MockTokenMessenger.DepositForBurn(10e6, 3, recipient, address(token));
        _execute(10e6, calls);

        assertEq(token.balanceOf(address(messenger)), 10e6);
        assertEq(token.balanceOf(payment), 0);
    }

    /// @notice A merchant contract can authenticate a notification by rebuilding
    /// the committed calls and checking that the factory derives the caller.
    function test_authenticated_order_book_accepts_a_genuine_payment() public {
        AuthenticatedOrderBook book = new AuthenticatedOrderBook(factory, MERCHANT, 10e6);
        bytes32 orderId = keccak256("order-4");
        Payment.Call[] memory previous = _list(_transfer(MERCHANT, 10e6));
        Payment.Call[] memory calls = _list(
            previous[0],
            _call(
                address(book),
                abi.encodeCall(
                    AuthenticatedOrderBook.markPaid, (orderId, address(token), 10e6, previous, expiry, RECOVERY, SALT)
                )
            )
        );
        address payment = _fund(10e6, calls, 10e6);

        _execute(10e6, calls);

        assertEq(book.paidBy(orderId), payment);
    }

    function test_authenticated_order_book_rejects_a_spoofed_caller() public {
        AuthenticatedOrderBook book = new AuthenticatedOrderBook(factory, MERCHANT, 10e6);
        Payment.Call[] memory previous = _list(_transfer(MERCHANT, 10e6));

        vm.expectRevert("not a genuine payment");
        vm.prank(address(0xBAD));
        book.markPaid(keccak256("order-5"), address(token), 10e6, previous, expiry, RECOVERY, SALT);
    }

    /// @notice A genuine payment whose earlier calls don't pay the merchant is
    /// caught too, because the book can trust the calls it rebuilt.
    function test_authenticated_order_book_rejects_a_payment_that_underpays() public {
        AuthenticatedOrderBook book = new AuthenticatedOrderBook(factory, MERCHANT, 10e6);
        bytes32 orderId = keccak256("order-6");
        Payment.Call[] memory previous = _list(_transfer(PLATFORM, 10e6));
        Payment.Call[] memory calls = _list(
            previous[0],
            _call(
                address(book),
                abi.encodeCall(
                    AuthenticatedOrderBook.markPaid, (orderId, address(token), 10e6, previous, expiry, RECOVERY, SALT)
                )
            )
        );
        address payment = _fund(10e6, calls, 10e6);

        vm.expectRevert(_callFailed(1, abi.encodeWithSignature("Error(string)", "does not pay the merchant")));
        _execute(10e6, calls);
        assertEq(token.balanceOf(payment), 10e6);
    }

    /// @notice Payments compose: one payment can fund another payment's
    /// address and execute it from within its own constructor.
    function test_a_payment_can_fund_and_execute_another_payment() public {
        Payment.Call[] memory innerCalls = _list(_transfer(MERCHANT, 10e6));
        bytes32 innerSalt = keccak256("inner");
        address inner =
            factory.paymentAddress(address(token), 10e6, innerCalls, expiry, RECOVERY, innerSalt, block.chainid);
        Payment.Call[] memory outerCalls = _list(
            _transfer(inner, 10e6),
            _call(
                address(factory),
                abi.encodeCall(
                    PaymentFactory.execute,
                    (address(token), 10e6, innerCalls, expiry, RECOVERY, innerSalt, block.chainid)
                )
            )
        );
        address outer = _fund(10e6, outerCalls, 10e6);

        _execute(10e6, outerCalls);

        assertTrue(Payment(outer).SETTLED());
        assertTrue(Payment(inner).SETTLED());
        assertEq(token.balanceOf(MERCHANT), 10e6);
    }

    /// @notice A zero amount settles with calls that move no tokens; the whole
    /// balance is excess and goes to recovery first.
    function test_zero_amount_payment_runs_its_calls_and_recovers_the_balance() public {
        OrderBook book = new OrderBook();
        bytes32 orderId = keccak256("order-7");
        Payment.Call[] memory calls = _list(_call(address(book), abi.encodeCall(OrderBook.markPaid, (orderId))));
        address payment = _fund(0, calls, 5e6);

        _execute(0, calls);

        assertEq(book.notifiedBy(orderId), payment);
        assertEq(token.balanceOf(RECOVERY), 5e6);
        assertTrue(Payment(payment).SETTLED());
    }

    /// @notice Calls run with the payment's full authority, by design: only
    /// the committed token is metered against `amount`.
    function test_calls_may_move_other_tokens_held_by_the_address() public {
        MockStablecoin other = new MockStablecoin("Mock Tether", "USDT");
        Payment.Call[] memory calls =
            _list(_transfer(MERCHANT, 10e6), _call(address(other), abi.encodeCall(ERC20.transfer, (PLATFORM, 3e6))));
        address payment = _fund(10e6, calls, 10e6);
        other.mint(payment, 3e6);

        _execute(10e6, calls);

        assertEq(other.balanceOf(PLATFORM), 3e6);
        assertEq(token.balanceOf(MERCHANT), 10e6);
    }

    //---------- Exact spend ----------//

    function test_underspending_reverts_with_amount_not_spent() public {
        _fundDirect(10e6);
        vm.expectRevert(abi.encodeWithSelector(Payment.AmountNotSpent.selector, 1));
        _deployDirect(10e6, _list(_transfer(MERCHANT, 10e6 - 1)));
    }

    function test_no_calls_cannot_settle_a_nonzero_amount() public {
        _fundDirect(10e6);
        vm.expectRevert(abi.encodeWithSelector(Payment.AmountNotSpent.selector, 10e6));
        _deployDirect(10e6, _list());
    }

    /// @notice An approval alone moves nothing: the spender must pull.
    function test_an_approval_that_is_never_pulled_leaves_the_amount_unspent() public {
        _fundDirect(10e6);
        vm.expectRevert(abi.encodeWithSelector(Payment.AmountNotSpent.selector, 10e6));
        _deployDirect(10e6, _list(_approve(address(vault), 10e6)));
    }

    /// @notice The excess has already left for recovery when the calls run, so
    /// no call can spend more than `amount`.
    function test_calls_cannot_spend_the_excess() public {
        _fundDirect(12e6);
        vm.expectRevert(_callFailed(0, abi.encodeWithSelector(ERC20.InsufficientBalance.selector)));
        _deployDirect(10e6, _list(_transfer(MERCHANT, 10e6 + 1)));
    }

    /// @notice Tokens that come back to the payment during the calls count as unspent.
    function test_tokens_returned_to_the_payment_count_as_unspent() public {
        Boomerang boomerang = new Boomerang();
        _fundDirect(10e6);
        vm.expectRevert(abi.encodeWithSelector(Payment.AmountNotSpent.selector, 10e6));
        _deployDirect(
            10e6,
            _list(
                _approve(address(boomerang), 10e6),
                _call(address(boomerang), abi.encodeCall(Boomerang.bounce, (address(token), 10e6)))
            )
        );
    }

    /// @notice A transfer that returns `false` without reverting is a successful
    /// call that moved nothing; the spend check catches it.
    function test_a_silently_failing_transfer_is_caught_by_the_spend_check() public {
        FalseReturningToken falseToken = new FalseReturningToken();
        falseToken.setFailSilently(true);
        address predicted = vm.computeCreateAddress(address(directDeployer), vm.getNonce(address(directDeployer)));
        falseToken.mint(predicted, 10e6);
        Payment.Call[] memory calls =
            _list(_call(address(falseToken), abi.encodeCall(ERC20.transfer, (MERCHANT, 10e6))));

        vm.expectRevert(abi.encodeWithSelector(Payment.AmountNotSpent.selector, 10e6));
        directDeployer.deploy(address(falseToken), 10e6, calls, expiry, RECOVERY, block.chainid);
    }

    //---------- Failures ----------//

    /// @notice A failing call reverts the whole deployment: earlier calls and
    /// the excess roll back, and a later attempt settles once the target recovers.
    function test_a_failed_call_reverts_everything_and_is_retryable() public {
        Payment.Call[] memory calls =
            _list(_transfer(MERCHANT, 10e6), _call(address(gate), abi.encodeCall(Gate.pass, ())));
        address payment = _fund(10e6, calls, 12e6);

        vm.expectRevert(_callFailed(1, abi.encodeWithSignature("Error(string)", "closed")));
        _execute(10e6, calls);
        assertEq(payment.code.length, 0);
        assertEq(token.balanceOf(payment), 12e6, "the earlier transfer and the excess roll back");
        assertEq(token.balanceOf(MERCHANT), 0);
        assertEq(token.balanceOf(RECOVERY), 0);

        gate.setOpen(true);
        _execute(10e6, calls);
        assertEq(gate.passes(), 1);
        assertEq(token.balanceOf(MERCHANT), 10e6);
        assertEq(token.balanceOf(RECOVERY), 2e6);
    }

    /// @notice An action that never succeeds keeps the funds at the address
    /// until expiry, and the expiry path then refunds them all.
    function test_a_permanently_failing_action_is_refunded_after_expiry() public {
        Payment.Call[] memory calls =
            _list(_transfer(MERCHANT, 10e6), _call(address(gate), abi.encodeCall(Gate.pass, ())));
        address payment = _fund(10e6, calls, 10e6);

        vm.expectRevert(_callFailed(1, abi.encodeWithSignature("Error(string)", "closed")));
        _execute(10e6, calls);

        vm.warp(expiry + 1);
        _execute(10e6, calls);
        assertEq(token.balanceOf(RECOVERY), 10e6);
        assertEq(token.balanceOf(MERCHANT), 0);
        assertFalse(Payment(payment).SETTLED());
    }

    /// @notice A failing call reports its index, with the target's own revert
    /// data unchanged inside.
    function test_a_failed_call_reports_its_index_and_revert_data() public {
        Payment.Call memory pay = _transfer(MERCHANT, 10e6);

        _fundDirect(10e6);
        vm.expectRevert(_callFailed(1, abi.encodeWithSelector(Reverter.Refused.selector, 42)));
        _deployDirect(10e6, _list(pay, _call(address(reverter), abi.encodeCall(Reverter.customError, ()))));

        _fundDirect(10e6);
        vm.expectRevert(_callFailed(1, abi.encodeWithSignature("Error(string)", "refused")));
        _deployDirect(10e6, _list(pay, _call(address(reverter), abi.encodeCall(Reverter.stringError, ()))));

        _fundDirect(10e6);
        vm.expectRevert(_callFailed(1, stdError.divisionError));
        _deployDirect(10e6, _list(pay, _call(address(reverter), abi.encodeCall(Reverter.panic, (0)))));

        _fundDirect(10e6);
        vm.expectRevert(_callFailed(1, ""));
        _deployDirect(10e6, _list(pay, _call(address(reverter), abi.encodeCall(Reverter.empty, ()))));
    }

    /// @notice A call to an address without code succeeds and does nothing, so
    /// an EOA, a precompile or the zero address must fail loudly instead.
    function test_a_call_to_an_address_without_code_reverts() public {
        address[3] memory codeless = [address(0xE0A), address(0x04), address(0)];
        for (uint256 i; i < codeless.length; ++i) {
            _fundDirect(10e6);
            vm.expectRevert(abi.encodeWithSelector(Payment.CallTargetHasNoCode.selector, 1, codeless[i]));
            _deployDirect(10e6, _list(_transfer(MERCHANT, 10e6), _call(codeless[i], "")));
        }

        // Calldata makes no difference to an address without code: it still returns nothing.
        _fundDirect(10e6);
        vm.expectRevert(abi.encodeWithSelector(Payment.CallTargetHasNoCode.selector, 1, address(0xE0A)));
        _deployDirect(
            10e6,
            _list(_transfer(MERCHANT, 10e6), _call(address(0xE0A), abi.encodeCall(ERC20.transfer, (MERCHANT, 10e6))))
        );
    }

    /// @notice Calls run inside the constructor, before the payment has code,
    /// so a high-level call back into it reverts with no data.
    function test_a_call_cannot_call_back_into_the_payment() public {
        Reentrant reentrant = new Reentrant();
        _fundDirect(10e6);
        vm.expectRevert(_callFailed(1, ""));
        _deployDirect(
            10e6,
            _list(
                _transfer(MERCHANT, 10e6),
                _call(address(reentrant), abi.encodeCall(Reentrant.recoverFromCaller, (address(token))))
            )
        );
    }

    function test_a_blacklisted_recipient_reverts_the_deployment_until_cleared() public {
        Payment.Call[] memory calls = _list(_transfer(MERCHANT, 10e6));
        address payment = _fund(10e6, calls, 10e6);
        token.setBlacklisted(MERCHANT, true);

        vm.expectRevert(
            _callFailed(0, abi.encodeWithSignature("Error(string)", "Blacklistable: account is blacklisted"))
        );
        _execute(10e6, calls);
        assertEq(token.balanceOf(payment), 10e6);

        token.setBlacklisted(MERCHANT, false);
        _execute(10e6, calls);
        assertEq(token.balanceOf(MERCHANT), 10e6);
    }

    /// @notice Too little gas for a call reverts the deployment rather than
    /// skipping the call, so an executor cannot settle a payment without its action.
    function test_too_little_gas_reverts_instead_of_skipping_a_call() public {
        GasBurner burner = new GasBurner();
        Payment.Call[] memory calls =
            _list(_transfer(MERCHANT, 10e6), _call(address(burner), abi.encodeCall(GasBurner.burn, (1_000_000))));
        address payment = _fund(10e6, calls, 10e6);

        for (uint256 gasLimit = 400_000; gasLimit <= 1_200_000; gasLimit += 100_000) {
            try factory.execute{gas: gasLimit}(address(token), 10e6, calls, expiry, RECOVERY, SALT, block.chainid) {
                revert("settled without enough gas for its action");
            } catch {}
            assertEq(payment.code.length, 0);
            assertEq(token.balanceOf(payment), 10e6);
        }

        _execute(10e6, calls);
        assertTrue(Payment(payment).SETTLED());
    }

    //---------- Events ----------//

    /// @notice The full log of an overpaid, multi-call settlement: the excess
    /// leaves first, each call is reported in order with its context, and
    /// settlement is reported last.
    function test_event_sequence_of_an_overpaid_multi_call_settlement() public {
        OrderBook book = new OrderBook();
        Payment.Call[] memory calls = _list(
            _approve(address(vault), 10e6),
            _call(address(vault), abi.encodeCall(ERC4626.deposit, (10e6, MERCHANT))),
            _call(address(book), abi.encodeCall(OrderBook.markPaid, (keccak256("order-8"))))
        );
        address payment = _fund(10e6, calls, 13e6);

        vm.recordLogs();
        _execute(10e6, calls);
        Vm.Log[] memory logs = _logsFrom(vm.getRecordedLogs(), payment);

        assertEq(logs.length, 5);
        assertEq(logs[0].topics[0], Recovered.selector);
        assertEq(logs[0].topics[1], bytes32(uint256(uint160(RECOVERY))));
        assertEq(logs[0].topics[2], bytes32(uint256(uint160(address(token)))));
        assertEq(abi.decode(logs[0].data, (uint256)), 3e6);

        bytes[3] memory results = [abi.encode(true), abi.encode(uint256(10e6)), abi.encode(true)];
        for (uint256 i; i < 3; ++i) {
            Vm.Log memory log = logs[1 + i];
            assertEq(log.topics[0], Called.selector);
            assertEq(uint256(log.topics[1]), i, "index");
            assertEq(log.topics[2], bytes32(uint256(uint160(calls[i].target))), "target");
            (bytes memory data, bytes memory result) = abi.decode(log.data, (bytes, bytes));
            assertEq(data, calls[i].data, "calldata");
            assertEq(result, results[i], "return data");
        }

        assertEq(logs[4].topics[0], Settled.selector);
        assertEq(logs[4].topics[1], bytes32(uint256(uint160(address(token)))));
        assertEq(abi.decode(logs[4].data, (uint256)), 10e6);
    }

    function test_a_call_with_no_return_value_reports_an_empty_result() public {
        gate.setOpen(true);
        Payment.Call[] memory calls =
            _list(_transfer(MERCHANT, 10e6), _call(address(gate), abi.encodeCall(Gate.pass, ())));
        address payment = _fund(10e6, calls, 10e6);

        vm.expectEmit(true, true, true, true, payment);
        emit Called(1, address(gate), calls[1].data, "");
        _execute(10e6, calls);
    }

    function test_a_view_call_reports_its_result() public {
        Payment.Call[] memory calls =
            _list(_call(address(token), abi.encodeCall(ERC20.balanceOf, (MERCHANT))), _transfer(MERCHANT, 10e6));
        token.mint(MERCHANT, 1e6);
        address payment = _fund(10e6, calls, 10e6);

        vm.expectEmit(true, true, true, true, payment);
        emit Called(0, address(token), calls[0].data, abi.encode(uint256(1e6)));
        _execute(10e6, calls);
    }

    //---------- Paths that run no calls ----------//

    /// @notice Expiry is checked before the calls, which are neither run nor
    /// validated: even calls that could never succeed let the refund through.
    function test_an_expired_payment_runs_no_calls_even_invalid_ones() public {
        gate.setOpen(true);
        Payment.Call[] memory calls = _list(
            _call(address(gate), abi.encodeCall(Gate.pass, ())),
            _call(address(0xE0A), ""),
            _call(address(reverter), abi.encodeCall(Reverter.customError, ()))
        );
        address payment = _fund(10e6, calls, 10e6);

        vm.warp(expiry + 1);
        vm.recordLogs();
        _execute(10e6, calls);
        Vm.Log[] memory logs = _logsFrom(vm.getRecordedLogs(), payment);

        assertEq(gate.passes(), 0);
        assertEq(logs.length, 1);
        assertEq(logs[0].topics[0], Recovered.selector);
        assertEq(token.balanceOf(RECOVERY), 10e6);
        assertFalse(Payment(payment).SETTLED());
    }

    function test_the_expiration_boundary_still_runs_the_calls() public {
        gate.setOpen(true);
        Payment.Call[] memory calls =
            _list(_transfer(MERCHANT, 10e6), _call(address(gate), abi.encodeCall(Gate.pass, ())));
        _fund(10e6, calls, 10e6);

        vm.warp(expiry);
        _execute(10e6, calls);
        assertEq(gate.passes(), 1);
        assertEq(token.balanceOf(MERCHANT), 10e6);
    }

    function test_a_wrong_chain_payment_runs_no_calls_even_invalid_ones() public {
        gate.setOpen(true);
        Payment.Call[] memory calls =
            _list(_call(address(gate), abi.encodeCall(Gate.pass, ())), _call(address(0xE0A), ""));
        uint256 otherChain = block.chainid + 1;
        address payment = factory.paymentAddress(address(token), 10e6, calls, expiry, RECOVERY, SALT, otherChain);
        token.mint(payment, 10e6);

        factory.execute(address(token), 10e6, calls, expiry, RECOVERY, SALT, otherChain);

        assertEq(gate.passes(), 0);
        assertEq(token.balanceOf(payment), 10e6);
        assertFalse(Payment(payment).SETTLED());
        assertEq(Payment(payment).recover(address(token)), 10e6);
    }

    /// @notice The balance check comes before the calls: an underfunded payment
    /// reports its shortfall, not a problem with its calls.
    function test_underfunding_is_reported_before_any_call_is_checked() public {
        _fundDirect(10e6 - 1);
        vm.expectRevert(abi.encodeWithSelector(Payment.InsufficientTokenBalance.selector, 10e6 - 1, 10e6));
        _deployDirect(10e6, _list(_call(address(0xE0A), "")));
    }

    //---------- After settlement ----------//

    function test_late_funds_go_to_recovery_not_through_the_calls() public {
        Payment.Call[] memory calls = _list(_transfer(MERCHANT, 10e6));
        address payment = _fund(10e6, calls, 10e6);
        _execute(10e6, calls);

        token.mint(payment, 4e6);
        assertEq(Payment(payment).recover(address(token)), 4e6);
        assertEq(token.balanceOf(RECOVERY), 4e6);
        assertEq(token.balanceOf(MERCHANT), 10e6);
    }

    /// @notice Pins why approvals in the calls should be exact: an approval the
    /// spender does not fully use outlives settlement, and a spender that
    /// anyone can drive can take late funds before `recover` sweeps them.
    function test_an_unused_approval_outlives_settlement() public {
        OpenSpender spender = new OpenSpender();
        Payment.Call[] memory calls = _list(
            _approve(address(spender), 15e6),
            _call(address(spender), abi.encodeCall(OpenSpender.pull, (address(token), MERCHANT, 10e6)))
        );
        address payment = _fund(10e6, calls, 10e6);
        _execute(10e6, calls);
        assertEq(token.allowance(payment, address(spender)), 5e6, "the unused approval survives");

        token.mint(payment, 5e6);
        vm.prank(address(0xBAD));
        spender.pullFrom(address(token), payment, address(0xBAD), 5e6);
        assertEq(token.balanceOf(address(0xBAD)), 5e6, "late funds were taken before recovery");
        assertEq(Payment(payment).recover(address(token)), 0);
    }

    function test_an_exact_approval_leaves_nothing_to_pull_after_settlement() public {
        OpenSpender spender = new OpenSpender();
        Payment.Call[] memory calls = _list(
            _approve(address(spender), 10e6),
            _call(address(spender), abi.encodeCall(OpenSpender.pull, (address(token), MERCHANT, 10e6)))
        );
        address payment = _fund(10e6, calls, 10e6);
        _execute(10e6, calls);
        assertEq(token.allowance(payment, address(spender)), 0);

        token.mint(payment, 5e6);
        vm.expectRevert(SafeTransferLib.TransferFromFailed.selector);
        spender.pullFrom(address(token), payment, address(0xBAD), 5e6);
        assertEq(Payment(payment).recover(address(token)), 5e6);
    }

    function _callFailed(uint256 index, bytes memory revertData) private pure returns (bytes memory) {
        return abi.encodeWithSelector(Payment.CallFailed.selector, index, revertData);
    }
}
