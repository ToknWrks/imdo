# Regen rail: deployment order, parameters, trust

The rail (`src/regen/`) turns ETH fees into retired Regen City Forest credits on Klima's Retirement Aggregator on Base,
with the paying project as beneficiary. Nothing in it has an owner, pause, setter or withdrawal. This page is the
operator's side of it: the order things must be deployed in, the values to deploy with, and what is trusted.

## Deployment order

Base first, Ethereum second. The order matters because receivers are predictable before they exist and project ids are
sequential: a forwarder on Ethereum pointed at a receiver whose project nobody has registered yet would send every
bridged wei to whoever registers that id first.

1. **Base: `script/DeployRegenRail.s.sol`**, one broadcast: `RegenRegistry`, `UniswapV3Venue`, `RegenRouter`,
   `RegenReceiverFactory`, then `register(projectName, regenAddress, beneficiary)` (must come out as id 1, the script
   checks) and `deploy(1)` for its receiver (checked against `predict(1)`). Record the receiver address.
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
| `ethUsd` / `maxFeedAge` | `0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70` / 3600 | Chainlink ETH/USD, 8 dec |
| `minBatch` / `maxBatch` | 0.001 / 0.05 ETH | a batch is ~1% of the kVCM pool; remainders under `minBatch` still process, with no bounty |
| `bountyBps` | 50 | a `process()` costs ~4M gas on Base; below ~0.01 ETH a third party's gas exceeds the bounty, so small balances rely on the project's own keeper (or anyone) processing them |
| `minOutBps` | 9700 | ETH→USDC held to 97% of Chainlink |
| `twapGranularity` / `minTonnesBps` | 4 / 9700 | tonnes held to 97% of the pool's 4-observation (≥2 h) time-weighted price; on 2026-10-12 spot was 1.5% under the 2 h average and 3.7% under the 12 h one, so 4 passes an honest batch and a longer window would skip more |

## What `process()` refuses and what it emits

- `Skipped("feedStale")`: Chainlink older than `maxFeedAge`, zero, negative, or dated in the future. ETH kept.
- `Skipped("classEmpty")`: no credit token quotes a step of a tonne for the batch's dollars. ETH kept.
- `Skipped("priceOff")`: a credit quotes, but under `minTonnesBps` of the time-weighted reference (the kVCM pool is
  pumped, or the pool's quote reverts). ETH kept, nothing swapped, no bounty.
- `SwapShort` (revert): the V3 pool paid under 97% of the oracle value.
- `NothingRetired` (revert): the plan passed before the swap, but after it no credit retires (the pool moved during
  the ETH leg, or every retirement reverted). The revert undoes the swap; ETH stays credited.
- `Processed(...)`: one retirement. `usdcSpent` may be below `usdcBought`: the difference is the project's own
  remainder (`usdcOf`), spent on its next batch, never under another project's name.

## Trust that remains

- **Klima.** The aggregator is an upgradeable diamond. If Klima retires or reconfigures it, the class vault, the credit
  tokens or its pool, every batch skips and the ETH waits in the router with no other exit; the treasury's Offsets leg
  keeps bridging into it (its seat is immutable too). The most a misbehaving aggregator could take per call is one
  batch's USDC allowance. Accepting this is the design (no owner); the alternative is a seat that can be re-pointed,
  which is a role.
- **The kVCM pool.** The time-weighted bar is as good as the pool's observations. A price held away from the average
  for a whole window (≥2 h with granularity 4) moves the bar; that costs the mover the pool's fees and the arbitrage
  against them for that long, for at most 3% of a batch.
- **Chainlink on Base.** Round completeness and the L2 sequencer uptime feed are not consulted; within one hour of a
  sequencer outage the last answer is accepted. The 97% floor and the 0.05 ETH cap bound what that could cost.
- **The canonical bridge.** A delivery that runs out of gas on Base is replayable by anyone (`relayMessage`); nothing
  is lost. `minGasLimit` is bounded so the L1 portal can never refuse the deposit.
- **The registry.** Names are unique on a key (lower-cased, spaces collapsed) and the regen address's bech32 checksum
  is verified on chain, but registration is first come and permanent: register in the deploy broadcast, and check the
  regen address is the project's own before sending (a valid address that is not yours cannot be corrected).

## Tests

- `forge test`: unit tests with a pool-priced aggregator stand-in (sandwich skipped before anything is spent, plan vs
  retirement divergence reverts, retirement reverts fall through, partial absorption stays with the project, rounding
  slack, remainders, bech32, name keys, forwarder bounds, both deploy scripts).
- `FOUNDRY_PROFILE=fork forge test` (`BASE_RPC_URL` optional; Base block 52,335,751): a real retirement through the real
  aggregator, a full batch against the real time-weighted bar, and an 8,000 USDC pump of the real pool answered with
  `Skipped("priceOff")`.
