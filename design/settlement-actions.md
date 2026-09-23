# Settlement actions

Status: implemented on `design/settlement-actions`. This is a new contract generation.

Feature: *trigger onchain actions when a payment settles*: pay a merchant, split fees, deposit into a vault, notify a merchant contract, burn through CCTP, and so on.

## Decision

`receiver` is replaced by an ordered list of committed calls. The default action, "pay the receiver", becomes just one call among many.

```solidity
struct Call { address target; bytes data; }

constructor(address token, uint256 amount, Call[] calls, uint64 expirationTimestamp, address recovery, uint256 chainId)
```

What the constructor does:

1. **Wrong chain:** emit `WrongChain` and return. No calls run. (unchanged)
2. **Expired:** send the whole balance to `recovery` and return. No calls run. (unchanged)
3. **Underfunded:** revert `InsufficientTokenBalance`. (unchanged)
4. **Excess to `recovery` first**, so the calls can only ever spend `amount`.
5. **Run each call in order.** Calls go through Solady's `LibCall.callContract`: a failed call bubbles up its own revert, and a call to an address without code reverts `TargetIsNotContract()`. After each call it emits `Called(i, target, data, result)`.
6. **Require the balance to be zero**, i.e. exactly `amount` was spent. Otherwise it reverts `AmountNotSpent(remaining)`.
7. Set `SETTLED = true` and emit `Settled(token, amount)`.

`PaymentFactory` hashes `(token, amount, calls, expirationTimestamp, recovery, salt, chainId)` into the CREATE3 salt, so every target, every byte of calldata and the order of the calls are fixed by the address. `BatchSweeper.Sweep` carries `calls` in place of `receiver`.

### Why this shape

- **One primitive with no special cases.** "Pay the receiver" is `token.transfer(receiver, amount)`. Approve-and-deposit, fee splits, CCTP burns and merchant notifications are all just more calls, and no adapter contracts are needed.
- **All or nothing.** Any failing call reverts the whole deployment, which matches the existing "a payment settles as specified or not at all" rule:
  - the sweeper retries on its next pass;
  - after expiry, the existing path refunds everything to `recovery`;
  - there are no half-settled states, and no fallback modes to choose between;
  - a relayer can't sabotage a call with too little gas, since that just reverts everything.
- **Exact spend, with the excess removed first.** The cap is structural: the calls only ever see `amount`. Requiring a zero balance at the end catches silent no-ops (a target with no code, a token that returns `false`) that would otherwise count as a settled payment.
- **Everything is verifiable offchain.** The address commits to the calls, so anyone can check what a payment will do before paying. That is also why there is no onchain allowlist (see below).
- **Calls run as the payment address, by design.** Targets are expected to work the same whoever calls them. A target that needs proof of payment should pull the tokens with `transferFrom`, because a token pull is proof no matter who the caller is.

### Considered and rejected

- **A single `Action {target, gasLimit, onFailure, data}` with approve → call → revoke built into `Payment`.** This was the first draft here. The call list covers it without special cases, and the revert-only rule removes the need for `onFailure` modes (`PayReceiver`, `Refund`) and the gas-griefing guard they required.
- **An onchain allowlist of `(target, selector)` pairs in `PaymentFactory`, owned per `guardId`.**
  - It is redundant, because the calls are already committed and can be checked offchain directly, which is stricter than checking a guard.
  - Its only real power would be blocking payments at execution time.
  - Target plus selector is too coarse: `(USDC, transfer)` allows transfers to anyone.
  - It would add owned, mutable state to ownerless contracts.
- **An onchain check that no allowance on `token` survives settlement.** It's not needed: `Payment` is single-use and holds nothing once the constructor finishes. An approval the target never used would only matter for late funds, and exact approvals can be checked offchain along with the rest of the calls.
- **Native value on calls.** Gum payments are ERC-20 only.

### Constraints for whoever builds calls (gum-server)

- The payment has no code while its calls run, so targets must not call back into it. Raw Uniswap pool swaps and flash loans are therefore out; routers that pull via `transferFrom` are fine.
- Approve exactly what the next call pulls.
- `execute` still surfaces every constructor failure as `CREATE3.DeploymentFailed`. Simulate the constructor, or `new Payment(...)` in an `eth_call`, to get the inner error.
- Calls are part of a payment's identity. The backend must store the full call list to derive the address and to execute it.
- An action that fails permanently (sold out, bad calldata) keeps the funds at the address until expiry, and then refunds them to `recovery`. So simulate calls when quoting a payment, and exclude failing items from sweep batches.
- A heavy call list uses its share of the batch's gas. Give such items their own batches, or cap the gas per item.

## What competitors ship

Researched from each project's source and docs in September 2026. The items marked *unverified* were inferred, not read in source.

| | How the action is specified | Committed how | Funds handoff | Target sees `msg.sender` = | On call failure | Gas griefing defence |
| --- | --- | --- | --- | --- | --- | --- |
| **rhino.fi** Smart Deposit Addresses | `postBridgeData: {_tag, …params}`. A **closed list of predefined actions** (`aavev3supply`, `mapledeposit`, `etherfideposit`, `extended`, …). No raw calldata. "For security reasons, only predefined actions are available." Paid add-on enabled per account. | **Not onchain.** Stored in Rhino's DB; addresses are reusable and mutable via `PATCH`. | Pool `safeTransfer`s to a sandbox `BridgeVM`, which runs Rhino-built `approve` + call steps (*unverified that SDA uses this path*). | Shared `BridgeVM` | The whole batch reverts. The offchain response depends on account config: retry, credit the destination token to `destinationAddress`, or webhook and wait for instructions. | n/a (Rhino relays) |
| **Daimo Pay** (closest analogue) | `finalCall {to, value, data}` + `finalCallToken {token, amount}` + `refundAddress` | **Hashed into a CREATE2 intent address**, like ours | Singleton executor **approves** `to`, calls, then sweeps the balance to `refundAddress`. **The allowance is not reset.** | Shared `DaimoPayExecutor` | **Bounces**: everything left goes to `refundAddress`, and the event says `success=false`. It does not revert. | None. Forwards all gas; the newer version restricts relayers to an allowlist. |
| **LI.FI** contract calls | `contractCalls[] {toContractAddress, toContractCallData, toContractGasLimit, toApprovalAddress, fromAmount}` + `toFallbackAddress` | Bridge message | Receiver approves `Executor`; `Executor` pulls, **max-approves** `approveTo`, calls, sweeps surplus to the receiver | Shared `Executor` | try/catch: the **full amount goes to the fallback** (the receiver) | `ReceiverStargateV2`: `recoverGas` reserve, `gas: gasleft() - recoverGas`. `ReceiverAcrossV3`: none. |
| **Squid** postHooks | `calls[] {callType, target, value, callData, payload:{tokenAddress, inputPos}}` | Bridge message | Router approves `SquidMulticall`, which pulls, then **writes its live balance into calldata at `inputPos`** | Shared `SquidMulticall` (anyone can call `run`) | try/catch: the bridged token goes to `refundRecipient` | None |
| **Bungee** destination payload | `destinationPayload`, `destinationGasLimit`. "Not available for deposit-address routes." | Signed by the Bungee backend | **Transfers** to the target, then calls `executeData(quoteId, amount, token, data)` | `CalldataExecutor` | Not rolled back: funds stay at the target, which must handle it | `excessivelySafeCall(gasLimit, 0 bytes copied)`, but no `gasleft()` check |
| **Across** | `message` → recipient's `handleV3AcrossMessage(token, amount, relayer, message)`; `MulticallHandler` `Instructions {Call[], fallbackRecipient}` | Deposit, and now also **counterfactual deposit addresses** committing to `message` via a merkle root of routes | SpokePool **transfers** to the recipient, then calls it | SpokePool, or the handler's caller, which anyone can call (docs: "Across does not guarantee message integrity") | `fallbackRecipient == 0`: the fill reverts and the user is refunded on origin after `fillDeadline`. Otherwise the calls roll back and the token is drained to the fallback. | n/a (the relayer is economically motivated to fill) |
| **deBridge DLN** hooks | `{fallbackAddress, target, payload{to, txGas, callData}, requireSuccessfulExecution, allowDelayedExecution, executionFee}` | Order | Adapter transfers to the executor. The default executor **approves exactly, calls, resets the approval to 0**, and sends leftovers to the fallback. It **rejects `approve`/`transfer`/`transferFrom`/`increaseAllowance` selectors.** | Adapter or executor | `requireSuccessfulExecution`: the fill reverts. Otherwise the funds go to `fallbackAddress`. The delayed mode can be retried by anyone for a fee. | `gasleft() >= txGas * 64/63`, else `NotEnoughTxGas` |
| **Circle CCTP V2** hooks | `hookData` bytes, opaque to CCTP | Burn message | Mint to `mintRecipient`; the integrator's wrapper then calls the hook | Integrator's wrapper | The reference wrapper is **non-atomic on purpose**. It warns that a permissionless relay allows a "low gas attack" that consumes the nonce without running the hook. | Owner-only relaying in the example |
| **Coinbase Commerce** onchain protocol | None: transfer + `Transferred` event only | Operator signature | n/a | n/a | n/a | n/a |

What we take from the table:

1. **Nobody else calls from a per-payment address.** Every competitor's target sees a *shared* executor, so targets cannot authenticate who paid. Ours see the single-use payment address. A target that wants to can authenticate it: it takes the other terms and the preceding calls as arguments, appends its own call (`msg.data`), and checks that `factory.paymentAddress(...)` equals `msg.sender`. There is no circularity, because a call's calldata never needs to contain itself. `AuthenticatedOrderBook` in `test/utils/SettlementFixtures.sol` does this.
2. **Handing funds over is part of the call list.** Approve then call and transfer then call are both just calls here. deBridge's exact-approve-and-revoke discipline becomes an offchain rule about exact approvals, which works because `Payment` is single-use.
3. **Every design that isn't all-or-nothing needs a gas guard.** deBridge and LI.FI's Stargate receiver have one; Squid, Bungee and Daimo don't, and Circle calls it out explicitly. Our revert-only rule sidesteps this.
4. **The failure policy splits the field.**
   - Atomic, retry until a deadline, then refund: Across without a fallback, deBridge's `requireSuccessfulExecution`.
   - Fall back to the *recipient*: LI.FI, Squid, Across `fallbackRecipient`, Rhino's "credit destination token".
   - Bounce to the *payer*: Daimo.

   deBridge makes it an explicit per-order flag. We chose atomic-only.
5. **Rhino's feature is a curated product over a private, trusted executor.** It is not an open primitive. Their "trigger onchain actions" is a menu of vault and protocol integrations that Rhino configures and relays, with the failure handling decided offchain per account. We can offer the same experience (call templates built by gum-server) on top of an onchain primitive that commits to the calls and needs no trusted executor.
6. **We don't need dynamic amount injection.** Squid's `inputPos` and Across's `Replacement` exist because bridge output amounts vary with fees and slippage. Our `amount` is exact and committed, and excess is split off before the call, so `data` can hard-code `amount`.
