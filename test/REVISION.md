# Bounded test revision

The accepted tests and fixtures are retained. `unit/TreasuryBoundaries.t.sol` adds:

- Rejection one second before cooldown expiry, with unchanged balances and processing
  timestamp, followed by successful permissionless processing at the exact boundary.
- Retry-streak continuity at the two-hour gap, reset one second beyond it, preservation
  of pending ETH, no duplicate team payment, and recovery after the external hook resumes.
- 1,000 fuzz cases for v4's independent buy/sell protocol fees. A sell-only fee leaves
  the buy quote unchanged; actual buys with both fees still meet the quoted output
  floors and conserve ETH across the Treasury, PoolManager, and team.
- Team callbacks into all three guarded maintenance methods, through both direct and
  deferred payments; failed payment rollback and rejection of a second payment.

The fixture uses the vendored v4 PoolManager and the existing local reward pools.
Protocol fees are bounded to v4's valid range of 1–1,000 millionths per direction.
Time assertions use explicit timestamps or `vm.getBlockTimestamp()` across `vm.warp`
to avoid optimizer reuse of an EVM timestamp read. No dependency, configuration, or
production source change is needed.

The existing Distributor and Treasury invariant campaigns remain configured inline
for 256 sequences of 64 calls per property, with unexpected handler reverts failing.

The medium-severity wallet-dividend specification discrepancy is reproduced in
`.imd-findings.json`. The self-contained proof was run in `test/scratch/` and failed
at zero IMD paid versus 100e18 expected. Its source is embedded in the report; the
failing file is not part of the passing suite. This is the previously documented
staking-versus-wallet eligibility conflict, not a new claim of stolen principal.

The optional fork profile explicitly skipped at setup because no `MAINNET_RPC_URL`
was configured in this revision. Live IMD/PNKSTR behavior, including the unverified
hook's tax, has not been revalidated here. Earlier fork results in `TESTING.md` are
historical evidence from the accepted round.

Final validation: `forge build` succeeded; `forge test --summary` reported 119 passing
entries, zero failures, and zero skips across 14 suites. Both invariant campaigns
completed 16,384 handler calls each, with zero unexpected reverts. The new protocol-fee
property completed its 1,000 configured fuzz cases. Existing compiler lint warnings
remain; this revision does not change production source to address them.
