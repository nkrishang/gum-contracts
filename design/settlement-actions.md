# Settlement actions: design notes

Status: draft for discussion. Nothing here is implemented yet.

Feature: *trigger an onchain action when a payment settles.* The obvious examples are depositing proceeds into a vault, telling a merchant contract that an order is paid, minting to the payer, or bridging proceeds elsewhere.

This document works out what the API should be for `Payment` / `PaymentFactory`. It also records what competitors ship and why we make each choice. The one-paragraph answer comes first.

## TL;DR

Add one optional **`Action`** to the payment terms and commit its hash into the CREATE3 salt, the same way every other term is committed. When the payment settles, the constructor:

1. sends the excess (`balance - amount`) to `recovery` **before** touching the action, so the action can never reach the overpayment;
2. **approves** `action.target` for exactly `amount`, then **calls** `action.target` with `action.data`, forwarding at least `action.gasLimit` gas;
3. **revokes** the approval, then sends whatever part of `amount` the target did not pull to `receiver`.

Under this pattern the action *is* the settlement when the target pulls the funds (vault deposit, CCTP burn, swap router, merchant `onPayment` that `transferFrom`s). It becomes a pure notification when the target does not pull, because `receiver` then gets the full `amount` right after the call. One primitive covers both cases. The token pull itself proves to the target that it was paid, so pull-style targets never need to authenticate `msg.sender`. Notify-style targets can do something no competitor's targets can: authenticate the caller by recomputing the payment address (§4).

A committed `onFailure` flag decides what a failed call means:

- **`Revert`** (default): the whole deployment reverts. The payment stays unsettled and retryable, and after `expirationTimestamp` the existing expiry path refunds everything to `recovery`. Use this when the action is *what the payer is buying*, such as a mint or an order.
- **`PayReceiver`**: the call's failure is caught and `amount` goes to `receiver` as if there were no action. Use this when the action is *what the merchant does with the proceeds*, such as treasury or yield routing. In this mode a relayer-supplied gas griefing guard is mandatory.

Expired and wrong-chain payments never run the action.

Three cheap onchain checks close the ways an action could exceed its mandate (§5b):
- `target != token`;
- `target` has code;
- `data` is not an ERC-20 `transfer`/`approve`/`transferFrom`/`increaseAllowance`/`permit`.

So yes, it is "additionally accept a call destination and calldata". But that alone is not enough. We also need an **allowance-based handoff**, **commitment into the address**, a **gas limit**, an explicit **failure policy**, and a **fixed ordering**, and that ordering is neither purely "before" nor purely "after" the disbursement.

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

1. **Nobody else calls from a per-payment address.** Every competitor's target sees a *shared* executor, so targets cannot authenticate who paid. We get that for free (§4), which is a real differentiator for "mark order paid" hooks.
2. **Approve-exact → call → revoke is the converged best practice.** deBridge does it. LI.FI max-approves, and Daimo doesn't revoke; both are gaps we shouldn't copy. Transfer-then-call (Across, Bungee) is used only where the recipient is itself the handler.
3. **Every non-atomic design needs a gas guard.** deBridge and LI.FI's Stargate receiver have one; Squid, Bungee and Daimo don't, and Circle calls it out explicitly.
4. **The failure policy splits the field.**
   - Atomic, retry until a deadline, then refund: Across without a fallback, deBridge's `requireSuccessfulExecution`.
   - Fall back to the *recipient*: LI.FI, Squid, Across `fallbackRecipient`, Rhino's "credit destination token".
   - Bounce to the *payer*: Daimo.

   deBridge makes it an explicit per-order flag, which is what we propose.
5. **Rhino's feature is a curated product over a private, trusted executor.** It is not an open primitive. Their "trigger onchain actions" is a menu of vault and protocol integrations that Rhino configures and relays, with the failure handling decided offchain per account. We can offer that same product experience (templates in the dashboard) on top of a trustless primitive. That combination is stronger than what they ship.
6. **We don't need dynamic amount injection.** Squid's `inputPos` and Across's `Replacement` exist because bridge output amounts vary with fees and slippage. Our `amount` is exact and committed, and excess is split off before the call, so `data` can hard-code `amount`.

## The design space, question by question

### 1. Where does the call execute from?

| Option | msg.sender seen by target | Blast radius of a malicious/buggy call |
| --- | --- | --- |
| **The `Payment` itself (in its constructor)** | the payment address | That one payment's `amount`. The payment never holds approvals from anyone, and excess is gone before the call. |
| `PaymentFactory` / a shared router | the shared contract | Every payment that routes through it at once. This is the root cause of the LI.FI (2024) and Socket (2024) router exploits: an arbitrary call from a contract that users had approved. |
| A shared stateless executor (LI.FI `Executor`, Across `MulticallHandler`) | the executor | Only what sits in the executor during the tx. That is safe only if it never holds approvals and sweeps itself empty. |

**Choose the `Payment` itself.** Each payment is already a single-use, isolated execution context holding only its own funds, the same shape as Daimo's per-intent contract. Nothing new needs to be trusted. Users never `approve` a `Payment`; funds are pushed to it. So the arbitrary-call class of bug is contained to funds whose destination the payer already agreed to by paying that address.

Because the call runs **inside the constructor**, some consequences follow (verified in `test/spike/ConstructorAction.t.sol`):

- The payment address has **no code** while the target runs. A target that calls back into `msg.sender` fails: a high-level call reverts on the extcodesize check, and a low-level call "succeeds" doing nothing. So actions cannot use callback-style protocols directly. A raw Uniswap v3 `pool.swap` calls `uniswapV3SwapCallback` on `msg.sender`, and flash loans are similar. Routers that `transferFrom` the payer work fine.
- `msg.sender.code.length == 0` inside the target, so a target with an "only EOAs" or `isContract` check treats the payment as an EOA. That is harmless for us, but worth documenting.
- ERC-4626 `deposit(amount, beneficiary)` from the constructor works unchanged (spike: `test_vault_deposit_from_constructor`).
- `recover()` cannot be reached until the constructor returns, so a target cannot re-enter it. Re-entering `factory.execute` with the same terms fails because the CREATE3 proxy already exists.

### 2. How do the funds reach the target? (approve vs. transfer vs. notify)

| Handoff | Works with | Problems |
| --- | --- | --- |
| **Approve `amount`, call, revoke** (pull) | Almost every DeFi entry point (`deposit`, `supply`, `depositForBurn`, routers), plus merchant contracts written as `onPayment(...) { token.transferFrom(msg.sender, ...) }` | Must revoke after the call, or the target can later pull late-arriving funds meant for `recovery`. USDT-style approve-to-zero rules are fine: a fresh contract starts at zero, and we end at zero. |
| Transfer `amount` to target, then call (push) | Balance-based handlers (Across `MulticallHandler`, Uniswap UniversalRouter with the router as payer) | The target cannot tell our transfer from anyone else's, so it must be a trusted stateless handler. If the call fails, the funds are already at the target, and a push-then-revert only works atomically. |
| Transfer `amount` to `receiver`, then call target (notify) | "Mark order paid" style hooks | The target has no proof it was paid unless it authenticates `msg.sender` (see §4). |

**Choose approve → call → revoke → pay the unspent remainder to `receiver`.** It subsumes the other two:

- *Pull:* the target `transferFrom`s what it needs, and the remainder (usually 0) goes to `receiver`.
- *Notify:* the target pulls nothing, so `receiver` gets the full `amount` straight after the call. The only difference from "transfer then call" is that the call happens a few opcodes *before* the transfer, inside the same atomic constructor, which no target can observe except by reading `receiver`'s balance mid-call. Nobody should rely on that anyway.
- *Push:* point the action at a small stateless adapter whose entry point `transferFrom`s the payment and then works on its own balance. LI.FI's `Executor` works this way. Push stays out of `Payment`.

Pull gives targets **proof of payment for free**: a target that received the tokens via `transferFrom` knows it got paid, whoever called it. Every existing ERC-20 approve-and-call integration already relies on this.

### 3. Ordering: "before or after disbursing?"

The question has no single answer, because with approve-and-call the action and the disbursement are the same step. The ordering that matters:

```
balance = token.balanceOf(this)
[expired]      -> all to recovery, no action.            (unchanged)
[wrong chain]  -> nothing, no action.                    (unchanged)
[underfunded]  -> revert.                                (unchanged)

excess = balance - amount
1. transfer excess -> recovery          // BEFORE the call: the action can never touch the payer's overpayment
2. approve(target, amount)
3. call target with data                // action runs; may pull up to `amount`
4. approve(target, 0)                   // always, success or failure
5. transfer balanceOf(this) -> receiver // unspent portion of `amount` (all of it on notify-style or PayReceiver-fallback)
6. emit Settled(receiver, amount, target, success)
```

Why this order:

- **Excess first.** If excess were still in the contract during the call, a push-style target, or a buggy target with a stale allowance, could reach Gum's recovery funds. Sending it out first means the contract holds exactly `amount` during the call, the only money the action is entitled to.
- **Revoke unconditionally.** A dangling allowance on a contract whose `recover()` is permissionless and that keeps receiving late payments lets the target drain those late payments.
- **Remainder to `receiver`, not `recovery`.** `amount` is the merchant's money whether or not the action spends it; `recovery` is only for funds that were never owed. That also makes `receiver` the natural fallback beneficiary.
- **The call runs after all state that matters is decided.** `SETTLED` is known and excess is gone. The only effect left after the call is paying out the unspent remainder, which the target cannot influence except by pulling.

Caveat for step 5: send the *remaining balance*, not `amount - pulled`. After step 1 the balance is exactly what is left of `amount`, and computing it from the balance tolerates targets that pull oddly. Step 5 **must** come after step 4.

### 4. Authenticating the caller (for notify-style targets)

The pull model makes this unnecessary for anything that takes the money. For a pure notification ("order 123 is paid, the money went to `receiver`"), the target has to trust that `msg.sender` is a genuine settled Gum payment.

Competitors can't offer this, because their target always sees a **shared** executor: Daimo's `DaimoPayExecutor`, Rhino's `BridgeVM`, LI.FI's `Executor`, Across's `MulticallHandler`. We call from the **single-use payment address**, and that address commits to everything, including `keccak256(action.data)`. So:

- Option A, **authenticate by recomputation**. The target's entry point takes the payment terms as arguments, for example `onGumPayment(PaymentTerms terms, uint32 gasLimit, OnFailure onFailure, bytes32 orderId)`. It then checks `msg.sender == factory.paymentAddress(terms, address(this), gasLimit, onFailure, keccak256(msg.data))`. This is not circular: the target hashes its own `msg.data`, and nothing in `data` has to contain its own hash or the payment address. It needs no special mode in `Payment`, because it is just a particular `data`. We could ship a small `GumPaymentReceiver` base contract that does the check.
- Option B, **pull as proof** (the simple default we recommend to merchants). For example: `onPayment(orderId) { usdc.transferFrom(msg.sender, treasury, PRICE); paid[orderId] = true; }`. It needs no authentication and is trivial to write. It matches how competitors tell integrators to handle hooks anyone can call, as in Across's warning and Daimo's "check the allowance from `msg.sender`, pull it with `transferFrom`" guidance.

**Choose raw calldata. Document B as the default and A for Gum-aware contracts that must not hold funds.** Neither needs anything extra in `Payment`.

### 5. Commitment: what goes into the address

The action must be committed, or the relayer picks the call and steals the approval. Since CREATE3 addresses depend on the salt only, not on init code, the action has to be in the salt:

```solidity
struct Action {
    address target;     // address(0) = no action
    uint32  gasLimit;   // minimum gas the call must receive; ignored when target == 0
    OnFailure onFailure;// Revert | PayReceiver
    bytes   data;
}

salt = keccak256(abi.encode(token, amount, receiver, expirationTimestamp, recovery, salt, chainId,
                            action.target, action.gasLimit, action.onFailure, keccak256(action.data)));
```

- Hash the calldata instead of encoding it raw, so `paymentAddress` stays cheap and callers can derive an address from `(terms, actionHash)` without holding the full calldata.
- `execute` has to receive the full `data`, because the constructor needs it. The backend must therefore **store the action calldata** alongside the other terms. The sweeper already requires the full terms, and this adds one more field.
- Pass a `PaymentTerms` struct instead of 11 positional arguments, which would hit stack-too-deep and is a footgun for integrators anyway. Since any change to `Payment` is a new generation, we can change the ABI freely.
- `paymentAddress(terms)` with `target == 0` gives plain payments. We should also require `gasLimit == 0 && data.length == 0` when `target == 0`, so there is exactly one encoding of "no action" and no two addresses for the same economic payment.

### 5b. What authority does the action author get?

The call runs *as the payment address*. For that one call, whoever authors the action (merchant or Gum backend) can therefore do anything the payment address can do. The approval only bounds what the target can do *by pulling*. It does not bound what `data` makes the payment do. Concretely:

- `target = token, data = approve(attacker, type(uint256).max)` leaves a standing allowance that our step-4 revoke does not touch, because it only revokes `target`. The attacker then drains every late payment that `recover()` should have sent to `recovery`.
- `target = someOtherToken, data = transfer(attacker, bal)` steals wrong-token funds that happen to be sitting at the address at settlement. Today those always go to `recovery`.
- `target = token, data = transfer(attacker, amount)` is just a roundabout way to pay `attacker`. That is harmless, because the receiver could be `attacker` anyway.

Today `receiver` can only ever receive `amount` of `token`. Actions widen that to "anything the address holds at settlement, plus allowances over the future". This matters if action authors are less trusted than whoever controls `recovery`, e.g. if merchants author actions in a dashboard.

Mitigations, cheapest first:

1. **Onchain: `target != token`**, and **reject ERC-20 mutating selectors** (`transfer`, `transferFrom`, `approve`, `increaseAllowance`, `permit`) regardless of target, as deBridge's default executor does. This kills the allowance trick and the "steal wrong-token funds" trick for standard ERC-20s. It costs one comparison and a 4-byte check, and no legitimate action needs those selectors, since `receiver` already covers plain transfers.
2. **Onchain: `target.code.length != 0`.** Otherwise a typo'd EOA target "succeeds" and silently skips the action (Across's `MulticallHandler` applies the same rule).
3. **Offchain: allowlist targets in the backend** (vaults, CCTP `TokenMessengerV2`, reviewed merchant contracts). Keep the contracts permissionless.

### 6. Failure policy

This is the real product decision. Everything else follows from the invariants above.

| | `Revert` (atomic) | `PayReceiver` (best effort) |
| --- | --- | --- |
| Call fails | Deployment reverts, and `execute` surfaces `CREATE3.DeploymentFailed`. Nothing moves. | Approval revoked, `amount` to `receiver`, `Settled(..., success=false)`. |
| Transient failure (vault cap full, paused, stale oracle, sequencer hiccup) | **Retried** by the sweeper on its next pass, for free. | **Permanently** degraded: the payment is now settled and the action can never run. |
| Permanent failure (sold out, target bug, bad calldata) | Funds wait until `expirationTimestamp`, then the expiry path refunds all of it to `recovery`. The merchant loses the sale; the payer is made whole. | The merchant is paid, the action silently did not happen, and reconciliation happens offchain. |
| Relayer gas griefing | Not possible. Too little gas reverts everything, so the relayer only wastes its own gas. | **Possible unless guarded.** See §7. |
| Right for | Actions the payer is paying *for*: mint, ticket, order fulfilment, subscription activation. | Actions the merchant wants *done with* the proceeds: vault deposit, bridge to treasury chain, swap to another stablecoin. |

Default to **`Revert`**. It keeps the existing invariant "a payment either settles as specified or it doesn't settle", composes with the existing expiry refund and sweeper retry, and adds no new states. Offer `PayReceiver` for treasury-style actions, where losing the sale over a yield preference would be absurd.

Other options we considered:

- *Bounce to `recovery` immediately on failure.* This is what Daimo Pay does: a failed `finalCall` sends everything to `refundAddress`, and the session is marked `bounced`. It is a legitimate third mode: the payer gets refunded at once instead of at expiry. We don't recommend it as the default, for two reasons:
  1. With a permissionless relayer, any transient failure bounces the payment for good. Our `Revert` mode retries on each sweep until expiry and only then refunds, which is the same outcome with more chances to succeed.
  2. It needs the same gas guard as `PayReceiver`, or a relayer can force bounces.

  If we want it, it is a third `OnFailure` variant (`Refund`) and slots straight into the enum. Note that our `recovery` is Gum custody, not necessarily the payer, so "refund" means "refund via Gum ops".
- *A separate `fallbackRecipient` field.* LI.FI's `toFallbackAddress`, Across's `fallbackRecipient` and deBridge's `fallbackAddress` all exist because bridges have no natural beneficiary. We do, in `receiver`. The field would only add a way to misconfigure things. We can add it later as a distinct `OnFailure` variant if a merchant needs it.
- *Retry the action later from a stored state.* That needs storage, an owner or retry entrypoint, and a replay story. It is not worth it: `Revert` + sweeper already gives retries, and `PayReceiver` is by definition fire-and-forget.

### 7. Gas

- The relayer (sweeper) chooses gas, and `execute` is permissionless.
- In `Revert` mode nothing is needed: out-of-gas anywhere reverts the deployment.
- In `PayReceiver` mode, a relayer can pick a gas amount at which the call runs out of gas but the constructor still completes (the 63/64 rule). The action is then skipped and the payment settled anyway. Our spike (`test_gas_griefing_without_guard`) shows that for a ~2M-gas action this is *not* achievable in practice. The code-deposit cost that follows the call (~200 gas/byte of runtime code) exceeds the 1/64 left over. But at 10M+ gas it is easy. That natural protection is incidental, so **guard explicitly**. deBridge's default executor does exactly this (`NotEnoughTxGas`), and Circle's CCTP hook docs warn about the same "low gas attack" on permissionless relays: `if (gasleft() < action.gasLimit * 64 / 63 + BUFFER) revert InsufficientGas();` before the call, then call with `gas: action.gasLimit`. The committed `gasLimit` then states exactly what "the action got a fair chance" means, and a starved call reverts the deployment instead of skipping the action.
- Do not copy return data: call via assembly with `returndatacopy` skipped, as in Solady's `SafeTransferLib`. That defeats return-bomb griefing by a malicious target, and `execute` hides the revert reason behind `DeploymentFailed` anyway.
- **`BatchSweeper` impact.** Its `try FACTORY.execute` forwards 63/64 of remaining gas to each item. One heavy or looping action in `Revert` mode can burn most of the batch's gas and starve later items. The sweeper should forward a per-item gas cap derived from `action.gasLimit` plus the base cost, or the backend should put actioned payments into their own batches.

### 8. Native value

Out of scope for v1. Gum payments are ERC-20 stablecoins, and `Payment` never holds ETH on purpose. If an action needs native gas, for example a LayerZero fee, that becomes a separate `value` term funded by... whom? That is exactly the sort of question to avoid until a merchant needs it. Commit `value = 0` implicitly.

### 9. Scenario checklist

| Scenario | Outcome under the proposal |
| --- | --- |
| Exact funding, action succeeds and pulls `amount` | Target has the funds, `receiver` gets 0, `Settled(receiver, amount, target, true)` |
| Exact funding, notify-style action (pulls 0) | `receiver` gets `amount` right after the call |
| Action pulls part of `amount` (e.g. exact-output swap) | Unspent part to `receiver` |
| Overpaid | Excess to `recovery` *before* the call; the action only ever sees `amount` |
| Underfunded | Revert (unchanged); the action is not attempted |
| Expired | Everything to `recovery`; the action is **not** run, even if the payment is funded |
| Wrong chain | Nothing moves; the action is not run; `recover` works (unchanged) |
| Action reverts, `Revert` | Deployment reverts; retried by the sweeper; refunded on expiry |
| Action reverts, `PayReceiver` | `amount` to `receiver`, `success=false` |
| Relayer under-supplies gas | `Revert`: reverts. `PayReceiver`: guard reverts. The action is never silently skipped. |
| Target returns a huge revert blob | Not copied; no griefing |
| Target leaves allowance unspent | Revoked in step 4, so late funds cannot be pulled |
| Target calls back into the payment | Fails (no code yet). Integrators must use pull-style entry points. |
| Target calls `factory.execute` for the same terms | Fails: the address is already deployed |
| Receiver or target blacklisted by USDC | `approve` to a blacklisted spender reverts on FiatToken. `Revert`: the deployment reverts. `PayReceiver`: approve must also be inside the try-path, otherwise the fallback is unreachable. |
| Action targets the token, an EOA, or encodes `approve`/`transfer` | `InvalidAction`, so the deployment reverts and the payment is refunded at expiry. The backend should catch this at quote time. |
| Late funds after settlement | `recover()` sends them to `recovery` (unchanged); no dangling allowance |
| Swap action with a stale `minOut` | Reverts once the price moves; `Revert` mode retries until expiry. **Swaps are a poor settlement action** unless the expiry window is short. Flag this in integrator docs. |
| Relayer sandwiching an action | Only as bad as the slippage bounds committed in `data`. The relayer cannot alter `data`. |

### 10. What the constructor looks like

```solidity
struct Action { address target; uint32 gasLimit; OnFailure onFailure; bytes data; }
enum OnFailure { Revert, PayReceiver }

event Settled(address indexed receiver, uint256 amount, address indexed actionTarget, bool actionSucceeded);

// ...after the existing chain/expiry/underfunded checks:
uint256 excess = balance - amount;
if (excess != 0) { safeTransfer(token, recovery, excess); emit Recovered(recovery, token, excess); }

bool ok = true;
if (action.target != address(0)) {
    // §5b: target must be code, must not be the token, and data must not be an ERC-20 mutator.
    // (Checked here rather than in the factory so the invariant lives with the code that makes the call.)
    if (action.target == token || action.target.code.length == 0 || _isErc20Mutator(action.data)) {
        revert InvalidAction();
    }
    if (action.onFailure == OnFailure.PayReceiver && gasleft() < uint256(action.gasLimit) * 64 / 63 + GAS_BUFFER) {
        revert InsufficientGas();
    }
    ok = _tryApprove(token, action.target, amount)
        && _callNoCopy(action.target, action.gasLimit, action.data);   // gas-capped, no returndata copy
    _tryApprove(token, action.target, 0);                            // revoke unconditionally
    if (!ok && action.onFailure == OnFailure.Revert) revert ActionFailed();
}

uint256 unspent = ERC20(token).balanceOf(address(this));
if (unspent != 0) safeTransfer(token, receiver, unspent);
SETTLED = true;
emit Settled(receiver, amount, action.target, ok);
```

One subtlety: in `Revert` mode the revoke on the failure path is pointless, because we revert anyway. In `PayReceiver` mode, if the revoke itself fails (some tokens revert on approve to certain spenders), the safe move is to revert the deployment rather than leave a dangling allowance.

## Open questions for the team

1. **Who authors actions?** Merchant-configured per checkout, Gum-configured per merchant (treasury routing), or both? This decides whether the dashboard exposes raw calldata or a curated set of action templates. Rhino.fi and LI.FI both expose curated flows over a raw-call primitive.
2. **Is `Revert` the right default for our merchants?** It is right for commerce, but it means a broken merchant hook delays the payer's refund until expiry. Do we need shorter expiries for actioned payments?
3. **Allowlist targets?** The contracts should stay permissionless. A backend-side allowlist of known-good targets (vaults, CCTP, merchant contracts we have reviewed) is cheap and removes most footguns from the dashboard.
4. **Ship a `GumPaymentReceiver` base contract (§4 Option A)?** Only if a merchant asks for authenticated notifications without pulling funds.
5. **Cross-chain actions.** "Settle on Base, deposit on Arbitrum" is our `WithdrawalForwarder` + CCTP V2 hooks (`depositForBurnWithHook`). The source-side action is just `approve TokenMessengerV2 + depositForBurnWithHook(...)` under this design. The destination side needs a hook executor, which CCTP does not provide.
