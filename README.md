# ADAM

Official X: **https://x.com/IaMaDamIMD**

Plain ERC-20 **ADAM**, fixed 1,000,000,000 supply; staking, fee hook, immutable Treasury, NFT claims and three reward assets. Nothing was broadcast by this work. No token was redeployed or re-minted. The accepted hook still charges ETH on buys/sells, decaying from 20% to 1.5% over the first 30 minutes of trading; its owner may only lower the final fee.

## Existing deployment and this continuation

The supplied deployment record is **Sepolia (11155111)**: ADAM `0x9a9d76ff61aaa11344f43915c16c58a7ca04bc42`, Distributor `0x77d42237c9273bf0bcc5aacbb315edcf0b132041`, Treasury `0x747588e4b4e0808f6029e768589e193605f4ce18`. These contracts remain unchanged onchain. They do **not** acquire this source revision's features. Build the original commit's ABIs for the original deployment, not these revised artifacts.

The requested NFTs and IMD/PNKSTR/IMDSTR pools are **Ethereum mainnet** contracts. No verified existing mainnet ADAM address was supplied. This repository supplies tested extensions and a manual deployment script; it does not invent a cross-chain token, bridge Sepolia funds, or mint a replacement. A production activation needs a reviewed same-chain deployment configuration and an existing ADAM balance of at least 110,000,000. The mainnet preset intentionally requires an existing token address; passing the known Sepolia address on mainnet fails validation.

Legacy `AdamDistributor` and `AdamTreasury` behavior and the original regression suites remain available. New deployments use `AdamDistributorV2`, `AdamTreasuryV2`, `AdamSplitOracle`, and `NFTClaim`. Shared legacy code received only extension access points and immutable ERC-7572 metadata; token/hook economics remain intact. The [parent README](docs/LEGACY_README.md) is historical context, including its factory/custom-hook limitation.

## NFT allocation and claims

`NFTClaim` is funded with **110,000,000 existing ADAM**:

| Collection | Allocation | Frozen count | Eligible token IDs | Full share per NFT |
|---|---:|---:|---|---:|
| IMD `0x0000ec93127baa929e58e97dd0095a2bfb38ec1d` | 100,000,000 | 2,000 | 0–1,999 | 50,000 ADAM |
| Swarm Pepe `0x999ce0ce8c5f7661e0c74a568ffe27ceb9177bdb` | 10,000,000 | 1,178 | 1–1,178 | floor(10,000,000e18 / 1,178) atomic units |

Counts were read onchain at mainnet block **26,127,182**. Swarm Pepe exposes `totalMinted()`, not `totalSupply()`, and may mint beyond this snapshot: later IDs are ineligible. IMD was fully minted. Both ranges and counts are immutable at construction; [snapshot evidence](docs/MAINNET_SNAPSHOT.json) records the reads. The deploy script rechecks that the deployment chain's minted counts cover the frozen ranges.

At the configured `launch` timestamp each tokenId unlocks 10% of its share, then another 10% every 24 hours: day 0 = 10%, day 1 = 20%, … day 9 = 100%. Claims close at **launch + 39 days** (full unlock + 30 days). Integer rounding is less than one atomic unit per vesting calculation; allocation division dust remains for the final burn.

- Current `ownerOf(tokenId)` calls `claim(collection, tokenIds)` or `claimAndStake(collection, tokenIds)`, where collection 0 is IMD and 1 is Swarm Pepe. Two collections need two calls. Approved operators cannot claim another owner's allocation.
- Batches atomically validate ownership. Repeated IDs cannot claim twice. Selling an NFT transfers its future/unclaimed entitlement; amounts already claimed stay recorded against the ID.
- `claimAndStake` credits ADAM stake to the claimant with an exact, cleared allowance. NFTClaim is permanently excluded from earning staking rewards.
- At the deadline anyone can call `burnUnclaimed()` to transfer the remaining ADAM, including burned/unclaimed NFT entitlements and dust, to `0x000000000000000000000000000000000000dEaD`. It does not reduce ERC-20 totalSupply. No administrator can withdraw funds or alter parameters.

The NFT launch time is an explicit deployment parameter, independent of the hook's first-filled-swap clock. Choose it in the future and fund before it. Existing holders must fund this allocation; the script never takes tokens from old pools or old stakers.

## Staking and rewards

Approve V2 Distributor and `stake(amount)`. `unstake(amount)` always returns principal without forcing reward claims. Fresh rewards accrue pro rata to current stake. No-stake rewards, including IMDSTR ETH, retain the original seven-day backlog stream, gated by at least 10,000,000 staked ADAM; falling below the threshold pauses it. Just-in-time staking of fresh rewards remains possible.

- `claim()` pulls IMD, PNKSTR and any transferable direct-mode IMDSTR. `exit()` also withdraws all principal. Neither silently buys IMDSTR with an arbitrary slippage tolerance.
- `earned(wallet, address(0))` is the wallet's **ETH budget for IMDSTR**, not withdrawable native ETH. Call `claimIMDSTR(ethAmount, minOut, deadline)` to spend up to the per-claim cap (default 1 ETH). Supply a nonzero minimum output and an unexpired deadline; the v4 PoolManager takes tokens **directly to msg.sender**. Failed/partial swaps revert without consuming the claim. Repeat for a larger budget.
- `earned(wallet, token)` reports token rewards. `claimReward(token)` pulls an individual asset, so one locked reward cannot block other rewards or principal.
- If the IMDSTR owner whitelists the Distributor using `setDistributor(distributor, true)`, anyone may call `enableDirectDistribution()` **once**. New IMDSTR budgets then buy directly into the Distributor and accrue as tokens. Old ETH claims retain their denomination and buy-on-claim path. The switch is irreversible; the external token owner can revoke the whitelist or upgrade the proxy, which can lock direct IMDSTR rewards until permissions recover.

IMDSTR pool: native ETH / `0x80271ce20184e38f4afe90d4ca134304d197aca2`, fee **0**, spacing **60**, hook `0x66b05c8eeca9329f7a2332c02ce3855cfab72444`; measured **10% output tax**, in addition to any price impact. PoolManager is not a whitelisted distributor. Mainnet fork tests demonstrate EOA receipt, the `InvalidTransfer()` wallet-transfer failure, and direct mode after a simulated owner whitelist.

## Fee processing and signed splits

Anyone calls V2 Treasury `process()`, normally hourly (minimum cooldown 600 seconds). The caller gets **0.5% of newly processed ETH**, once. The remaining 99.5% is split **90% holders / 10% team**. Example: 1 ETH → 0.005 ETH bounty, 0.0995 ETH team, 0.8955 ETH holders. Bounty is charged on new allocation, even if a buy is deferred; retries/reroutes never earn another bounty. A rejecting caller accrues a reserved `keeperOwed` balance and can pull it with `claimKeeper(recipient)`. The team itself calls `payTeam()`. Staker tokens are always pulled by their owners.

Holder allocations use the newest valid IMD Oracle v2 report. Immutable signer and canonical questionHash; 26-hour maximum age; signature, domain, reason hash, panel quorum, expiry and replay checks; weights clamped to **1500–7000 bps each**, summing to 10000. Missing/stale reports give **3333/3333/3334** (last wei goes to IMDSTR). Invalid submissions cannot evict a still-valid signed report. The effective split emits `SplitUpdated(imdBps,pnkstrBps,imdstrBps,reportId,reasonHash,source)` from AdamSplitOracle on processing. `source=0` is fallback, `source=1` is signed. The daily policy favors the weakest 24-hour performer unless liquidity/risk signals intervene; see the complete [heartbeat specification and prompt](docs/HEARTBEAT.md).

All three legs retain independent 1 ETH attempt caps, 3% slippage floors below the greater of checkpoint and spot output after pool fees/hook tax, halving retries down to 1 gwei, and rerouting only after at least four failures spanning three days, without gaps over two hours (or configured cooldown if longer). Dust waits. Rerouting prefers a healthy alternate leg and can change the eventual mix. IMDSTR normally **accrues ETH without swapping**; its automatic swap/floor/retry logic applies once direct mode is enabled. An already-accrued user's ETH cannot be seized or rerouted: they can retry their own claim with suitable slippage if that pool recovers.

Every leg's swap **and** reward notification share an atomic failure boundary. Checkpoints move only after actual successful buys; ETH accrual does not move the IMDSTR checkpoint. These floors are circuit breakers, not independent price oracles; sustained adverse price moves can defer trades. The external oracle signs allocation weights, not execution prices. Use private transaction submission and realistic minOut values for claims.

## Deployment and operation

`script/DeployAdamExtension.s.sol` accepts a complete `Config` as arguments; no secrets, environment reads, FFI or filesystem cheatcodes. `mainnetConfig(existingAdam, deployer, team, launch, questionHash)` supplies the observed mainnet defaults. `run(Config)` records the reviewed actions for a manual signer; without an explicit user-run `--broadcast`, Foundry only simulates. This assignment ran tests/simulations only.

The script validates chain/token identity and fixed supply, checks the funding balance and NFT counters, deploys the oracle and V2 Distributor, predicts/excludes NFTClaim's CREATE address, deploys NFTClaim and V2 Treasury, and funds exactly 11%. The unit suite calls both `deploy(Config)` and `run(Config)` directly with explicit creators. A separate funder must approve exactly 110,000,000 ADAM; when creator=funder the signer transfers its own tokens directly. All components are immutable, so review constructor data and code before funding. Script execution is multiple manual transactions: after any interruption, inspect deployed contracts and completed transfers before resuming.

The old hook's Treasury is immutable. The new Treasury does not take over existing fees automatically. To activate a new fee-bearing pool without changing ADAM, the original `DeployAdam` **hook-only** path accepts the new V2 Treasury in `TREASURY` and the existing token in mandatory `ADAM_TOKEN`; it mines the same AdamHook and can seed a reviewed, ADAM-only position from the owner's remaining balance. The NFT allocation must be reserved first (at most 890,000,000 of the original supply remains for all other uses). Existing pools/positions remain untouched. No custom pool or liquidity migration was executed here. Frontends/routers must explicitly use the new hooked PoolKey; the factory pool and other hookless pools do not pay these fees.

The deployer records final addresses/PoolKeys and ABIs, verifies code, confirms oracle signer/canonical questionHash and service consumer domain, chooses claim launch time and team beneficiary, funds the heartbeat, and arranges keeper calls. IMDSTR whitelist authority remains with its external token owner. An independent adversarial review remains required before release with real funds. Distributor/Treasury expose immutable ERC-7572 `contractURI()` data URIs; ADAM remains a plain ERC-20. First-party contracts include `@custom:x`.

## Verification

```sh
forge build
forge test
forge fmt --check
FOUNDRY_PROFILE=fork forge test -vv --threads 1 --compute-units-per-second 50
```

Default tests run offline with the existing pinned **Solidity 0.8.26**, dependencies and Foundry configuration. Fork tests are explicitly separated by the existing profile and use public RPC plus pinned blocks; no tests read/set environment variables. The fork suites use public Nodies/Tenderly archive endpoints and fail visibly on network failure. No dependencies or build configuration changed.

See [test coverage](test/TESTING.md), [self-audit](SELF_AUDIT.md), and [mainnet evidence](docs/MAINNET_SNAPSHOT.json).
