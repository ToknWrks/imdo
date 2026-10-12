#!/bin/sh
# Mainnet deploy REHEARSAL: a forge simulation of the real broadcast from the real deployer, nothing is sent.
# Review the printed transaction sequence, gas and addresses. Add --broadcast and a signer ONLY for the real deploy,
# after regenerating LAUNCH (at least 1 hour and at most 30 days ahead at simulation time) and setting HOLDER_ROOT.
# Opening tick 177540 = $50,018 market cap at ETH $2,565.71 (2026-10-07); recompute on the day: tick = round(ln(ETHUSD / 0.00005) / ln(1.0001) / 60) * 60.
DEPLOYER=0xe478dCc55af363132C0cBe7F52262Fbf2Ed24768
OPS=0x357baE4F23F7C4494aa107DfcDB337E7892344ec
# Offsets seat: EITHER the Safe (OFFSETS set, RECEIVER_ON_BASE zero) OR the Regen rail's forwarder (OFFSETS zero,
# RECEIVER_ON_BASE = the receiver DeployRegenRail deployed on Base). The rail is the intended seat (docs/REGEN_RAIL.md);
# set it once the Base side is deployed. The rehearsal below still seats the Safe until then.
OFFSETS=${OFFSETS:-0xb41E9b474D5b6f9d41D76Bcf3129Ea9a4E5011cf}
RECEIVER_ON_BASE=${RECEIVER_ON_BASE:-0x0000000000000000000000000000000000000000}
L1_BRIDGE=0x3154Cf16ccdb4C6d922629664174b904d80F2C35
MIN_GAS_LIMIT=200000
REGEN=0xb41E9b474D5b6f9d41D76Bcf3129Ea9a4E5011cf
HOOK_OWNER=0x5966CA0df8b753D8458162867f3435fa6E49222E
POOL_MANAGER=0x000000000004444c5dc75cB358380D2e3dE08A90
POSITION_MANAGER=0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e
PERMIT2=0x000000000022D473030F116dDEE9F6B43aC78BA3
CREATE2=0x4e59b44847b379578588920cA78FbF26c0B4956C
IMD=0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7
IMD_HOOKS=0x0000000000000000000000000000000000000000
SEAT_NFT=0x0000eC93127BAA929E58E97dd0095A2BFb38ec1D
TICK=${TICK:-177540}
HOLDER_ROOT=0x9a0051c69602d2ece5a4c2658ae2922ae453e8b546a894540dca02af51a877ff   # snapshot/axlregen-52485808.json (Base block 52485808, 2026-10-11 23:22 UTC, 50 holders)
LAUNCH=${LAUNCH:-1791385766}
RPC=${RPC:-https://ethereum-rpc.publicnode.com}
cd "$(dirname "$0")/.." || exit 1
exec forge script script/DeployImdo.s.sol:DeployImdo \
  --sig 'run((uint256,address,address,address,address,address,address,address,address,address,address,address,address,int24,bytes32,uint256,address,address,uint32))' \
  "(1,$DEPLOYER,$OPS,$OFFSETS,$REGEN,$HOOK_OWNER,$POOL_MANAGER,$POSITION_MANAGER,$PERMIT2,$CREATE2,$IMD,$IMD_HOOKS,$SEAT_NFT,$TICK,$HOLDER_ROOT,$LAUNCH,$L1_BRIDGE,$RECEIVER_ON_BASE,$MIN_GAS_LIMIT)" \
  --rpc-url "$RPC" --sender "$DEPLOYER" -vvv "$@"
