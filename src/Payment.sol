// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {ERC20} from "lib/solady/src/tokens/ERC20.sol";
import {LibCall} from "lib/solady/src/utils/LibCall.sol";
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
/// contract, and must not call back into the payment. A failing call bubbles up
/// its revert, and a call to an address without code reverts with
/// `LibCall.TargetIsNotContract`.
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

    //---------- Storage ----------//

    /// @notice The address to which all token balance other than target amount is forward.
    address internal immutable RECOVERY;
    /// @notice True when deployment executed the calls, false otherwise.
    bool public immutable SETTLED;

    constructor(
        address token,
        uint256 amount,
        Call[] memory calls,
        uint64 expirationTimestamp,
        address recoveryAddress,
        uint256 chainId
    ) {
        RECOVERY = recoveryAddress;

        // On the wrong chain, the provided token address may have no code at all.
        // So, we return early to ensure we don't block deployment, and so, a later
        // `recover` call remains possible.
        if (block.chainid != chainId) {
            SETTLED = false;
            emit WrongChain(chainId, block.chainid);
            return;
        }

        uint256 balance = ERC20(token).balanceOf(address(this));

        if (block.timestamp > expirationTimestamp) {
            SafeTransferLib.safeTransfer({token: token, to: recoveryAddress, amount: balance});
            emit Recovered(recoveryAddress, token, balance);
            return;
        }

        if (balance < amount) revert InsufficientTokenBalance(balance, amount);

        // The excess leaves before any call runs, so the calls can only ever spend `amount` of it.
        uint256 remainder = balance - amount;
        if (remainder != 0) {
            SafeTransferLib.safeTransfer({token: token, to: recoveryAddress, amount: remainder});
            emit Recovered(recoveryAddress, token, remainder);
        }

        for (uint256 i; i < calls.length; ++i) {
            Call memory call = calls[i];
            // Bubbles up a revert, and rejects an address without code, where a call
            // would otherwise succeed without doing anything.
            bytes memory result = LibCall.callContract(call.target, call.data);
            emit Called(i, call.target, call.data, result);
        }

        uint256 unspent = ERC20(token).balanceOf(address(this));
        if (unspent != 0) revert AmountNotSpent(unspent);

        SETTLED = true;
        emit Settled(token, amount);
    }

    /// @notice Permissionless forward of this contract's full balance of `token` to the recovery wallet.
    function recover(address token) external returns (uint256 amount) {
        amount = ERC20(token).balanceOf(address(this));
        if (amount == 0) return 0;
        SafeTransferLib.safeTransfer({token: token, to: RECOVERY, amount: amount});
        emit Recovered(RECOVERY, token, amount);
    }
}
