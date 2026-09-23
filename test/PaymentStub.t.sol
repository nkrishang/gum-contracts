// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {ERC20} from "lib/solady/src/tokens/ERC20.sol";
import {Payment} from "src/Payment.sol";
import {PaymentFactory} from "src/PaymentFactory.sol";
import {PaymentCallsBase} from "test/utils/SettlementFixtures.sol";

/// @notice The deployment mechanics behind the gas layout: every payment's code
/// is a 65-byte stub delegatecalling one shared implementation, and the init
/// code is built from the calldata verbatim.
contract PaymentStubTest is PaymentCallsBase {
    function test_the_factory_deploys_the_implementation_at_nonce_1() public view {
        address implementation = factory.paymentImplementation();
        assertEq(implementation, vm.computeCreateAddress(address(factory), 1));
        assertEq(implementation.code, type(Payment).runtimeCode, "the implementation is Payment's runtime");
    }

    /// @notice Pins the stub byte for byte: proxy code, implementation, recovery, settled flag.
    function test_a_settled_payment_deploys_the_stub() public {
        Payment.Call[] memory calls = _list(_transfer(MERCHANT, 10e6));
        address payment = _fund(10e6, calls, 10e6);
        _execute(10e6, calls);

        assertEq(payment.code, _stub(RECOVERY, true));
    }

    function test_expired_and_wrong_chain_payments_deploy_an_unsettled_stub() public {
        Payment.Call[] memory calls = _list(_transfer(MERCHANT, 10e6));
        address expired = _fund(10e6, calls, 10e6);
        vm.warp(expiry + 1);
        _execute(10e6, calls);
        assertEq(expired.code, _stub(RECOVERY, false));

        address wrongChain = factory.paymentAddress(address(token), 10e6, calls, expiry, RECOVERY, SALT, 1);
        factory.execute(address(token), 10e6, calls, expiry, RECOVERY, SALT, 1);
        assertEq(wrongChain.code, _stub(RECOVERY, false));
    }

    /// @notice The implementation reads its arguments from the stub's code, so
    /// outside a stub it refuses to run rather than read garbage.
    function test_the_implementation_cannot_be_called_directly() public {
        Payment implementation = Payment(factory.paymentImplementation());
        token.mint(address(implementation), 1e6);

        vm.expectRevert();
        implementation.recover(address(token));
        vm.expectRevert();
        implementation.SETTLED();
        assertEq(token.balanceOf(address(implementation)), 1e6);
    }

    function test_the_stub_rejects_ether() public {
        Payment.Call[] memory calls = _list(_transfer(MERCHANT, 10e6));
        address payment = _fund(10e6, calls, 10e6);
        _execute(10e6, calls);

        vm.deal(address(this), 1 ether);
        (bool plainTransfer,) = payment.call{value: 1 ether}("");
        (bool withRecover,) = payment.call{value: 1 ether}(abi.encodeCall(Payment.recover, (address(token))));
        assertFalse(plainTransfer);
        assertFalse(withRecover);
        assertEq(payment.balance, 0);
    }

    /// @notice The init code is built from calldata verbatim, so calldata with
    /// anything appended names a different, unfunded payment and can never
    /// reach the funded one.
    function test_non_canonical_calldata_cannot_reach_a_funded_payment() public {
        Payment.Call[] memory calls = _list(_transfer(MERCHANT, 10e6));
        address payment = _fund(10e6, calls, 10e6);
        bytes memory canonical = abi.encodeCall(
            PaymentFactory.execute, (address(token), 10e6, calls, expiry, RECOVERY, SALT, block.chainid)
        );

        (bool success, bytes memory revertData) = address(factory).call(bytes.concat(canonical, hex"00"));
        assertFalse(success);
        assertEq(revertData, abi.encodeWithSelector(Payment.InsufficientTokenBalance.selector, 0, 10e6));
        assertEq(token.balanceOf(payment), 10e6);

        (success,) = address(factory).call(canonical);
        assertTrue(success);
        assertEq(token.balanceOf(MERCHANT), 10e6);
    }

    function _stub(address recovery, bool settled) private view returns (bytes memory) {
        return abi.encodePacked(
            hex"365f5f375f5f365f73",
            factory.paymentImplementation(),
            hex"5af43d5f5f3e5f3d91602a57fd5bf3",
            recovery,
            settled
        );
    }
}
