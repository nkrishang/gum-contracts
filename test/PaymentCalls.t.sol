// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test} from "lib/forge-std/src/Test.sol";
import {CREATE3} from "lib/solady/src/utils/CREATE3.sol";
import {ERC20} from "lib/solady/src/tokens/ERC20.sol";
import {ERC4626} from "lib/solady/src/tokens/ERC4626.sol";
import {MockStablecoin} from "src/mock/MockStablecoin.sol";
import {Payment} from "src/Payment.sol";
import {PaymentFactory} from "src/PaymentFactory.sol";

contract MockVault is ERC4626 {
    address internal immutable _asset;

    constructor(address asset_) {
        _asset = asset_;
    }

    function asset() public view override returns (address) {
        return _asset;
    }

    function name() public pure override returns (string memory) {
        return "Mock Vault";
    }

    function symbol() public pure override returns (string memory) {
        return "mVAULT";
    }
}

/// @dev Stands in for a merchant contract that is temporarily unable to accept an order.
contract Gate {
    bool public open;
    uint256 public passes;

    function setOpen(bool open_) external {
        open = open_;
    }

    function pass() external {
        require(open, "closed");
        passes++;
    }
}

/// @dev Calls back into its caller, which is a `Payment` still under construction.
contract Reentrant {
    function recoverFromCaller(address token) external {
        Payment(msg.sender).recover(token);
    }
}

contract PaymentDirectDeployer {
    function deploy(
        address token,
        uint256 amount,
        Payment.Call[] memory calls,
        uint64 expirationTimestamp,
        address recovery,
        uint256 chainId
    ) external returns (Payment) {
        return new Payment(token, amount, calls, expirationTimestamp, recovery, chainId);
    }
}

contract PaymentCallsTest is Test {
    event Called(uint256 indexed index, address indexed target, bytes data, bytes result);
    event Settled(address indexed token, uint256 amount);
    event Recovered(address indexed recovery, address indexed token, uint256 amount);

    MockStablecoin internal token;
    PaymentFactory internal factory;
    MockVault internal vault;
    Gate internal gate;

    address internal constant MERCHANT = address(0xBEEF);
    address internal constant PLATFORM = address(0xFEE);
    address internal constant RECOVERY = address(0xCAFE);

    function setUp() public {
        token = new MockStablecoin("Mock USD Coin", "USDC");
        factory = new PaymentFactory();
        vault = new MockVault(address(token));
        gate = new Gate();
    }

    /// @notice The canonical action: approve a vault and deposit on the merchant's
    /// behalf. Each call is reported with its calldata and return data.
    function test_approve_and_deposit_settles_into_a_vault() public {
        Payment.Call[] memory calls = new Payment.Call[](2);
        calls[0] = _call(address(token), abi.encodeCall(ERC20.approve, (address(vault), 10e6)));
        calls[1] = _call(address(vault), abi.encodeCall(ERC4626.deposit, (10e6, MERCHANT)));
        (address paymentAddress, uint64 expirationTimestamp) = _fund(10e6, calls, 10e6);

        vm.expectEmit(true, true, true, true, paymentAddress);
        emit Called(0, address(token), calls[0].data, abi.encode(true));
        vm.expectEmit(true, true, true, true, paymentAddress);
        emit Called(1, address(vault), calls[1].data, abi.encode(uint256(10e6)));
        vm.expectEmit(true, true, true, true, paymentAddress);
        emit Settled(address(token), 10e6);
        _execute(10e6, calls, expirationTimestamp);

        assertEq(vault.balanceOf(MERCHANT), 10e6, "the merchant holds the vault shares");
        assertEq(token.balanceOf(address(vault)), 10e6);
        assertEq(token.balanceOf(paymentAddress), 0);
        assertTrue(Payment(paymentAddress).SETTLED());
    }

    function test_calls_can_split_the_amount_between_recipients() public {
        Payment.Call[] memory calls = new Payment.Call[](2);
        calls[0] = _call(address(token), abi.encodeCall(ERC20.transfer, (MERCHANT, 9.7e6)));
        calls[1] = _call(address(token), abi.encodeCall(ERC20.transfer, (PLATFORM, 0.3e6)));
        (, uint64 expirationTimestamp) = _fund(10e6, calls, 10e6);

        _execute(10e6, calls, expirationTimestamp);

        assertEq(token.balanceOf(MERCHANT), 9.7e6);
        assertEq(token.balanceOf(PLATFORM), 0.3e6);
    }

    /// @notice A call that moves less than the amount (or nothing at all) must
    /// not count as settlement: it would silently strand the merchant's money.
    function test_underspending_calls_revert_with_amount_not_spent() public {
        PaymentDirectDeployer deployer = new PaymentDirectDeployer();
        address predicted = vm.computeCreateAddress(address(deployer), vm.getNonce(address(deployer)));
        token.mint(predicted, 10e6);

        vm.expectRevert(abi.encodeWithSelector(Payment.AmountNotSpent.selector, 1));
        deployer.deploy(
            address(token), 10e6, _pay(MERCHANT, 10e6 - 1), uint64(block.timestamp + 1 hours), RECOVERY, block.chainid
        );
    }

    function test_no_calls_cannot_settle_a_nonzero_amount() public {
        Payment.Call[] memory calls = new Payment.Call[](0);
        (address paymentAddress, uint64 expirationTimestamp) = _fund(10e6, calls, 10e6);

        vm.expectRevert(CREATE3.DeploymentFailed.selector);
        _execute(10e6, calls, expirationTimestamp);
        assertEq(token.balanceOf(paymentAddress), 10e6);
    }

    /// @notice The excess has already left for recovery when the calls run, so
    /// no call can spend more than the amount.
    function test_calls_cannot_spend_the_excess() public {
        PaymentDirectDeployer deployer = new PaymentDirectDeployer();
        address predicted = vm.computeCreateAddress(address(deployer), vm.getNonce(address(deployer)));
        token.mint(predicted, 12e6);

        vm.expectPartialRevert(Payment.CallFailed.selector);
        deployer.deploy(
            address(token), 10e6, _pay(MERCHANT, 10e6 + 1), uint64(block.timestamp + 1 hours), RECOVERY, block.chainid
        );
    }

    /// @notice A failing call reverts the whole deployment, so the payment stays
    /// funded and executable; the next attempt after the target recovers settles.
    function test_failed_call_reverts_everything_and_is_retryable() public {
        Payment.Call[] memory calls = new Payment.Call[](2);
        calls[0] = _call(address(token), abi.encodeCall(ERC20.transfer, (MERCHANT, 10e6)));
        calls[1] = _call(address(gate), abi.encodeCall(Gate.pass, ()));
        (address paymentAddress, uint64 expirationTimestamp) = _fund(10e6, calls, 12e6);

        vm.expectRevert(CREATE3.DeploymentFailed.selector);
        _execute(10e6, calls, expirationTimestamp);
        assertEq(paymentAddress.code.length, 0);
        assertEq(token.balanceOf(paymentAddress), 12e6, "the earlier transfer and the excess roll back too");
        assertEq(token.balanceOf(MERCHANT), 0);
        assertEq(token.balanceOf(RECOVERY), 0);

        gate.setOpen(true);
        _execute(10e6, calls, expirationTimestamp);
        assertEq(gate.passes(), 1);
        assertEq(token.balanceOf(MERCHANT), 10e6);
        assertEq(token.balanceOf(RECOVERY), 2e6);
    }

    function test_failed_call_reports_its_index_and_revert_data() public {
        Payment.Call[] memory calls = new Payment.Call[](2);
        calls[0] = _call(address(token), abi.encodeCall(ERC20.transfer, (MERCHANT, 10e6)));
        calls[1] = _call(address(gate), abi.encodeCall(Gate.pass, ()));
        PaymentDirectDeployer deployer = new PaymentDirectDeployer();
        address predicted = vm.computeCreateAddress(address(deployer), vm.getNonce(address(deployer)));
        token.mint(predicted, 10e6);

        vm.expectRevert(
            abi.encodeWithSelector(Payment.CallFailed.selector, 1, abi.encodeWithSignature("Error(string)", "closed"))
        );
        deployer.deploy(address(token), 10e6, calls, uint64(block.timestamp + 1 hours), RECOVERY, block.chainid);
    }

    /// @notice A call to an address without code succeeds and does nothing, so a
    /// mistyped target must fail loudly instead.
    function test_call_to_an_address_without_code_reverts() public {
        Payment.Call[] memory calls = new Payment.Call[](2);
        calls[0] = _call(address(token), abi.encodeCall(ERC20.transfer, (MERCHANT, 10e6)));
        calls[1] = _call(address(0xE0A), "");
        PaymentDirectDeployer deployer = new PaymentDirectDeployer();
        address predicted = vm.computeCreateAddress(address(deployer), vm.getNonce(address(deployer)));
        token.mint(predicted, 10e6);

        vm.expectRevert(abi.encodeWithSelector(Payment.CallTargetHasNoCode.selector, 1, address(0xE0A)));
        deployer.deploy(address(token), 10e6, calls, uint64(block.timestamp + 1 hours), RECOVERY, block.chainid);
    }

    /// @notice Calls run inside the constructor, before the payment has code, so
    /// a target cannot call back into it.
    function test_calls_cannot_call_back_into_the_payment() public {
        Reentrant reentrant = new Reentrant();
        Payment.Call[] memory calls = new Payment.Call[](2);
        calls[0] = _call(address(token), abi.encodeCall(ERC20.transfer, (MERCHANT, 10e6)));
        calls[1] = _call(address(reentrant), abi.encodeCall(Reentrant.recoverFromCaller, (address(token))));
        PaymentDirectDeployer deployer = new PaymentDirectDeployer();
        address predicted = vm.computeCreateAddress(address(deployer), vm.getNonce(address(deployer)));
        token.mint(predicted, 10e6);

        vm.expectPartialRevert(Payment.CallFailed.selector);
        deployer.deploy(address(token), 10e6, calls, uint64(block.timestamp + 1 hours), RECOVERY, block.chainid);
    }

    function test_expired_payment_runs_no_calls() public {
        gate.setOpen(true);
        Payment.Call[] memory calls = _payAndPass(10e6);
        (address paymentAddress, uint64 expirationTimestamp) = _fund(10e6, calls, 10e6);

        vm.warp(expirationTimestamp + 1);
        _execute(10e6, calls, expirationTimestamp);

        assertEq(gate.passes(), 0, "an expired payment must not trigger its action");
        assertEq(token.balanceOf(MERCHANT), 0);
        assertEq(token.balanceOf(RECOVERY), 10e6);
        assertFalse(Payment(paymentAddress).SETTLED());
    }

    function test_wrong_chain_payment_runs_no_calls() public {
        gate.setOpen(true);
        Payment.Call[] memory calls = _payAndPass(10e6);
        uint64 expirationTimestamp = uint64(block.timestamp + 1 hours);
        uint256 otherChain = block.chainid + 1;
        address paymentAddress =
            factory.paymentAddress(address(token), 10e6, calls, expirationTimestamp, RECOVERY, bytes32(0), otherChain);
        token.mint(paymentAddress, 10e6);

        factory.execute(address(token), 10e6, calls, expirationTimestamp, RECOVERY, bytes32(0), otherChain);

        assertEq(gate.passes(), 0, "a wrong-chain payment must not trigger its action");
        assertEq(token.balanceOf(paymentAddress), 10e6);
        assertFalse(Payment(paymentAddress).SETTLED());
    }

    /// @notice Every target, every byte of calldata, and the order of the calls
    /// are committed into the address, so no executor can alter the action.
    function test_calls_are_committed_into_the_address() public view {
        uint64 expirationTimestamp = uint64(block.timestamp + 1 hours);
        Payment.Call[] memory calls = _payAndPass(10e6);
        address committed = _address(10e6, calls, expirationTimestamp);

        Payment.Call[] memory otherRecipient = _payAndPass(10e6);
        otherRecipient[0].data = abi.encodeCall(ERC20.transfer, (PLATFORM, 10e6));
        assertNotEq(_address(10e6, otherRecipient, expirationTimestamp), committed, "calldata is committed");

        Payment.Call[] memory otherTarget = _payAndPass(10e6);
        otherTarget[1].target = address(vault);
        assertNotEq(_address(10e6, otherTarget, expirationTimestamp), committed, "targets are committed");

        Payment.Call[] memory reordered = new Payment.Call[](2);
        reordered[0] = calls[1];
        reordered[1] = calls[0];
        assertNotEq(_address(10e6, reordered, expirationTimestamp), committed, "order is committed");

        Payment.Call[] memory truncated = new Payment.Call[](1);
        truncated[0] = calls[0];
        assertNotEq(_address(10e6, truncated, expirationTimestamp), committed, "the call count is committed");
    }

    //---------- Helpers ----------//

    function _call(address target, bytes memory data) private pure returns (Payment.Call memory) {
        return Payment.Call({target: target, data: data});
    }

    function _pay(address to, uint256 amount) private view returns (Payment.Call[] memory calls) {
        calls = new Payment.Call[](1);
        calls[0] = _call(address(token), abi.encodeCall(ERC20.transfer, (to, amount)));
    }

    function _payAndPass(uint256 amount) private view returns (Payment.Call[] memory calls) {
        calls = new Payment.Call[](2);
        calls[0] = _call(address(token), abi.encodeCall(ERC20.transfer, (MERCHANT, amount)));
        calls[1] = _call(address(gate), abi.encodeCall(Gate.pass, ()));
    }

    function _address(uint256 amount, Payment.Call[] memory calls, uint64 expirationTimestamp)
        private
        view
        returns (address)
    {
        return factory.paymentAddress(
            address(token), amount, calls, expirationTimestamp, RECOVERY, bytes32(0), block.chainid
        );
    }

    function _fund(uint256 amount, Payment.Call[] memory calls, uint256 funding)
        private
        returns (address paymentAddress, uint64 expirationTimestamp)
    {
        expirationTimestamp = uint64(block.timestamp + 1 hours);
        paymentAddress = _address(amount, calls, expirationTimestamp);
        token.mint(paymentAddress, funding);
    }

    function _execute(uint256 amount, Payment.Call[] memory calls, uint64 expirationTimestamp) private {
        factory.execute(address(token), amount, calls, expirationTimestamp, RECOVERY, bytes32(0), block.chainid);
    }
}
