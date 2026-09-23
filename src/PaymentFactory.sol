// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {CREATE3} from "lib/solady/src/utils/CREATE3.sol";
import {Payment} from "src/Payment.sol";

/// @notice Ownerless CREATE3 deployer for `Payment`.
///
/// Every constructor parameter of `Payment`, including every call target and
/// its calldata, is committed into the deployment salt, so the counterfactual
/// address fixes the routing of funds.
///
/// Execution is permissionless; the deployed `Payment` reports the outcome through
/// its `Called`/`Settled`/`Recovered` events and `SETTLED` state variable.
///
/// The factory is deployed at the same address on every supported chain, so
/// the same arguments generate the same address for `Payment` everywhere.
contract PaymentFactory {
    /// @notice Returns the deterministic payment address for the given parameters.
    function paymentAddress(
        address token,
        uint256 amount,
        Payment.Call[] calldata calls,
        uint64 expirationTimestamp,
        address recovery,
        bytes32 salt,
        uint256 chainId
    ) external view returns (address payable) {
        return payable(CREATE3.predictDeterministicAddress(
                deploymentSalt(token, amount, calls, expirationTimestamp, recovery, salt, chainId)
            ));
    }

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
        CREATE3.deployDeterministic({
            salt: deploymentSalt(token, amount, calls, expirationTimestamp, recovery, salt, chainId),
            initCode: abi.encodePacked(
                type(Payment).creationCode, abi.encode(token, amount, calls, expirationTimestamp, recovery, chainId)
            )
        });
    }

    /// @notice Returns the CREATE3 salt used to generate the deterministic payment address for the given parameters.
    function deploymentSalt(
        address token,
        uint256 amount,
        Payment.Call[] calldata calls,
        uint64 expirationTimestamp,
        address recovery,
        bytes32 salt,
        uint256 chainId
    ) private pure returns (bytes32) {
        return keccak256(abi.encode(token, amount, calls, expirationTimestamp, recovery, salt, chainId));
    }
}
