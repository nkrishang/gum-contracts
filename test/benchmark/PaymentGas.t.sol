// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test} from "lib/forge-std/src/Test.sol";
import {Vm} from "lib/forge-std/src/Vm.sol";
import {console2} from "lib/forge-std/src/console2.sol";
import {ERC20} from "lib/solady/src/tokens/ERC20.sol";
import {MockStablecoin} from "src/mock/MockStablecoin.sol";
import {Payment} from "src/Payment.sol";
import {PaymentFactory} from "src/PaymentFactory.sol";
import {LegacyPayment} from "test/benchmark/legacy/LegacyPayment.sol";
import {LegacyPaymentFactory} from "test/benchmark/legacy/LegacyPaymentFactory.sol";

/// @notice Gas cost of the same job, paying `amount` of a stablecoin to a
/// receiver on settlement, under the previous generation (`receiver`) and the
/// current one (a single committed `transfer` call).
///
/// The suites run in isolation mode, so every top-level call is its own
/// transaction: funding commits before `execute`, which then pays real
/// cold-access and storage costs, and `vm.lastCallGas` reports what the sender
/// pays. Each scenario measures both generations from the same state snapshot.
/// Run with `-vv` to print the comparison.
abstract contract PaymentGasBenchmark is Test {
    struct Measurement {
        uint256 transaction; // gas the sender pays: 21000 + calldata + execution - refund
        uint256 execution; // execution before the refund
        uint256 refund; // gas refunded
        uint256 calldataBytes; // length of the `execute` transaction's input
        uint256 calldataGas; // 4 per zero byte, 16 per nonzero byte
    }

    /// @dev Fresh addresses, so a live chain can't have funded them already.
    address internal receiver;
    address internal recovery;
    bytes32 internal constant SALT = keccak256("gas-benchmark");

    address internal token;
    uint256 internal amount;
    LegacyPaymentFactory internal legacyFactory;
    PaymentFactory internal factory;
    uint64 internal expiry;

    /// @dev Runs at the start of each scenario; returns false to skip it.
    function _prepare() internal virtual returns (bool);

    /// @dev Credits `account` with `value` of the token, on top of its balance.
    function _credit(address account, uint256 value) internal virtual;

    function _deployFactories() internal {
        receiver = makeAddr("gum-benchmark-receiver");
        recovery = makeAddr("gum-benchmark-recovery");
        legacyFactory = new LegacyPaymentFactory();
        factory = new PaymentFactory();
        expiry = uint64(block.timestamp + 1 hours);
    }

    //---------- Scenarios ----------//

    /// @notice The common case: exact funding, paid to a merchant that already
    /// holds the token.
    function test_gas_exact_payment_to_an_existing_holder() public {
        if (!_prepare()) return;
        _credit(receiver, 1);
        _compare("exact payment, receiver already holds the token", amount);
    }

    /// @notice A merchant's first payment: the receiver's balance goes from zero.
    function test_gas_exact_payment_to_a_new_holder() public {
        if (!_prepare()) return;
        assertEq(ERC20(token).balanceOf(receiver), 0);
        _compare("exact payment, receiver holds none of the token", amount);
    }

    /// @notice An overpayment: the excess also leaves for recovery.
    function test_gas_overpayment_with_excess_to_recovery() public {
        if (!_prepare()) return;
        _credit(receiver, 1);
        _credit(recovery, 1);
        _compare("overpayment, excess to recovery", amount + 1);
    }

    //---------- Measurement ----------//

    function _compare(string memory scenario, uint256 funding) internal {
        uint256 snapshot = vm.snapshotState();
        Measurement memory legacy = _measureLegacy(funding);
        vm.revertToState(snapshot);
        Measurement memory current = _measureCurrent(funding);

        console2.log("");
        console2.log(scenario);
        console2.log("                        legacy      current        delta");
        _row("transaction total", legacy.transaction, current.transaction);
        _row("  execution", legacy.execution, current.execution);
        _row("  refund", legacy.refund, current.refund);
        _row("  calldata gas", legacy.calldataGas, current.calldataGas);
        _row("calldata bytes", legacy.calldataBytes, current.calldataBytes);
        console2.log(
            string.concat(
                "  overhead: +",
                _percent(current.transaction - legacy.transaction, legacy.transaction),
                " of the legacy transaction"
            )
        );
    }

    function _measureLegacy(uint256 funding) internal returns (Measurement memory m) {
        address payment = legacyFactory.paymentAddress(token, amount, receiver, expiry, recovery, SALT, block.chainid);
        _credit(payment, funding);
        uint256 receiverBefore = ERC20(token).balanceOf(receiver);

        m = _measure(
            address(legacyFactory),
            abi.encodeCall(
                LegacyPaymentFactory.execute, (token, amount, receiver, expiry, recovery, SALT, block.chainid)
            )
        );

        assertTrue(LegacyPayment(payment).SETTLED());
        assertEq(ERC20(token).balanceOf(receiver) - receiverBefore, amount, "legacy paid the receiver");
    }

    function _measureCurrent(uint256 funding) internal returns (Measurement memory m) {
        Payment.Call[] memory calls = new Payment.Call[](1);
        calls[0] = Payment.Call({target: token, data: abi.encodeCall(ERC20.transfer, (receiver, amount))});
        address payment = factory.paymentAddress(token, amount, calls, expiry, recovery, SALT, block.chainid);
        _credit(payment, funding);
        uint256 receiverBefore = ERC20(token).balanceOf(receiver);

        m = _measure(
            address(factory),
            abi.encodeCall(PaymentFactory.execute, (token, amount, calls, expiry, recovery, SALT, block.chainid))
        );

        assertTrue(Payment(payment).SETTLED());
        assertEq(ERC20(token).balanceOf(receiver) - receiverBefore, amount, "current paid the receiver");
    }

    function _measure(address target, bytes memory data) internal returns (Measurement memory m) {
        (bool success,) = target.call(data);
        require(success, "execute failed");
        Vm.Gas memory gas = vm.lastCallGas();

        m.calldataBytes = data.length;
        for (uint256 i; i < data.length; ++i) {
            m.calldataGas += data[i] == 0 ? 4 : 16;
        }
        // Outside isolation mode the reading excludes the intrinsic cost.
        require(gas.gasTotalUsed > 21_000 + m.calldataGas, "run the benchmark in isolation mode");
        m.transaction = gas.gasTotalUsed;
        m.refund = gas.gasRefunded > 0 ? uint256(uint64(gas.gasRefunded)) : 0;
        m.execution = m.transaction + m.refund - 21_000 - m.calldataGas;
    }

    //---------- Formatting ----------//

    function _row(string memory label, uint256 legacy, uint256 current) private pure {
        string memory delta = current >= legacy
            ? string.concat("+", vm.toString(current - legacy))
            : string.concat("-", vm.toString(legacy - current));
        console2.log(
            string.concat("  ", _pad(label, 20), _pad(vm.toString(legacy), 12), _pad(vm.toString(current), 13), delta)
        );
    }

    function _pad(string memory s, uint256 width) private pure returns (string memory) {
        bytes memory b = bytes(s);
        if (b.length >= width) return string.concat(s, " ");
        bytes memory spaces = new bytes(width - b.length);
        for (uint256 i; i < spaces.length; ++i) {
            spaces[i] = " ";
        }
        return string.concat(s, string(spaces));
    }

    /// @dev `part / whole` as a percentage with one decimal.
    function _percent(uint256 part, uint256 whole) private pure returns (string memory) {
        uint256 tenths = (part * 1000 + whole / 2) / whole;
        return string.concat(vm.toString(tenths / 10), ".", vm.toString(tenths % 10), "%");
    }
}

/// @notice Offline: against the six-decimal `MockStablecoin`.
/// forge-config: default.isolate = true
contract MockStablecoinPaymentGasBenchmark is PaymentGasBenchmark {
    function setUp() public {
        token = address(new MockStablecoin("Mock USD Coin", "USDC"));
        amount = 10e6;
        _deployFactories();
    }

    function _prepare() internal pure override returns (bool) {
        return true;
    }

    function _credit(address account, uint256 value) internal override {
        MockStablecoin(token).mint(account, value);
    }
}

/// @notice Against live USDC on Base, whose `transfer` goes through a proxy and
/// blacklist checks. Skipped unless `GUM_FORK_TESTS=1`.
/// forge-config: default.isolate = true
contract BaseUsdcPaymentGasBenchmark is PaymentGasBenchmark {
    function _prepare() internal override returns (bool) {
        if (!vm.envOr("GUM_FORK_TESTS", false)) {
            vm.skip(true);
            return false;
        }
        vm.createSelectFork(vm.envOr("GUM_FORK_RPC_URL_8453", string("https://mainnet.base.org")));
        assertEq(block.chainid, 8453, "fork is not Base");
        token = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
        amount = 10e6;
        _deployFactories();
        return true;
    }

    function _credit(address account, uint256 value) internal override {
        deal(token, account, ERC20(token).balanceOf(account) + value);
    }
}
