// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test} from "lib/forge-std/src/Test.sol";
import {BubblingCREATE3} from "src/utils/BubblingCREATE3.sol";

contract Deployer {
    function deploy(bytes memory initCode, bytes32 salt) external returns (address) {
        return BubblingCREATE3.deployDeterministic(initCode, salt);
    }

    function predict(bytes32 salt) external view returns (address) {
        return BubblingCREATE3.predictDeterministicAddress(salt, address(this));
    }
}

contract Deployee {
    uint256 public immutable value;

    constructor(uint256 value_) {
        value = value_;
    }
}

contract CustomErrorConstructor {
    error Nope(uint256 code, string reason);

    constructor() {
        revert Nope(7, "because");
    }
}

contract LongRevertConstructor {
    constructor(uint256 length) {
        bytes memory data = new bytes(length);
        for (uint256 i; i < length; ++i) {
            data[i] = bytes1(uint8(i));
        }
        assembly {
            revert(add(data, 0x20), mload(data))
        }
    }
}

contract BubblingCREATE3Test is Test {
    /// @dev The proxy initialization code, as documented in the library.
    bytes internal constant PROXY_INITCODE = hex"75363d3d37363d34f06014573d6000803e3d6000fd5b003d526016600af3";

    Deployer internal deployer;

    function setUp() public {
        deployer = new Deployer();
    }

    /// @notice The hash matches the documented bytecode (also checked with `cast keccak`).
    function test_proxy_initcode_hash_matches_the_bytecode() public pure {
        assertEq(keccak256(PROXY_INITCODE), BubblingCREATE3.PROXY_INITCODE_HASH);
        assertEq(
            BubblingCREATE3.PROXY_INITCODE_HASH, 0xc57c9b86f6f9162380bc9ddd7e90e8a4a1bab25d7dc6981dc9bf0d85f3490ef9
        );
    }

    /// @notice The assembly derivation matches a plain-Solidity statement of the
    /// formula other implementations follow: the proxy is CREATE2 of the
    /// proxy initcode, and the contract is the proxy's first CREATE.
    function testFuzz_prediction_matches_the_plain_formula(bytes32 salt, address factory) public pure {
        address proxy =
            address(uint160(uint256(keccak256(abi.encodePacked(hex"ff", factory, salt, keccak256(PROXY_INITCODE))))));
        address expected = address(uint160(uint256(keccak256(abi.encodePacked(hex"d694", proxy, hex"01")))));
        assertEq(BubblingCREATE3.predictDeterministicAddress(salt, factory), expected);
    }

    function test_deploys_at_the_predicted_address() public {
        bytes32 salt = keccak256("salt");
        address predicted = deployer.predict(salt);

        address deployed = deployer.deploy(abi.encodePacked(type(Deployee).creationCode, abi.encode(42)), salt);

        assertEq(deployed, predicted);
        assertEq(Deployee(deployed).value(), 42);
    }

    /// @notice The address depends only on the salt, never on the initcode.
    function test_the_address_is_independent_of_the_initcode() public {
        bytes32 salt = keccak256("independent");
        address predicted = deployer.predict(salt);
        address deployed = deployer.deploy(abi.encodePacked(type(Deployee).creationCode, abi.encode(1)), salt);
        assertEq(deployed, predicted);

        Deployer other = new Deployer();
        assertEq(other.deploy(abi.encodePacked(type(Deployee).creationCode, abi.encode(2)), salt), other.predict(salt));
    }

    function test_a_reverting_constructor_bubbles_its_revert_data() public {
        vm.expectRevert(abi.encodeWithSelector(CustomErrorConstructor.Nope.selector, 7, "because"));
        deployer.deploy(type(CustomErrorConstructor).creationCode, keccak256("custom"));
    }

    /// @notice Revert data of any length passes through the proxy intact.
    function testFuzz_revert_data_of_any_length_bubbles_intact(uint256 length) public {
        length = bound(length, 1, 4096);
        bytes memory expected = new bytes(length);
        for (uint256 i; i < length; ++i) {
            expected[i] = bytes1(uint8(i));
        }

        vm.expectRevert(expected);
        deployer.deploy(abi.encodePacked(type(LongRevertConstructor).creationCode, abi.encode(length)), bytes32(length));
    }

    /// @notice A failed deployment leaves nothing behind: the same salt deploys later.
    function test_a_failed_deployment_can_be_retried_with_the_same_salt() public {
        bytes32 salt = keccak256("retry");
        vm.expectRevert(abi.encodeWithSelector(CustomErrorConstructor.Nope.selector, 7, "because"));
        deployer.deploy(type(CustomErrorConstructor).creationCode, salt);

        address deployed = deployer.deploy(abi.encodePacked(type(Deployee).creationCode, abi.encode(3)), salt);
        assertEq(deployed, deployer.predict(salt));
    }

    function test_an_empty_revert_is_deployment_failed() public {
        vm.expectRevert(BubblingCREATE3.DeploymentFailed.selector);
        deployer.deploy(hex"60006000fd", keccak256("empty")); // revert(0, 0)
    }

    function test_initcode_that_returns_no_code_is_deployment_failed() public {
        vm.expectRevert(BubblingCREATE3.DeploymentFailed.selector);
        deployer.deploy(hex"00", keccak256("stop")); // STOP: deploys an empty account
    }

    function test_a_used_salt_reverts_with_already_deployed() public {
        bytes32 salt = keccak256("twice");
        deployer.deploy(abi.encodePacked(type(Deployee).creationCode, abi.encode(4)), salt);

        vm.expectRevert(BubblingCREATE3.AlreadyDeployed.selector);
        deployer.deploy(abi.encodePacked(type(Deployee).creationCode, abi.encode(5)), salt);
    }
}
