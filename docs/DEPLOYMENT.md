# Manual deployment handoff

The assignment performed no deployment. Use a fresh mainnet deployment for the complete system; the Sepolia factory manifest is not a substitute.

`DeployImdo.Config` tuple order:

| Field | Production value / responsibility |
|---|---|
| chainId | `1` for Ethereum mainnet |
| deployer | Explicit manual signer address |
| opsWallet | Operations beneficiary selected by operator |
| offsetsSafe | Safe responsible for ecological-credit retirement |
| regenSafe | Safe responsible for REGEN purchases and staker distributions |
| hookOwner | Safe accepting the hook's two-step ownership transfer |
| poolManager | `0x000000000004444c5dc75cB358380D2e3dE08A90` |
| positionManager | `0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e` |
| permit2 | `0x000000000022D473030F116dDEE9F6B43aC78BA3` |
| create2Deployer | `0x4e59b44847b379578588920cA78FbF26c0B4956C` for Foundry broadcasts |
| imd | `0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7` |
| imdHooks | Zero address |
| seatNFT | `0x0000eC93127BAA929E58E97dd0095A2BFb38ec1D` |
| openingTick | Operator-reviewed multiple of 60; ADAM example `177240` |
| holderRoot | Reviewed immutable sorted-pair Merkle root, or zero to disable holders |
| launch | Unix timestamp at least 1 hour (`MIN_LAUNCH_LEAD`) after the simulation; preflight rejects less. Choose enough time to complete and fund deployment |

The script's ABI signature is:

```
run((uint256,address,address,address,address,address,address,address,address,address,address,address,address,int24,bytes32,uint256))
```

Pass the serialized tuple with `forge script script/DeployImdo.s.sol:DeployImdo --sig '<signature>' '<tuple>' --rpc-url '<operator RPC>' --sender '<manual signer>'`. Select a hardware wallet or externally managed signer using Foundry's signing options. Do not store signing material in this repository. Simulation is the default. The operator decides separately whether to broadcast after reviewing the transaction sequence. No script entry point reads environment variables.

Fixed application settings are IMD pool fee 10000, spacing 200; 1 ETH max buy; 300 bps slippage; 600-second cooldown; REGEN cap 0.5 ETH with bounds 0.05–5 ETH; 2,000 seats. The full manual pool has LP fee zero, spacing 60, and the custom hook. Lower tick = opening tick − 69,060; both must lie inside Uniswap's tick bounds. Opening tick 177240 is historical base behavior, not a recommendation of fair pricing.

The deployment requires all 1 billion newly created tokens: 890 million budgeted for the sole position and 110 million for claims. Liquidity uses integer rounding, so a small remainder goes to dead along with the LP NFT. It is not an owner allocation. Deployment checks clear ERC-20 and Permit2 approvals after minting the position.

Transaction order matters for the claim prediction. Staking and claim must be consecutive deployer transactions; do not insert signer transactions between them. If the claim creation reverts (for example `launch` already passed), its nonce is consumed and the staking's claim address can never receive code: token and staking must be redeployed. The script verifies the resulting address. Foundry broadcast is a sequence of transactions, not an atomic batch: a partially broadcast sequence needs an operator-led recovery/rehearsal before resuming. Never restart a partially completed launch blindly.

Before broadcast, check real token metadata, IMD pool liquidity and price, all wallet authorities, seat contract identity and ID range, and the holder root dataset. Publish the dataset/proofs and a sum check; omit duplicate account leaves. Afterward record contract addresses, creation receipts, hook salt, exact PoolKey, LP token ID, claim funding, launch/deadline, and pending owner. Have the hook owner accept ownership.

Keepers call `redeemFees` when claim tokens exist, then `process` at most once per cooldown. Review pending buys and failed notifications. Operations and offsets beneficiaries pull their own allocations. The REGEN custodian reconciles lifetime credits against its external fulfilled-credit ledger, purchases and distributes REGEN, and publishes receipts. The offsets custodian publishes retirement records. Cap changes are public and affect only new accrual; delayed ETH notification does not change its original epoch allocation.
