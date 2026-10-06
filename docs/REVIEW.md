# Implementation review and imported findings

This is a local engineering record, not an independent security assessment. No deployment occurred. All supplied protected suites and reference files were read as task data. Solidity remains 0.8.26 with the supplied optimizer, Cancun and `bytecode_hash = "none"` settings. Build configuration, remappings and vendored dependencies are unchanged.

## Reproductions before changes

The original sources were copied to temporary storage before modification. Scratch tests used the original contracts and local v4 fixtures. The four reproduction assertions passed: the fresh-manager swap reverted, unrestricted beneficiary staking succeeded, missing-manager construction reverted, and the IMD leg stayed pending through 420 attempts spanning 70 hours. The first checkpoint test draft used compiler-cacheable timestamps across time travel; correcting the test to an explicit clock produced the stated reproduction.

| Imported finding ID | Evidence and disposition |
|---|---|
| `0b6a7c3ad5569cb58b366e4de2b174491defb6b1c93e6a71bc60d9d24bedc778` | Reproduced the supplied fresh-manager proof with an expected revert: 890 million tokens in a single-sided pool, zero manager ETH, first 1 ETH buy fails. Fixed by minting claim tokens when the manager lacks the fee balance. Fee arithmetic and the funded-manager direct path are preserved. `HookDeferredFeesTest` covers both fresh buy modes, redemption and rollback. |
| `2e3af08bb59752ce590d1c14e87ef679fcebd37e10ad2a83559ec08c651922ad` | Reproduced an 8 ETH organic buy against the base's 200 ETH IMD pool, followed by 420 treasury attempts at 600-second spacing. No IMD was credited; the original pending allocation remained. Fixed with deterministic checkpoint decay while retaining the maximum of checkpoint and spot, fee-adjusted min-out, halving retries and no rerouting. `test_staleCheckpointRecoversWithoutRerouting` verifies initial refusal and eventual full processing. The explicit tradeoff is weakening the stale reference over elapsed time; spot manipulation/MEV resistance is limited. |
| `7be6c587c5c1619c34ce506c1a48df615969e5caefa28ced75253236073dcfad` | Reproduced no-code manager rejection locally. JSON-RPC `eth_getCode` against `https://ethereum-sepolia-rpc.publicnode.com` on 2026-10-07 returned `0x` for both required literals. Literal replacement would violate the assignment. The manifest instead declares this limitation in notes, supports constructor-only inspection, and omits the unsupported root key. Treasury processing rejects missing dependencies/uninitialized pools before allocating ETH; a subsequently initialized pool can seed a zero checkpoint automatically. The manual script rejects the configuration before any contract creation. Unit regressions cover both guards and late initialization. A working Sepolia pipeline with these fixed literals cannot be delivered by changing this repository: the full manual launch targets mainnet. |
| `b7ae43fd51699a5ea94840346cf1705028622105ec9c902fdfc502041edad05e` | Reproduced stranger-funded `stakeFor(alice,1)` on the original V2 after Alice staked 1 million tokens. The base had no lock, so repeated lock grief itself was prospective, not an already-present base exploit. Fixed in IMDO with the immutable claim caller check and lock reset for both deposit entry points. `test_stakeForRestrictedAndEveryStakeResetsLock` proves authorization and exact lock boundaries. |
| `94fdafdac95c82c957672bcbcea708c779e5a18b03331dc6909f526ad469dbd2` | Source reproduction confirmed the no-argument run entry point used environment address reads and implicit broadcasting, and the LP mint encoded the deployer as owner. The specific unset-environment failure was not executed: tests intentionally do not depend on process environment. The replacement uses explicit `Config`, `startBroadcast(c.deployer)`, preflight and a dead LP recipient. `ImdoDeployTest` executes both direct deployment and manual broadcast simulation, including a forwarding caller. |

The first, second and fourth findings reproduced behaviorally. The third reproduced both locally and by a network read; the address/network conflict remains an external deployment constraint, not a claim of a live Sepolia integration. The fifth reproduced by source inspection and is covered by replacement script execution tests. No imported lead was dismissed without the stated reason.

## Review decisions

- The hook only changes fee funding when the shared manager lacks ETH. Redemptions burn claims inside an authenticated unlock and always pay the immutable treasury. A rejected redemption rolls back the burn. Same fee calculations, launch clock, initialization authority, address flags and partial-fill guards remain.
- Staking uses the original accumulator and backlog transitions. Address zero is a credit key, never an ERC-20 or ETH payout in holder claims. Withdrawals cannot decrease lifetime account credit or exceed notification totals, including forced-ETH scenarios.
- Treasury allocates before external calls; all maintenance and payout paths are guarded. IMD swap plus notification is an atomic self-call; a failure cannot consume its allocation. REGEN failure preserves its pending ETH and original epoch usage. Only cap mutation is exposed.
- Claims checkpoint per seat or holder before transfer/staking. Current NFT ownership controls future seat allocation. Holder proofs bind caller and total, and aggregate holder payments cannot consume the seat reserve. The root remains an operator-supplied trust input.
- The script validates dependencies and pool state before token creation, verifies predicted addresses, sends the LP NFT to dead, clears allowances, funds exactly 110 million claims and starts explicit ownership handoff. Broadcast consists of separate transactions, which needs an operator-supervised rehearsal and recovery plan.
- The manifest faithfully uses only two application contracts, flat arguments and backward references. Its owner placeholder for the claim caller is immutable and is not represented as a fully connected manual claim system.

## Verification results

Recorded on 2026-10-07:

| Check | Result |
|---|---|
| `forge build` | Passed with Solidity 0.8.26; narrowing-cast lints are informational |
| `forge test` | **83 passed, 0 failed, 0 skipped**, across 14 local suites |
| `forge fmt --check` | Passed |
| Pinned mainnet test (`forge test --match-path 'test/fork/*.t.sol' --no-match-path 'test/__none__/**'`) | **1 passed, 0 failed, 0 skipped** at block 26,126,549 |
| Staking invariant | 128 runs / 8,192 handler calls, zero reverts |
| Treasury invariant | 128 runs / 6,144 handler calls, zero reverts |
| Manifest/ABI checks | Only supported root shape; 5/15 flat arguments; backward references; treasury exposes only `setRegenCap` as a setter |
| Runtime checks | All five contracts below 24,576 bytes; opcode scan found no DELEGATECALL, CALLCODE or SELFDESTRUCT |
| Protected configuration/dependencies | No diff; original Foundry/remappings hashes preserved |
| Removed-route and script checks | No obsolete asset paths or social metadata tags in delivered source/docs; no environment reads in scripts/tests |

Runtime byte lengths: IMDOToken 2,469; ImdoStaking 8,727; ImdoTreasury 12,916; ImdoClaim 5,196; ImdoHook 8,496. Network-dependent tests are separate from offline verification. The manual broadcast test uses the canonical deterministic deployer runtime preserved as an ordinary fixture literal, so offline execution needs no fetch.

## Limits

No Slither, Mythril, formal proof, independent assessment or production transaction was performed. External IMD behavior, pool liquidity, custody by the two safes, holder-list correctness, dependency identity and transaction ordering remain trust/operational assumptions. The deterministic decaying checkpoint is a bounded purchase circuit breaker, not a manipulation-proof price feed. The script's fixed future launch, signer nonce, exact PoolKey and completed transaction sequence must be checked during deployment. REGEN distribution and ecological-credit retirement evidence are off-chain responsibilities.
