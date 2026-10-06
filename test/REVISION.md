# Suite adaptation

The original ADAM token, hook, adverse-token and partial-fill tests were retained with names and fixture wiring updated. Withdrawal tests now advance past the explicit 24-hour lock. The sell-fee test sells purchased tokens, since the local fixture now reserves 110 million tokens instead of seeding the full supply.

The obsolete alternate-asset and signed-allocation tests were removed with their implementations. Treasury, staking, claim, deployment, fork and invariant suites were adapted to the requested fixed allocations and single reward asset. New failure cases cover deferred swap fees, lifetime REGEN credit, cap overflow/retries, immutable claim authorization, transferable seat rights and holder proofs.

Test time travel uses `vm.getBlockTimestamp()` or a monotonic explicit clock. This avoids compiler reuse of `block.timestamp` across Foundry time-travel calls with the base's IR optimizer settings.
