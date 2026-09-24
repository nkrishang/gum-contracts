// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test} from "lib/forge-std/src/Test.sol";
import {ERC20} from "lib/solady/src/tokens/ERC20.sol";
import {MockStablecoin} from "src/mock/MockStablecoin.sol";
import {Payment} from "src/Payment.sol";
import {PaymentFactory} from "src/PaymentFactory.sol";
import {Gate, RawPaymentDeployer} from "test/utils/SettlementFixtures.sol";

/// @notice The `Payment` constructor reads the calls' offsets and lengths
/// straight out of `terms`, which on the direct-deployment path no ABI decoder
/// has validated. Every one of them is therefore bounds-checked to sit inside
/// `terms`: a malformed list reverts the deployment instead of executing bytes
/// that a previous call's return data could have placed outside it. (The
/// factory path cannot produce malformed terms — its own decoder rejects them
/// first, and it copies its calldata verbatim.) Also pins the EIP-3860
/// init-code size limit, which keeps an undeployable address from ever being
/// offered.
contract PaymentCallBoundsTest is Test {
    MockStablecoin internal token;
    PaymentFactory internal factory;
    RawPaymentDeployer internal rawDeployer;
    address internal gate;
    uint64 internal expiry;

    address internal constant RECEIVER = address(0xBEEF);
    address internal constant RECOVERY = address(0xCAFE);

    constructor() {
        // Stand-in call target at a fixed address; `pass()` ignores trailing calldata.
        gate = address(new Gate());
    }

    function setUp() public {
        token = new MockStablecoin("Mock USD Coin", "USDC");
        factory = new PaymentFactory();
        rawDeployer = new RawPaymentDeployer();
        expiry = uint64(block.timestamp + 1 hours);
        Gate(gate).setOpen(true);
    }

    //---------- Crafting terms ----------//

    /// @dev The fields a malformed list might lie about.
    struct Raw {
        uint256 arrayLength;
        uint256 elementOffset;
        uint256 dataOffset;
        uint256 dataLength;
    }

    /// @dev Builds `terms` for one call, choosing every offset and length
    /// explicitly. The call is `pass()` at the fixed `gate` address; the data
    /// word can claim a different length than the `0x60` bytes actually
    /// provided, which is how an overrun is crafted. `amount` is zero so
    /// nothing blocks the calls.
    function _terms(Raw memory r) private view returns (bytes memory terms) {
        terms = abi.encodePacked(
            // abi.encode(token, amount, calls, expiry, recovery, salt, chainId), with
            // `calls` spliced in after the head.
            abi.encode(address(token), 0, 0xe0, expiry, RECOVERY, bytes32(0), block.chainid),
            abi.encode(r.arrayLength, r.elementOffset, gate, r.dataOffset, r.dataLength),
            abi.encodeWithSignature("pass()"), // 4 bytes
            new bytes(0x40), // padding to 0x44 bytes of data
            new bytes(0x1c) // the data's zero padding to a whole word
        );
    }

    function _canonical() private pure returns (Raw memory r) {
        r = Raw({arrayLength: 1, elementOffset: 0x20, dataOffset: 0x40, dataLength: 0x44});
    }

    /// @dev `rawDeployer.deploy(terms)`; returns the call's success and revert data.
    function _deployRaw(bytes memory terms) private returns (bool ok, bytes memory revertData) {
        (ok, revertData) = address(rawDeployer).call(abi.encodeCall(RawPaymentDeployer.deploy, (terms)));
    }

    //---------- Well-formed terms ----------//

    /// @notice The canonical shape this file's crafted terms copy: it settles
    /// and runs the call, so the malformed cases below are rejected for their
    /// offsets and lengths, not for their overall shape.
    function test_canonical_terms_settle() public {
        (bool ok, bytes memory revertData) = _deployRaw(_terms(_canonical()));
        assertTrue(ok, revertData.length == 0 ? "reverted with no data" : string(revertData));
        assertGatePassed(1);
    }

    /// @notice A data length reaching exactly the end of `terms` is accepted,
    /// even though it overlaps the array's own encoding: it is still all
    /// committed bytes.
    function test_a_data_length_reaching_exactly_the_end_of_terms_is_accepted() public {
        (bool ok, bytes memory revertData) =
            _deployRaw(_terms(Raw({arrayLength: 1, elementOffset: 0x20, dataOffset: 0x40, dataLength: 0x60})));
        assertTrue(ok, revertData.length == 0 ? "reverted with no data" : string(revertData));
        assertGatePassed(1);
    }

    //---------- Malformed terms ----------//

    /// @notice A calls offset past the end of `terms` cannot even find the
    /// array's length word.
    function test_a_calls_offset_past_the_end_of_terms_reverts() public {
        bytes memory terms = abi.encodePacked(
            abi.encode(address(token), 0, 0x1e0, expiry, RECOVERY, bytes32(0), block.chainid),
            abi.encode(1, 0x20, gate, 0x40, 0x44),
            abi.encodeWithSignature("pass()"),
            new bytes(0x40),
            new bytes(0x1c)
        );
        (bool ok, bytes memory revertData) = _deployRaw(terms);
        assertFalse(ok, "deployment must revert");
        assertEq(revertData, hex"");
        assertGatePassed(0);
    }

    /// @notice An element offset pointing past `terms` would otherwise read the
    /// tuple from scratch memory, which a previous call's return data can reach.
    function test_an_element_offset_past_the_end_of_terms_reverts() public {
        (bool ok, bytes memory revertData) = _deployRaw(_terms(_withElementOffset(0x10000)));
        assertFalse(ok, "deployment must revert");
        assertEq(revertData, hex"");
        assertGatePassed(0);
    }

    /// @notice An element offset that points the tuple's head just past `terms`.
    function test_an_element_head_past_the_end_of_terms_reverts() public {
        (bool ok, bytes memory revertData) = _deployRaw(_terms(_withElementOffset(0x60)));
        assertFalse(ok, "deployment must revert");
        assertEq(revertData, hex"");
        assertGatePassed(0);
    }

    /// @notice A data offset past `terms` would execute calldata that was never
    /// committed to the address.
    function test_a_data_offset_past_the_end_of_terms_reverts() public {
        (bool ok, bytes memory revertData) = _deployRaw(_terms(_withDataOffset(0x10000)));
        assertFalse(ok, "deployment must revert");
        assertEq(revertData, hex"");
        assertGatePassed(0);
    }

    /// @notice The offset checks cannot be bypassed by wrapping: a near-`2**256`
    /// offset would otherwise wrap the data pointer back into memory.
    function test_a_wrapping_data_offset_reverts() public {
        (bool ok, bytes memory revertData) =
            _deployRaw(_terms(_withDataOffset(0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffc0)));
        assertFalse(ok, "deployment must revert");
        assertEq(revertData, hex"");
        assertGatePassed(0);
    }

    /// @notice A data length that overruns `terms` is rejected.
    function test_a_data_length_overrunning_terms_reverts() public {
        (bool ok, bytes memory revertData) = _deployRaw(_terms(_withDataLength(0x10000)));
        assertFalse(ok, "deployment must revert");
        assertEq(revertData, hex"");
        assertGatePassed(0);
    }

    /// @notice One byte past the end is still past the end. The largest length
    /// this layout allows is `0x60`: `terms` ends `0x60` bytes after the data
    /// word, and the bounds check spends `0x20` of them on the length word.
    function test_a_data_length_one_byte_over_the_limit_reverts() public {
        (bool ok, bytes memory revertData) = _deployRaw(_terms(_withDataLength(0x61)));
        assertFalse(ok, "deployment must revert");
        assertEq(revertData, hex"");
        assertGatePassed(0);
    }

    /// @notice An array length that lies about the number of elements: the
    /// second element's offset word would be read out of the call's own data
    /// bytes, naming an element far outside `terms`.
    function test_an_array_length_that_overcounts_the_elements_reverts() public {
        (bool ok, bytes memory revertData) = _deployRaw(_terms(_withArrayLength(2)));
        assertFalse(ok, "deployment must revert");
        assertEq(revertData, hex"");
        assertGatePassed(0, "the first call rolls back with the deployment");
    }

    /// @notice Truncated `terms` — less than the seven head words — is rejected
    /// before anything is read.
    function test_truncated_terms_revert() public {
        bytes memory terms = abi.encode(address(token), 0, 0xe0, expiry, RECOVERY, bytes32(0), block.chainid);
        assembly {
            let n := mload(terms)
            mstore(terms, sub(n, 0x20)) // Drop the last word.
        }
        (bool ok, bytes memory revertData) = _deployRaw(terms);
        assertFalse(ok, "deployment must revert");
        assertEq(revertData, hex"");
    }

    //---------- Helpers ----------//

    function _withArrayLength(uint256 arrayLength) private pure returns (Raw memory r) {
        r = _canonical();
        r.arrayLength = arrayLength;
    }

    function _withElementOffset(uint256 elementOffset) private pure returns (Raw memory r) {
        r = _canonical();
        r.elementOffset = elementOffset;
    }

    function _withDataOffset(uint256 dataOffset) private pure returns (Raw memory r) {
        r = _canonical();
        r.dataOffset = dataOffset;
    }

    function _withDataLength(uint256 dataLength) private pure returns (Raw memory r) {
        r = _canonical();
        r.dataLength = dataLength;
    }

    /// @dev Reverts unless the fixed gate was `passed` exactly `count` times.
    function assertGatePassed(uint256 count, string memory message) private view {
        assertEq(Gate(gate).passes(), count, message);
    }

    function assertGatePassed(uint256 count) private view {
        assertGatePassed(count, "");
    }

    //---------- Init-code size limit ----------//

    /// @dev One call to `token.transfer(RECEIVER, 10e6)` whose data is padded
    /// with zeros to `dataLength` bytes, which sets the whole init code's size:
    /// `creationCode ++ abi.encode(implementation, terms)` where the terms are
    /// `0x1e0 + dataLength` bytes (head, array length, element offset, tuple,
    /// data length, data).
    function _paddedTransferCalls(uint256 dataLength) private view returns (Payment.Call[] memory calls) {
        calls = new Payment.Call[](1);
        calls[0] = Payment.Call({
            target: address(token),
            data: abi.encodePacked(abi.encodeCall(ERC20.transfer, (RECEIVER, 10e6)), new bytes(dataLength - 68))
        });
    }

    /// @dev The largest one-call data length whose init code stays within
    /// EIP-3860's 49,152-byte limit.
    function _largestAcceptedDataLength() private view returns (uint256 length) {
        uint256 slack = 49152 - type(Payment).creationCode.length - 0x1e0;
        length = (slack / 32) * 32;
    }

    /// @notice Terms at the limit itself are accepted and settle: the boundary
    /// is inclusive, and the oversized padding rides along as a transfer that
    /// ignores its trailing calldata.
    function test_init_code_at_the_eip3860_limit_is_accepted() public {
        uint256 dataLength = _largestAcceptedDataLength();
        Payment.Call[] memory calls = _paddedTransferCalls(dataLength);
        address payment =
            factory.paymentAddress(address(token), 10e6, calls, expiry, RECOVERY, bytes32(0), block.chainid);
        token.mint(payment, 10e6);

        factory.execute(address(token), 10e6, calls, expiry, RECOVERY, bytes32(0), block.chainid);

        assertTrue(Payment(payment).SETTLED());
        assertEq(token.balanceOf(RECEIVER), 10e6);
    }

    /// @notice Terms one word over the limit are refused an address at all:
    /// `execute` could never deploy them, so funding the predicted address
    /// would strand the funds. Both entry points revert with the same error.
    function test_init_code_over_the_eip3860_limit_reverts_with_init_code_too_large() public {
        uint256 dataLength = _largestAcceptedDataLength() + 32;
        uint256 initCodeLength = type(Payment).creationCode.length + 0x1e0 + dataLength;
        Payment.Call[] memory calls = _paddedTransferCalls(dataLength);

        vm.expectRevert(abi.encodeWithSelector(PaymentFactory.InitCodeTooLarge.selector, initCodeLength));
        factory.paymentAddress(address(token), 10e6, calls, expiry, RECOVERY, bytes32(0), block.chainid);

        vm.expectRevert(abi.encodeWithSelector(PaymentFactory.InitCodeTooLarge.selector, initCodeLength));
        factory.execute(address(token), 10e6, calls, expiry, RECOVERY, bytes32(0), block.chainid);
    }
}
