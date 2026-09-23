// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test} from "lib/forge-std/src/Test.sol";
import {ERC20} from "lib/solady/src/tokens/ERC20.sol";
import {SafeTransferLib} from "lib/solady/src/utils/SafeTransferLib.sol";
import {MockStablecoin} from "src/mock/MockStablecoin.sol";
import {Payment} from "src/Payment.sol";
import {PaymentFactory} from "src/PaymentFactory.sol";
import {BubblingCREATE3} from "src/utils/BubblingCREATE3.sol";

/// @notice Pins what `execute` reverts with, which the backend decodes: the
/// `Payment` constructor's own error, `AlreadyDeployed` for a payment that has
/// already executed, and `DeploymentFailed` only when there is no revert data.
contract ExecuteRevertTest is Test {
    MockStablecoin private token;
    PaymentFactory private factory;

    address private constant RECEIVER = address(0xBEEF);
    address private constant RECOVERY = address(0xCAFE);
    uint256 private constant AMOUNT = 10e6;

    uint64 private expirationTimestamp;

    function setUp() public {
        token = new MockStablecoin("Mock USD Coin", "USDC");
        factory = new PaymentFactory();
        expirationTimestamp = uint64(block.timestamp + 1 days);
    }

    function test_underpayment_reverts_with_insufficient_token_balance_and_leaves_no_code() public {
        Payment.Call[] memory calls = _pay(RECEIVER, AMOUNT);
        address paymentAddress = _address(calls, bytes32(uint256(1)));
        token.mint(paymentAddress, AMOUNT - 1);

        vm.expectRevert(abi.encodeWithSelector(Payment.InsufficientTokenBalance.selector, AMOUNT - 1, AMOUNT));
        _execute(calls, bytes32(uint256(1)));

        assertEq(paymentAddress.code.length, 0);
        assertEq(token.balanceOf(paymentAddress), AMOUNT - 1);
    }

    function test_already_executed_reverts_with_already_deployed() public {
        Payment.Call[] memory calls = _pay(RECEIVER, AMOUNT);
        address paymentAddress = _address(calls, bytes32(uint256(2)));
        token.mint(paymentAddress, AMOUNT);

        _execute(calls, bytes32(uint256(2)));
        assertGt(paymentAddress.code.length, 0);

        vm.expectRevert(BubblingCREATE3.AlreadyDeployed.selector);
        _execute(calls, bytes32(uint256(2)));
    }

    /// @notice A failing call surfaces with its index and the target's own
    /// revert data, here the token's blacklist check.
    function test_failed_call_reverts_with_call_failed() public {
        Payment.Call[] memory calls = _pay(RECEIVER, AMOUNT);
        token.mint(_address(calls, bytes32(uint256(3))), AMOUNT);
        token.setBlacklisted(RECEIVER, true);

        vm.expectRevert(
            abi.encodeWithSelector(
                Payment.CallFailed.selector,
                0,
                abi.encodeWithSignature("Error(string)", "Blacklistable: account is blacklisted")
            )
        );
        _execute(calls, bytes32(uint256(3)));
    }

    function test_unspent_amount_reverts_with_amount_not_spent() public {
        Payment.Call[] memory calls = _pay(RECEIVER, AMOUNT - 1);
        token.mint(_address(calls, bytes32(uint256(4))), AMOUNT);

        vm.expectRevert(abi.encodeWithSelector(Payment.AmountNotSpent.selector, 1));
        _execute(calls, bytes32(uint256(4)));
    }

    function test_failed_recovery_transfer_reverts_with_the_token_error() public {
        Payment.Call[] memory calls = _pay(RECEIVER, AMOUNT);
        token.mint(_address(calls, bytes32(uint256(5))), AMOUNT + 1);
        token.setBlacklisted(RECOVERY, true);

        vm.expectRevert(SafeTransferLib.TransferFailed.selector);
        _execute(calls, bytes32(uint256(5)));
    }

    /// @notice A constructor that runs out of gas reverts with no data, which
    /// is the one case left to `DeploymentFailed`.
    function test_out_of_gas_constructor_reverts_with_deployment_failed() public {
        Payment.Call[] memory calls = _pay(RECEIVER, AMOUNT);
        address paymentAddress = _address(calls, bytes32(uint256(6)));
        token.mint(paymentAddress, AMOUNT);

        vm.expectRevert(BubblingCREATE3.DeploymentFailed.selector);
        factory.execute{gas: 300_000}(
            address(token), AMOUNT, calls, expirationTimestamp, RECOVERY, bytes32(uint256(6)), block.chainid
        );

        assertEq(paymentAddress.code.length, 0);
        _execute(calls, bytes32(uint256(6)));
        assertTrue(Payment(paymentAddress).SETTLED(), "a retry with enough gas settles");
    }

    function _pay(address to, uint256 amount) private view returns (Payment.Call[] memory calls) {
        calls = new Payment.Call[](1);
        calls[0] = Payment.Call({target: address(token), data: abi.encodeCall(ERC20.transfer, (to, amount))});
    }

    function _address(Payment.Call[] memory calls, bytes32 salt) private view returns (address) {
        return factory.paymentAddress(address(token), AMOUNT, calls, expirationTimestamp, RECOVERY, salt, block.chainid);
    }

    function _execute(Payment.Call[] memory calls, bytes32 salt) private {
        factory.execute(address(token), AMOUNT, calls, expirationTimestamp, RECOVERY, salt, block.chainid);
    }
}
