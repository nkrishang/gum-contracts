// SPDX-License-Identifier: MIT
// Verbatim copy of the pre-settlement-calls generation from `main` (f4b7a38),
// renamed so it compiles alongside the current contracts. Benchmark baseline only.
pragma solidity ^0.8.13;

import {CREATE3} from "lib/solady/src/utils/CREATE3.sol";
import {LegacyPayment} from "test/benchmark/legacy/LegacyPayment.sol";

/// @notice Ownerless CREATE3 deployer for `Payment`.
///
/// Every constructor parameter, of `Payment` is committed into the deployment salt,
/// so the counterfactual address fixes the routing of funds.
///
/// Execution is permissionless; the deployed `Payment` reports the outcome through
/// its `Settled`/`Recovered` events and `settled` state variable.
///
/// The factory is deployed at the same address on every supported chain, so
/// the same arguments generate the same address for `Payment` everywhere.
contract LegacyPaymentFactory {
    /// @notice Returns the deterministic payment address for the given parameters.
    function paymentAddress(
        address token,
        uint256 amount,
        address receiver,
        uint64 expirationTimestamp,
        address recovery,
        bytes32 salt,
        uint256 chainId
    ) external view returns (address payable) {
        return payable(CREATE3.predictDeterministicAddress(
                deploymentSalt(token, amount, receiver, expirationTimestamp, recovery, salt, chainId)
            ));
    }

    /// @notice Executes the deterministic payment for the given paramters by deploying `Payment`.
    function execute(
        address token,
        uint256 amount,
        address receiver,
        uint64 expirationTimestamp,
        address recovery,
        bytes32 salt,
        uint256 chainId
    ) external {
        CREATE3.deployDeterministic({
            salt: deploymentSalt(token, amount, receiver, expirationTimestamp, recovery, salt, chainId),
            initCode: abi.encodePacked(
                type(LegacyPayment).creationCode,
                abi.encode(token, amount, receiver, expirationTimestamp, recovery, chainId)
            )
        });
    }

    /// @notice Returns the CREATE3 salt used to generate the deterministic payment address for the given parameters.
    function deploymentSalt(
        address token,
        uint256 amount,
        address receiver,
        uint64 expirationTimestamp,
        address recovery,
        bytes32 salt,
        uint256 chainId
    ) private pure returns (bytes32) {
        return keccak256(abi.encode(token, amount, receiver, expirationTimestamp, recovery, salt, chainId));
    }
}
