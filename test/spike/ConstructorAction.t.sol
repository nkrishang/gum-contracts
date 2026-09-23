// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test} from "lib/forge-std/src/Test.sol";
import {ERC20} from "lib/solady/src/tokens/ERC20.sol";
import {ERC4626} from "lib/solady/src/tokens/ERC4626.sol";
import {MockStablecoin} from "src/mock/MockStablecoin.sol";

contract Vault is ERC4626 {
    address immutable _asset;

    constructor(address a) {
        _asset = a;
    }

    function asset() public view override returns (address) {
        return _asset;
    }

    function name() public pure override returns (string memory) {
        return "v";
    }

    function symbol() public pure override returns (string memory) {
        return "v";
    }
}

interface IPing {
    function ping() external view returns (uint256);
}

/// Calls back into msg.sender (the Payment under construction).
contract CallbackTarget {
    bool public lowLevelOk;
    uint256 public senderCodeSize;

    function go() external {
        senderCodeSize = msg.sender.code.length;
        (lowLevelOk,) = msg.sender.call(abi.encodeWithSignature("ping()"));
        IPing(msg.sender).ping(); // high-level: extcodesize check -> reverts
    }
}

contract Hungry {
    uint256 public n;

    /// Succeeds, but needs ~2M gas.
    function eat(uint256 need) external {
        uint256 g = gasleft();
        while (g - gasleft() < need) {}
        n++;
    }
}

/// Minimal stand-in for a Payment with an action, all in the constructor.
contract ActionPayment {
    bool public ok;

    function ping() external pure returns (uint256) {
        return 1;
    }

    constructor(address token, uint256 amount, address target, bytes memory data, uint256 gasLimit, bool guard) {
        ERC20(token).approve(target, amount);
        if (guard && gasleft() < gasLimit * 64 / 63 + 10_000) revert("insufficient gas");
        (ok,) = target.call{gas: gasLimit}(data);
        ERC20(token).approve(target, 0);
    }
}

contract Relayer {
    function run(
        address token,
        uint256 amount,
        address target,
        bytes memory data,
        uint256 gasLimit,
        bool guard,
        uint256 gasToForward
    ) external returns (bool deployed, bool actionOk) {
        try this.deploy{gas: gasToForward}(token, amount, target, data, gasLimit, guard) returns (ActionPayment p) {
            return (true, p.ok());
        } catch {
            return (false, false);
        }
    }

    function deploy(address token, uint256 amount, address target, bytes memory data, uint256 gasLimit, bool guard)
        external
        returns (ActionPayment p)
    {
        p = new ActionPayment(token, amount, target, data, gasLimit, guard);
    }
}

contract ConstructorActionSpike is Test {
    MockStablecoin token;

    function setUp() public {
        token = new MockStablecoin("USD", "USD");
    }

    function _predict(bytes memory args, bytes32 salt, address deployer) internal pure returns (address) {
        return address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(
                            bytes1(0xff),
                            deployer,
                            salt,
                            keccak256(abi.encodePacked(type(ActionPayment).creationCode, args))
                        )
                    )
                )
            )
        );
    }

    /// Pull-style targets (ERC-4626 deposit) work from a constructor.
    function test_vault_deposit_from_constructor() public {
        Vault v = new Vault(address(token));
        bytes memory data = abi.encodeCall(ERC4626.deposit, (10e6, address(0xBEEF)));
        bytes memory args = abi.encode(address(token), 10e6, address(v), data, 500_000, false);
        address p = _predict(args, bytes32(0), address(this));
        token.mint(p, 10e6);
        ActionPayment ap = new ActionPayment{salt: bytes32(0)}(address(token), 10e6, address(v), data, 500_000, false);
        assertTrue(ap.ok());
        assertEq(v.balanceOf(address(0xBEEF)), 10e6);
        assertEq(token.allowance(address(ap), address(v)), 0);
    }

    /// Targets that call back into the Payment see no code: low-level succeeds silently, high-level reverts.
    function test_callback_into_constructing_payment() public {
        CallbackTarget t = new CallbackTarget();
        ActionPayment ap =
            new ActionPayment(address(token), 0, address(t), abi.encodeCall(CallbackTarget.go, ()), 500_000, false);
        assertFalse(ap.ok(), "high-level callback into a constructing contract reverts");
    }

    /// Without a gas guard, a relayer can starve a best-effort action so it fails while settlement succeeds.
    function test_gas_griefing_without_guard() public {
        Relayer r = new Relayer();
        Hungry h = new Hungry();
        string[3] memory label = ["deployed, action ok", "deployed, ACTION SKIPPED", "whole deployment reverted"];
        uint256[3] memory needs = [uint256(2_000_000), 10_000_000, 25_000_000];
        for (uint256 j; j < 3; ++j) {
            bytes memory data = abi.encodeCall(Hungry.eat, (needs[j]));
            for (uint256 i; i < 2; ++i) {
                bool guard = i == 1;
                // Find the smallest forwarded gas that lets the deployment succeed, and report what happened there.
                uint256 lo = needs[j] / 2;
                uint256 hi = needs[j] * 2;
                while (hi - lo > 1000) {
                    uint256 mid = (lo + hi) / 2;
                    (bool d,) = r.run(address(token), 0, address(h), data, needs[j] * 2, guard, mid);
                    if (d) hi = mid;
                    else lo = mid;
                }
                (bool deployed, bool ok) = r.run(address(token), 0, address(h), data, needs[j] * 2, guard, hi);
                emit log_named_uint(guard ? "action gas, GUARDED" : "action gas, unguarded", needs[j]);
                emit log_named_string("   at min gas that deploys", label[deployed ? (ok ? 0 : 1) : 2]);
            }
        }
    }
}
