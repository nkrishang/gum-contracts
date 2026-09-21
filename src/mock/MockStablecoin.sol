// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {ERC20} from "lib/solady/src/tokens/ERC20.sol";
import {ECDSA} from "lib/solady/src/utils/ECDSA.sol";

/// @notice Minimal mintable six-decimal stablecoin fixture for local Anvil use
/// only: the bootstrap deploys one as USDC and one as USDT.
///
/// It mirrors the two Circle FiatToken controls the sweep worker classifies
/// failures with: a global pause and per-account blacklisting, both readable
/// through the same view functions the real token exposes. It also mirrors
/// the EIP-3009 authorizations a withdrawal relays (`transferWithAuthorization`
/// and the payee-only `receiveWithAuthorization`), with Circle's type hashes
/// and revert strings, so the withdrawal path runs unchanged against Anvil.
/// The EIP-712 domain is solady's: `name()`, version "1", exposed through
/// `version()` the way FiatToken exposes its "2".
contract MockStablecoin is ERC20 {
    string private _name;
    string private _symbol;

    constructor(string memory name_, string memory symbol_) {
        _name = name_;
        _symbol = symbol_;
    }

    // keccak256("TransferWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)")
    bytes32 public constant TRANSFER_WITH_AUTHORIZATION_TYPEHASH =
        0x7c7c6cdb67a18743f49ec6fa9b35f50d52ed05cbed4cc592e13b44501c1a2267;
    // keccak256("ReceiveWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)")
    bytes32 public constant RECEIVE_WITH_AUTHORIZATION_TYPEHASH =
        0xd099cc98ef71107a616c4f0f941f04c322d8e254fe26b3c6668db87aae413de8;

    event AuthorizationUsed(address indexed authorizer, bytes32 indexed nonce);

    bool public paused;
    mapping(address => bool) internal blacklisted;
    mapping(address => mapping(bytes32 => bool)) internal authorizationStates;

    function name() public view override returns (string memory) {
        return _name;
    }

    function symbol() public view override returns (string memory) {
        return _symbol;
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    /// @notice The EIP-712 domain version, as FiatToken reports it.
    function version() public pure returns (string memory) {
        return "1";
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setPaused(bool paused_) external {
        paused = paused_;
    }

    function setBlacklisted(address account, bool blacklisted_) external {
        blacklisted[account] = blacklisted_;
    }

    function isBlacklisted(address account) external view returns (bool) {
        return blacklisted[account];
    }

    function authorizationState(address authorizer, bytes32 nonce) external view returns (bool) {
        return authorizationStates[authorizer][nonce];
    }

    function transferWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        bytes calldata signature
    ) external {
        _useAuthorization(
            TRANSFER_WITH_AUTHORIZATION_TYPEHASH, from, to, value, validAfter, validBefore, nonce, signature
        );
        _transfer(from, to, value);
    }

    function receiveWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        bytes calldata signature
    ) external {
        require(to == msg.sender, "FiatTokenV2: caller must be the payee");
        _useAuthorization(
            RECEIVE_WITH_AUTHORIZATION_TYPEHASH, from, to, value, validAfter, validBefore, nonce, signature
        );
        _transfer(from, to, value);
    }

    function _useAuthorization(
        bytes32 typeHash,
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        bytes calldata signature
    ) internal {
        require(block.timestamp > validAfter, "FiatTokenV2: authorization is not yet valid");
        require(block.timestamp < validBefore, "FiatTokenV2: authorization is expired");
        require(!authorizationStates[from][nonce], "FiatTokenV2: authorization is used or canceled");
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                DOMAIN_SEPARATOR(),
                keccak256(abi.encode(typeHash, from, to, value, validAfter, validBefore, nonce))
            )
        );
        require(ECDSA.recoverCalldata(digest, signature) == from, "FiatTokenV2: invalid signature");
        authorizationStates[from][nonce] = true;
        emit AuthorizationUsed(from, nonce);
    }

    function _beforeTokenTransfer(address from, address to, uint256) internal view override {
        require(!paused, "Pausable: paused");
        require(!blacklisted[from] && !blacklisted[to], "Blacklistable: account is blacklisted");
    }
}
