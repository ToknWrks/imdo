# Hook Owner Safe: accept ownership, then `open()` the pool

Two transactions, both from the Hook Owner Safe, both through the Safe{Wallet} web UI (app.safe.global). Nothing else
the Safe ever has to do for the hook, except `lowerFee` if the owner one day decides to lower the steady-state fee.

| | |
|---|---|
| Safe | `0x5966CA0df8b753D8458162867f3435fa6E49222E` on Ethereum, 2-of-3 |
| Signers | `0x217C…563B`, `0xa71F…75Cb`, `0xb1eC…E559` |
| Hook | the `hook` address printed by the deploy (`DeployImdo.Deployment.hook`; the 2026-10-12 rehearsal predicted `0x5d79a5998cFCB4F17FfFcaa0aa603499f73E60CC`, which only holds if the deployer's nonce is unchanged at broadcast). Take it from the broadcast receipt, never from this file. |
| Contract | `ImdoHook` (`src/ImdoHook.sol`), OpenZeppelin `Ownable2Step` |

## Why two steps

The deploy script's last transaction calls `transferOwnership(hookOwner)` from the deployer. With `Ownable2Step` that only
**offers** ownership: the deployer stays owner until the Safe calls `acceptOwnership()`. Until then the Safe cannot call
`open()` and the pool charges the flat 20% launch fee on every trade. The order is therefore:

1. `acceptOwnership()` as soon as the deploy has landed (no reason to wait).
2. `open()` at the announced launch time. It starts the fee decay from 20% to 1.5% over 30 minutes. Callable once, cannot be
   undone, gates nothing: trading is possible before it, only dearer. **Forgetting it leaves everyone paying 20%.**

## Before you start: read the hook on Etherscan

Open `https://etherscan.io/address/<hook>#readContract` (the code is verified at deploy; if the tab is empty, use the
`cast` lines at the bottom instead) and check:

| Read | Expect before step 1 | Expect after step 1 | Expect after step 2 |
|---|---|---|---|
| `owner()` | the deployer `0xe478…4768` | the Safe `0x5966…222E` | the Safe |
| `pendingOwner()` | the Safe `0x5966…222E` | zero address | zero address |
| `launchTimestamp()` | 0 | 0 | the block time of `open()` |
| `currentFeeBps()` | 2000 | 2000 | falling from 2000 to 150 over 30 min |

If `pendingOwner()` is not the Safe, stop: the deploy did not offer ownership to this Safe and the hook is still the
deployer's. Fix that from the deployer (`transferOwnership(safe)`), not from here.

## Step 1: `acceptOwnership()` in the Safe UI

1. app.safe.global → open the Safe (Ethereum) → **New transaction** → **Transaction Builder** (under Safe Apps; it is a
   Safe-made app, no third party).
2. **Enter Address or ENS Name**: the hook address. The builder tries to fetch the ABI from Etherscan; if it finds it,
   skip to 4.
3. If it asks for the ABI, paste this (the two functions this runbook needs, plus the reads):
   ```json
   [
     {"type":"function","name":"acceptOwnership","inputs":[],"outputs":[],"stateMutability":"nonpayable"},
     {"type":"function","name":"open","inputs":[],"outputs":[],"stateMutability":"nonpayable"},
     {"type":"function","name":"owner","inputs":[],"outputs":[{"type":"address"}],"stateMutability":"view"},
     {"type":"function","name":"pendingOwner","inputs":[],"outputs":[{"type":"address"}],"stateMutability":"view"},
     {"type":"function","name":"launchTimestamp","inputs":[],"outputs":[{"type":"uint64"}],"stateMutability":"view"},
     {"type":"function","name":"currentFeeBps","inputs":[],"outputs":[{"type":"uint256"}],"stateMutability":"view"}
   ]
   ```
4. **Contract Method Selector**: `acceptOwnership`. No inputs. **ETH value**: 0.
5. **Add transaction** → **Create Batch** → **Send Batch** → review. The review screen must show exactly one call,
   `acceptOwnership()` to the hook address, value 0. The data is the 4-byte selector `0x79ba5097` and nothing else.
6. Sign with the first signer, then the second signer confirms and executes (2-of-3). Gas is paid by whoever executes.
7. Re-read `owner()` and `pendingOwner()` as in the table.

## Step 2: `open()` at launch time

Same Transaction Builder flow with method `open`, no inputs, value 0. Selector `0xfcfff16f`. Review screen: one call,
`open()` to the hook, value 0.

Timing: the fee starts falling at the block that includes the execution, not at signing. Collect the first signature
early, leave the second signer to execute at the announced minute. A Safe transaction waits in the queue as long as you
like; nothing happens until the second signer executes.

If the execution reverts with `AlreadyOpen`, it was already called: read `launchTimestamp()`.

## What can go wrong

- **`OwnableUnauthorizedAccount`** on either call: the Safe is not the owner yet (step 1 not executed, or executed from
  the wrong Safe). Check `owner()`.
- **Wrong network**: the Safe exists on Ethereum and Base at the same address; the hook is on Ethereum only. The UI shows
  the network in the top left.
- **Transaction Builder shows more than one call**, or a value other than 0, or a different `to`: reject and start over.
- **A signer's wallet proposes a different Safe nonce**: harmless, the queue handles it; but do not execute `open()`
  before `acceptOwnership()` has been executed.

## The same checks from a terminal

```sh
HOOK=0x...   # from the deploy receipt
RPC=https://ethereum-rpc.publicnode.com
cast call $HOOK 'owner()(address)'           --rpc-url $RPC
cast call $HOOK 'pendingOwner()(address)'    --rpc-url $RPC
cast call $HOOK 'launchTimestamp()(uint64)'  --rpc-url $RPC
cast call $HOOK 'currentFeeBps()(uint256)'   --rpc-url $RPC
cast sig 'acceptOwnership()'   # 0x79ba5097
cast sig 'open()'              # 0xfcfff16f
```
