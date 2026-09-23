// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Payment} from "src/Payment.sol";

/// @notice Ownerless CREATE2 deployer for `Payment`.
///
/// Every term of a payment, including every call target and its calldata, is
/// part of its init code, so the counterfactual address fixes the routing of funds:
///
///     terms    = abi.encode(token, amount, calls, expirationTimestamp, recovery, salt, chainId)
///     initCode = type(Payment).creationCode ++ abi.encode(paymentImplementation(), terms)
///     payment  = CREATE2(factory, bytes32(0), keccak256(initCode))
///
/// `terms` is exactly the calldata arguments of `paymentAddress` and `execute`,
/// which both build the init code from their own calldata.
///
/// Execution is permissionless; the deployed `Payment` reports the outcome through
/// its `Called`/`Settled`/`Recovered` events and `SETTLED`. When the `Payment`
/// constructor reverts, `execute` reverts with the same revert data. It reverts
/// with `AlreadyDeployed` once the payment has executed, and `DeploymentFailed`
/// when the constructor reverted without data.
///
/// The factory is deployed at the same address on every supported chain, so
/// the same arguments generate the same address for `Payment` everywhere.
contract PaymentFactory {
    //---------- Errors ----------//

    /// @notice The payment for these terms has already been executed.
    error AlreadyDeployed();
    /// @notice The deployment failed without revert data, e.g. out of gas.
    error DeploymentFailed();

    constructor() {
        // Deploy `Payment`'s runtime as the implementation every payment's stub
        // delegatecalls. As this contract's first creation, it lands at the
        // CREATE address for nonce 1 (see `paymentImplementation`).
        bytes memory runtime = type(Payment).runtimeCode;
        address implementation;
        /// @solidity memory-safe-assembly
        assembly {
            let n := mload(runtime)
            // 61 nnnn 80 60 0a 5f 39 5f f3: codecopy(0, 10, n); return(0, n). Overwrites the length word.
            mstore(runtime, or(or(shl(72, 0x61), shl(56, n)), 0x80600a5f395ff3))
            implementation := create(0, add(runtime, 0x16), add(n, 0x0a))
        }
        if (implementation == address(0) || implementation != paymentImplementation()) revert DeploymentFailed();
    }

    //---------- Views ----------//

    /// @notice Returns the deterministic payment address for the given parameters.
    function paymentAddress(
        address token,
        uint256 amount,
        Payment.Call[] calldata calls,
        uint64 expirationTimestamp,
        address recovery,
        bytes32 salt,
        uint256 chainId
    ) external view returns (address payable payment) {
        (token, amount, calls, expirationTimestamp, recovery, salt, chainId);
        (uint256 initCode, uint256 initCodeLength) = _initCode();
        /// @solidity memory-safe-assembly
        assembly {
            payment := _create2Address(initCode, initCodeLength)

            function _create2Address(offset, length) -> predicted {
                let initCodeHash := keccak256(offset, length)
                mstore(0x00, address())
                mstore8(0x0b, 0xff)
                mstore(0x20, 0)
                let m := mload(0x40)
                mstore(0x40, initCodeHash)
                predicted := and(keccak256(0x0b, 0x55), 0xffffffffffffffffffffffffffffffffffffffff)
                mstore(0x40, m)
            }
        }
    }

    /// @notice The implementation every payment's stub delegatecalls: `Payment`'s
    /// runtime, deployed by this factory's constructor.
    function paymentImplementation() public view returns (address implementation) {
        /// @solidity memory-safe-assembly
        assembly {
            mstore(0x14, address())
            mstore(0x00, 0xd694)
            mstore8(0x34, 0x01) // Nonce 1.
            implementation := and(keccak256(0x1e, 0x17), 0xffffffffffffffffffffffffffffffffffffffff)
            mstore(0x34, 0) // Restore the part of the free memory pointer that was overwritten.
        }
    }

    //---------- Execution ----------//

    /// @notice Executes the deterministic payment for the given parameters by deploying `Payment`.
    function execute(
        address token,
        uint256 amount,
        Payment.Call[] calldata calls,
        uint64 expirationTimestamp,
        address recovery,
        bytes32 salt,
        uint256 chainId
    ) external {
        (token, amount, calls, expirationTimestamp, recovery, salt, chainId);
        (uint256 initCode, uint256 initCodeLength) = _initCode();
        // Not memory-safe: it lays out memory freely, and always ends in `return` or `revert`.
        assembly {
            if iszero(create2(0, initCode, initCodeLength, 0)) {
                // Bubble up the constructor's revert.
                if returndatasize() {
                    returndatacopy(0x00, 0x00, returndatasize())
                    revert(0x00, returndatasize())
                }
                // No revert data: the address is taken, or the constructor failed silently.
                let initCodeHash := keccak256(initCode, initCodeLength)
                mstore(0x00, address())
                mstore8(0x0b, 0xff)
                mstore(0x20, 0)
                mstore(0x40, initCodeHash)
                if extcodesize(keccak256(0x0b, 0x55)) {
                    mstore(0x00, 0xa6ef0ba1) // `AlreadyDeployed()`.
                    revert(0x1c, 0x04)
                }
                mstore(0x00, 0x30116425) // `DeploymentFailed()`.
                revert(0x1c, 0x04)
            }
            stop()
        }
    }

    //---------- Internal ----------//

    /// @dev Lays out `type(Payment).creationCode ++ abi.encode(paymentImplementation(), terms)`
    /// in memory, where `terms` is this call's calldata arguments, and returns its
    /// offset and length. Leaves it unallocated: callers hash or deploy it straight away.
    function _initCode() private view returns (uint256 offset, uint256 length) {
        bytes memory creationCode = type(Payment).creationCode;
        address implementation = paymentImplementation();
        /// @solidity memory-safe-assembly
        assembly {
            offset := add(creationCode, 0x20)
            let args := add(offset, mload(creationCode))
            let n := sub(calldatasize(), 4)
            let paddedLength := and(add(n, 0x1f), not(0x1f))
            mstore(args, implementation)
            mstore(add(args, 0x20), 0x40)
            mstore(add(args, 0x40), n)
            // Copying past the end of calldata writes zeros, which pads `terms`.
            calldatacopy(add(args, 0x60), 4, paddedLength)
            length := add(sub(args, offset), add(0x60, paddedLength))
        }
    }
}
