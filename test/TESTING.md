# ADAM test coverage

Run `forge build` and `forge test` from the repository root. No added dependencies or
configuration changes are required. The existing default profile excludes `test/fork/`.

The additional tests use the accepted staking implementation as the custody model.
That assumption does **not** satisfy the original requirement for automatic dividends
on ordinary wallet balances. `.imd-findings.json` reports this documented discrepancy
with a self-contained failing proof, reproduced in scratch before reporting. Production
contracts were not changed.

| Suite | Properties checked |
| --- | --- |
| `invariant/Distributor.invariant.t.sol` | Four actors; transfers and delegated transfers; stake/unstake/exit; time changes; two reward tokens; donations; repeated claims; rejected over-withdrawals. Independent wallet and stake accounting, fixed supply, reward funding/payout conservation, rounding bounds, and full principal withdrawal after each sequence. |
| `invariant/Treasury.invariant.t.sol` | Multiple callers; real local v4 swaps; varying tax and hook outages; rejected/recovered team payments; pending buys, cooldown, donations and flushing. ETH conservation across Treasury, PoolManager and team; event amounts reconciled to real balances; initial 90/10 and 50/50 earmarks; per-leg size caps; retry state and reward delivery. |
| `unit/DistributorAdversarial.t.sol` | Six-decimal rewards; transfer fees; complete transfer tax; false/missing ERC-20 return values; paused rewards; callback reentrancy into all five guarded methods; failed intake/payout rollback; every fixed exclusion; two independent reward epochs; one wei and whole-supply stake/exit. |
| `unit/HookAdversarial.t.sol` | Actual ETH and token movements on both sell modes, randomized decay times and fee reductions, exact decay boundaries, permanent zero-fee reduction, and complete rollback of a partially filled exact-output sell. |

Each invariant suite runs 256 sequences of 64 calls, configured inline in the Solidity
file, with unexpected handler reverts treated as failures. Only the intended handler
selectors are targeted. Both suites start with nonzero funding and exercise meaningful
state before random actions. The Distributor uses separate six- and eighteen-decimal
reward stand-ins. New arithmetic fuzz properties run 1,000 examples each. Bounds are
encoded in the inputs, without discard-heavy assumptions.

Reward-accounting checks allow only a count-based number of raw reward wei for integer
division. The Distributor rounds each accumulator update and account settlement down;
the invariant's allowance is 16 wei per handler call, not a percentage of the funds.
Principal and Treasury ETH conservation use exact equality. Unsolicited donations are
tracked separately from liabilities, so they cannot hide undercollateralization or
create unbacked reward entitlements.

The local integration fixture executes the vendored Uniswap v4 PoolManager. Its mock
PNKSTR hook models output tax and failure, not the real hook's nested sale of its tax.
The six real-pool checks remain in `fork/MainnetFork.t.sol`, pinned to Ethereum block
26,126,549. Set an archive-capable RPC URL in the invoking shell, then run:

```sh
FOUNDRY_PROFILE=fork forge test -vv
```

The suite reads `MAINNET_RPC_URL` and explicitly skips if it is absent. It never changes
the shared test environment with `vm.setEnv`. A supplied but broken RPC fails instead
of hiding the failure as a skip. No credential is stored in the repository. The fork
checks cover the real IMD PoolKey, PNKSTR's output tax measured from the original swap
event, maximum-size reward buys, zero-ETH single-sided liquidity, process/claims,
anti-snipe fees, and refusal of a manipulated IMD price.

Successful tests at the pinned block are historical integration evidence. They do not
establish the unverified PNKSTR hook's future behavior or validate deployment-time prices.
The existing staking eligibility, instantaneous-stake reward allocation, checkpoint-based
price protection and delayed rerouting remain implementation limitations documented in
the root README; none is silently reclassified as the original brief's guarantee.

Validation on this checkout: `forge build` passed, and the default `forge test --summary`
reported 111 passing entries with no failures or skips. This includes both invariant
campaigns (four properties, 32,768 handler calls in total, zero unexpected reverts).
All six mainnet-fork tests passed at the pinned block through an archive-capable public
RPC. The no-RPC fork run was also checked and skipped explicitly. The wallet-eligibility
proof failed with actual IMD payout zero versus expected 100e18; its source is in the
findings report, not a passing regression that blesses the discrepancy.
