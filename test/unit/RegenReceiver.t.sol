// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {RegenReceiver, RegenReceiverFactory, IRegenRouterDeposit} from "../../src/regen/RegenReceiver.sol";
import {OffsetsForwarder, IOffsetsSource, IL1StandardBridge} from "../../src/regen/OffsetsForwarder.sol";

/// @dev Records deposits per project; knows ids 1..known.
contract MockRouter is IRegenRouterDeposit {
    uint256 public known;
    mapping(uint256 => uint256) public received;

    constructor(uint256 known_) {
        known = known_;
    }

    function deposit(uint256 projectId) external payable {
        require(projectId != 0 && projectId <= known, "unknown");
        received[projectId] += msg.value;
    }

    function projectExists(uint256 projectId) external view returns (bool) {
        return projectId != 0 && projectId <= known;
    }
}

contract RegenReceiverTest is Test {
    MockRouter internal router;
    RegenReceiverFactory internal factory;

    function setUp() public {
        router = new MockRouter(2);
        factory = new RegenReceiverFactory(router);
    }

    function test_predictMatchesDeployAndIsStable() public {
        address predicted = factory.predict(1);
        assertEq(predicted.code.length, 0);
        vm.expectEmit(true, false, false, true);
        emit RegenReceiverFactory.ReceiverDeployed(1, predicted);
        address r = factory.deploy(1);
        assertEq(r, predicted);
        assertEq(RegenReceiver(payable(r)).projectId(), 1);
        assertEq(address(RegenReceiver(payable(r)).router()), address(router));
        assertTrue(factory.predict(2) != predicted);
        vm.expectRevert(abi.encodeWithSelector(RegenReceiverFactory.AlreadyDeployed.selector, predicted));
        factory.deploy(1);
    }

    function test_unregisteredProjectCannotGetAReceiver() public {
        vm.expectRevert(abi.encodeWithSelector(RegenReceiverFactory.UnknownProject.selector, 3));
        factory.deploy(3);
        vm.expectRevert(abi.encodeWithSelector(RegenReceiverFactory.UnknownProject.selector, 0));
        factory.deploy(0);
    }

    function test_ethSentBeforeDeployIsForwardedAfter() public {
        address predicted = factory.predict(1);
        vm.deal(predicted, 0.3 ether); // what the bridge does: plain ETH to an address, no data
        factory.deploy(1);
        RegenReceiver r = RegenReceiver(payable(predicted));
        vm.expectEmit(true, false, false, true);
        emit RegenReceiver.Forwarded(1, 0.3 ether);
        r.forward();
        assertEq(router.received(1), 0.3 ether);
        assertEq(predicted.balance, 0);
        vm.expectRevert(RegenReceiver.NothingToForward.selector);
        r.forward();
    }

    function test_receiveAcceptsPlainEthWithLittleGas() public {
        RegenReceiver r = RegenReceiver(payable(factory.deploy(2)));
        (bool ok,) = address(r).call{value: 1 wei, gas: 30_000}("");
        assertTrue(ok);
        r.forward();
        assertEq(router.received(2), 1);
    }
}

contract MockTreasury is IOffsetsSource {
    address public offsetsSafe;
    uint256 public owed;

    error Unauthorized();
    error NothingOwed();

    function setSafe(address s) external {
        offsetsSafe = s;
    }

    function fund() external payable {
        owed += msg.value;
    }

    function payOffsets() external {
        if (msg.sender != offsetsSafe) revert Unauthorized();
        if (owed == 0) revert NothingOwed();
        uint256 a = owed;
        owed = 0;
        (bool ok,) = offsetsSafe.call{value: a}("");
        require(ok);
    }
}

contract MockBridge is IL1StandardBridge {
    address public lastTo;
    uint32 public lastGas;
    bytes public lastData;
    uint256 public lastValue;

    function depositETHTo(address _to, uint32 _minGasLimit, bytes calldata _extraData) external payable {
        lastTo = _to;
        lastGas = _minGasLimit;
        lastData = _extraData;
        lastValue = msg.value;
    }
}

contract OffsetsForwarderTest is Test {
    MockTreasury internal treasury;
    MockBridge internal bridge;
    OffsetsForwarder internal fwd;
    address internal receiver = makeAddr("receiver-on-base");

    function setUp() public {
        treasury = new MockTreasury();
        bridge = new MockBridge();
        fwd = new OffsetsForwarder(treasury, bridge, receiver, 100_000);
        treasury.setSafe(address(fwd));
    }

    function test_forwardPullsThenBridgesEverything() public {
        treasury.fund{value: 1 ether}();
        vm.expectEmit(false, false, false, true);
        emit OffsetsForwarder.Forwarded(1 ether);
        fwd.forward();
        assertEq(bridge.lastTo(), receiver);
        assertEq(bridge.lastGas(), 100_000);
        assertEq(bridge.lastData().length, 0);
        assertEq(bridge.lastValue(), 1 ether);
        assertEq(address(fwd).balance, 0);
        assertEq(treasury.owed(), 0);
    }

    function test_nothingOwedButBalanceHeldStillBridges() public {
        vm.deal(address(fwd), 0.2 ether);
        fwd.forward();
        assertEq(bridge.lastValue(), 0.2 ether);
    }

    function test_nothingAnywhereReverts() public {
        vm.expectRevert(OffsetsForwarder.NothingToForward.selector);
        fwd.forward();
    }

    function test_onlyTheForwarderCanPullTheLeg() public {
        treasury.fund{value: 1 ether}();
        vm.expectRevert(MockTreasury.Unauthorized.selector);
        treasury.payOffsets();
    }

    function test_constructorRefusesZeroes() public {
        vm.expectRevert(OffsetsForwarder.ZeroAddress.selector);
        new OffsetsForwarder(IOffsetsSource(address(0)), bridge, receiver, 1);
        vm.expectRevert(OffsetsForwarder.ZeroAddress.selector);
        new OffsetsForwarder(treasury, IL1StandardBridge(address(0)), receiver, 1);
        vm.expectRevert(OffsetsForwarder.ZeroAddress.selector);
        new OffsetsForwarder(treasury, bridge, address(0), 1);
    }

    function test_constructorRefusesATreasuryOrBridgeWithNoCode() public {
        address eoa = makeAddr("mispredicted-treasury");
        vm.expectRevert(abi.encodeWithSelector(OffsetsForwarder.NoCode.selector, eoa));
        new OffsetsForwarder(IOffsetsSource(eoa), bridge, receiver, 100_000);
        vm.expectRevert(abi.encodeWithSelector(OffsetsForwarder.NoCode.selector, eoa));
        new OffsetsForwarder(treasury, IL1StandardBridge(eoa), receiver, 100_000);
    }

    function test_constructorBoundsTheGasLimit() public {
        vm.expectRevert(abi.encodeWithSelector(OffsetsForwarder.BadGasLimit.selector, uint32(0)));
        new OffsetsForwarder(treasury, bridge, receiver, 0);
        vm.expectRevert(abi.encodeWithSelector(OffsetsForwarder.BadGasLimit.selector, uint32(99_999)));
        new OffsetsForwarder(treasury, bridge, receiver, 99_999);
        vm.expectRevert(abi.encodeWithSelector(OffsetsForwarder.BadGasLimit.selector, uint32(1_000_001)));
        new OffsetsForwarder(treasury, bridge, receiver, 1_000_001);
        vm.expectRevert(abi.encodeWithSelector(OffsetsForwarder.BadGasLimit.selector, type(uint32).max));
        new OffsetsForwarder(treasury, bridge, receiver, type(uint32).max);
        assertEq(new OffsetsForwarder(treasury, bridge, receiver, 100_000).minGasLimit(), 100_000);
        assertEq(new OffsetsForwarder(treasury, bridge, receiver, 1_000_000).minGasLimit(), 1_000_000);
    }
}
