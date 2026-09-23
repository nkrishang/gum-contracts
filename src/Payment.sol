// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "lib/solady/src/tokens/ERC20.sol";
import {SafeTransferLib} from "lib/solady/src/utils/SafeTransferLib.sol";

/// @notice Deployed by `PaymentFactory` at a counterfactual address.
///
/// The constructor forwards any balance above the target amount to the
/// recovery address, then executes the committed calls in order; together they
/// must spend exactly the target amount. After expiration, all funds are paid
/// to the recovery address. On the unexpected chain, all funds are paid to the
/// recovery address.
///
/// Calls run as this contract, and before it has code. A call target must be a
/// contract, and must not call back into the payment.
///
/// Gas layout, for the curious:
///
/// - `terms` is the ABI encoding of `(token, amount, calls, expirationTimestamp,
///   recovery, salt, chainId)`, read in place rather than decoded.
/// - The deployed code is not this contract's runtime but a 65-byte stub that
///   delegatecalls `implementation`, followed by the recovery address and the
///   settled flag. The implementation is this contract's runtime, deployed once
///   by the factory, so `recover` and `SETTLED` below run in the stub's context
///   and read those two values from the stub's code.
contract Payment {
    //---------- Structs ----------//

    /// @notice A call the payment makes on settlement.
    struct Call {
        address target;
        bytes data;
    }

    //---------- Errors ----------//

    /// @notice Emitted when the contract token balance is less than the target amount.
    error InsufficientTokenBalance(uint256 balance, uint256 required);
    /// @notice Emitted when a call reverts, carrying the call's own revert data.
    error CallFailed(uint256 index, bytes revertData);
    /// @notice Emitted when a call returns nothing from an address without code, having done nothing.
    error CallTargetHasNoCode(uint256 index, address target);
    /// @notice Emitted when the calls leave part of the target amount unspent.
    error AmountNotSpent(uint256 remaining);

    //---------- Events ----------//

    /// @notice Emitted after each settlement call.
    event Called(uint256 indexed index, address indexed target, bytes data, bytes result);
    /// @notice Emitted when the calls have spent exactly the target amount.
    event Settled(address indexed token, uint256 amount);
    /// @notice Emitted when a balance of token forwarded to the recovery wallet.
    event Recovered(address indexed recovery, address indexed token, uint256 amount);
    /// @notice Emitted when deployed on a chain other than the target.
    event WrongChain(uint256 expectedChainId, uint256 actualChainId);

    //---------- Constants ----------//

    /// @dev Size of the deployed stub: 44 bytes of code, the recovery address, the settled flag.
    uint256 internal constant _STUB_SIZE = 65;
    /// @dev Offset of the recovery address in the stub.
    uint256 internal constant _STUB_ARGS_OFFSET = 44;

    /// @dev `Called.selector`.
    uint256 private constant _CALLED_TOPIC = 0x74a5b5c63602662a2c967556916428411d055eeb47c4d96e6325304cb5603a99;
    /// @dev `Settled.selector`.
    uint256 private constant _SETTLED_TOPIC = 0x7823e479a1a4ebe2418874847436f8a1680c5ee5b17f38bb59dbff28e1b45552;
    /// @dev `Recovered.selector`.
    uint256 private constant _RECOVERED_TOPIC = 0xfff3b3844276f57024e0b42afec1a37f75db36511e43819a4f2a63ab7862b648;
    /// @dev `WrongChain.selector`.
    uint256 private constant _WRONG_CHAIN_TOPIC = 0x24497bc308635bccbc06f4997297d2158da178be2267eeead419bfdb19d42d4b;

    //---------- Settlement ----------//

    /// @param implementation The runtime every stub delegatecalls; see `PaymentFactory.paymentImplementation`.
    /// @param terms `abi.encode(token, amount, calls, expirationTimestamp, recovery, salt, chainId)`.
    constructor(address implementation, bytes memory terms) {
        // Not memory-safe: it lays out memory freely, and always ends in `return` or `revert`.
        assembly {
            // ERC20 `transfer`, with Solady `SafeTransferLib.safeTransfer` semantics.
            function safeTransfer(token, to, amount) {
                mstore(0x14, to)
                mstore(0x34, amount)
                mstore(0x00, 0xa9059cbb000000000000000000000000) // `transfer(address,uint256)`.
                let success := call(gas(), token, 0, 0x10, 0x44, 0x00, 0x20)
                if iszero(and(eq(mload(0x00), 1), success)) {
                    if iszero(lt(or(iszero(extcodesize(token)), returndatasize()), success)) {
                        mstore(0x00, 0x90b8ec18) // `TransferFailed()`.
                        revert(0x1c, 0x04)
                    }
                }
            }

            // ERC20 `balanceOf(address(this))`, with Solidity high-level call semantics.
            function selfBalance(token) -> amount {
                mstore(0x00, 0x70a08231) // `balanceOf(address)`.
                mstore(0x20, address())
                if iszero(staticcall(gas(), token, 0x1c, 0x24, 0x00, 0x20)) {
                    returndatacopy(0x00, 0x00, returndatasize())
                    revert(0x00, returndatasize())
                }
                if lt(returndatasize(), 0x20) { revert(0x00, 0x00) }
                amount := mload(0x00)
            }

            // Returns the stub as the deployed code, ending the constructor.
            function deployStub(stubImplementation, stubRecovery, settled) {
                // 36 5f 5f 37       calldatacopy(0, 0, calldatasize)
                // 5f 5f 36 5f 73 i  delegatecall(gas, i, 0, calldatasize, 0, 0)
                // 5a f4
                // 3d 5f 5f 3e       returndatacopy(0, 0, returndatasize)
                // 5f 3d 91 60 2a 57 jumpi(0x2a, success)
                // fd 5b f3          revert(0, rds) / jumpdest; return(0, rds)
                mstore(0x00, shl(184, 0x365f5f375f5f365f73))
                mstore(0x09, shl(96, stubImplementation))
                mstore(0x1d, shl(136, 0x5af43d5f5f3e5f3d91602a57fd5bf3))
                mstore(0x2c, shl(96, stubRecovery))
                mstore8(0x40, settled)
                return(0x00, 0x41)
            }

            // Runs call `i`, whose ABI-encoded `(target, data)` is at `element`,
            // and emits `Called`, laying out event and revert data at `free`.
            function runCall(i, element, free) {
                let target := mload(element)
                let data := add(element, mload(add(element, 0x20)))
                let length := mload(data)

                let success := call(gas(), target, 0, add(data, 0x20), length, 0x00, 0x00)
                // Return and revert data beyond 64 KiB is truncated.
                let resultLength := returndatasize()
                if gt(resultLength, 0xffff) { resultLength := 0xffff }

                if iszero(success) {
                    mstore(free, 0x5c0dee5d) // `CallFailed(uint256,bytes)`.
                    mstore(add(free, 0x20), i)
                    mstore(add(free, 0x40), 0x40)
                    mstore(add(free, 0x60), resultLength)
                    returndatacopy(add(free, 0x80), 0x00, resultLength)
                    mstore(add(add(free, 0x80), resultLength), 0) // Zero the padding.
                    revert(add(free, 0x1c), add(0x64, and(add(resultLength, 0x1f), not(0x1f))))
                }
                // A call to an address without code succeeds without doing anything.
                if iszero(resultLength) {
                    if iszero(extcodesize(target)) {
                        mstore(0x00, 0x5dcee19d) // `CallTargetHasNoCode(uint256,address)`.
                        mstore(0x20, i)
                        mstore(0x40, target)
                        revert(0x1c, 0x44)
                    }
                }

                // `Called(i, target, data, result)`, with `abi.encode(data, result)` at `free`.
                let paddedLength := and(add(length, 0x1f), not(0x1f))
                mstore(free, 0x40)
                mstore(add(free, 0x20), add(0x60, paddedLength))
                mstore(add(free, 0x40), length)
                mcopy(add(free, 0x60), add(data, 0x20), length)
                mstore(add(add(free, 0x60), length), 0) // Zero the padding.
                let result := add(add(free, 0x60), paddedLength)
                mstore(result, resultLength)
                returndatacopy(add(result, 0x20), 0x00, resultLength)
                mstore(add(add(result, 0x20), resultLength), 0) // Zero the padding.
                log3(
                    free,
                    add(sub(add(result, 0x20), free), and(add(resultLength, 0x1f), not(0x1f))),
                    _CALLED_TOPIC,
                    i,
                    target
                )
            }

            // The terms' head: token, amount, calls offset, expiration, recovery, salt, chainId.
            let t := add(terms, 0x20)
            if lt(mload(terms), 0xe0) { revert(0x00, 0x00) }
            // Scratch space for event and revert data, past everything allocated.
            let free := mload(0x40)

            // On the wrong chain, the provided token address may have no code at all.
            // So, we return early to ensure we don't block deployment, and so, a later
            // `recover` call remains possible.
            if iszero(eq(chainid(), mload(add(t, 0xc0)))) {
                mstore(0x00, mload(add(t, 0xc0)))
                mstore(0x20, chainid())
                log1(0x00, 0x40, _WRONG_CHAIN_TOPIC)
                deployStub(implementation, mload(add(t, 0x80)), 0)
            }

            let funded := selfBalance(mload(t))

            // After expiry, the whole balance goes to recovery.
            if gt(timestamp(), mload(add(t, 0x60))) {
                safeTransfer(mload(t), mload(add(t, 0x80)), funded)
                mstore(0x00, funded)
                log3(0x00, 0x20, _RECOVERED_TOPIC, mload(add(t, 0x80)), mload(t))
                deployStub(implementation, mload(add(t, 0x80)), 0)
            }

            if lt(funded, mload(add(t, 0x20))) {
                mstore(0x40, mload(add(t, 0x20)))
                mstore(0x20, funded)
                mstore(0x00, 0xa17124f8) // `InsufficientTokenBalance(uint256,uint256)`.
                revert(0x1c, 0x44)
            }

            // The excess leaves before any call runs, so the calls can only ever spend `amount` of it.
            let remainder := sub(funded, mload(add(t, 0x20)))
            if remainder {
                safeTransfer(mload(t), mload(add(t, 0x80)), remainder)
                mstore(0x00, remainder)
                log3(0x00, 0x20, _RECOVERED_TOPIC, mload(add(t, 0x80)), mload(t))
            }

            let calls := add(t, mload(add(t, 0x40)))
            for { let i := 0 } lt(i, mload(calls)) { i := add(i, 1) } {
                runCall(i, add(add(calls, 0x20), mload(add(add(calls, 0x20), shl(5, i)))), free)
            }

            let unspent := selfBalance(mload(t))
            if unspent {
                mstore(0x00, 0xe58991f1) // `AmountNotSpent(uint256)`.
                mstore(0x20, unspent)
                revert(0x1c, 0x24)
            }

            mstore(0x00, mload(add(t, 0x20)))
            log2(0x00, 0x20, _SETTLED_TOPIC, mload(t))
            deployStub(implementation, mload(add(t, 0x80)), 1)
        }
    }

    //---------- Implementation, run by every payment's stub ----------//

    /// @notice True when deployment executed the calls, false otherwise.
    function SETTLED() external view returns (bool settled) {
        (, settled) = _stubArgs();
    }

    /// @notice Permissionless forward of this contract's full balance of `token` to the recovery wallet.
    function recover(address token) external returns (uint256 amount) {
        (address recovery,) = _stubArgs();
        amount = ERC20(token).balanceOf(address(this));
        if (amount == 0) return 0;
        SafeTransferLib.safeTransfer({token: token, to: recovery, amount: amount});
        emit Recovered(recovery, token, amount);
    }

    /// @dev Reads the recovery address and settled flag from the stub's code.
    /// Reverts outside a stub, e.g. when the implementation is called directly.
    function _stubArgs() private view returns (address recovery, bool settled) {
        /// @solidity memory-safe-assembly
        assembly {
            if iszero(eq(extcodesize(address()), _STUB_SIZE)) { revert(0x00, 0x00) }
            extcodecopy(address(), 0x00, _STUB_ARGS_OFFSET, 0x15)
            let args := mload(0x00)
            recovery := shr(96, args)
            settled := byte(20, args)
        }
    }
}
