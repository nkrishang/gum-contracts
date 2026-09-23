// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test} from "lib/forge-std/src/Test.sol";
import {Vm} from "lib/forge-std/src/Vm.sol";
import {CREATE3} from "lib/solady/src/utils/CREATE3.sol";
import {ERC20} from "lib/solady/src/tokens/ERC20.sol";
import {Payment} from "src/Payment.sol";
import {PaymentFactory} from "src/PaymentFactory.sol";
import {ITokenMessengerV2} from "src/WithdrawalForwarder.sol";

interface IFiatTokenAdmin {
    function blacklister() external view returns (address);
    function blacklist(address account) external;
    function unBlacklist(address account) external;
}

/// @dev Settlement calls against the live tokens and CCTP V2. Skipped unless
/// `GUM_FORK_TESTS=1`, so `forge test` stays offline.
abstract contract PaymentCallsForkBase is Test {
    uint256 internal constant AMOUNT = 1_234_567; // 1.234567 of a six-decimal stablecoin
    address internal constant MERCHANT = address(0xD00D);
    address internal constant RECOVERY = address(0xCAFE);
    bytes32 internal constant SALT = keccak256("gum-fork-payment");

    uint256 internal chainId;
    address internal stablecoin;
    string internal rpcVariable;
    string internal defaultRpc;

    PaymentFactory internal factory;
    uint64 internal expiry;

    modifier onlyFork() {
        if (!vm.envOr("GUM_FORK_TESTS", false)) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(vm.envOr(rpcVariable, defaultRpc));
        assertEq(block.chainid, chainId, "fork is not the expected chain");
        factory = new PaymentFactory();
        expiry = uint64(block.timestamp + 1 hours);
        _;
    }

    function _transfer(address to, uint256 amount) internal view returns (Payment.Call memory) {
        return Payment.Call({target: stablecoin, data: abi.encodeCall(ERC20.transfer, (to, amount))});
    }

    function _address(Payment.Call[] memory calls) internal view returns (address) {
        return factory.paymentAddress(stablecoin, AMOUNT, calls, expiry, RECOVERY, SALT, block.chainid);
    }

    function _execute(Payment.Call[] memory calls) internal {
        factory.execute(stablecoin, AMOUNT, calls, expiry, RECOVERY, SALT, block.chainid);
    }

    /// @dev Tops up `account` by `amount` on top of whatever it already holds.
    function _topUp(address account, uint256 amount) internal {
        deal(stablecoin, account, ERC20(stablecoin).balanceOf(account) + amount);
    }

    /// @notice The default settlement against the live token: exact amount to
    /// the merchant, and the overpayment to recovery.
    function test_fork_plain_transfer_settles_and_recovers_the_excess() public onlyFork {
        Payment.Call[] memory calls = new Payment.Call[](1);
        calls[0] = _transfer(MERCHANT, AMOUNT);
        address payment = _address(calls);
        _topUp(payment, AMOUNT + 1);
        uint256 merchantBefore = ERC20(stablecoin).balanceOf(MERCHANT);
        uint256 recoveryBefore = ERC20(stablecoin).balanceOf(RECOVERY);

        _execute(calls);

        assertEq(ERC20(stablecoin).balanceOf(MERCHANT) - merchantBefore, AMOUNT);
        assertEq(ERC20(stablecoin).balanceOf(RECOVERY) - recoveryBefore, 1);
        assertEq(ERC20(stablecoin).balanceOf(payment), 0);
        assertTrue(Payment(payment).SETTLED());
    }

    function test_fork_fee_split_settles() public onlyFork {
        Payment.Call[] memory calls = new Payment.Call[](2);
        calls[0] = _transfer(MERCHANT, AMOUNT - 1_000);
        calls[1] = _transfer(address(0xFEE), 1_000);
        address payment = _address(calls);
        _topUp(payment, AMOUNT);
        uint256 merchantBefore = ERC20(stablecoin).balanceOf(MERCHANT);

        _execute(calls);

        assertEq(ERC20(stablecoin).balanceOf(MERCHANT) - merchantBefore, AMOUNT - 1_000);
        assertEq(ERC20(stablecoin).balanceOf(address(0xFEE)), 1_000);
        assertEq(ERC20(stablecoin).balanceOf(payment), 0);
    }
}

/// @dev USDC-only scenarios: CCTP V2 burns and FiatToken blacklisting.
abstract contract UsdcPaymentCallsForkTest is PaymentCallsForkBase {
    address internal constant TOKEN_MESSENGER_V2 = 0x28b5a0e9C621a5BadaA536219b3a228C8168cf5d;
    address internal constant MESSAGE_TRANSMITTER_V2 = 0x81D40F21F12A8F0E3252Bccb954D722d4c464B64;
    bytes32 internal constant MESSAGE_SENT_TOPIC = keccak256("MessageSent(bytes)");

    uint32 internal domain;

    /// @notice Settling straight into a CCTP V2 burn: the payment approves the
    /// messenger and burns towards a recipient on another chain, and the
    /// message names the payment address as the burner.
    function test_fork_settlement_burns_through_cctp() public onlyFork {
        uint32 destinationDomain = domain == 6 ? 3 : 6;
        bytes32 recipient = bytes32(uint256(uint160(MERCHANT)));
        Payment.Call[] memory calls = new Payment.Call[](2);
        calls[0] = Payment.Call({target: stablecoin, data: abi.encodeCall(ERC20.approve, (TOKEN_MESSENGER_V2, AMOUNT))});
        calls[1] = Payment.Call({
            target: TOKEN_MESSENGER_V2,
            data: abi.encodeCall(
                ITokenMessengerV2.depositForBurn,
                (AMOUNT, destinationDomain, recipient, stablecoin, bytes32(0), 0, 2000)
            )
        });
        address payment = _address(calls);
        _topUp(payment, AMOUNT);
        uint256 supplyBefore = ERC20(stablecoin).totalSupply();

        vm.recordLogs();
        _execute(calls);

        assertEq(supplyBefore - ERC20(stablecoin).totalSupply(), AMOUNT, "the full amount was burned");
        assertEq(ERC20(stablecoin).balanceOf(payment), 0);
        assertEq(ERC20(stablecoin).allowance(payment, TOKEN_MESSENGER_V2), 0, "the exact approval was used up");
        assertTrue(Payment(payment).SETTLED());

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes memory message;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == MESSAGE_TRANSMITTER_V2 && logs[i].topics[0] == MESSAGE_SENT_TOPIC) {
                message = abi.decode(logs[i].data, (bytes));
            }
        }
        // Header is 148 bytes; the BurnMessageV2 body is version(4) burnToken(32)
        // mintRecipient(32) amount(32) messageSender(32) ...
        assertEq(_u32(message, 4), domain, "source domain");
        assertEq(_u32(message, 8), destinationDomain, "destination domain");
        assertEq(_b32(message, 148 + 36), recipient, "mint recipient");
        assertEq(uint256(_b32(message, 148 + 68)), AMOUNT, "amount");
        assertEq(_b32(message, 148 + 100), bytes32(uint256(uint160(payment))), "the payment is the burner");
    }

    /// @notice A blacklisted recipient makes the live token revert the call, so
    /// the deployment reverts and the funds wait for a later attempt.
    function test_fork_blacklisted_recipient_reverts_until_cleared() public onlyFork {
        Payment.Call[] memory calls = new Payment.Call[](1);
        calls[0] = _transfer(MERCHANT, AMOUNT);
        address payment = _address(calls);
        _topUp(payment, AMOUNT);
        address blacklister = IFiatTokenAdmin(stablecoin).blacklister();

        vm.prank(blacklister);
        IFiatTokenAdmin(stablecoin).blacklist(MERCHANT);
        vm.expectRevert(CREATE3.DeploymentFailed.selector);
        _execute(calls);
        assertEq(ERC20(stablecoin).balanceOf(payment), AMOUNT);
        assertEq(payment.code.length, 0);

        vm.prank(blacklister);
        IFiatTokenAdmin(stablecoin).unBlacklist(MERCHANT);
        _execute(calls);
        assertEq(ERC20(stablecoin).balanceOf(payment), 0);
        assertTrue(Payment(payment).SETTLED());
    }

    function _u32(bytes memory data, uint256 offset) private pure returns (uint32 value) {
        for (uint256 i; i < 4; ++i) {
            value = (value << 8) | uint32(uint8(data[offset + i]));
        }
    }

    function _b32(bytes memory data, uint256 offset) private pure returns (bytes32 value) {
        assembly {
            value := mload(add(add(data, 0x20), offset))
        }
    }
}

contract MonadUsdcPaymentCallsForkTest is UsdcPaymentCallsForkTest {
    constructor() {
        chainId = 143;
        domain = 15;
        stablecoin = 0x754704Bc059F8C67012fEd69BC8A327a5aafb603;
        rpcVariable = "GUM_FORK_RPC_URL_143";
        defaultRpc = "https://rpc.monad.xyz";
    }
}

contract BaseUsdcPaymentCallsForkTest is UsdcPaymentCallsForkTest {
    constructor() {
        chainId = 8453;
        domain = 6;
        stablecoin = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
        rpcVariable = "GUM_FORK_RPC_URL_8453";
        defaultRpc = "https://mainnet.base.org";
    }
}

contract ArbitrumUsdcPaymentCallsForkTest is UsdcPaymentCallsForkTest {
    constructor() {
        chainId = 42161;
        domain = 3;
        stablecoin = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
        rpcVariable = "GUM_FORK_RPC_URL_42161";
        defaultRpc = "https://arb1.arbitrum.io/rpc";
    }
}

contract MonadUsdt0PaymentCallsForkTest is PaymentCallsForkBase {
    constructor() {
        chainId = 143;
        stablecoin = 0xe7cd86e13AC4309349F30B3435a9d337750fC82D;
        rpcVariable = "GUM_FORK_RPC_URL_143";
        defaultRpc = "https://rpc.monad.xyz";
    }
}

contract ArbitrumUsdt0PaymentCallsForkTest is PaymentCallsForkBase {
    constructor() {
        chainId = 42161;
        stablecoin = 0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9;
        rpcVariable = "GUM_FORK_RPC_URL_42161";
        defaultRpc = "https://arb1.arbitrum.io/rpc";
    }
}
