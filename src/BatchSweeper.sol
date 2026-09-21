// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Payment} from "src/Payment.sol";
import {PaymentFactory} from "src/PaymentFactory.sol";

/// @notice Executes independent sweeps in one transaction.
contract BatchSweeper {
    //---------- Structs ----------//

    /// @notice The deployment parameters of the `Payment` contract.
    struct Sweep {
        address token;
        uint256 amount;
        address receiver;
        uint64 expirationTimestamp;
        address recovery;
        bytes32 salt;
        uint256 chainId;
    }

    //---------- Events ----------//

    /// @notice Emitted on failure of `factory.execute` (fresh deployment) or `Payment.recover`.
    event SweepFailed(address indexed paymentAddress, address indexed token, bytes revertData);

    //---------- Storage ----------//

    PaymentFactory public immutable FACTORY;

    constructor(PaymentFactory factory) {
        FACTORY = factory;
    }

    function executeBatch(Sweep[] calldata sweeps) external {
        for (uint256 i; i < sweeps.length; ++i) {
            Sweep calldata sweep = sweeps[i];
            address paymentAddress = FACTORY.paymentAddress(
                sweep.token,
                sweep.amount,
                sweep.receiver,
                sweep.expirationTimestamp,
                sweep.recovery,
                sweep.salt,
                sweep.chainId
            );

            if (paymentAddress.code.length != 0) {
                try Payment(paymentAddress).recover(sweep.token) returns (uint256) {}
                catch (bytes memory revertData) {
                    emit SweepFailed(paymentAddress, sweep.token, revertData);
                }
                continue;
            }

            try FACTORY.execute(
                sweep.token,
                sweep.amount,
                sweep.receiver,
                sweep.expirationTimestamp,
                sweep.recovery,
                sweep.salt,
                sweep.chainId
            ) {}
            catch (bytes memory revertData) {
                emit SweepFailed(paymentAddress, sweep.token, revertData);
            }
        }
    }
}
