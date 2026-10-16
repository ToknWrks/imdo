// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {RegenDrop} from "../src/RegenDrop.sol";

/// @notice Base: the stakers' axlREGEN drop (docs/todo-imdo-flywheel.md §5.6). Safe = the Offsets Treasury Safe, which
///         exists at the same address on Base. Dry run: forge script script/DeployRegenDrop.s.sol --rpc-url <base> --sender <deployer>
///         Broadcast: same + --broadcast --account deployer.
contract DeployRegenDrop is Script {
    address constant AXL_REGEN = 0x2E6C05f1f7D1f4Eb9A088bf12257f1647682b754;   // axlREGEN on Base, 6 decimals
    address constant SAFE = 0xb41E9b474D5b6f9d41D76Bcf3129Ea9a4E5011cf;        // Offsets Treasury Safe (Ethereum + Base, 2-of-3)

    function run() external {
        require(block.chainid == 8453, "Base only");
        require(AXL_REGEN.code.length > 0 && SAFE.code.length > 0, "token or safe has no code on this chain");
        vm.startBroadcast();
        RegenDrop drop = new RegenDrop(AXL_REGEN, SAFE);
        vm.stopBroadcast();
        require(address(drop.token()) == AXL_REGEN && drop.safe() == SAFE, "wiring");
        console2.log("RegenDrop", address(drop));
    }
}
