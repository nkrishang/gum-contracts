// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

/// @dev The EIP-3009 surface of Circle's FiatToken (v2.2 and later): a
/// `receiveWithAuthorization` that only the payee may submit.
interface IERC3009 {
    function receiveWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        bytes calldata signature
    ) external;
    function approve(address spender, uint256 value) external returns (bool);
}

/// @dev CCTP V2 `TokenMessengerV2.depositForBurn`.
interface ITokenMessengerV2 {
    function depositForBurn(
        uint256 amount,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        address burnToken,
        bytes32 destinationCaller,
        uint256 maxFee,
        uint32 minFinalityThreshold
    ) external;
}

/// @notice Bridges a merchant's USDC through CCTP on the strength of one
/// off-chain signature, without the relayer ever choosing where it lands.
///
/// The merchant signs an EIP-3009 `ReceiveWithAuthorization` naming this
/// contract as the payee and, as the authorization's nonce, a commitment to
/// the CCTP destination: `keccak256(abi.encode(destinationDomain,
/// mintRecipient, salt))`. Whoever relays it must supply the same destination,
/// because this contract recomputes the nonce from what it is told and USDC
/// checks that nonce against the signature.
///
/// A relayer that substitutes its own recipient produces a nonce the merchant
/// never signed, and the token reverts before any funds move. USDC also
/// requires the payee itself to submit the authorization, so nobody but
/// this contract can consume it, and this contract can do exactly one thing
/// with what it receives: burn it towards the signed recipient.
///
/// Stateless, ownerless, holds nothing between transactions. Standard
/// (finality-attested) transfers only: zero protocol fee, `maxFee` 0, so the
/// recipient is minted the full amount.
contract WithdrawalForwarder {
    /// @notice CCTP V2's finality threshold for a Standard Transfer.
    uint32 public constant STANDARD_FINALITY_THRESHOLD = 2000;

    ITokenMessengerV2 public immutable tokenMessenger;

    /// @notice `value` of `token` left `from` towards `mintRecipient` on `destinationDomain`.
    event Bridged(
        address indexed from,
        address indexed token,
        uint256 value,
        uint32 destinationDomain,
        bytes32 indexed mintRecipient
    );

    constructor(ITokenMessengerV2 tokenMessenger_) {
        tokenMessenger = tokenMessenger_;
    }

    /// @notice The EIP-3009 nonce a merchant signs to commit to a destination.
    function bridgeNonce(uint32 destinationDomain, bytes32 mintRecipient, bytes32 salt) public pure returns (bytes32) {
        return keccak256(abi.encode(destinationDomain, mintRecipient, salt));
    }

    /// @notice Pull `value` of `token` from `from` under the signed authorization
    /// and burn it towards `mintRecipient` on `destinationDomain`.
    /// @param signature `from`'s EIP-712 signature over `ReceiveWithAuthorization{from, to: this,
    /// value, validAfter: 0, validBefore, nonce: bridgeNonce(destinationDomain, mintRecipient, salt)}`.
    function bridge(
        IERC3009 token,
        address from,
        uint256 value,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        bytes32 salt,
        uint256 validBefore,
        bytes calldata signature
    ) external {
        bytes32 nonce = bridgeNonce(destinationDomain, mintRecipient, salt);
        token.receiveWithAuthorization(from, address(this), value, 0, validBefore, nonce, signature);
        require(token.approve(address(tokenMessenger), value), "approve failed");
        tokenMessenger.depositForBurn(
            value,
            destinationDomain,
            mintRecipient,
            address(token),
            bytes32(0), // any relayer may submit the mint
            0, // no fee: Standard Transfer
            STANDARD_FINALITY_THRESHOLD
        );
        emit Bridged(from, address(token), value, destinationDomain, mintRecipient);
    }
}
