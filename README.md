# IMD Offsets (IMDO)

IMDO is a fork of the supplied **ADAM** repository, under the MIT license. It retains the Foundry layout, vendored dependencies, custom errors, reentrancy guards, reward accumulator, seven-day backlog, pull payments, fee calculations and adapted regression tests. No transactions were broadcast.

**1,000,000,000 IMDO**, 18 decimals, are created once for the deploying account. `IMDOToken` inherits `LaunchToken` without constructor arguments. The token has no administrator, further issuance, transfer tax or upgrade mechanism.

Trades on the designated hooked ETH/IMDO pool pay an ETH fee. That fee buys IMD for IMDO stakers, funds off-chain REGEN purchases for stakers, ecological-credit retirement, and operations. Wallet balances alone do not participate: holders must stake.

## Changes from ADAM

- Renamed the application to `ImdoHook`, `ImdoStaking`, `ImdoTreasury` and `ImdoClaim`; removed the former alternate-asset routes, signed allocation component, extension variants and social metadata tags.
- Preserved the hook's fee amounts: 20% at the first successful nonempty swap, linearly decreasing over 30 minutes to 1.5%. Its owner can only lower the final rate. When the manager lacks enough ETH, fees become ERC-6909 claims held by the hook; anyone can redeem them to the fixed treasury after settlement.
- Reduced staking to IMD and a lifetime REGEN credit denominated in ETH. Added the 24-hour lock, claim-only `stakeFor`, and bounded REGEN custodian withdrawals. Removed staking swaps and direct-distribution switches.
- Replaced variable splits with the fixed allocations below, separate operations/retirement pull payments, and an epoch cap for REGEN. Removed rerouting and added gradual checkpoint relaxation to prevent indefinite purchase stalls after price changes.
- Replaced the second NFT collection with a fixed holder Merkle root. Seat ownership follows `ownerOf`; `seatClaimedBy` records each new claiming owner.
- Replaced environment-based deployment with an explicit configuration and manual signer. The LP NFT goes directly to the dead address. Deployment funds the claim contract and starts two-step hook ownership transfer.

`foundry.toml` is unchanged, including **`bytecode_hash = "none"`**, Solidity **0.8.26**, Cancun, IR compilation, and optimizer settings. No new dependencies were installed.

## ETH accounting

For 1 ETH of newly processed fees, the keeper receives 0.005 ETH. The remaining 0.995 ETH is allocated as follows:

| Destination | Net basis points | ETH |
|---|---:|---:|
| Operations | 1000 | 0.0995 |
| Ecological-credit retirement | 2500 | 0.24875 |
| Off-chain REGEN purchases | 2500 | 0.24875 |
| IMD purchases | 4000 | 0.398 |

Integer split dust belongs to the IMD leg. REGEN accrual is limited per `block.timestamp / 7 days` epoch, initially 0.5 ETH. Excess joins the IMD pending balance immediately. Only `regenSafe` can change that cap, within immutable bounds of 0.05–5 ETH. Lowering it below the amount already accrued does not take back past credits; it leaves no further capacity that epoch. Pending notifications already consumed their original epoch's capacity; a retry never consumes it again.

`process()` has a 600-second cooldown. It processes at most `maxEthPerBuy * 10000² / (4000 * 9950)` of new ETH each time (about 2.5126 ETH with the default 1 ETH buy cap). Additional ETH stays unsplit. Each IMD buy is capped at 1 ETH; failed attempts halve the next cap down to 1 gwei. Dust waits, and nothing is rerouted. The swap and IMD notification are atomic, while REGEN notification failure stays pending independently. Keeper bounties apply only to newly split ETH. A rejected bounty becomes a pull balance.

The IMD minimum output uses the larger of spot sqrt-price and `checkpoint * 7 days / (7 days + checkpoint age)`, accounting for directional protocol and LP fees, then 300 bps slippage. Construction seeds the checkpoint; after each successful buy it is refreshed from the post-swap price, clamped to the floor the same buy enforced on the low side and to `MAX_CHECKPOINT_RISE_BPS` (200 bps of sqrt-price, about 4% in price) above that floor on the high side (`CheckpointRefreshed`). A sandwiched buy therefore cannot lower the next floor below what the 7-day decay allows, and a dust buy at a pushed price cannot pin the floor above spot for longer than that decay takes to close a 2% gap (under an hour). There is no administrative repricing. This preserves a same-block reference while gradually accommodating a sustained market move. It is not an independent market-price feed; manipulation, transaction ordering, pool depletion and unavailable tokens remain operational risks. A missing dependency or uninitialized pool prevents processing before any split.

Treasury ETH equals operations owed + retirement owed + keeper owed + IMD pending + REGEN pending + unsplit ETH. Staking ETH is at least notified REGEN ETH minus withdrawn REGEN ETH; forced ETH cannot enlarge the custodian's withdrawal allowance.

## Staking and claims

Every successful `stake` or `stakeFor` restarts the beneficiary's entire position's 24-hour withdrawal lock. IMD claims are available during the lock. `unstake` preserves accrued rewards; `exit` combines withdrawal and IMD claim. A failed IMD claim can be avoided by using `unstake` separately after the lock.

Rewards notified without stake enter ADAM's seven-day backlog. Streaming begins only with at least 10,000,000 IMDO staked. Dropping below that threshold pauses it; regaining the threshold restarts the remaining reserve over seven days. New rewards with any existing stake distribute immediately. Newcomers receive no credit for past stream time. Rounding dust stays in custody. Fixed exclusions are zero, dead, staking itself, IMDO, IMD, the manager, the claim address and the REGEN safe.

`regenCreditOf(account)` measures lifetime credit, including vested backlog, and is never spent by `claim`, `claimReward`, `exit`, `unstake` or custodian withdrawals. Only the safe withdraws REGEN ETH, up to cumulative notifications, including notifications received with no stake. That safe must keep an external ledger of credits already fulfilled, publish purchase receipts and conversion amounts, and distribute purchased REGEN to stakers. The contracts neither buy REGEN nor verify its delivery. The offsets safe similarly handles ecological-credit purchases and retirement receipts off-chain. These are explicit custody responsibilities.

`ImdoClaim` receives 110,000,000 IMDO:

| Allocation | Amount | Eligibility |
|---|---:|---|
| Seats | 100,000,000 | Current owners of IDs 0–1999 of `0x0000eC93127BAA929E58E97dd0095A2BFb38ec1D` |
| Holders | 10,000,000 | Addresses and totals committed to the immutable holder root |

Each seat has 50,000 IMDO. Ten percent unlocks at `launch`, then another ten percent each day through day nine. Claims close exactly at `launch + 39 days`. Seat claims require the caller to own every supplied ID; approved operators cannot claim. Duplicates cannot pay twice. Transferring a seat transfers its remaining entitlement. A new owner may record ownership in a claim with no newly vested amount; a repeated call with neither a new owner nor an amount reverts.

Holder leaves use `keccak256(bytes.concat(keccak256(abi.encode(account, total))))` and OpenZeppelin sorted-pair proofs. The root must contain one total per address, summing to at most 10,000,000e18. A global payment bound also protects the seat reserve if the root is misconfigured. A zero root disables holder claims. Either claim can stake through `stakeFor`, using an exact allowance that is cleared afterward. Anyone may call `burnUnclaimed` after the deadline: ADAM's burn convention transfers leftovers to `0x000000000000000000000000000000000000dEaD`, without changing the fixed ERC-20 supply.

## Who can call what

| Actor | Authority |
|---|---|
| Any non-excluded holder | Stake; claim IMD; unstake or exit after its lock |
| Anyone | Fund IMD/REGEN rewards; process treasury ETH; flush IMD to staking; redeem deferred hook fees to treasury; burn expired claim funds |
| Current seat owner / proven holder | Claim its own vested allocation, optionally staking it |
| Immutable claim address | Call `stakeFor` on behalf of beneficiaries (each call restarts that beneficiary's 24-hour lock; an externally controlled claim address could use this to keep a staker locked) |
| Operations wallet | Pull only `opsOwed` |
| Offsets safe | Pull only `offsetsOwed` |
| REGEN safe | Change only the REGEN cap within bounds; withdraw only notified REGEN ETH to itself |
| Keeper | Pull its own rejected bounty to a chosen recipient |
| Hook owner | Initialize the one pool; lower the steady fee; start ownership transfer or renounce ownership |
| Pending hook owner | Accept the two-step ownership transfer |
| PoolManager | Invoke active hook callbacks and authorized unlock callbacks |

The staking, treasury and claim contracts have no owner, upgrades, rescue withdrawals or configurable beneficiaries. `setRegenCap` is the treasury's sole setter. The hook recipient and token are immutable. If its recipient rejects ETH, the original direct payment path can block fee-bearing swaps when the manager is funded; failed deferred redemption preserves the claim. The script's treasury has a bare payable receive function.

## Networks, manifest and manual deployment

The requested network context is **11155111 (Sepolia)**. Ethereum mainnet (**1**) is the real manual target. The required manifest manager and IMD literals had no code on Sepolia when checked on 2026-10-07. Constructors support inspection without external chain state, but this does **not** make that manifest an operational Sepolia fee pipeline. Do not fund it. The script checks chain, dependency code, manager/position-manager/Permit2 compatibility, and initialized liquid IMD pool before creating the token.

`launch.json` has no `chainId` root property. It lists `IMDOToken`, then flat-constructor `ImdoStaking` (5 arguments), then `ImdoTreasury` (15). Because later references are unsupported, its claim address and all three wallets are `$owner`. That immutable staking instance cannot later be connected to a different claim contract. **Trust assumption of that manifest wiring:** `stakeFor` is restricted to the claim address and restarts the beneficiary's 24-hour lock, so an externally controlled `$owner` could call `stakeFor(staker, 1)` once a day and keep any staker's principal locked indefinitely. In the manual deployment the claim address is `ImdoClaim`, which only stakes for `msg.sender`, so no third party has that power. `ImdoHook` and `ImdoClaim` are deployed only by the manual script.

The manifest's factory supplies its own allocation and initialization-only pool guard. It cannot attach the custom fee hook or reproduce the manual 890-million/110-million distribution. Its fee 3000 is the admission value; the live factory fee and opening price follow network policy. Fees from that pool do not flow to this treasury. The complete manual system is a separate fresh deployment; its frontend must pin its exact hooked PoolKey.

Use `script/DeployImdo.s.sol:DeployImdo`, passing the complete `Config` tuple to `run`. All external addresses, expected chain, opening tick, holder root and launch timestamp are arguments. No environment lookup or private key appears in the script. Select your signer manually in Foundry; simulate first and supply `--broadcast` only during the separately authorized deployment. [Deployment parameters and CLI signature](docs/DEPLOYMENT.md) describe the handoff.

The script creates token → staking with predicted claim address → claim → treasury → mined hook; initializes ETH/IMDO; seeds one IMDO-only position with a budget of 890,000,000 tokens and sends its LP NFT to dead; funds claims with 110,000,000; disposes of integer liquidity dust to dead; clears approvals; starts hook ownership transfer. Pool LP fee is zero and spacing is 60, as in ADAM's manual pool. Its lower tick is opening tick minus 69,060. The LP NFT cannot be recovered. The new hook owner must separately accept ownership. Preflight requires `launch` to be at least `MIN_LAUNCH_LEAD` (1 hour) ahead of the simulation time: the claim is created in a later transaction than the staking that bakes in its predicted address, and a `launch` that has passed by then reverts that creation and burns the address. Preflight verifies code and liquidity, not the economic fairness of the opening price or holder list.

## Verification

Run `forge build`, `forge test`, and `forge fmt --check` using the unchanged configuration. The default tests run without RPC access or environment variables. `test/fork/` is excluded by the supplied configuration; the explicit fork profile tests actual mainnet IMD purchases at a pinned block. Test coverage, imported-finding reproductions and remaining validation limits are recorded in [test/TESTING.md](test/TESTING.md) and [docs/REVIEW.md](docs/REVIEW.md). Test success is not an independent security assessment. Independent review and a same-chain deployment rehearsal remain release responsibilities.
