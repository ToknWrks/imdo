# Regen rail: deployment order, parameters, trust

The rail (`src/regen/`) turns ETH fees into retired Regen City Forest credits on Klima's Retirement Aggregator on Base,
with the paying project as beneficiary. Nothing in it has an owner, pause, setter or withdrawal. This page is the
operator's side of it: the order things must be deployed in, the values to deploy with, and what is trusted.

## Deployment order

Base first, Ethereum second. The order matters because receivers are predictable before they exist and project ids are
sequential: a forwarder on Ethereum pointed at a receiver whose project nobody has registered yet would send every
bridged wei to whoever registers that id first.

1. **Base: `script/DeployRegenRail.s.sol`**, one broadcast: `RegenRegistry` WITH the first project (the registry's
   constructor registers `projectName / regenAddress / beneficiary` as id 1 in its own creation transaction, so no
   registration can land in between), `UniswapV3Venue`, `RegenRouter`, `RegenReceiverFactory`, then `deploy(1)` for the
   project's receiver (checked against `predict(1)`; a receiver someone else already landed at that address is the
   same CREATE2 receiver and is taken instead of reverting). Preflight checks a WETH/USDC V3 pool exists at `v3Fee`
   AND exercises the credit leg (the pool quotes at `twapGranularity`, the factory fee is under 100%, the aggregator
   quotes every credit): every one of those reads runs inside a try/catch in the router, so a misconfigured rail would
   otherwise deploy and skip "priceOff" forever. Record the receiver address.
2. **Ethereum: `script/DeployImdo.s.sol`** with `offsetsSafe = 0`, `receiverOnBase = <that receiver>`,
   `l1Bridge = 0x3154Cf16ccdb4C6d922629664174b904d80F2C35`, `minGasLimit = 200000`. The script predicts the
   `OffsetsForwarder` address from the deployer's next nonce, creates the treasury with it as `offsetsSafe`, creates the
   forwarder in the very next transaction and reverts unless `treasury.offsetsSafe() == forwarder` and the forwarder's
   `treasury` is the treasury. The forwarder's constructor refuses a treasury or bridge with no code, so a mispredicted
   address fails the broadcast instead of leaving a seat nothing can pull from.
3. **Check on both chains** after the broadcasts: `treasury.offsetsSafe()`, `forwarder.receiverOnBase()`,
   `factory.predict(1)`, `receiver.projectId()`, `registry.project(1)`.
4. **Regen side:** Christian verifies the registered name, regen address and beneficiary (the retirement message is
   assembled from them, byte for byte, grammar v1).

`script/rehearse-mainnet.sh` seats the Safe until `RECEIVER_ON_BASE` is set; the re-rehearsal with the forwarder seat
is part of the deploy, not optional.

## Parameters (intended values, Base)

| Parameter | Value | Why |
|---|---|---|
| `aggregator` | `0xda0a793d7c32ab80bcdab7f8c725c96db22464f4` | Klima Retirement Aggregator (diamond) |
| `usdc` | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` | the aggregator is paid in USDC |
| `kvcm` | `0x00fbac94fec8d4089d3fe979f39454f48c71a65d` | Klima's carbon token (18 dec); reference quotes only |
| `kvcmPool` | `0x5C0D76fab1822bDeb47308eD6028231761ED723E` | Aerodrome USDC/kVCM volatile pool the aggregator swaps in |
| `classVault` | `0xf4699531e0a5f6e9351a36de3753deaad329bf45` | City Forest class vault |
| `creditA/B/C` | C02-004 `0xe662…71b8`, C02-003 `0x3d1b…83b8`, C02-006 `0xb77a…1d7d` | fixed order, fall through |
| `swapRouter02` / `weth` / `v3Fee` | `0x2626664c2603336E57B271c5C0b26F421741e481` / `0x4200…0006` / 500 | WETH/USDC 0.05% V3 pool |
| `ethUsd` / `maxFeedAge` | `0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70` / 3600 | Chainlink ETH/USD, 8 dec; an answer on the aggregator's min/max clamp counts as stale (on Base the clamp is 1 .. 2^176, so it never binds today) |
| `sequencerUptime` | `0xBCF85224fc0756B9Fa45aA7892530B47e10b6433` | Chainlink L2 sequencer uptime feed; a batch skips while the sequencer is down and for one hour after it returns (`SEQUENCER_GRACE`) |
| `minBatch` / `maxBatch` | 0.001 / 0.05 ETH | a batch is ~1% of the kVCM pool; remainders under `minBatch` still process, with no bounty |
| `bountyBps` | 50 | paid pro rata to the dollars retired out of the dollars the batch bought (a batch that mostly parks dollars because every class vault is nearly empty pays mostly nothing; sub-step rounding pays in full), so a mover is not paid for capturing slots. A `process()` quotes all three credits before and after the swap and costs about 18.6M gas on live Base (measured by the bridge operator's keeper, 2026-10-12; an earlier estimate here said ~5M, and a keeper capped at 15M fails). Below a few hundredths of an ETH a third party's gas exceeds the bounty, so small balances rely on the project's own keeper (or anyone) processing them |
| `minOutBps` | 9700 | ETH→USDC held to 97% of Chainlink |
| `twapGranularity` / `minTonnesBps` | 48 / 9500 | the RELATIVE bar, compared in kVCM: the kVCM the aggregator needs for the offered tonnes (what the dollars buy at SPOT) must be at least 95% of the kVCM those dollars buy at the pool's 48-completed-interval (≥ 24 h) time-weighted price, pool fee taken off. In kVCM and not in tonnes because the live quoter caps a dollar-budget quote at the class's liquid tonnes: compared in tonnes, a class under one batch compared L with L and a same-transaction pump went through up to the ceiling (round-3 review). 24 h because a price HELD across the whole window becomes the average (observations are written on any state change and `sync()` is public and free: round-2 audit, proven on the fork with a 2 h window). A day-long hold ties the mover's capital in a token whose only venue is this pool. 95% because a thin pool drifts: on 2026-10-12 the spot was 2.7% under the day's average at one block and 9.1% under at another (the honest batch skips there and waits) |
| `maxUsdcPerTonne` | 75 USDC/t | the ABSOLUTE bar: never pay more than this per tonne, whatever the pool says. ~3.5× the $21.4/t market of 2026-10-12 (the bridge operator's recommendation over 45, taken 2026-10-12: at 45 a doubling of kVCM is a permanent halt with ETH waiting in the router and no exit; the TWAP bar already catches short pumps, the ceiling is the backstop for a held one). This is what bounds a batch's loss against a held pump; immutable, so if credits ever cost more than this organically the rail halts (ETH waits) until a new rail is deployed |
| `processInterval` | 7200 s | one retirement per (project, depositor) per 2 h: a held pump pays for at most 12 batches per depositor per day, whatever is pending. The same cap bounds the project's own throughput: the bridge receiver is ONE depositor, so at most `(24h / processInterval) × maxBatch` = 0.6 ETH a day of the Offsets leg is retired; above ~2.4 ETH/day of net treasury fees the receiver's balance grows as a backlog (nothing is lost; it waits, unhedged). A deliberate trade; resize `maxBatch` or `processInterval` if the leg outgrows it |

**What a mover can still take, in numbers.** Hold the pool off its average for a full day (capital in the pool, fees
on the way in and out, every kVCM seller sells into you), keep the price under the ceiling, and each of the project's
depositors loses at most `(24h / processInterval) × maxBatch × (1 − market / maxUsdcPerTonne)` a day: at the values
above 12 × ~$125 × (1 − 21.4 / 75) ≈ $1,070 per depositor per day, against more capital held in the pool for that day than the ~$15k a 45 ceiling asked for (the pool has to be held at a higher price).
A depositor carrying parked dollars (`usdcOf`) can lose up to twice that, because at most one `maxBatch`'s worth of
the remainder joins a batch; parking itself needs every class vault near empty (the router takes the credit that
spends the most of the batch, so a sliver of one credit no longer captures a batch: round-3 review). Tighten
`maxUsdcPerTonne` or lengthen `processInterval` to shrink it; both also raise the odds of honest skips or a halt.
There is no oracle for kVCM; this is the trade.

## What `process()` refuses and what it emits

- `Skipped("feedStale")`: Chainlink older than `maxFeedAge`, zero, negative, dated in the future, or on the
  aggregator's clamp; or the sequencer down / back for under an hour. ETH kept.
- `NothingToProcess` (revert): this (project, depositor) has neither ETH nor a dollar remainder. A depositor whose
  ETH is gone but whose remainder is not is processed on the remainder alone: no swap, no bounty, the interval applies.
- `TooSoon(nextAt)` (revert): this (project, depositor) retired less than `processInterval` ago. A skip does not start
  the clock.
- `Skipped("classEmpty")`: no credit token quotes a step of a tonne for the batch's dollars, or every vault is empty of
  its credit (the aggregator quotes its curve regardless of the vault; the router caps the offer at what the vault
  holds, so a near-empty class drains to zero instead of reverting; a credit whose `balanceOf` reverts counts as
  empty for that credit only). ETH kept.
- `Skipped("priceOff")`: a credit quotes, but over `maxUsdcPerTonne`, or under `minTonnesBps` of the time-weighted
  reference, or the pool's quote or fee read reverts. ETH kept, nothing swapped, no bounty.
- `SwapShort` (revert): the V3 pool paid under 97% of the oracle value.
- `NothingRetired` (revert): the plan passed before the swap, but after it no credit retires (the pool moved during
  the ETH leg, every retirement reverted, or the aggregator asked for more than the planned spend plus 0.1% + 100
  micro-USDC). The revert undoes the swap; ETH stays credited.
- `Processed(...)`: one retirement, from the credit whose offer spends the most of the batch (fixed order breaks a
  tie). `usdcSpent` may be below `usdcBought`: the difference is THAT DEPOSITOR'S remainder (`usdcOf[project]
  [depositor]`), spent on its next batches, at most one `maxBatch`'s worth per batch; a 1-wei depositor cannot retire
  someone else's dollars under its own `src`. `bounty` is what the caller was paid: pro rata to `usdcSpent` out of
  `usdcBought`, the rest re-credited to the depositor's ETH.

## Trust that remains

- **Klima.** The aggregator is an upgradeable diamond. If Klima retires or reconfigures it, the class vault, the credit
  tokens or its pool, every batch skips and the ETH waits in the router with no other exit; the treasury's Offsets leg
  keeps bridging into it (its seat is immutable too). The most a misbehaving aggregator could take per call is one
  batch's USDC allowance. Accepting this is the design (no owner); the alternative is a seat that can be re-pointed,
  which is a role.
- **The kVCM pool.** The relative bar is as good as the pool's observations, and those can be written by anyone with
  `sync()`: a price held for the whole window IS the average. The ceiling and the interval bound what that buys (the
  numbers above). The pool's fee is read from Aerodrome's factory and taken off the reference; a fee at or above 100%
  is refused.
- **Klima's quotes.** The aggregator's views are trusted to return well-formed data (a malformed answer reverts the
  call rather than skipping; the ETH/USD clamp read and the credit tokens' vault balances are the exceptions, done
  with raw static calls so that one broken answer means "no clamp" / "this credit is empty", never a halt). A retirement that
  burns all the gas it is handed ends the call without trying the next credit; the caller can retry with more gas.
- **Chainlink on Base.** The sequencer uptime feed and the aggregator clamp are consulted; round completeness is not
  (OCR feeds no longer need it). The 97% floor and the 0.05 ETH cap bound what a wrong answer could cost.
- **The canonical bridge.** A delivery that runs out of gas on Base is replayable by anyone (`relayMessage`); nothing
  is lost. `minGasLimit` is bounded so the L1 portal can never refuse the deposit.
- **The registry.** Names are unique on a key (lower-cased, spaces collapsed) and the regen address's bech32 checksum
  is verified on chain, but registration is first come and permanent: register in the deploy broadcast, and check the
  regen address is the project's own before sending (a valid address that is not yours cannot be corrected).

## Rehearsed (dry runs, nothing broadcast; 2026-10-12)

**2026-10-13: cleared for deploy, planned Saturday 2026-10-17.** The bridge operator's reply of 2026-10-12 confirmed the four
numbers (48 / 9500 / 7200, ceiling 75 taken over the accepted 45), read `cb481da` (206/206), and wrote "With those in, deploy.
Nothing else from me gates it." His keeper runs every 15 minutes and the status page fills from the router, registry, receiver
and deploy block we send after the Base broadcast. Ethereum rehearsal re-run the same day after the treasury's 14-argument
constructor (`017e345`; the IMD leg's no-hook pool key is a constant): passed, 15 transactions, forwarder check passed; use an
Alchemy RPC (publicnode answers "block not found"). Deployer still at Ethereum nonce 3 / Base nonce 1, 0.027 / 0.0002 ETH:
fund to 0.03 / 0.001 first. **Fork tests not yet re-run at `017e345`**; do that before Saturday. LAUNCH for the 17th is undecided.

**Second rehearsal, same day, after the ceiling moved to 75 (both passed, nothing broadcast):**

- Base, `DeployRegenRail` from the real deployer (Base nonce 1) with every value in the table above, beneficiary
  `0x6bbAC4329dcD4C1075A462Db6342Ac0Ce0C78099`, regen address `regen183ht37fsp2fhnq3gneyjycp08c3ju4xnvxnvan`: 5
  transactions, 7,648,333 gas, 0.00008 ETH at 0.0106 gwei. Predicted: registry `0x5C4f…3524`, venue `0x2aBf…1dB0`,
  router `0x87B5…4e9F`, factory `0xB92B…e93b`, receiver `0x5280…e4Bb` (project 1). These hold only while the deployer's
  Base nonce is still 1: any Base transaction from it before the broadcast moves every one of them.
- Ethereum, `script/rehearse-mainnet.sh` with `OFFSETS=0x0`, `RECEIVER_ON_BASE=0x528064dEeb2Aa63542B9Ba4665dA25788093e4Bb`,
  `TICK=177240` (ETH $2,494 by Chainlink), `LAUNCH=1792422000` (2026-10-19 15:00 UTC): 15 transactions, 13,892,828 gas,
  0.00196 ETH at 0.14 gwei; the forwarder (`0x3765…E5f1`, deployer nonce 7) was created right after the treasury and the
  `treasury.offsetsSafe() == forwarder` check passed. The deployer's Ethereum nonce is 3 now (it was 0 at the
  2026-10-07 rehearsal), so every predicted address differs from that run; the token (`0x87B5…4e9F`) happens to share
  its address with the Base router (nonce 3 on both chains, different contracts).
- Funding before the real broadcasts: the deployer held 0.0019 ETH on Ethereum (the simulation itself needs 0.00196
  at 0.14 gwei; at 1 gwei the deploy is ~0.014 ETH) and 0.0002 ETH on Base. Fund Ethereum to at least 0.03 ETH and
  Base to 0.001 ETH first. Order stays: Base broadcast, read the real receiver, then Ethereum with that receiver.

- `DeployRegenRail` against live Base with the intended values above: preflight passed on the real addresses (pool
  tokens, code, the V3 pool at the fee tier), 5 transactions, ~7.5M gas (~0.00008 ETH at 0.01 gwei). The broadcast
  sender must be an EOA.
- `script/rehearse-mainnet.sh` with `OFFSETS=0x0`, `RECEIVER_ON_BASE=<dummy>`: the forwarder is predicted from the
  deployer's next nonce and created right after the treasury; the pair check passed under the real broadcast
  simulation (~13.9M gas in total). Re-run with the real receiver address after the Base broadcast.

## Tests

- `forge test`: unit tests with a pool-priced aggregator stand-in (sandwich skipped before anything is spent, plan vs
  retirement divergence reverts, retirement reverts fall through, partial absorption stays with the depositor, a
  sliver of the first credit does not capture the batch, at most one batch of carry per batch, the remainder retired
  once the ETH is gone, a reverting `balanceOf` passed over, the bar in kVCM against a liquid-supply-capped quoter,
  pro-rata bounty, rounding slack, remainders, bech32, name keys, forwarder bounds, both deploy scripts including the
  credit-leg preflight and a front-run receiver).
- **Grammar v1 shared vectors** (Regen's reference parser and 28 vectors: `github.com/CShear/mode-e-grammar`, commit
  `6f5a5a0`; copy in `test/fixtures/mode-e-grammar-v1-vectors.json`). The router is a builder, so the check runs the other
  way round: every valid vector's project, name and regen address go through the registry's validators and
  `router.message()` and must come back byte for byte (`RegenRouter.t.sol`); every invalid vector a registration could be
  blamed for (pipe, 65 bytes, trailing space, non-ASCII, newline, bad bech32 charset, uppercase) is refused by the
  registry (`RegenRegistry.t.sol`); the parser-side ones (prefix, mode, order, separator, tags, src chain, leading zero,
  checksummed address, over 512 bytes) cannot come out of the router's template. Two stated differences from the vectors:
  the router always writes `src:8453:<depositor on Base>`, the Ethereum forwarder's ETH included (it arrives through the
  bridge at the project's `RegenReceiver`, so the mirror sees the receiver, not the forwarder; vectors with `src:1:` are
  compared with the chain id swapped), and the router writes no tags.
- `forge test --match-path "test/invariant/RegenRouter*"`: a handler drives deposits, batches, pool spot and average
  moves, fill changes, credit supply, retirement reverts, feed staleness and keepers that cannot take ETH; invariants:
  ETH conserved and equal to the sum of balances, USDC conserved and fully attributed to depositors, tonnes counted
  once in whole steps, no standing allowance, carry spent per batch under the cap, carry-only batches swap nothing,
  bounty never over `bountyBps`.
- `FOUNDRY_PROFILE=fork forge test` (`BASE_RPC_URL` / `ETH_RPC_URL` optional; Base blocks 52,335,751 and 52,487,479):
  a real retirement through the real aggregator, a full batch against the real 24 h bar, a block where the honest
  batch is a skip, an 8,000 USDC pump answered with `Skipped("priceOff")`, the same pump HELD for 25 hours with
  `sync()` writing the window and still refused by the ceiling, the interval, and the forwarder pulling and bridging
  through the real L1StandardBridge at both gas bounds.
