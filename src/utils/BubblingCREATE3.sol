// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

/// @notice CREATE3 whose deployment reverts with the constructor's own revert data.
///
/// Solady's CREATE3 proxy runs `CREATE` and stops, so a reverting constructor
/// leaves only an address without code, and the deployer can report nothing
/// more than `DeploymentFailed()`. This proxy reverts with the revert data of
/// its failed `CREATE` instead, and `deployDeterministic` passes it on.
///
/// The proxy bytecode differs from Solady's, so addresses differ too: derive
/// them with `predictDeterministicAddress` or `PROXY_INITCODE_HASH`, not with
/// Solady's `CREATE3`.
///
/// Modified from Solady (https://github.com/vectorized/solady/blob/main/src/utils/CREATE3.sol).
library BubblingCREATE3 {
    //---------- Errors ----------//

    /// @notice The contract at the address for this salt is already deployed.
    error AlreadyDeployed();
    /// @notice The deployment failed without revert data, e.g. out of gas.
    error DeploymentFailed();

    //---------- Bytecode ----------//

    /**
     * Proxy runtime (22 bytes):
     * -------------------------------------------------------------------+
     * Opcode      | Mnemonic         | Stack        | Memory             |
     * -------------------------------------------------------------------|
     * 36          | CALLDATASIZE     | cds          |                    |
     * 3d          | RETURNDATASIZE   | 0 cds        |                    |
     * 3d          | RETURNDATASIZE   | 0 0 cds      |                    |
     * 37          | CALLDATACOPY     |              | [0..cds): calldata |
     * 36          | CALLDATASIZE     | cds          | [0..cds): calldata |
     * 3d          | RETURNDATASIZE   | 0 cds        | [0..cds): calldata |
     * 34          | CALLVALUE        | value 0 cds  | [0..cds): calldata |
     * f0          | CREATE           | newContract  | [0..cds): calldata |
     * 60 0x14     | PUSH1 0x14       | 0x14 new     | [0..cds): calldata |
     * 57          | JUMPI            |              | [0..cds): calldata |
     * 3d          | RETURNDATASIZE   | rds          | [0..cds): calldata |
     * 60 0x00     | PUSH1 0x00       | 0 rds        | [0..cds): calldata |
     * 80          | DUP1             | 0 0 rds      | [0..cds): calldata |
     * 3e          | RETURNDATACOPY   |              | [0..rds): revert   |
     * 3d          | RETURNDATASIZE   | rds          | [0..rds): revert   |
     * 60 0x00     | PUSH1 0x00       | 0 rds        | [0..rds): revert   |
     * fd          | REVERT           |              | [0..rds): revert   |
     * 5b          | JUMPDEST         |              | [0..cds): calldata |
     * 00          | STOP             |              | [0..cds): calldata |
     * -------------------------------------------------------------------+
     *
     * Proxy initialization code (30 bytes):
     * -------------------------------------------------------------------+
     * 75 runtime  | PUSH22 runtime   | runtime      |                    |
     * 3d          | RETURNDATASIZE   | 0 runtime    |                    |
     * 52          | MSTORE           |              | [10..32): runtime  |
     * 60 0x16     | PUSH1 0x16       | 0x16         | [10..32): runtime  |
     * 60 0x0a     | PUSH1 0x0a       | 0x0a 0x16    | [10..32): runtime  |
     * f3          | RETURN           |              | [10..32): runtime  |
     * -------------------------------------------------------------------+
     *
     * `PUSH1 0x00` rather than `RETURNDATASIZE` pushes zero after the failed
     * `CREATE`, whose revert data makes the return data size nonzero.
     */

    /// @dev The proxy initialization code.
    uint256 private constant _PROXY_INITCODE = 0x75363d3d37363d34f06014573d6000803e3d6000fd5b003d526016600af3;

    /// @notice Hash of the proxy initialization code.
    /// Equivalent to `keccak256(hex"75363d3d37363d34f06014573d6000803e3d6000fd5b003d526016600af3")`.
    bytes32 internal constant PROXY_INITCODE_HASH = 0xc57c9b86f6f9162380bc9ddd7e90e8a4a1bab25d7dc6981dc9bf0d85f3490ef9;

    //---------- Operations ----------//

    /// @notice Deploys `initCode` deterministically with `salt`, reverting with the
    /// constructor's revert data if it reverts.
    function deployDeterministic(bytes memory initCode, bytes32 salt) internal returns (address deployed) {
        /// @solidity memory-safe-assembly
        assembly {
            mstore(0x00, _PROXY_INITCODE) // The 30 bytes land at [0x02..0x20).
            let proxy := create2(0, 0x02, 0x1e, salt)
            if iszero(proxy) {
                mstore(0x00, 0xa6ef0ba1) // `AlreadyDeployed()`.
                revert(0x1c, 0x04)
            }
            mstore(0x14, proxy) // Store the proxy's address.
            // 0xd6 = 0xc0 (short RLP prefix) + 0x16 (length of: 0x94 ++ proxy ++ 0x01).
            // 0x94 = 0x80 + 0x14 (0x14 = the length of an address, 20 bytes, in hex).
            mstore(0x00, 0xd694)
            mstore8(0x34, 0x01) // Nonce of the proxy contract (1).
            deployed := keccak256(0x1e, 0x17)
            if iszero(call(gas(), proxy, 0, add(initCode, 0x20), mload(initCode), 0x00, 0x00)) {
                if iszero(returndatasize()) {
                    mstore(0x00, 0x30116425) // `DeploymentFailed()`.
                    revert(0x1c, 0x04)
                }
                // Bubble up the constructor's revert.
                let m := mload(0x40)
                returndatacopy(m, 0x00, returndatasize())
                revert(m, returndatasize())
            }
            if iszero(extcodesize(deployed)) {
                mstore(0x00, 0x30116425) // `DeploymentFailed()`.
                revert(0x1c, 0x04)
            }
        }
    }

    /// @notice Returns the deterministic address for `salt` with `deployer`.
    function predictDeterministicAddress(bytes32 salt, address deployer) internal pure returns (address deployed) {
        /// @solidity memory-safe-assembly
        assembly {
            let m := mload(0x40) // Cache the free memory pointer.
            mstore(0x00, deployer) // Store `deployer`.
            mstore8(0x0b, 0xff) // Store the prefix.
            mstore(0x20, salt) // Store the salt.
            mstore(0x40, PROXY_INITCODE_HASH) // Store the bytecode hash.

            mstore(0x14, keccak256(0x0b, 0x55)) // Store the proxy's address.
            mstore(0x40, m) // Restore the free memory pointer.
            // 0xd6 = 0xc0 (short RLP prefix) + 0x16 (length of: 0x94 ++ proxy ++ 0x01).
            // 0x94 = 0x80 + 0x14 (0x14 = the length of an address, 20 bytes, in hex).
            mstore(0x00, 0xd694)
            mstore8(0x34, 0x01) // Nonce of the proxy contract (1).
            deployed := keccak256(0x1e, 0x17)
        }
    }
}
