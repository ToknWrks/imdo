# ADAM contracts

ADAM is a plain, non-upgradeable ERC-20: 1,000,000,000 tokens, 18 decimals, minted once to its deployer. `AdamHook` collects native ETH from trades in its one ETH/ADAM Uniswap v4 pool. Anyone can call `AdamTreasury.process()`: 10% goes to the immutable team wallet and the remaining ETH is split equally between IMD and PNKSTR buys. `AdamDistributor` holds those rewards for pull-based claims by ADAM **stakers**.

This revision preserves the accepted staking architecture. Deployment has not been broadcast. All dependencies are ordinary files in `lib/`; the default tests need no network or environment variables. Solidity is pinned to **0.8.26**, Cancun, with metadata hashes disabled and FFI disabled.

```sh
forge build
forge test
forge fmt --check
FOUNDRY_PROFILE=fork forge test -vv
```

The last command uses the public RPC in `test/fork/MainnetFork.t.sol` and Ethereum block **26,126,549**. The fork profile is deliberately separate from offline default verification. It tests the real PoolManager, PositionManager and both reward pools. The reviewer proofs were validated unchanged in `test/scratch/`; permanent regressions are in `test/unit/Revision.t.sol` and the existing unit suites.

**Deployment parameters.** `DeployAdam.mainnetConfig(deployer, teamWallet, hookOwner, adamToken)` defines the exact configuration. For `run()`, hookOwner equals DEPLOYER; `ADAM_TOKEN` is optional (zero deploys a new token). The deployer chooses the team wallet and signer addresses. No private keys belong in this repository.

| Parameter | Value |
| --- | --- |
| PoolManager | `0x000000000004444c5dc75cB358380D2e3dE08A90` |
| PositionManager | `0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e` |
| Permit2 | `0x000000000022D473030F116dDEE9F6B43aC78BA3` |
| CREATE2 deployer | `0x4e59b44847b379578588920cA78FbF26c0B4956C` |
| IMD | `0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7` |
| PNKSTR | `0xc50673EDb3A7b94E8CAD8a7d4E0cD68864E33eDF` |
| PNKSTR hook | `0xfAaad5B731F52cDc9746F2414c823eca9B06E844` |
| ETH/IMD PoolKey | `(address(0), IMD, 10000, 200, address(0))` |
| ETH/PNKSTR PoolKey | `(address(0), PNKSTR, 0, 60, PNKSTR_HOOK)` |
| ETH/ADAM PoolKey | `(address(0), ADAM, 0, 60, newly mined AdamHook)` |
| Treasury limits | 1 ETH per leg, 300 bps slippage, 600 seconds cooldown |
| Assumed reward hook buy taxes | IMD: 0 bps; PNKSTR: 1000 bps of output |
| ADAM opening tick / LP range | `177240` / `[108180, 177240]` |
| Default liquidity allocation | `1_000_000_000e18` ADAM; 0 ETH |

Constructor order and exact arguments (the symbols above resolve to the table or prior deployments):

```text
LaunchToken()
AdamDistributor(ADAM, IMD, PNKSTR, POOL_MANAGER, address(0))
AdamTreasury(Distributor, teamWallet, POOL_MANAGER,
             IMD, 10000, 200, address(0), 0,
             PNKSTR, 0, 60, PNKSTR_HOOK, 1000,
             1000000000000000000, 300, 600)
AdamHook(POOL_MANAGER, ADAM, Treasury, hookOwner)
```

The IMD key hashes to pool ID `0xb07d640fd9e2eb9dc81b953c8e4fd006bdfeaf276010fb5418eb763ca15abfb3`; successful real-pool swaps in the fork verify that key.

Before signing, independently check both reward pools' prices and liquidity. Treasury checkpoints their prices in its constructor; the pools must already exist. A missing pool/manager leaves a zero checkpoint and that leg fails closed. There is no administrative price reset. Use the fork run to verify that both 1 ETH buys satisfy their floors at deployment time; do not treat the pinned block as current market validation.

Manual deployment steps:

1. Review the configuration and select DEPLOYER and TEAM_WALLET in the signing session. If using existing ADAM, set ADAM_TOKEN and configure `liquidityAdam` to the allocation actually owned by the deployer. The default consumes essentially the whole supply, with only fixed-point rounding dust left over; it does not implement factory supply allocations.
2. Simulate `forge script script/DeployAdam.s.sol:DeployAdam --rpc-url <mainnet-rpc> --sender <deployer>` with those environment values. Review every transaction and resulting address. The script's `run()` reads environment variables; the tests call its configuration/deployment functions directly.
3. Only the human deployer signs/broadcasts the reviewed transactions, for example using the same command with `--broadcast --ledger`. No transaction was signed or sent during this assignment. Gas requires ETH, even though liquidity funding does not.
4. The script deploys the token, distributor and treasury, then mines and deploys the hook using CREATE2. Its low 14 address bits must equal **0x20cc** (beforeInitialize, beforeSwap, afterSwap and both swap-return-delta flags). Re-mine for the actual init code, owner, treasury and CREATE2 deployer; an old salt/address cannot be reused blindly.
5. The hook owner initializes the ADAM PoolKey at `TickMath.getSqrtPriceAtTick(177240)`. The script approves ADAM to Permit2, grants PositionManager a bounded allowance, and mints the LP NFT with `amount0Max = 0`, `amount1Max = liquidityAdam`, lower tick 108180 and upper tick 177240. Deadlines/allowances last one hour in the generated calls; re-simulate delayed signing sessions. The NFT goes to the deployer, who controls liquidity withdrawal.
6. Record the exact PoolKey, contracts, salt and LP NFT. Verify sources and constructor arguments on the explorer. Optional hook ownership transfer uses `transferOwnership` then `acceptOwnership`; renouncing before initialization would make initialization impossible.

ETH is currency0 and ADAM currency1, so tick price is ADAM per ETH. An ADAM-only position is at/below the current tick; expressed as ETH per ADAM, that range is above the opening price. The initial position sits at its upper tick, costs zero ETH and becomes active as buys move the tick down. It initially offers no ETH for sells.

**Fees and operation.** The first nonempty, successful swap starts the 30-minute anti-snipe clock at 20%. It decays linearly to 1.5%; the owner can only reduce the final rate. A reverted/empty swap cannot start the clock. Exact-output fees are grossed up using `net * bps / (10000 - bps)`, rounded down; exact-input fees use the gross ETH amount. Exact-input buys and exact-output sells must fill completely: price limits and exhausted liquidity that prevent a full fill revert the entire swap and its fee. The other two paths tax actual ETH deltas.

Run `process()` hourly using any funded keeper. There is no keeper bounty. Maximum new fees split per call are `floor(2e18 * 10000 / 9000)` wei (about 2.222 ETH), with at most 1 ETH bought per token; the rest waits unsplit. A failed team push records `teamOwed`; anyone may retry `payTeam()`, which always pays the configured wallet. `flushRewards()` forwards donated reward tokens to the distributor.

Each buy uses the greater of its stored checkpoint price and current spot price, less pool fees, configured output tax and the 3% slippage allowance. Successful buys refresh the checkpoint to the final pool price. Failed buys keep ETH pending and halve the next attempt, down to 1 gwei. Success restores the 1 ETH cap. Smaller pending amounts accumulate without being treated as failures. Rerouting requires at least four failed attempts spanning three days, with no gap exceeding two hours (or the configured cooldown if longer). Longer gaps or successful buys reset the streak. Keep hourly calls going during an outage; monitor `LegFailed`, `LegBought`, `LegRerouted` and pending balances. Rerouting changes the eventual reward mix from 50/50.

At block 26,126,549, a 0.01 ETH PNKSTR buy produced 1,694.207736324191102696 PNKSTR before the hook and 1,524.786962691771992427 after it: exactly 10% output tax rounded down. The spot-relative shortfall rounds up to 1001 bps because it includes price impact. The unverified hook immediately sells its collected tax; its final token balance is not a tax measurement. The fork test checks the original PoolManager Swap event against the buyer delta and checks the actual received balance. This supports the 1000 bps tax parameter, with the separate 300 bps allowance covering impact/slippage. Future hook behavior remains an external dependency.

To earn and claim: approve Distributor for the desired ADAM amount, call `stake(amount)`, then call `claim()` for both tokens. `unstake(amount)` returns ADAM and preserves accrued rewards; `exit()` returns all remaining stake and claims, including when already fully unstaked. Rewards received with no stake are parked. They stream over seven days only while at least 10,000,000 ADAM (1% of supply) is staked. Dropping below that threshold pauses release; regaining it restarts the remaining reserve over seven days. No elapsed time below the threshold vests. New stakes never earn already elapsed stream time. Ordinary new rewards remain immediate pro-rata distributions to current stakers.

**What differs from the brief.** Unstaked wallet balances earn nothing; ordinary ERC-20 transfers do not update the distributor. Staking preserves the previously accepted plain launch token. New reward notifications use instantaneous stake: just-in-time staking remains possible, and a sole staker receives all newly notified rewards. The backlog threshold/stream addresses the launch-pot attack, not that general snapshot-economics choice. Only the exact hooked PoolKey pays these fees; a factory-created or hookless ADAM pool does not.

The fixed exclusion set is zero, dead, Distributor, ADAM, PoolManager, both reward tokens and the optional extra address. V4 pools have no separate custody address; PoolManager covers pool-held tokens. The script passes zero for the extra address. Hook and Treasury are not explicit exclusions, but neither has any path to approve/stake ADAM or execute arbitrary calls. This informational deviation is retained and tested; no new exclusion administrator was added. Neither Treasury nor Distributor has an owner, sweep, upgrade or holder-fund withdrawal power. See `SELF_AUDIT.md` for limits of the review and `.imd-responses.json` for every finding's disposition.
