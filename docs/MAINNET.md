# IMDO on Ethereum mainnet — as deployed 2026-10-16

Broadcast 2026-10-16 17:06 UTC from the deployer `0xe478dCc55af363132C0cBe7F52262Fbf2Ed24768`, 15 transactions in blocks
26206481–26206483 (`script/rehearse-mainnet.sh --broadcast`, `OFFSETS=0x0`, `RECEIVER_ON_BASE=0x528064dEeb2Aa63542B9Ba4665dA25788093e4Bb`,
`TICK=177000` at ETH $2,425, `LAUNCH=1792177318`). The Base rail was deployed 2026-10-14 (docs/REGEN_RAIL.md).

| Contract | Address |
|---|---|
| IMDO token (`LaunchToken`) | `0x87B525bC5Ff6D7211f16291219c363e082ed4e9F` |
| ImdoStaking | `0xB92B250B3F7A925806a809cd9AC5667B31Ade93b` |
| ImdoClaim | `0xee3293e7c739C2a25E8B1A7db219c384b31c1C41` |
| ImdoTreasury | `0xaA9026624658ea0d745E062C5D82fE845474c3f7` |
| OffsetsForwarder | `0x376536Dd40B57081a9Fdf5f5443923f63A68E5f1` |
| ImdoHook | `0x5d79a5998cFCB4F17FfFcaa0aa603499f73E60CC` |

Pool: native ETH / IMDO, LP fee 0, tick spacing 60, hooks = ImdoHook; poolId
`0x6676c963c163734caa07a9abd5056375ed88e777bbc424834558019446d0dfba`. Single-sided position = PositionManager NFT **467543**,
transferred to `0x000000000000000000000000000000000000dEaD` in `0xaede105df9b51ba972ced4e27182f834b374527d704e5b93b8f0794f52f3a21a`.

Verified right after: `treasury.offsetsSafe() == forwarder`, `forwarder.receiverOnBase() == 0x5280…e4Bb`, `forwarder.treasury() == treasury`,
890,000,000 IMDO in the PoolManager, 110,000,000 in ImdoClaim, `claim.launch` 1792177318 (2026-10-16 19:01:58 UTC), `claim.deadline`
1795546918, `holderRoot` `0x9a0051c6…77ff`, hook `pendingOwner` = Hook Owner Safe `0x5966CA0df8b753D8458162867f3435fa6E49222E`,
`currentFeeBps` 2000 until `open()`.
