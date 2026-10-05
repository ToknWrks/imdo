# ADAM continuation self-audit

Reviewed NFTClaim, AdamSplitOracle, V2 Distributor/Treasury, deployment and shared-code changes against the supplied security reference. This is a self-review, not an independent audit. No transactions were broadcast, no token was replaced, and no dependencies/build configuration changed.

## Findings fixed

- **IMDSTR transfer lock:** default rewards accrue as ETH. A claimant's swap calls PoolManager.take directly to the claimant, verifies full ETH consumption and actual token receipt, and rolls back on slippage. Mainnet fork tests reproduce the wallet-transfer revert and exact 10% buy tax.
- **Failure propagation:** V2 isolates each swap plus reward notification in one atomic self-call. A failure rolls back that leg and triggers its existing retry/reroute policy. Callback and self-call authorization prevent arbitrary execution. ETH accrual never updates a price checkpoint.
- **Revoked whitelist:** direct funding rechecks `isDistributor`, preventing new locked rewards after revocation. Individual `claimReward(token)` calls and independent principal withdrawal prevent one locked asset from blocking everything. Pre-switch ETH credits keep their buy-on-claim path.
- **Invalid/replayed oracle reports:** verify the actual IMD v2 EIP-712 domain/type, signer, canonical questionHash, reason, answer shape/sum, quorum, timestamps and reportId. Invalid submissions cannot erase a valid report; missing/expired reports fall back automatically. Fuzz tests verify clamps always preserve bounds and sum. A real public signature vector independently proves wire-format compatibility.
- **NFT double claims/dilution:** frozen counts and ID ranges exclude later mints; accounting follows tokenId and current ownership. Duplicate IDs cannot repeat payment, batches are atomic, and state updates precede transfers. NFTClaim is permanently excluded from staking rewards; exact staking approvals are cleared. Claim/burn deadlines do not overlap.
- **Keeper accounting/reentrancy:** bounty applies once to newly allocated ETH, never pending retries. Team, keeper and leg liabilities are reserved separately. Rejected bounties remain caller-owned pull credits. Reentry tests and conservation fuzzing cover both reward and ETH paths.
- **Token replacement:** operational scripts require existing ADAM. The original run() is now hook-only; the zero-token branch remains a local/fork regression fixture helper. Deployment tests verify unchanged supply and exact 110,000,000 ADAM funding, address predictions, exclusions and explicit-signer simulation.
- **Test timestamp caching:** a failing backlog test was traced to compiler reuse of block.timestamp across cheatcode warps. New repeated clock advances use vm.getBlockTimestamp(); the corrected tests pass without changing production vesting.

## Assumptions and remaining risks

The supplied live token is on **Sepolia**, while the requested NFTs/pools are **mainnet**. No compatible same-chain production configuration or bridge is supplied. The existing contracts are immutable and are not upgraded by these sources. Activation needs an existing ADAM allocation and separately reviewed new application/hooked-pool deployment. See README.

The operator must obtain the service's **canonical** questionHash for the frozen policy, confirm recurring-window hash behavior and the signer, commission/fund the daily heartbeat, and relay reports. Keccak256(question text) did not match an inspected service hash. No paid oracle job was commissioned here. Oracle/panel judgment is trusted for allocation; signer rotation or outage leads to equal thirds. Execution floors remain checkpoint/spot circuit breakers, not manipulation-proof price oracles.

IMDSTR's external owner can revoke its whitelist or upgrade the proxy. Existing direct rewards may remain locked until permissions recover. A permanently broken pool can leave user ETH credits pending; they are neither seized/rerouted nor withdrawable as native ETH. Principal and other reward claims remain available.

Swarm Pepe snapshot IDs stop at 1178; subsequent mints receive no allocation. NFT launch is an explicit wall-clock parameter, independent of first trading. Division dust goes to dead at expiry. Bounty is deducted before the 90/10 split and is earned on allocation even if trades defer. Fresh rewards retain the parent's just-in-time staking exposure; backlog gating only protects empty-stake reserves. Tiny per-share rounding dust and forced donations have no owner sweep.

## Validation

Solidity 0.8.26 build, offline unit/fuzz/legacy invariant suites, deployment simulations, published-signature vector, formatting and pinned mainnet forks; final counts are in [test/TESTING.md](test/TESTING.md). The fork proves real EOA receipt, token lock, NFT counters, pool/implementation identity and simulated whitelist behavior. No Slither or Mythril run. Independent adversarial review and deployer verification remain open before release with funds.
