// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {OffsetsForwarder, IOffsetsSource, IL1StandardBridge} from "../../src/regen/OffsetsForwarder.sol";
import {MockTreasury} from "../unit/RegenReceiver.t.sol";

/// @notice Ethereum mainnet fork: the forwarder against the real Base L1StandardBridge. Explicit fork profile;
///         `ETH_RPC_URL` overrides the public RPC.
contract OffsetsForwarderMainnetForkTest is Test {
    address constant BRIDGE = 0x3154Cf16ccdb4C6d922629664174b904d80F2C35;
    // ETHBridgeInitiated(address indexed from, address indexed to, uint256 amount, bytes extraData)
    bytes32 constant ETH_BRIDGE_INITIATED = keccak256("ETHBridgeInitiated(address,address,uint256,bytes)");
    address receiver = makeAddr("receiver-on-base");

    function setUp() public {
        vm.createSelectFork(vm.envOr("ETH_RPC_URL", string("https://ethereum-rpc.publicnode.com")));
    }

    function _forwarder(uint32 gas) internal returns (OffsetsForwarder f, MockTreasury t) {
        t = new MockTreasury();
        f = new OffsetsForwarder(IOffsetsSource(address(t)), IL1StandardBridge(BRIDGE), receiver, gas);
        t.setSafe(address(f));
    }

    function test_forwardPullsAndBridgesThroughTheRealBridge() public {
        (OffsetsForwarder f, MockTreasury t) = _forwarder(200_000);
        t.fund{value: 0.3 ether}();
        vm.deal(address(f), 0.1 ether); // ETH already here is bridged with it
        vm.recordLogs();
        f.forward();
        assertEq(address(f).balance, 0);
        assertEq(t.owed(), 0);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == BRIDGE && logs[i].topics[0] == ETH_BRIDGE_INITIATED) {
                found = true;
                assertEq(address(uint160(uint256(logs[i].topics[1]))), address(f));
                assertEq(address(uint160(uint256(logs[i].topics[2]))), receiver);
                (uint256 amount,) = abi.decode(logs[i].data, (uint256, bytes));
                assertEq(amount, 0.4 ether);
            }
        }
        assertTrue(found, "no ETHBridgeInitiated from the bridge");
    }

    function test_bothGasBoundsAreAcceptedByTheRealBridge() public {
        (OffsetsForwarder lo,) = _forwarder(100_000);
        vm.deal(address(lo), 1 ether);
        lo.forward();
        (OffsetsForwarder hi,) = _forwarder(1_000_000);
        vm.deal(address(hi), 1 ether);
        hi.forward();
        assertEq(address(lo).balance + address(hi).balance, 0);
    }
}
