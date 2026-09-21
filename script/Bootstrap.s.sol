// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Script} from "lib/forge-std/src/Script.sol";
import {console} from "lib/forge-std/src/console.sol";
import {BatchSweeper} from "src/BatchSweeper.sol";
import {PaymentFactory} from "src/PaymentFactory.sol";
import {ITokenMessengerV2, WithdrawalForwarder} from "src/WithdrawalForwarder.sol";

/// @notice Deploys one `PaymentFactory`, the `BatchSweeper` bound to it, and
/// the `WithdrawalForwarder` bound to the chain's CCTP V2 `TokenMessengerV2`.
///
/// `Payment.creationCode` is embedded in the factory, so any `Payment` change
/// requires a new deployment.
///
/// The generation must live at the same addresses on every supported chain:
/// a payer's counterfactual address is only recoverable on a chain where the
/// factory exists at the address that derived it. CREATE addresses depend on
/// the deployer and its nonce alone, so the script insists on a fresh deployer
/// key (nonce 0) and the same key is used on every chain. The forwarder comes
/// last, so the factory and the sweeper keep their nonce-0 and nonce-1
/// addresses.
contract BootstrapScript is Script {
    // Circle deploys CCTP V2's `TokenMessengerV2` at this address on every
    // mainnet it supports. Testnets differ: set `GUM_TOKEN_MESSENGER_V2`.
    address internal constant TOKEN_MESSENGER_V2 = 0x28b5a0e9C621a5BadaA536219b3a228C8168cf5d;

    PaymentFactory public factory;
    BatchSweeper public batchSweeper;
    WithdrawalForwarder public withdrawalForwarder;

    function setUp() public {}

    function run() public {
        uint256 expectedChainId = vm.envUint("GUM_CHAIN_ID");
        require(block.chainid == expectedChainId, "unexpected deployment chain");
        (, address deployer,) = vm.readCallers();
        require(
            vm.getNonce(deployer) == 0, "deploy each generation from a fresh key so every chain gets the same addresses"
        );
        // The forwarder's messenger is immutable, so a wrong address could
        // only be fixed by redeploying the generation.
        address tokenMessenger = vm.envOr("GUM_TOKEN_MESSENGER_V2", TOKEN_MESSENGER_V2);
        require(tokenMessenger.code.length != 0, "no TokenMessengerV2 on this chain; set GUM_TOKEN_MESSENGER_V2");

        vm.startBroadcast();

        factory = new PaymentFactory();
        batchSweeper = new BatchSweeper(factory);
        withdrawalForwarder = new WithdrawalForwarder(ITokenMessengerV2(tokenMessenger));

        vm.stopBroadcast();

        console.log("GUM_FACTORY_ADDRESS=%s", vm.toString(address(factory)));
        console.log("GUM_FACTORY_CODE_HASH=%s", vm.toString(address(factory).codehash));
        console.log("GUM_BATCH_SWEEPER_ADDRESS=%s", vm.toString(address(batchSweeper)));
        console.log("GUM_BATCH_SWEEPER_CODE_HASH=%s", vm.toString(address(batchSweeper).codehash));
        console.log("GUM_WITHDRAWAL_FORWARDER_ADDRESS=%s", vm.toString(address(withdrawalForwarder)));
        console.log("GUM_WITHDRAWAL_FORWARDER_CODE_HASH=%s", vm.toString(address(withdrawalForwarder).codehash));
    }
}
