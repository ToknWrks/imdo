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
| ClaimAdversarial | Atomic batch rollback, empty batches, owner-only rights despite operator approval, failed stake/payment retries, ownership updates without resetting locks, double-hashed Merkle leaves, malformed proofs, aggregate holder allocation bound, and 1,000 randomized wallet/stake tranche schedules |
| TreasuryBoundaries | Deferred REGEN across epoch rollover, lowering caps below already-accrued amounts, isolation of multiple keepers' debts, rejected keeper payouts, and atomic reward-flush failure/retry |
| ImdoDeploy | Real local PoolManager and PositionManager, allowance-only Permit2 stand-in, claim prediction, one dead-owned LP NFT, token allocation, cleared approvals, manual broadcast simulation through a different caller, preflight failure |
| StakingInvariant | Guided randomized stake/unstake/claim/reward/time/withdraw sequences; ghost balances, principal conservation, reward solvency, lifetime credit monotonicity and cumulative ETH custody bound |
| TreasuryInvariant | Guided funding, processing, keeper/pull claims, cap changes and withdrawals; complete ETH conservation and owed/pending identity |
| ClaimInvariant | Independent per-seat and per-holder entitlement model across transfers, duplicate claims, invalid proofs, stake/exit, time and burning; token custody, allowance cleanup, lock accounting and final settlement of every generated history |
| HookInvariant | Fresh token-only manager with deferred fees, randomized buys/sells/redemption, rejected redemptions, fee reductions and decay; total ETH/token conservation, deferred-claim backing, fixed fee destination and final redemption |
| MainnetFork | Actual mainnet IMD buy, minimum output, reward notification and staker claim |

The staking and treasury invariant suites use 128 sequences with depths 64 and 48. Claim and hook invariants use 256 sequences with depths 96 and 64, with explicit handler selectors. All fail on unexpected handler reverts; expected authorization, proof, lock, payment and deadline failures are checked inside the handlers. Claim and hook also settle remaining custody obligations after each sequence. The retained hook/adversarial fuzz tests and the new daily-tranche fuzz test use 1,000-run inline settings. Other fuzzing uses the unchanged 256-run default.

Build and test artifacts may be redirected into disposable scaffolding without editing configuration:

```
FOUNDRY_OUT=test/scratch/out FOUNDRY_CACHE_PATH=test/scratch/cache forge build --offline
FOUNDRY_OUT=test/scratch/out FOUNDRY_CACHE_PATH=test/scratch/cache forge test --offline
```

Delivered tests do not import anything from `test/scratch/` and need no new dependencies. The claim fixture uses the production token and staking contracts with a local ERC-721 and a four-leaf standard Merkle tree. The hook invariant uses the vendored real PoolManager and swap router; its recipient can reject ETH to exercise redemption rollback. The small fixture extraction in `HookDeferredFees.t.sol` preserves its existing tests.

Validation of this addition: `forge build --offline` succeeded; the default `forge test --offline` run passed all 98 tests across 18 suites with no failures or skips. The four invariant suites executed 55,296 handler calls in that run with no unexpected reverts. The separate fork profile also passed its mainnet IMD buy test at block 26,126,549 using `--no-storage-caching`. The build retained existing source lint warnings; no production or configuration files were changed.

The Permit2 stand-in checks allowance, expiration and transfer amount; it does not demonstrate production signature handling. The actual mainnet integration covers the IMD buy, while an operator must rehearse the full deployment against the target chain. The tests are not an independent security assessment. See docs/REVIEW.md for recorded results and limitations.
