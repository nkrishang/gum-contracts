// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test} from "lib/forge-std/src/Test.sol";
import {Vm} from "lib/forge-std/src/Vm.sol";
import {MockStablecoin} from "src/mock/MockStablecoin.sol";
import {IERC3009, ITokenMessengerV2, WithdrawalForwarder} from "src/WithdrawalForwarder.sol";

interface IFiatToken {
    function name() external view returns (string memory);
    function version() external view returns (string memory);
    function DOMAIN_SEPARATOR() external view returns (bytes32);
    function balanceOf(address account) external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function transferWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        bytes calldata signature
    ) external;
}

/// @dev Holds what it is asked to burn so the unit tests can see the amount leave the payer.
contract MockTokenMessenger is ITokenMessengerV2 {
    event DepositForBurn(uint256 amount, uint32 destinationDomain, bytes32 mintRecipient, address burnToken);

    function depositForBurn(
        uint256 amount,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        address burnToken,
        bytes32 destinationCaller,
        uint256 maxFee,
        uint32 minFinalityThreshold
    ) external {
        require(destinationCaller == bytes32(0), "unexpected destinationCaller");
        require(maxFee == 0, "unexpected maxFee");
        require(minFinalityThreshold == 2000, "unexpected finality threshold");
        require(MockStablecoin(burnToken).transferFrom(msg.sender, address(this), amount), "transferFrom failed");
        emit DepositForBurn(amount, destinationDomain, mintRecipient, burnToken);
    }
}

/// @dev EIP-3009 signing shared by the unit and fork tests.
abstract contract Eip3009Test is Test {
    bytes32 internal constant TRANSFER_TYPEHASH = 0x7c7c6cdb67a18743f49ec6fa9b35f50d52ed05cbed4cc592e13b44501c1a2267;
    bytes32 internal constant RECEIVE_TYPEHASH = 0xd099cc98ef71107a616c4f0f941f04c322d8e254fe26b3c6668db87aae413de8;
    bytes32 internal constant MESSAGE_SENT_TOPIC = keccak256("MessageSent(bytes)");
    bytes32 internal constant AUTHORIZATION_USED_TOPIC = keccak256("AuthorizationUsed(address,bytes32)");

    function _sign(
        uint256 key,
        address token,
        bytes32 typeHash,
        address from,
        address to,
        uint256 value,
        uint256 validBefore,
        bytes32 nonce
    ) internal view returns (bytes memory) {
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                IFiatToken(token).DOMAIN_SEPARATOR(),
                keccak256(abi.encode(typeHash, from, to, value, uint256(0), validBefore, nonce))
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }

    function _receiveSignature(
        uint256 key,
        address token,
        WithdrawalForwarder forwarder,
        address from,
        uint256 value,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        bytes32 salt,
        uint256 validBefore
    ) internal view returns (bytes memory) {
        bytes32 nonce = forwarder.bridgeNonce(destinationDomain, mintRecipient, salt);
        return _sign(key, token, RECEIVE_TYPEHASH, from, address(forwarder), value, validBefore, nonce);
    }
}

contract WithdrawalForwarderTest is Eip3009Test {
    MockStablecoin private token;
    MockTokenMessenger private messenger;
    WithdrawalForwarder private forwarder;
    uint256 private merchantKey;
    address private merchant;
    address private constant RELAYER = address(0xBEEF);
    bytes32 private constant RECIPIENT = bytes32(uint256(uint160(0xD00D)));
    bytes32 private constant SALT = bytes32(uint256(7));

    function setUp() public {
        token = new MockStablecoin("Mock USD Coin", "USDC");
        messenger = new MockTokenMessenger();
        forwarder = new WithdrawalForwarder(messenger);
        (merchant, merchantKey) = makeAddrAndKey("merchant");
        token.mint(merchant, 25e6);
    }

    function test_bridge_pulls_exact_amount_and_burns_it_towards_signed_recipient() public {
        uint256 validBefore = block.timestamp + 1 days;
        bytes memory signature =
            _receiveSignature(merchantKey, address(token), forwarder, merchant, 25e6, 6, RECIPIENT, SALT, validBefore);

        vm.expectEmit(true, true, true, true, address(forwarder));
        emit WithdrawalForwarder.Bridged(merchant, address(token), 25e6, 6, RECIPIENT);
        vm.prank(RELAYER);
        forwarder.bridge(IERC3009(address(token)), merchant, 25e6, 6, RECIPIENT, SALT, validBefore, signature);

        assertEq(token.balanceOf(merchant), 0, "the whole authorized amount leaves the merchant");
        assertEq(token.balanceOf(address(forwarder)), 0, "the forwarder keeps nothing");
        assertEq(token.balanceOf(address(messenger)), 25e6, "the messenger received the burn amount");
        assertTrue(token.authorizationState(merchant, forwarder.bridgeNonce(6, RECIPIENT, SALT)));
    }

    function test_bridge_rejects_a_relayer_that_redirects_the_mint() public {
        uint256 validBefore = block.timestamp + 1 days;
        bytes memory signature =
            _receiveSignature(merchantKey, address(token), forwarder, merchant, 25e6, 6, RECIPIENT, SALT, validBefore);
        bytes32 attacker = bytes32(uint256(uint160(0xBAD)));

        vm.expectRevert("FiatTokenV2: invalid signature");
        forwarder.bridge(IERC3009(address(token)), merchant, 25e6, 6, attacker, SALT, validBefore, signature);

        vm.expectRevert("FiatTokenV2: invalid signature");
        forwarder.bridge(IERC3009(address(token)), merchant, 25e6, 3, RECIPIENT, SALT, validBefore, signature);

        vm.expectRevert("FiatTokenV2: invalid signature");
        forwarder.bridge(IERC3009(address(token)), merchant, 24e6, 6, RECIPIENT, SALT, validBefore, signature);

        assertEq(token.balanceOf(merchant), 25e6, "nothing moved");
    }

    function test_bridge_authorization_is_single_use() public {
        uint256 validBefore = block.timestamp + 1 days;
        bytes memory signature =
            _receiveSignature(merchantKey, address(token), forwarder, merchant, 10e6, 6, RECIPIENT, SALT, validBefore);
        forwarder.bridge(IERC3009(address(token)), merchant, 10e6, 6, RECIPIENT, SALT, validBefore, signature);

        vm.expectRevert("FiatTokenV2: authorization is used or canceled");
        forwarder.bridge(IERC3009(address(token)), merchant, 10e6, 6, RECIPIENT, SALT, validBefore, signature);
    }

    function test_only_the_forwarder_can_consume_its_authorization() public {
        uint256 validBefore = block.timestamp + 1 days;
        bytes32 nonce = forwarder.bridgeNonce(6, RECIPIENT, SALT);
        bytes memory signature =
            _receiveSignature(merchantKey, address(token), forwarder, merchant, 25e6, 6, RECIPIENT, SALT, validBefore);

        vm.prank(RELAYER);
        vm.expectRevert("FiatTokenV2: caller must be the payee");
        token.receiveWithAuthorization(merchant, address(forwarder), 25e6, 0, validBefore, nonce, signature);

        vm.prank(RELAYER);
        vm.expectRevert("FiatTokenV2: invalid signature");
        token.transferWithAuthorization(merchant, RELAYER, 25e6, 0, validBefore, nonce, signature);
    }

    function test_expired_authorization_is_refused() public {
        uint256 validBefore = block.timestamp + 1 hours;
        bytes memory signature =
            _receiveSignature(merchantKey, address(token), forwarder, merchant, 25e6, 6, RECIPIENT, SALT, validBefore);
        vm.warp(validBefore);
        vm.expectRevert("FiatTokenV2: authorization is expired");
        forwarder.bridge(IERC3009(address(token)), merchant, 25e6, 6, RECIPIENT, SALT, validBefore, signature);
    }

    /// @dev The vectors `gum-core`'s `withdrawal_authorization` tests,
    /// the SDK, and the web adapter pin, computed here from the type hash
    /// and `abi.encode` alone so every implementation agrees with Solidity.
    function test_nonce_and_digest_vectors_match_the_other_implementations() public view {
        bytes32 nonce = forwarder.bridgeNonce(6, bytes32(uint256(uint160(0xD00D))), bytes32(uint256(7)));
        assertEq(nonce, 0x18b79105e486e10f626b71939a0226c47316949b7c24ff1c397661ea861fafaa, "nonce vector");

        bytes32 domainSeparator = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("USDC"),
                keccak256("2"),
                uint256(143),
                0x754704Bc059F8C67012fEd69BC8A327a5aafb603
            )
        );
        assertEq(
            domainSeparator, 0xfe22123edc0dd4aeb912eb7948c5f0e531592c2053b3067612f427db342c93c6, "Monad USDC domain"
        );
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                domainSeparator,
                keccak256(
                    abi.encode(
                        RECEIVE_TYPEHASH,
                        0x1111111111111111111111111111111111111111,
                        0x2222222222222222222222222222222222222222,
                        uint256(1_234_567),
                        uint256(0),
                        uint256(1_800_000_000),
                        nonce
                    )
                )
            )
        );
        assertEq(digest, 0xfe0bcc7d9e69ee02881011f29a4156caa15e02b8e94c2e0c9f40e66711651993, "digest vector");
    }

    function test_same_chain_leg_is_a_relayed_transfer_with_authorization() public {
        uint256 validBefore = block.timestamp + 1 days;
        address destination = address(0xD00D);
        bytes32 nonce = keccak256("random");
        bytes memory signature =
            _sign(merchantKey, address(token), TRANSFER_TYPEHASH, merchant, destination, 25e6, validBefore, nonce);

        vm.prank(RELAYER);
        token.transferWithAuthorization(merchant, destination, 25e6, 0, validBefore, nonce, signature);

        assertEq(token.balanceOf(destination), 25e6);
        assertEq(token.balanceOf(merchant), 0);
    }
}

/// @notice The empirical gate: the forwarder against the real USDC and CCTP V2
/// contracts on each supported chain. Skipped unless `GUM_FORK_TESTS=1`
/// (`just forge-fork`), so `forge test` stays offline.
abstract contract ForwarderForkTest is Eip3009Test {
    address internal constant TOKEN_MESSENGER_V2 = 0x28b5a0e9C621a5BadaA536219b3a228C8168cf5d;
    address internal constant MESSAGE_TRANSMITTER_V2 = 0x81D40F21F12A8F0E3252Bccb954D722d4c464B64;
    uint256 internal constant AMOUNT = 1_234_567; // 1.234567 USDC

    uint256 internal chainId;
    uint32 internal domain;
    address internal usdc;
    string internal expectedName;
    string internal rpcVariable;
    string internal defaultRpc;

    WithdrawalForwarder internal forwarder;
    uint256 internal merchantKey;
    address internal merchant;

    modifier onlyFork() {
        if (!vm.envOr("GUM_FORK_TESTS", false)) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(vm.envOr(rpcVariable, defaultRpc));
        assertEq(block.chainid, chainId, "fork is not the expected chain");
        forwarder = new WithdrawalForwarder(ITokenMessengerV2(TOKEN_MESSENGER_V2));
        (merchant, merchantKey) = makeAddrAndKey("gum-fork-merchant");
        deal(usdc, merchant, AMOUNT);
        _;
    }

    /// @dev The domain the server reconstructs from live `name()` / `version()`
    /// must be the token's own; the name differs between Circle deployments.
    function test_fork_eip712_domain_matches_live_token() public onlyFork {
        IFiatToken token = IFiatToken(usdc);
        assertEq(token.name(), expectedName, "USDC EIP-712 name");
        assertEq(token.version(), "2", "USDC EIP-712 version");
        bytes32 expected = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes(token.name())),
                keccak256(bytes(token.version())),
                block.chainid,
                usdc
            )
        );
        assertEq(token.DOMAIN_SEPARATOR(), expected, "domain separator");
    }

    function test_fork_bridge_burns_full_amount_towards_signed_recipient() public onlyFork {
        IFiatToken token = IFiatToken(usdc);
        uint32 destinationDomain = domain == 6 ? 15 : 6;
        bytes32 recipient = bytes32(uint256(uint160(0xD00D)));
        bytes32 salt = keccak256("salt");
        uint256 validBefore = block.timestamp + 1 days;
        bytes memory signature = _receiveSignature(
            merchantKey, usdc, forwarder, merchant, AMOUNT, destinationDomain, recipient, salt, validBefore
        );
        uint256 supplyBefore = token.totalSupply();
        uint256 messengerBefore = token.balanceOf(TOKEN_MESSENGER_V2);

        vm.recordLogs();
        vm.prank(address(0xBEEF));
        forwarder.bridge(IERC3009(usdc), merchant, AMOUNT, destinationDomain, recipient, salt, validBefore, signature);

        assertEq(token.balanceOf(merchant), 0, "merchant drained");
        assertEq(token.balanceOf(address(forwarder)), 0, "forwarder holds nothing");
        assertEq(token.balanceOf(TOKEN_MESSENGER_V2), messengerBefore, "the messenger kept nothing: it burned");
        assertEq(supplyBefore - token.totalSupply(), AMOUNT, "the full amount was burned");

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes memory message;
        bool authorizationUsed;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == MESSAGE_TRANSMITTER_V2 && logs[i].topics[0] == MESSAGE_SENT_TOPIC) {
                message = abi.decode(logs[i].data, (bytes));
            }
            if (logs[i].emitter == usdc && logs[i].topics[0] == AUTHORIZATION_USED_TOPIC) {
                authorizationUsed = true;
            }
        }
        assertTrue(authorizationUsed, "USDC consumed the authorization");
        assertEq(message.length, 148 + 4 + 32 * 7, "MessageSent carries a BurnMessageV2 with empty hookData");
        // CCTP V2 message header: version(4) sourceDomain(4) destinationDomain(4) nonce(32)
        // sender(32) recipient(32) destinationCaller(32) minFinalityThreshold(4)
        // finalityThresholdExecuted(4); body: version(4) burnToken(32) mintRecipient(32)
        // amount(32) messageSender(32) maxFee(32) feeExecuted(32) expirationBlock(32) hookData.
        assertEq(_u32(message, 4), domain, "source domain");
        assertEq(_u32(message, 8), destinationDomain, "destination domain");
        assertEq(_b32(message, 108), bytes32(0), "any caller may mint");
        assertEq(_u32(message, 140), 2000, "standard finality threshold");
        assertEq(_b32(message, 148 + 4), bytes32(uint256(uint160(usdc))), "burn token");
        assertEq(_b32(message, 148 + 36), recipient, "mint recipient is the signed one");
        assertEq(uint256(_b32(message, 148 + 68)), AMOUNT, "amount");
        assertEq(uint256(_b32(message, 148 + 132)), 0, "maxFee 0");
    }

    function test_fork_bridge_rejects_redirected_recipient() public onlyFork {
        bytes32 recipient = bytes32(uint256(uint160(0xD00D)));
        bytes32 salt = keccak256("salt");
        uint256 validBefore = block.timestamp + 1 days;
        bytes memory signature =
            _receiveSignature(merchantKey, usdc, forwarder, merchant, AMOUNT, 6, recipient, salt, validBefore);

        vm.expectRevert("FiatTokenV2: invalid signature");
        forwarder.bridge(
            IERC3009(usdc), merchant, AMOUNT, 6, bytes32(uint256(uint160(0xBAD))), salt, validBefore, signature
        );
        assertEq(IFiatToken(usdc).balanceOf(merchant), AMOUNT, "nothing moved");
    }

    function test_fork_same_chain_transfer_with_authorization() public onlyFork {
        address destination = address(0xD00D);
        bytes32 nonce = keccak256("random nonce");
        uint256 validBefore = block.timestamp + 1 days;
        bytes memory signature =
            _sign(merchantKey, usdc, TRANSFER_TYPEHASH, merchant, destination, AMOUNT, validBefore, nonce);

        vm.prank(address(0xBEEF));
        IFiatToken(usdc).transferWithAuthorization(merchant, destination, AMOUNT, 0, validBefore, nonce, signature);

        assertEq(IFiatToken(usdc).balanceOf(destination), AMOUNT);
        assertEq(IFiatToken(usdc).balanceOf(merchant), 0);
    }

    function _u32(bytes memory data, uint256 offset) private pure returns (uint32 value) {
        for (uint256 i = 0; i < 4; i++) {
            value = (value << 8) | uint32(uint8(data[offset + i]));
        }
    }

    function _b32(bytes memory data, uint256 offset) private pure returns (bytes32 value) {
        assembly {
            value := mload(add(add(data, 0x20), offset))
        }
    }
}

contract MonadForwarderForkTest is ForwarderForkTest {
    constructor() {
        chainId = 143;
        domain = 15;
        usdc = 0x754704Bc059F8C67012fEd69BC8A327a5aafb603;
        expectedName = "USDC";
        rpcVariable = "GUM_FORK_RPC_URL_143";
        defaultRpc = "https://rpc.monad.xyz";
    }
}

contract BaseForwarderForkTest is ForwarderForkTest {
    constructor() {
        chainId = 8453;
        domain = 6;
        usdc = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
        expectedName = "USD Coin";
        rpcVariable = "GUM_FORK_RPC_URL_8453";
        defaultRpc = "https://mainnet.base.org";
    }
}

contract ArbitrumForwarderForkTest is ForwarderForkTest {
    constructor() {
        chainId = 42161;
        domain = 3;
        usdc = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
        expectedName = "USD Coin";
        rpcVariable = "GUM_FORK_RPC_URL_42161";
        defaultRpc = "https://arb1.arbitrum.io/rpc";
    }
}
