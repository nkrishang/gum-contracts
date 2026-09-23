// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "lib/forge-std/src/Test.sol";
import {Vm} from "lib/forge-std/src/Vm.sol";
import {ERC20} from "lib/solady/src/tokens/ERC20.sol";
import {ERC4626} from "lib/solady/src/tokens/ERC4626.sol";
import {SafeTransferLib} from "lib/solady/src/utils/SafeTransferLib.sol";
import {MockStablecoin} from "src/mock/MockStablecoin.sol";
import {Payment} from "src/Payment.sol";
import {PaymentFactory} from "src/PaymentFactory.sol";

//---------- Call targets ----------//

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

/// @dev A merchant contract that takes payment by pulling it: the pull itself
/// is the proof of payment, so it never needs to trust `msg.sender`.
contract Checkout {
    event OrderPaid(bytes32 indexed orderId, address indexed payer, uint256 amount);

    address public immutable token;
    address public immutable treasury;
    mapping(bytes32 => address) public paidBy;

    constructor(address token_, address treasury_) {
        token = token_;
        treasury = treasury_;
    }

    function pay(bytes32 orderId, uint256 amount) external {
        require(paidBy[orderId] == address(0), "already paid");
        SafeTransferLib.safeTransferFrom(token, msg.sender, treasury, amount);
        paidBy[orderId] = msg.sender;
        emit OrderPaid(orderId, msg.sender, amount);
    }
}

/// @dev A merchant contract that is only told about a payment.
contract OrderBook {
    mapping(bytes32 => address) public notifiedBy;

    function markPaid(bytes32 orderId) external returns (bool) {
        notifiedBy[orderId] = msg.sender;
        return true;
    }
}

/// @dev A merchant contract that accepts a notification only from a genuine
/// payment that paid it. It receives every other term of the payment, rebuilds
/// the committed call list with its own call (`msg.data`) appended, and checks
/// that the factory derives `msg.sender` from it. Its own call must come last.
contract AuthenticatedOrderBook {
    PaymentFactory public immutable factory;
    address public immutable merchant;
    uint256 public immutable price;
    mapping(bytes32 => address) public paidBy;

    constructor(PaymentFactory factory_, address merchant_, uint256 price_) {
        factory = factory_;
        merchant = merchant_;
        price = price_;
    }

    function markPaid(
        bytes32 orderId,
        address token,
        uint256 amount,
        Payment.Call[] calldata previousCalls,
        uint64 expirationTimestamp,
        address recovery,
        bytes32 salt
    ) external {
        Payment.Call[] memory calls = new Payment.Call[](previousCalls.length + 1);
        for (uint256 i; i < previousCalls.length; ++i) {
            calls[i] = previousCalls[i];
        }
        calls[previousCalls.length] = Payment.Call({target: address(this), data: msg.data});
        address payment =
            factory.paymentAddress(token, amount, calls, expirationTimestamp, recovery, salt, block.chainid);
        require(msg.sender == payment, "not a genuine payment");

        // The earlier calls are now trusted: check they pay the merchant the price.
        require(previousCalls.length == 1 && previousCalls[0].target == token, "unexpected calls");
        require(
            keccak256(previousCalls[0].data) == keccak256(abi.encodeCall(ERC20.transfer, (merchant, price))),
            "does not pay the merchant"
        );
        paidBy[orderId] = msg.sender;
    }
}

/// @dev Returns the first `length` bytes of its argument as raw return data.
contract RawReturner {
    function echo(bytes calldata raw, uint256 length) external pure {
        assembly {
            calldatacopy(0, raw.offset, length)
            return(0, length)
        }
    }
}

/// @dev Stands in for a target that is temporarily unable to accept a call.
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

contract Reverter {
    error Refused(uint256 code);

    function customError() external pure {
        revert Refused(42);
    }

    function stringError() external pure {
        revert("refused");
    }

    function panic(uint256 divisor) external pure returns (uint256) {
        return 1 / divisor;
    }

    function empty() external pure {
        revert();
    }
}

/// @dev Calls back into its caller, which is a `Payment` still under construction.
contract Reentrant {
    function recoverFromCaller(address token) external {
        Payment(msg.sender).recover(token);
    }
}

contract GasBurner {
    function burn(uint256 gasToBurn) external view {
        uint256 start = gasleft();
        while (start - gasleft() < gasToBurn) {}
    }
}

/// @dev Pulls tokens from the caller and sends them straight back.
contract Boomerang {
    function bounce(address token, uint256 amount) external {
        SafeTransferLib.safeTransferFrom(token, msg.sender, address(this), amount);
        SafeTransferLib.safeTransfer(token, msg.sender, amount);
    }
}

/// @dev A spender with a permissionless pull path, the shape of many router
/// exploits: anyone can make it spend any allowance granted to it.
contract OpenSpender {
    /// @dev The intended use: spend the caller's allowance.
    function pull(address token, address to, uint256 amount) external {
        SafeTransferLib.safeTransferFrom(token, msg.sender, to, amount);
    }

    /// @dev The flaw: spend anyone's allowance.
    function pullFrom(address token, address from, address to, uint256 amount) external {
        SafeTransferLib.safeTransferFrom(token, from, to, amount);
    }
}

/// @dev A token whose `transfer` can report failure by returning `false`
/// without reverting, as some older ERC-20s do.
contract FalseReturningToken is ERC20 {
    bool public failSilently;

    function name() public pure override returns (string memory) {
        return "False";
    }

    function symbol() public pure override returns (string memory) {
        return "FALSE";
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setFailSilently(bool failSilently_) external {
        failSilently = failSilently_;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (failSilently) return false;
        return super.transfer(to, amount);
    }
}

/// @dev Deploys `Payment` with plain CREATE, at an address tests can predict
/// from this contract's nonce, with the same arguments `PaymentFactory` passes.
contract PaymentDirectDeployer {
    address internal immutable IMPLEMENTATION = new PaymentFactory().paymentImplementation();

    function deploy(
        address token,
        uint256 amount,
        Payment.Call[] memory calls,
        uint64 expirationTimestamp,
        address recovery,
        uint256 chainId
    ) external returns (Payment) {
        return new Payment(
            IMPLEMENTATION, abi.encode(token, amount, calls, expirationTimestamp, recovery, bytes32(0), chainId)
        );
    }
}

//---------- Test base ----------//

abstract contract PaymentCallsBase is Test {
    event Called(uint256 indexed index, address indexed target, bytes data, bytes result);
    event Settled(address indexed token, uint256 amount);
    event Recovered(address indexed recovery, address indexed token, uint256 amount);
    event WrongChain(uint256 expectedChainId, uint256 actualChainId);

    address internal constant MERCHANT = address(0xBEEF);
    address internal constant PLATFORM = address(0xFEE);
    address internal constant RECOVERY = address(0xCAFE);
    bytes32 internal constant SALT = bytes32(uint256(0x5A17));

    MockStablecoin internal token;
    PaymentFactory internal factory;
    uint64 internal expiry;

    PaymentDirectDeployer internal directDeployer;

    function setUp() public virtual {
        token = new MockStablecoin("Mock USD Coin", "USDC");
        factory = new PaymentFactory();
        directDeployer = new PaymentDirectDeployer();
        expiry = uint64(block.timestamp + 1 hours);
    }

    //---------- Call builders ----------//

    function _call(address target, bytes memory data) internal pure returns (Payment.Call memory) {
        return Payment.Call({target: target, data: data});
    }

    function _transfer(address to, uint256 amount) internal view returns (Payment.Call memory) {
        return _call(address(token), abi.encodeCall(ERC20.transfer, (to, amount)));
    }

    function _approve(address spender, uint256 amount) internal view returns (Payment.Call memory) {
        return _call(address(token), abi.encodeCall(ERC20.approve, (spender, amount)));
    }

    function _list() internal pure returns (Payment.Call[] memory calls) {
        calls = new Payment.Call[](0);
    }

    function _list(Payment.Call memory a) internal pure returns (Payment.Call[] memory calls) {
        calls = new Payment.Call[](1);
        calls[0] = a;
    }

    function _list(Payment.Call memory a, Payment.Call memory b) internal pure returns (Payment.Call[] memory calls) {
        calls = new Payment.Call[](2);
        calls[0] = a;
        calls[1] = b;
    }

    function _list(Payment.Call memory a, Payment.Call memory b, Payment.Call memory c)
        internal
        pure
        returns (Payment.Call[] memory calls)
    {
        calls = new Payment.Call[](3);
        calls[0] = a;
        calls[1] = b;
        calls[2] = c;
    }

    //---------- Payment lifecycle ----------//

    function _address(uint256 amount, Payment.Call[] memory calls) internal view returns (address) {
        return factory.paymentAddress(address(token), amount, calls, expiry, RECOVERY, SALT, block.chainid);
    }

    /// @dev Derives the payment address and sends `funding` of the token to it.
    function _fund(uint256 amount, Payment.Call[] memory calls, uint256 funding) internal returns (address payment) {
        payment = _address(amount, calls);
        token.mint(payment, funding);
    }

    function _execute(uint256 amount, Payment.Call[] memory calls) internal {
        factory.execute(address(token), amount, calls, expiry, RECOVERY, SALT, block.chainid);
    }

    /// @dev Funds the address the next direct deployment will land at. Call
    /// `vm.expectRevert` after this and before `_deployDirect`.
    function _fundDirect(uint256 funding) internal returns (address predicted) {
        predicted = vm.computeCreateAddress(address(directDeployer), vm.getNonce(address(directDeployer)));
        token.mint(predicted, funding);
    }

    function _deployDirect(uint256 amount, Payment.Call[] memory calls) internal returns (Payment) {
        return directDeployer.deploy(address(token), amount, calls, expiry, RECOVERY, block.chainid);
    }

    /// @dev The recorded logs emitted by `emitter`, in order.
    function _logsFrom(Vm.Log[] memory logs, address emitter) internal pure returns (Vm.Log[] memory filtered) {
        uint256 count;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == emitter) count++;
        }
        filtered = new Vm.Log[](count);
        count = 0;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == emitter) filtered[count++] = logs[i];
        }
    }
}
