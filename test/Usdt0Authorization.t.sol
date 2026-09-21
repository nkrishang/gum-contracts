// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Test} from "lib/forge-std/src/Test.sol";

interface IUsdt0 {
    function name() external view returns (string memory);
    function decimals() external view returns (uint8);
    function DOMAIN_SEPARATOR() external view returns (bytes32);
    function balanceOf(address account) external view returns (uint256);
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

/// @notice The empirical gate for USDT withdrawals: Tether's USDT0 on each
/// chain that serves USDT accepts the same EIP-3009 `TransferWithAuthorization`
/// the relayer submits for a same-chain leg, under the EIP-712 domain the
/// chain reader reconstructs (`name()`, version "1", which USDT0 does not
/// expose through a getter). Skipped unless `GUM_FORK_TESTS=1`
/// (`just forge-fork`), so `forge test` stays offline.
abstract contract Usdt0AuthorizationForkTest is Test {
    // keccak256("TransferWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)")
    bytes32 internal constant TRANSFER_TYPEHASH = 0x7c7c6cdb67a18743f49ec6fa9b35f50d52ed05cbed4cc592e13b44501c1a2267;
    uint256 internal constant AMOUNT = 1_234_567; // 1.234567 USDT

    uint256 internal chainId;
    address internal usdt;
    string internal expectedName;
    string internal rpcVariable;
    string internal defaultRpc;

    uint256 internal merchantKey;
    address internal merchant;

    modifier onlyFork() {
        if (!vm.envOr("GUM_FORK_TESTS", false)) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(vm.envOr(rpcVariable, defaultRpc));
        assertEq(block.chainid, chainId, "fork is not the expected chain");
        (merchant, merchantKey) = makeAddrAndKey("gum-fork-merchant");
        deal(usdt, merchant, AMOUNT);
        _;
    }

    /// @dev What the server reconstructs must be the token's own: six
    /// decimals, and a domain hashed under `name()` and version "1".
    function test_fork_usdt0_domain_is_name_and_version_one() public onlyFork {
        IUsdt0 token = IUsdt0(usdt);
        assertEq(token.decimals(), 6, "USDT0 decimals");
        assertEq(token.name(), expectedName, "USDT0 EIP-712 name");
        bytes32 expected = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes(token.name())),
                keccak256("1"),
                block.chainid,
                usdt
            )
        );
        assertEq(token.DOMAIN_SEPARATOR(), expected, "domain separator hashes under version 1");
    }

    function test_fork_usdt0_transfer_with_authorization_moves_the_whole_balance() public onlyFork {
        IUsdt0 token = IUsdt0(usdt);
        address destination = address(0xD00D);
        bytes32 nonce = keccak256("random nonce");
        uint256 validBefore = block.timestamp + 1 days;
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                token.DOMAIN_SEPARATOR(),
                keccak256(abi.encode(TRANSFER_TYPEHASH, merchant, destination, AMOUNT, uint256(0), validBefore, nonce))
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(merchantKey, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        vm.prank(address(0xBEEF));
        token.transferWithAuthorization(merchant, destination, AMOUNT, 0, validBefore, nonce, signature);

        assertEq(token.balanceOf(destination), AMOUNT, "destination received the amount");
        assertEq(token.balanceOf(merchant), 0, "merchant drained");

        // The same authorization cannot be replayed.
        vm.prank(address(0xBEEF));
        vm.expectRevert();
        token.transferWithAuthorization(merchant, destination, AMOUNT, 0, validBefore, nonce, signature);
    }
}

contract MonadUsdt0ForkTest is Usdt0AuthorizationForkTest {
    constructor() {
        chainId = 143;
        usdt = 0xe7cd86e13AC4309349F30B3435a9d337750fC82D;
        expectedName = "USDT0";
        rpcVariable = "GUM_FORK_RPC_URL_143";
        defaultRpc = "https://rpc.monad.xyz";
    }
}

contract ArbitrumUsdt0ForkTest is Usdt0AuthorizationForkTest {
    constructor() {
        chainId = 42161;
        usdt = 0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9;
        expectedName = unicode"USD₮0";
        rpcVariable = "GUM_FORK_RPC_URL_42161";
        defaultRpc = "https://arb1.arbitrum.io/rpc";
    }
}
