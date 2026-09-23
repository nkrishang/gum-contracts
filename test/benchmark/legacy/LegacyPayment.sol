// SPDX-License-Identifier: MIT
// Verbatim copy of the pre-settlement-calls generation from `main` (f4b7a38),
// renamed so it compiles alongside the current contracts. Benchmark baseline only.
pragma solidity ^0.8.13;

import {ERC20} from "lib/solady/src/tokens/ERC20.sol";
import {SafeTransferLib} from "lib/solady/src/utils/SafeTransferLib.sol";

/// @notice Deployed by `PaymentFactory` at a counterfactual address.
///
/// The constructor pays the target amount to the receiver, and pays out the
/// balance to the recovery address. After expiration, all funds are paid to
/// the recovery address. On the unexpected chain, all funds are paid to the
/// recovery address.
contract LegacyPayment {
    //---------- Errors ----------//

    /// @notice Emitted when the contract token balance is less than the target amount.
    error InsufficientTokenBalance(uint256 balance, uint256 required);

    //---------- Events ----------//

    /// @notice Emitted when receiver is paid target amount at deployment.
    event Settled(address indexed receiver, uint256 amount);
    /// @notice Emitted when a balance of token forwarded to the recovery wallet.
    event Recovered(address indexed recovery, address indexed token, uint256 amount);
    /// @notice Emitted when deployed on a chain other than the target.
    event WrongChain(uint256 expectedChainId, uint256 actualChainId);

    //---------- Storage ----------//

    /// @notice The address to which all token balance other than target amount is forward.
    address internal immutable RECOVERY;
    /// @notice True when deployment paid target amount to receiver, false otherwise.
    bool public immutable SETTLED;

    constructor(
        address token,
        uint256 amount,
        address receiver,
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

        SETTLED = true;
        SafeTransferLib.safeTransfer({token: token, to: receiver, amount: amount});
        emit Settled(receiver, amount);

        uint256 remainder = balance - amount;
        if (remainder != 0) {
            SafeTransferLib.safeTransfer({token: token, to: recoveryAddress, amount: remainder});
            emit Recovered(recoveryAddress, token, remainder);
        }
    }

    /// @notice Permissionless forward of this contract's full balance of `token` to the recovery wallet.
    function recover(address token) external returns (uint256 amount) {
        amount = ERC20(token).balanceOf(address(this));
        if (amount == 0) return 0;
        SafeTransferLib.safeTransfer({token: token, to: RECOVERY, amount: amount});
        emit Recovered(RECOVERY, token, amount);
    }
}
