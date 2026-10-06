# Testing

The unchanged Foundry configuration pins Solidity 0.8.26 and separates local and mainnet-fork profiles. Tests never read or set environment variables. There are no added dependencies.

```
forge build
forge test
forge fmt --check
FOUNDRY_PROFILE=fork forge test
```

The last command deliberately selects network-dependent tests. Its RPC is an explicit public URL and its mainnet block is pinned to 26,126,549; it is excluded from ordinary offline verification. The profile selection is a shell option, not an environment read inside a test.

Coverage:

| Suite | Evidence |
|---|---|
| LaunchToken | Fixed supply, metadata, exact transfer, missing admin/mint paths, conservation fuzz |
| ImdoHook / HookAdversarial / Revision | Adapted ADAM fee and permission tests, all four swap modes, decay boundaries, lowering-only authority, two-step ownership, partial/empty-fill rollback, conservation fuzz |
| HookDeferredFees | Fresh token-only PoolManager with zero ETH, exact-input and exact-output buys, retained fee claims, permissionless redemption, failed redemption rollback and callback authentication |
| ImdoStaking | IMD pro rata, 24-hour locks, claim-only stakeFor, lifetime REGEN credit, no ETH holder claims, gated backlog/pause/restart, custody bounds, rejected/reentrant withdrawal rollback, credit fuzz |
| DistributorAdversarial | Adapted ADAM six-decimal/no-return/false-return/taxed/paused token tests, reentry on intake and payout, principal withdrawal independent of reward failure, fixed exclusions, conservation fuzz |
| ImdoTreasury | Exact split/bounty, cap overflow and epoch roll, cap authority/bounds, notification retries without duplicate accrual/bounty, atomic failed buy/notification, halving retries, checkpoint recovery, deferred keeper bounty, failed/reentrant pull payments, cooldown and callback guards |
| TreasuryFuzz | Processing cap and whole-system ETH conservation |
| ImdoClaim | Owner-only seats and post-transfer rights, ownership events, duplicate IDs, holder proof/total/address binding, repeat claims, zero root, stake lock, launch/deadline and unclaimed disposal |
| ImdoDeploy | Real local PoolManager and PositionManager, allowance-only Permit2 stand-in, claim prediction, one dead-owned LP NFT, token allocation, cleared approvals, manual broadcast simulation through a different caller, preflight failure |
| StakingInvariant | Guided randomized stake/unstake/claim/reward/time/withdraw sequences; ghost balances, principal conservation, reward solvency, lifetime credit monotonicity and cumulative ETH custody bound |
| TreasuryInvariant | Guided funding, processing, keeper/pull claims, cap changes and withdrawals; complete ETH conservation and owed/pending identity |
| MainnetFork | Actual mainnet IMD buy, minimum output, reward notification and staker claim |

The invariant suites use 128 sequences with depths 64 (staking) and 48 (treasury), and fail on unexpected handler reverts. The retained hook/adversarial fuzz tests use the base's 1,000-run settings where present. Other fuzzing uses the unchanged 256-run default.

The Permit2 stand-in checks allowance, expiration and transfer amount; it does not demonstrate production signature handling. The actual mainnet integration covers the IMD buy, while an operator must rehearse the full deployment against the target chain. The tests are not an independent security assessment. See docs/REVIEW.md for recorded results and limitations.
