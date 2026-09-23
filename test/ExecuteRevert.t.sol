// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test} from "lib/forge-std/src/Test.sol";
import {CREATE3} from "lib/solady/src/utils/CREATE3.sol";
import {ERC20} from "lib/solady/src/tokens/ERC20.sol";
import {MockStablecoin} from "src/mock/MockStablecoin.sol";
import {Payment} from "src/Payment.sol";
import {PaymentFactory} from "src/PaymentFactory.sol";

/// @notice Pins the observable CREATE3 failures used by the backend.
contract ExecuteRevertTest is Test {
    MockStablecoin private token;
    PaymentFactory private factory;

    function setUp() public {
        token = new MockStablecoin("Mock USD Coin", "USDC");
        factory = new PaymentFactory();
    }

    function test_underpayment_reverts_with_DeploymentFailed_and_leaves_no_code() public {
        uint256 amount = 10e6;
        bytes32 salt = bytes32(uint256(1));
        uint64 expirationTimestamp = uint64(block.timestamp + 1 days);
        address recovery = address(0xCAFE);
        address paymentAddress = factory.paymentAddress(
            address(token), amount, _pay(address(0xBEEF), amount), expirationTimestamp, recovery, salt, block.chainid
        );
        token.mint(paymentAddress, amount - 1);

        vm.expectRevert(CREATE3.DeploymentFailed.selector);
        factory.execute(
            address(token), amount, _pay(address(0xBEEF), amount), expirationTimestamp, recovery, salt, block.chainid
        );

        assertEq(paymentAddress.code.length, 0);
        assertEq(token.balanceOf(paymentAddress), amount - 1);
    }

    function test_already_executed_reverts_with_DeploymentFailed() public {
        uint256 amount = 10e6;
        bytes32 salt = bytes32(uint256(2));
        address receiver = address(0xBEEF);
        uint64 expirationTimestamp = uint64(block.timestamp + 1 days);
        address recovery = address(0xCAFE);
        address paymentAddress = factory.paymentAddress(
            address(token), amount, _pay(receiver, amount), expirationTimestamp, recovery, salt, block.chainid
        );
        token.mint(paymentAddress, amount);

        factory.execute(
            address(token), amount, _pay(receiver, amount), expirationTimestamp, recovery, salt, block.chainid
        );
        assertGt(paymentAddress.code.length, 0);

        vm.expectRevert(CREATE3.DeploymentFailed.selector);
        factory.execute(
            address(token), amount, _pay(receiver, amount), expirationTimestamp, recovery, salt, block.chainid
        );
    }

    function _pay(address to, uint256 amount) private view returns (Payment.Call[] memory calls) {
        calls = new Payment.Call[](1);
        calls[0] = Payment.Call({target: address(token), data: abi.encodeCall(ERC20.transfer, (to, amount))});
    }
}
