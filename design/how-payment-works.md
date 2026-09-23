# How the new Payment works

A payment is a single-use contract that sits at an address you can compute ahead of time. The payer sends tokens to that address, and when someone "executes" it, a small program runs once at that address, moves the money exactly as agreed, and leaves behind a tiny stub.

## 1. The address is a commitment
Every payment is defined by seven terms:
- `token` and `amount`;
- `calls`, the list of actions to run when it settles;
- `expirationTimestamp`, `recovery`, `salt` and `chainId`.

The address is a hash of `Payment`'s creation code together with all seven terms. So:
- You can compute the address before anything exists onchain (`factory.paymentAddress(...)`), and give it to the payer.
- Changing any term, even one byte of one call's data, gives a different address. Nobody can run different logic against the funds sitting at *this* address, because only these exact terms produce it.
- Anyone who knows the terms can check offchain, before paying, exactly what the payment will do.

## 2. Paying
The payer just sends tokens to that address with a normal ERC-20 transfer. Nothing is deployed yet, and the address is only an account holding a token balance.

## 3. Executing
Anyone can call `factory.execute(terms...)`. The factory does three things:
1. It takes the terms exactly as they arrived in its calldata and places them after `Payment`'s creation code.
2. It deploys that with `CREATE2`. Because the result is the same init code the address was computed from, it lands exactly at the funded address.
3. If the deployment fails, it re-throws the constructor's own error, so the caller sees `InsufficientTokenBalance`, `CallFailed(index, reason)`, `AmountNotSpent` and so on. If the payment was already executed, it reverts with `AlreadyDeployed`.

## 4. What the constructor does
The constructor is the one-time program. It runs at the payment address with the payment's balance, and checks, in order:
1. **Wrong chain?** It moves nothing, emits `WrongChain`, and finishes, so the funds can be recovered later.
2. **Expired?** It sends the whole balance to `recovery`, emits `Recovered`, and finishes.
3. **Underfunded?** It reverts. Nothing is deployed, so `execute` can be tried again once more money arrives.
4. **Overpaid?** It sends the excess to `recovery` *first*, so the calls can only ever touch `amount`.
5. **It runs the calls in order**, each as a normal call made *by the payment address*. For example, `usdc.transfer(merchant, amount)`, or `usdc.approve(vault, amount)` followed by `vault.deposit(amount, merchant)`. After each call it emits `Called(index, target, data, result)`.
   - If any call fails, the whole thing reverts with `CallFailed(index, targetsOwnError)`. Nothing moves, and it can be retried until expiry.
   - A call to an address with no code would silently do nothing, so that reverts too, with `CallTargetHasNoCode`.
6. **Did the calls spend exactly `amount`?** It checks that the balance is now zero, and reverts with `AmountNotSpent` otherwise. That catches calls that did less than intended, such as a typo'd target or a token that returns `false` instead of reverting.
7. It emits `Settled(token, amount)`.

It's all or nothing: either every step succeeds, or nothing happens and the payment stays funded and retryable.

## 5. What stays behind: a 65-byte stub
A normal contract leaves its full code behind, and storing code costs 200 gas per byte. So instead of leaving `Payment`'s ~700-byte runtime at every address, the constructor finishes by writing a 65-byte stub:

```
[44 bytes: "forward any call to IMPLEMENTATION"][20 bytes: recovery][1 byte: settled?]
```

`IMPLEMENTATION` is a single copy of `Payment`'s functions (`recover` and `SETTLED`), deployed once by the factory. When you call `recover(token)` or `SETTLED()` on a payment:
- The stub forwards the call with `delegatecall`, so the shared code runs *as the payment address*, on the payment's own token balances.
- That code reads `recovery` and the settled flag from the last 21 bytes of the stub.
- If anyone calls the shared implementation directly, it refuses, because it isn't running inside a stub.

## 6. After settlement
- `recover(token)` is open to anyone. It sends the payment address's full balance of any token to `recovery`, which covers late payments, the wrong token, or funds sent on the wrong chain.
- `SETTLED()` returns true only if the calls actually ran.
- Calling `execute` again reverts with `AlreadyDeployed`, because code now exists at the address.

## Why it's cheap
- **One contract creation.** The terms travel inside the deployment itself, so there's no separate proxy deployment as with CREATE3.
- **65 bytes of stored code instead of ~1 KB.** That saves ~185k gas per payment.
- **No redundant copying.** The terms are copied straight from calldata into the deployment and read where they land.

The result is about 97k gas for a plain USDC payment, against ~315k for the contracts live today.
