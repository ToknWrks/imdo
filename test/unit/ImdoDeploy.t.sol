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

contract ScriptCaller {
    function run(DeployImdo script, DeployImdo.Config memory c) external returns (DeployImdo.Deployment memory) {
        return script.run(c);
    }
}

contract ImdoDeployTest is LocalV4 {
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
            address(0),
            address(seats),
            177240,
            bytes32(0),
            vm.getBlockTimestamp() + 1 days
        );
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
}
