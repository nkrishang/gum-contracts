// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Script} from "lib/forge-std/src/Script.sol";
import {console} from "lib/forge-std/src/console.sol";
import {BatchSweeper} from "src/BatchSweeper.sol";
import {PaymentFactory} from "src/PaymentFactory.sol";

/// @notice Deploys one `PaymentFactory` and the `BatchSweeper` bound to it.
///
/// `Payment.creationCode` is embedded in the factory, so any `Payment` change
/// requires a new deployment.
///
/// The generation must live at the same addresses on every supported chain.
/// a payer's counterfactual address is only recoverable on a chain they did
/// CREATE addresses depend on the deployer and its nonce alone, so the script
/// insists on a fresh deployer key (nonce 0) and the same key is used on
/// every chain.
contract BootstrapScript is Script {
    PaymentFactory public factory;
    BatchSweeper public batchSweeper;

    function setUp() public {}

    function run() public {
        uint256 expectedChainId = vm.envUint("GUM_CHAIN_ID");
        require(block.chainid == expectedChainId, "unexpected deployment chain");
        (, address deployer,) = vm.readCallers();
        require(
            vm.getNonce(deployer) == 0, "deploy each generation from a fresh key so every chain gets the same addresses"
        );

        vm.startBroadcast();

        factory = new PaymentFactory();
        batchSweeper = new BatchSweeper(factory);

        vm.stopBroadcast();

        console.log("GUM_FACTORY_ADDRESS=%s", vm.toString(address(factory)));
        console.log("GUM_FACTORY_CODE_HASH=%s", vm.toString(address(factory).codehash));
        console.log("GUM_BATCH_SWEEPER_ADDRESS=%s", vm.toString(address(batchSweeper)));
        console.log("GUM_BATCH_SWEEPER_CODE_HASH=%s", vm.toString(address(batchSweeper).codehash));
    }
}
