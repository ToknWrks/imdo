// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {LocalV4} from "../utils/LocalV4.sol";
import {DeployImdo} from "../../script/DeployImdo.s.sol";
import {PositionManager} from "@uniswap/v4-periphery/src/PositionManager.sol";
import {IPositionDescriptor} from "@uniswap/v4-periphery/src/interfaces/IPositionDescriptor.sol";
import {IWETH9} from "@uniswap/v4-periphery/src/interfaces/external/IWETH9.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {Permit2Mock} from "../utils/Permit2Mock.sol";
import {ClaimNFTMock} from "./ImdoClaim.t.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {MockBridge} from "./RegenReceiver.t.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

contract ScriptCaller {
    function run(DeployImdo script, DeployImdo.Config memory c) external returns (DeployImdo.Deployment memory) {
        return script.run(c);
    }
}

contract ImdoDeployTest is LocalV4 {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    DeployImdo script;
    PositionManager positions;
    Permit2Mock permit;
    ClaimNFTMock seats;

    function _config() internal returns (DeployImdo.Config memory c) {
        script = new DeployImdo();
        permit = new Permit2Mock();
        seats = new ClaimNFTMock();
        seats.mint(alice, 0);
        positions = new PositionManager(
            poolManager,
            IAllowanceTransfer(address(permit)),
            100000,
            IPositionDescriptor(address(0)),
            IWETH9(address(0))
        );
        c = DeployImdo.Config(
            block.chainid,
            address(script),
            opsWallet,
            offsetsSafe,
            regenSafe,
            hookOwner,
            address(poolManager),
            address(positions),
            address(permit),
            address(script),
            address(imd),
            address(seats),
            177240,
            bytes32(0),
            vm.getBlockTimestamp() + 1 days,
            address(0),
            address(0),
            0
        );
    }

    function test_forwarderSeatIsPredictedCreatedAndChecked() public {
        DeployImdo.Config memory c = _config();
        c.offsetsSafe = address(0);
        c.l1Bridge = address(new MockBridge());
        c.receiverOnBase = makeAddr("receiver-on-base");
        c.minGasLimit = 200_000;
        DeployImdo.Deployment memory d = script.deploy(c);
        assertTrue(address(d.forwarder) != address(0));
        assertEq(d.treasury.offsetsSafe(), address(d.forwarder));
        assertEq(address(d.forwarder.treasury()), address(d.treasury));
        assertEq(address(d.forwarder.bridge()), c.l1Bridge);
        assertEq(d.forwarder.receiverOnBase(), c.receiverOnBase);
        assertEq(d.forwarder.minGasLimit(), 200_000);
        assertEq(script.MIN_FORWARD_GAS(), d.forwarder.MIN_GAS_LIMIT());
        assertEq(script.MAX_FORWARD_GAS(), d.forwarder.MAX_GAS_LIMIT());
        // the seat pulls: fees reach the treasury, the forwarder takes the Offsets leg and bridges it
        swapRouter.swap{value: 1 ether}(
            d.key,
            SwapParams(true, -int256(1 ether), TickMath.MIN_SQRT_PRICE + 1),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        assertEq(address(d.treasury).balance, 0.2 ether);
        vm.warp(block.timestamp + 601);
        d.treasury.process();
        uint256 owed = d.treasury.offsetsOwed();
        assertGt(owed, 0);
        d.forwarder.forward();
        assertEq(MockBridge(c.l1Bridge).lastValue(), owed);
        assertEq(MockBridge(c.l1Bridge).lastTo(), c.receiverOnBase);
        assertEq(address(d.forwarder).balance, 0);
    }

    function test_exactlyOneOffsetsSeat() public {
        DeployImdo.Config memory c = _config();
        uint64 nonce = vm.getNonce(address(script));
        c.offsetsSafe = address(0); // neither
        vm.expectRevert(DeployImdo.InvalidConfiguration.selector);
        script.deploy(c);
        c = _config(); // both
        c.receiverOnBase = makeAddr("receiver-on-base");
        c.l1Bridge = address(new MockBridge());
        c.minGasLimit = 200_000;
        vm.expectRevert(DeployImdo.InvalidConfiguration.selector);
        script.deploy(c);
        c.offsetsSafe = address(0); // a bridge with no code
        c.l1Bridge = makeAddr("not-the-bridge");
        vm.expectRevert(DeployImdo.InvalidConfiguration.selector);
        script.deploy(c);
        c.l1Bridge = address(new MockBridge()); // a gas limit the forwarder would refuse
        c.minGasLimit = 50_000;
        vm.expectRevert(DeployImdo.InvalidConfiguration.selector);
        script.deploy(c);
        assertEq(vm.getNonce(address(script)), nonce);
    }

    function test_scriptDeploysFundsSeedsBurnsLpAndStartsOwnershipTransfer() public {
        DeployImdo.Config memory c = _config();
        DeployImdo.Deployment memory d = script.deploy(c);
        assertEq(d.token.totalSupply(), 1_000_000_000e18);
        assertEq(d.token.balanceOf(address(d.claim)), 110_000_000e18);
        assertApproxEqAbs(d.token.balanceOf(address(poolManager)), 890_000_000e18, 1e8);
        assertEq(d.token.balanceOf(address(script)), 0);
        assertEq(positions.ownerOf(d.positionId), script.DEAD());
        assertEq(positions.nextTokenId(), d.positionId + 1);
        assertEq(d.hook.owner(), address(script));
        assertEq(d.hook.pendingOwner(), hookOwner);
        assertEq(d.staking.claimContract(), address(d.claim));
        assertEq(d.staking.regenSafe(), regenSafe);
        assertEq(address(d.treasury.staking()), address(d.staking));
        assertEq(d.token.allowance(address(script), address(permit)), 0);
        (uint160 allowed,) = permit.allowance(address(script), address(d.token), address(positions));
        assertEq(allowed, 0);
        assertEq(uint160(address(d.hook)) & 0x3fff, 0x20cc);
        vm.prank(hookOwner);
        d.hook.acceptOwnership();
        assertEq(d.hook.owner(), hookOwner);
        swapRouter.swap{value: 1 ether}(
            d.key,
            SwapParams(true, -int256(1 ether), TickMath.MIN_SQRT_PRICE + 1),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        assertEq(address(d.treasury).balance, 0.2 ether);
        vm.warp(c.launch);
        uint256[] memory ids = new uint256[](1);
        vm.prank(alice);
        d.claim.claimSeat(ids, true);
        assertEq(d.staking.stakedBalance(alice), 5_000e18);
    }

    /// @dev The property the whitepaper relies on and the sell-pressure chart draws: the launch pool is ONE single-sided
    ///      position below the opening price, so sellers can only take out the ETH buyers put in, the price can never
    ///      rise above the opening price, and a sell into an empty pool is refused rather than filled at nothing.
    function test_sellersCanOnlyTakeOutWhatBuyersPaidIn() public {
        DeployImdo.Config memory c = _config();
        DeployImdo.Deployment memory d = script.deploy(c);
        IPoolManager pm = IPoolManager(address(poolManager));
        (, int24 tick0,,) = pm.getSlot0(d.key.toId());
        assertEq(tick0, c.openingTick, "the pool opens at the opening tick");
        // a buy: 1 ETH in, 20% launch fee to the treasury, 0.8 ETH into the pool, the price rises (the tick falls)
        uint256 pmBefore = address(poolManager).balance; // the local harness has an ETH/IMD pool in the same manager
        swapRouter.swap{value: 1 ether}(
            d.key,
            SwapParams(true, -int256(1 ether), TickMath.MIN_SQRT_PRICE + 1),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        uint256 bought = d.token.balanceOf(address(this));
        assertGt(bought, 0);
        assertEq(address(d.treasury).balance, 0.2 ether);
        assertEq(
            address(poolManager).balance - pmBefore,
            0.8 ether,
            "the pool holds exactly what buyers paid in after the fee"
        );
        (, int24 tick1,,) = pm.getSlot0(d.key.toId());
        assertLt(tick1, c.openingTick);
        // sell every token back: the price returns to the opening tick, the pool's ETH goes out (less the hook's sell fee)
        d.token.approve(address(swapRouter), bought);
        uint256 before = address(this).balance;
        swapRouter.swap(
            d.key,
            SwapParams(false, -int256(bought), TickMath.MAX_SQRT_PRICE - 1),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        uint256 got = address(this).balance - before;
        (, int24 tick2,,) = pm.getSlot0(d.key.toId());
        assertGe(tick2, c.openingTick - 1);
        assertLe(tick2, c.openingTick, "sells cannot cross the opening price");
        assertLe(got, 0.8 ether, "sellers never take out more than buyers paid in");
        assertGt(got, 0.6 ether); // 0.8 ETH minus the 20% launch fee on the way out
        assertLt(address(poolManager).balance - pmBefore, 1e9, "the pool is back to (rounding) dust of ETH");
        // one more sell into the emptied pool. There is no liquidity above the opening price, so the seller gets NO ETH
        // and loses only rounding dust (1 wei of tokens): nobody can take out more than buyers paid in. What the pool
        // does NOT stop is the price reading: with zero liquidity the swap runs the tick to the seller's limit
        // (MAX here), so slot0 reads an absurd price until the next buy carries it back into the position's range.
        // Recorded as a finding (cosmetic for the pool, ugly for charts and spot readers); see the hook notes.
        vm.warp(c.launch);
        uint256[] memory ids = new uint256[](1);
        vm.prank(alice);
        d.claim.claimSeat(ids, false);
        uint256 extra = d.token.balanceOf(alice);
        assertGt(extra, 0);
        vm.startPrank(alice);
        d.token.approve(address(swapRouter), extra);
        uint256 aliceEth = alice.balance;
        swapRouter.swap(
            d.key,
            SwapParams(false, -int256(extra), TickMath.MAX_SQRT_PRICE - 1),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        vm.stopPrank();
        assertEq(alice.balance - aliceEth, 0, "an empty pool pays nothing");
        assertLe(extra - d.token.balanceOf(alice), 1, "and takes nothing but rounding dust");
        (, int24 tick3,,) = pm.getSlot0(d.key.toId());
        assertGt(tick3, c.openingTick, "the price reading runs past the opening tick into empty space");
        // the next buy fills from the opening price as if nothing happened
        uint256 had = d.token.balanceOf(address(this));
        swapRouter.swap{value: 0.1 ether}(
            d.key,
            SwapParams(true, -int256(0.1 ether), TickMath.MIN_SQRT_PRICE + 1),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        assertGt(d.token.balanceOf(address(this)) - had, 0);
        (, int24 tick4,,) = pm.getSlot0(d.key.toId());
        assertLt(tick4, c.openingTick, "back inside the position");
    }

    function test_manualSignerRunUsesArgumentsRegardlessOfCaller() public {
        DeployImdo.Config memory c = _config();
        c.deployer = makeAddr("manual signer");
        c.create2Deployer = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
        // Foundry uses the deterministic CREATE2 deployer for broadcast simulation.
        // Canonical deployed runtime, checked by eth_getCode on mainnet; retained offline here.
        vm.etch(
            c.create2Deployer,
            hex"7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe03601600081602082378035828234f58015156039578182fd5b8082525050506014600cf3"
        );
        ScriptCaller caller = new ScriptCaller();
        DeployImdo.Deployment memory d = caller.run(script, c);
        assertEq(d.hook.owner(), c.deployer);
        assertEq(d.hook.pendingOwner(), hookOwner);
        assertEq(d.staking.claimContract(), address(d.claim));
        assertEq(d.token.balanceOf(address(d.claim)), 110_000_000e18);
        assertEq(positions.ownerOf(d.positionId), script.DEAD());
    }

    function test_scriptRejectsMissingCodeWrongChainAndBadTickBeforeCreation() public {
        DeployImdo.Config memory c = _config();
        uint64 nonce = vm.getNonce(address(script));
        c.poolManager = address(0x1234);
        vm.expectRevert(DeployImdo.InvalidConfiguration.selector);
        script.deploy(c);
        assertEq(vm.getNonce(address(script)), nonce);
        c.poolManager = address(poolManager);
        c.chainId++;
        vm.expectRevert(DeployImdo.InvalidConfiguration.selector);
        script.deploy(c);
        c.chainId = block.chainid;
        c.openingTick = 177241;
        vm.expectRevert(DeployImdo.TickNotAligned.selector);
        script.deploy(c);
    }

    /// @dev Finding (low): the claim is created after the staking that bakes in its address. A launch at or
    /// just after "now" can pass the simulation and revert on the broadcast block, burning the predicted address.
    function test_scriptRequiresLaunchLeadBeforeAnyCreation() public {
        DeployImdo.Config memory c = _config();
        uint256 nonce = vm.getNonce(address(script));
        c.launch = vm.getBlockTimestamp();
        vm.expectRevert(DeployImdo.InvalidConfiguration.selector);
        script.deploy(c);
        c.launch = vm.getBlockTimestamp() + script.MIN_LAUNCH_LEAD() - 1;
        vm.expectRevert(DeployImdo.InvalidConfiguration.selector);
        script.deploy(c);
        assertEq(vm.getNonce(address(script)), nonce);
        c.launch = vm.getBlockTimestamp() + script.MAX_LAUNCH_LEAD() + 1;
        vm.expectRevert(DeployImdo.InvalidConfiguration.selector);
        script.deploy(c);
        assertEq(vm.getNonce(address(script)), nonce);
        c.launch = vm.getBlockTimestamp() + script.MIN_LAUNCH_LEAD();
        DeployImdo.Deployment memory d = script.deploy(c);
        assertEq(d.staking.claimContract(), address(d.claim));
    }
}
