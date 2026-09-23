# gum-contracts

Smart contracts for Gum's stablecoin payments: counterfactual payment addresses that settle themselves on deployment, a batch sweeper for executing many of them at once, and a trust-minimized forwarder for bridging merchant withdrawals over Circle's CCTP V2.

Every contract is **ownerless, permissionless and non-upgradeable**. Where funds can go is fixed by an address or a signature before any transaction is sent, so whoever relays a transaction never gets to choose where the money lands.

Built with [Foundry](https://book.getfoundry.sh/) and [Solady](https://github.com/Vectorized/solady).

## Contracts

| Contract | Purpose |
| --- | --- |
| [`PaymentFactory`](src/PaymentFactory.sol) | Ownerless CREATE3 deployer that derives a deterministic payment address from the payment's terms and executes it. |
| [`Payment`](src/Payment.sol) | Single-use contract whose constructor runs committed calls that spend exactly the payment amount, and sends everything else to a recovery address. |
| [`BatchSweeper`](src/BatchSweeper.sol) | Executes many independent payments in one transaction; one failure never rolls back the others. |
| [`WithdrawalForwarder`](src/WithdrawalForwarder.sol) | Bridges USDC through CCTP V2 on the strength of one EIP-3009 signature that commits to the destination. |
| [`MockStablecoin`](src/mock/MockStablecoin.sol) | Local-only six-decimal token mirroring Circle FiatToken's pause, blacklist and EIP-3009 behaviour. |

### Deployed addresses

The current generation is live at the same addresses on Monad, Base and Arbitrum:

| Contract | Address |
| --- | --- |
| `PaymentFactory` | `0x7D0790f8983F028bDa32c44c40b50EBE902Fe17B` |
| `BatchSweeper` | `0xf58a0A9Df7764784dF01Aa7f10094Fc1A5a72b97` |
| `WithdrawalForwarder` | `0x7f66A10D96d369Dab93e121415772b9F752Bc0d1` |

| Chain | Chain ID |
| --- | --- |
| Monad | `143` |
| Base | `8453` |
| Arbitrum | `42161` |

## How payments work

A payment is described by seven parameters:

| Parameter | Meaning |
| --- | --- |
| `token` | The ERC-20 being paid |
| `amount` | The amount the calls must spend |
| `calls` | Ordered `Call{target, data}` list the payment executes on settlement |
| `expirationTimestamp` | After this, the payment no longer settles |
| `recovery` | Where any funds that aren't spent by the calls go |
| `salt` | Distinguishes otherwise identical payments |
| `chainId` | The only chain on which the payment may settle |

`PaymentFactory` hashes all seven into a CREATE3 salt, so **the address itself commits to the routing of funds**. Changing any parameter yields a different address, and nobody can deploy different logic at the address the payer was given.

The factory deploys through [`BubblingCREATE3`](src/utils/BubblingCREATE3.sol), whose proxy differs from Solady's so that constructor reverts reach the caller. To derive an address offchain, use the proxy's init code hash `0xc57c9b86f6f9162380bc9ddd7e90e8a4a1bab25d7dc6981dc9bf0d85f3490ef9`, not Solady's:

```
salt    = keccak256(abi.encode(token, amount, calls, expirationTimestamp, recovery, salt, chainId))
proxy   = keccak256(0xff ++ factory ++ salt ++ 0xc57c9b86…0ef9)[12:]
payment = keccak256(0xd694 ++ proxy ++ 0x01)[12:]
```

```
1. Quote     factory.paymentAddress(...)  ->  counterfactual address, no code yet
2. Pay       payer sends tokens to that address with an ordinary ERC-20 transfer
3. Execute   anyone calls factory.execute(...)  ->  Payment is deployed, and its
             constructor routes the balance it finds at its own address
```

What the `Payment` constructor does with the balance:

| Situation | Outcome |
| --- | --- |
| Funded, not expired | Any excess goes to `recovery` first. The calls then run in order and must spend exactly `amount`. Emits `Recovered` for any excess, `Called` after each call, then `Settled`, and `SETTLED` is `true`. |
| A call reverts, targets an address with no code, or the calls leave part of `amount` unspent | Reverts with `CallFailed(index, revertData)`, which carries the failing call's own revert data, `CallTargetHasNoCode(index, target)` or `AmountNotSpent`. Nothing moves, and `execute` can be retried. |
| Underfunded, not expired | Reverts with `InsufficientTokenBalance`. No code is left behind, so `execute` can be retried once the balance arrives. |
| Expired (`block.timestamp > expirationTimestamp`) | The whole balance goes to `recovery`. Emits `Recovered`. |
| Wrong chain (`block.chainid != chainId`) | Moves nothing and emits `WrongChain`. Deployment still succeeds, even if `token` has no code on this chain, so `recover` stays callable. |

After deployment, `recover(token)` is a permissionless call that forwards the contract's full balance of **any** token to `recovery`. It covers late payments, payments in the wrong token, and funds sent on the wrong chain.

Things worth knowing when integrating:

- `execute` reverts with the `Payment` constructor's own revert data, e.g. `InsufficientTokenBalance(balance, required)`, `CallFailed(index, revertData)`, `AmountNotSpent(remaining)` or a token's transfer error, so decode it against the `Payment` ABI. It reverts with `AlreadyDeployed()` once the payment has executed, and with `DeploymentFailed()` only when the constructor reverted without data, e.g. out of gas. `BatchSweeper` reports the same data in `SweepFailed`. [`test/ExecuteRevert.t.sol`](test/ExecuteRevert.t.sol) pins this behaviour.
- Settlement is atomic. If the excess can't be delivered to `recovery` (for example, a blacklisted address), or any call fails, the whole deployment reverts and nothing is paid.
- The expiry boundary is inclusive: a payment executed at exactly `expirationTimestamp` still settles.
- The factory must live at the same address on every supported chain so that the same terms produce the same payment address everywhere. That is what makes funds sent on the wrong chain recoverable.

### Settlement calls

The calls are how a payment triggers onchain actions. A plain payment is a single call, `token.transfer(receiver, amount)`. Some other shapes:

| Action | Calls |
| --- | --- |
| Pay a merchant | `token.transfer(merchant, amount)` |
| Split with a platform fee | `token.transfer(merchant, amount - fee)`, `token.transfer(platform, fee)` |
| Deposit into an ERC-4626 vault | `token.approve(vault, amount)`, `vault.deposit(amount, merchant)` |
| Settle and notify a merchant contract | `token.transfer(merchant, amount)`, `merchantContract.markPaid(orderId)` |

Rules the calls must follow:

- **Every target and every byte of calldata is committed into the address.** Anyone can therefore verify what a payment will do offchain, before paying, by recomputing the address. The contracts enforce no allowlist, and the chosen calls are exactly what runs.
- **Calls run as the payment address, inside its constructor.** The payment has no code yet, so a target that calls back into it, such as a swap callback or a flash-loan callback, fails. Targets should not care who calls them. A target that must know it was paid should pull the tokens with `transferFrom` rather than trust `msg.sender`. Alternatively, it can take the payment's terms as arguments and check that the factory derives `msg.sender` from them; `AuthenticatedOrderBook` in [`test/utils/SettlementFixtures.sol`](test/utils/SettlementFixtures.sol) shows how.
- **The calls must spend exactly `amount`.** The excess has already gone to `recovery` when they run, so they cannot spend more. Leaving any of it unspent reverts with `AmountNotSpent`. A call to an address with no code reverts with `CallTargetHasNoCode`, because it would otherwise succeed and do nothing.
- **Approvals should be exact.** An approval the target doesn't fully use outlives the constructor, and would let that spender pull late funds before `recover` sweeps them. Check this offchain along with the rest of the calls.
- **Calls carry no native value**, and expired or wrong-chain payments never run their calls.

### Batch sweeping

`BatchSweeper.executeBatch(Sweep[])` processes each item independently:

- If the payment address has no code, it calls `factory.execute`.
- If the payment is already deployed, it calls `recover` instead, picking up any funds that arrived late.
- Failures are caught and reported as `SweepFailed(paymentAddress, token, revertData)` rather than reverting the batch, so a paused token, a failing call or an underfunded item only affects itself.

## How withdrawals work

`WithdrawalForwarder` lets a relayer bridge a merchant's USDC to another chain without the merchant sending a transaction, and without the relayer being trusted with the destination.

1. The merchant signs an EIP-3009 `ReceiveWithAuthorization` naming the forwarder as payee. The authorization's nonce is a commitment to the destination:

   ```solidity
   nonce = keccak256(abi.encode(destinationDomain, mintRecipient, salt))
   ```

   `bridgeNonce(...)` computes this on-chain for convenience.
2. Anyone relays `bridge(token, from, value, destinationDomain, mintRecipient, salt, validBefore, signature)`.
3. The forwarder recomputes the nonce from the arguments it was given, pulls the funds with `receiveWithAuthorization`, and burns them via CCTP V2 `depositForBurn` towards `mintRecipient`.

A relayer that substitutes its own recipient produces a nonce the merchant never signed, so USDC rejects the signature before any funds move. USDC also requires the payee itself to submit a `ReceiveWithAuthorization`, so only the forwarder can consume it, and the only thing the forwarder can do with the funds is burn them towards the signed recipient.

The forwarder is stateless and holds nothing between transactions. It uses Standard Transfers only (`minFinalityThreshold = 2000`, `maxFee = 0`), so the recipient is minted the full amount. `destinationCaller` is left empty, meaning any relayer may submit the mint on the destination chain.

Same-chain withdrawals don't involve the forwarder: they are a relayed EIP-3009 `transferWithAuthorization` directly on the token. This is also the path used for USDT (Tether's USDT0).

## Getting started

Requires [Foundry](https://book.getfoundry.sh/getting-started/installation).

```shell
git clone --recurse-submodules <repo-url>
cd gum-contracts
forge build
```

If you cloned without submodules, run `git submodule update --init --recursive`.

## Testing

```shell
forge test
```

The default run is fully offline. Fork tests are skipped unless you opt in:

```shell
GUM_FORK_TESTS=1 forge test
```

Fork tests exercise the forwarder and settlement calls (plain transfers, fee splits, CCTP V2 burns, blacklisted recipients) against the live USDC, USDT0 and CCTP V2 contracts, and verify that USDT0 accepts the EIP-3009 authorizations and EIP-712 domain the backend reconstructs. Each chain uses a public RPC by default, which you can override:

| Chain | Chain ID | RPC override | Covers |
| --- | --- | --- | --- |
| Monad | `143` | `GUM_FORK_RPC_URL_143` | USDC + CCTP, USDT0, settlement calls |
| Base | `8453` | `GUM_FORK_RPC_URL_8453` | USDC + CCTP, settlement calls |
| Arbitrum | `42161` | `GUM_FORK_RPC_URL_42161` | USDC + CCTP, USDT0, settlement calls |

CI runs `forge fmt --check`, `forge build --sizes` and `forge test -vvv` on every push and pull request.

## Local development

[`LocalBootstrap.s.sol`](script/LocalBootstrap.s.sol) deploys deterministic fixtures to a fresh Anvil and tops up Anvil accounts #0 and #1 with 1,000,000 of each mock token:

```shell
anvil

forge script script/LocalBootstrap.s.sol:LocalBootstrapScript \
  --rpc-url http://127.0.0.1:8545 \
  --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 \
  --broadcast
```

The key above is Anvil's well-known account #0. The fixtures are that account's first four CREATE addresses:

| Fixture | Address |
| --- | --- |
| `PaymentFactory` | `0x5FbDB2315678afecb367f032d93F642f64180aa3` |
| `MockStablecoin` (USDC) | `0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512` |
| `BatchSweeper` | `0x9fE46736679d2D9a65F0992F2272dE9f3c7fa6e0` |
| `MockStablecoin` (USDT) | `0xCf7Ed3AccA5a467e9e704C703E8D87F634fB0Fc9` |

The script is idempotent, and it refuses to run if the bytecode at a fixture address doesn't match the current build. If you change a contract, restart Anvil before bootstrapping again. On every run it prints `GUM_FACTORY_CODE_HASH` and `GUM_BATCH_SWEEPER_CODE_HASH` for the services that pin a contract generation by code hash.

## Deployment

[`Bootstrap.s.sol`](script/Bootstrap.s.sol) deploys one generation: a `PaymentFactory`, the `BatchSweeper` bound to it, and the `WithdrawalForwarder` bound to the chain's CCTP V2 `TokenMessengerV2`.

```shell
GUM_CHAIN_ID=<chain-id> forge script script/Bootstrap.s.sol:BootstrapScript \
  --rpc-url <rpc-url> \
  --private-key <fresh-deployer-key> \
  --broadcast
```

- **Use a fresh deployer key, and the same key on every chain.** All three contracts are plain CREATE deployments, so their addresses depend only on the deployer and its nonce. The script requires nonce `0` to guarantee identical addresses across chains.
- `GUM_CHAIN_ID` must match the chain behind the RPC URL; the script aborts otherwise.
- The forwarder defaults to Circle's mainnet `TokenMessengerV2`, `0x28b5a0e9C621a5BadaA536219b3a228C8168cf5d`, which is the same on every supported chain. On a testnet, set `GUM_TOKEN_MESSENGER_V2`. The script aborts if the address has no code.
- `Payment`'s creation code is embedded in the factory, so **any change to `Payment` requires a new generation**, deployed from a new key.
- The script prints `GUM_FACTORY_ADDRESS`, `GUM_BATCH_SWEEPER_ADDRESS`, `GUM_WITHDRAWAL_FORWARDER_ADDRESS` and their code hashes for the backend's environment.

## Project layout

```
src/
  Payment.sol               Self-settling payment contract with committed calls
  PaymentFactory.sol        CREATE3 factory and address derivation
  utils/BubblingCREATE3.sol CREATE3 that bubbles up constructor reverts
  BatchSweeper.sol          Batched execute / recover
  WithdrawalForwarder.sol   EIP-3009 + CCTP V2 withdrawal bridge
  mock/MockStablecoin.sol   FiatToken-like fixture for tests and Anvil
script/
  Bootstrap.s.sol           Production deployment of a generation
  LocalBootstrap.s.sol      Deterministic Anvil fixtures
test/                       Unit, fuzz and opt-in fork tests
lib/                        forge-std and solady (git submodules)
```

## License

The contracts are MIT licensed, per their SPDX headers.
