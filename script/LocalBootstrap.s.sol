// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Script} from "lib/forge-std/src/Script.sol";
import {console} from "lib/forge-std/src/console.sol";

import {BatchSweeper} from "src/BatchSweeper.sol";
import {PaymentFactory} from "src/PaymentFactory.sol";
import {MockStablecoin} from "src/mock/MockStablecoin.sol";

/// @notice Deploys deterministic local payment fixtures on a fresh Anvil.
///
/// The fixture addresses are account #0's first CREATE addresses, so a
/// long-running Anvil keeps whichever contract generation it saw first. The
/// script refuses to run against a stale generation instead of leaving the
/// services pinned to bytecode that no longer matches this build.
contract LocalBootstrapScript is Script {
    // Account #0's nonce-0, nonce-1, nonce-2 and nonce-3 CREATE addresses,
    // respectively. USDT came last, so the earlier fixtures keep their addresses.
    address internal constant FACTORY = 0x5FbDB2315678afecb367f032d93F642f64180aa3;
    address internal constant USDC = 0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512;
    address internal constant BATCH_SWEEPER = 0x9fE46736679d2D9a65F0992F2272dE9f3c7fa6e0;
    address internal constant USDT = 0xCf7Ed3AccA5a467e9e704C703E8D87F634fB0Fc9;
    address internal constant ANVIL_ACCOUNT_0 = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;
    address internal constant ANVIL_ACCOUNT_1 = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
    uint256 internal constant FIXTURE_BALANCE = 1_000_000 * 1e6;

    function run() external {
        if (FACTORY.code.length == 0) {
            vm.broadcast();
            PaymentFactory factory = new PaymentFactory();
            require(address(factory) == FACTORY, "factory address mismatch; use fresh Anvil account #0");
            console.log("PaymentFactory deployed at", FACTORY);
        } else {
            // The factory embeds Payment.creationCode, so a stale factory would
            // deploy the previous Payment generation at the fixture address.
            require(
                FACTORY.codehash == keccak256(type(PaymentFactory).runtimeCode),
                "stale PaymentFactory at the fixture address; restart Anvil so the new contract generation deploys"
            );
        }

        if (USDC.code.length == 0) {
            vm.broadcast();
            MockStablecoin token = new MockStablecoin("Mock USD Coin", "USDC");
            require(address(token) == USDC, "USDC address mismatch; use fresh Anvil account #0");
            console.log("MockStablecoin USDC deployed at", USDC);
        }

        if (BATCH_SWEEPER.code.length == 0) {
            vm.broadcast();
            BatchSweeper batchSweeper = new BatchSweeper(PaymentFactory(FACTORY));
            require(
                address(batchSweeper) == BATCH_SWEEPER, "batch sweeper address mismatch; use fresh Anvil account #0"
            );
            console.log("BatchSweeper deployed at", BATCH_SWEEPER);
        } else {
            // `type(BatchSweeper).runtimeCode` is unavailable because of its
            // immutable, so check the binding that immutable holds first...
            require(
                address(BatchSweeper(BATCH_SWEEPER).FACTORY()) == FACTORY,
                "BatchSweeper at the fixture address is bound to another factory; restart Anvil so the new contract generation deploys"
            );
            // ...then compare against a reference deployment of this build
            // with the same binding. It is created outside `vm.broadcast`, so
            // it exists only in the simulation and is never sent to the chain.
            BatchSweeper expected = new BatchSweeper(PaymentFactory(FACTORY));
            require(
                BATCH_SWEEPER.codehash == address(expected).codehash,
                "stale BatchSweeper at the fixture address; restart Anvil so the new contract generation deploys"
            );
        }

        if (USDT.code.length == 0) {
            vm.broadcast();
            MockStablecoin usdt = new MockStablecoin("Mock Tether USD", "USDT");
            require(address(usdt) == USDT, "USDT address mismatch; restart Anvil so the fixtures deploy in order");
            console.log("MockStablecoin USDT deployed at", USDT);
        }

        // The services pin the generation by these hashes; print them on every
        // run so a developer can copy them into the environment.
        console.log("GUM_FACTORY_CODE_HASH=%s", vm.toString(FACTORY.codehash));
        console.log("GUM_BATCH_SWEEPER_CODE_HASH=%s", vm.toString(BATCH_SWEEPER.codehash));

        _topUp(USDC, ANVIL_ACCOUNT_0);
        _topUp(USDC, ANVIL_ACCOUNT_1);
        _topUp(USDT, ANVIL_ACCOUNT_0);
        _topUp(USDT, ANVIL_ACCOUNT_1);
    }

    function _topUp(address tokenAddress, address account) internal {
        MockStablecoin token = MockStablecoin(tokenAddress);
        uint256 balance = token.balanceOf(account);
        if (balance < FIXTURE_BALANCE) {
            vm.broadcast();
            token.mint(account, FIXTURE_BALANCE - balance);
            console.log("MockStablecoin funded", tokenAddress, account);
        }
    }
}
