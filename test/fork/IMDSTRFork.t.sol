// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {LaunchToken} from "../../src/LaunchToken.sol";
import {AdamDistributorV2, IStrategyToken} from "../../src/AdamDistributorV2.sol";
import {DeployAdamExtension} from "../../script/DeployAdamExtension.s.sol";

interface IStrategyAdmin {
    function owner() external view returns (address);
    function setDistributor(address, bool) external;
    function getImplementation() external view returns (address);
    function hookAddress() external view returns (address);
}

interface INFTCounter {
    function totalSupply() external view returns (uint256);
    function totalMinted() external view returns (uint256);
}

/// @notice Opt-in, pinned mainnet fork. No env reads and no silent skip; network failures fail this suite.
/// @custom:x https://x.com/IaMaDamIMD
contract IMDSTRForkTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    address constant MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address constant IMDSTR = 0x80271ce20184e38F4AFe90d4Ca134304d197Aca2;
    address constant HOOK = 0x66b05C8eecA9329F7a2332C02Ce3855cfaB72444;
    IPoolManager internal pm = IPoolManager(MANAGER);
    AdamDistributorV2 internal distributor;
    LaunchToken internal adam;
    PoolKey internal key;
    address internal alice = makeAddr("claimerEOA");
    address internal bob = makeAddr("recipientEOA");

    function setUp() public {
        vm.createSelectFork("https://eth-pokt.nodies.app", 26_127_182);
        key = PoolKey(Currency.wrap(address(0)), Currency.wrap(IMDSTR), 0, 60, IHooks(HOOK));
        adam = new LaunchToken(); // local fork fixture only
        distributor = new AdamDistributorV2(
            address(adam),
            0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7,
            0xc50673EDb3A7b94E8CAD8a7d4E0cD68864E33eDF,
            MANAGER,
            address(0),
            key,
            1 ether
        );
        adam.transfer(alice, 100_000_000e18);
        vm.startPrank(alice);
        adam.approve(address(distributor), 100_000_000e18);
        distributor.stake(100_000_000e18);
        vm.stopPrank();
        vm.deal(address(this), 10 ether);
    }

    function testPoolIdentityAndBuildSnapshot() public view {
        (uint160 sqrtP,,,) = pm.getSlot0(key.toId());
        assertGt(sqrtP, 0);
        assertGt(pm.getLiquidity(key.toId()), 0);
        assertEq(IStrategyAdmin(IMDSTR).hookAddress(), HOOK);
        assertEq(IStrategyAdmin(IMDSTR).getImplementation(), 0x7fB856425F164929F023055E8BC40E980B362f61);
        assertFalse(IStrategyToken(IMDSTR).isDistributor(MANAGER));
        assertEq(INFTCounter(0x0000eC93127BAA929E58E97dd0095A2BFb38ec1D).totalSupply(), 2000);
        assertEq(INFTCounter(0x999ce0CE8C5f7661e0c74a568FfE27CEB9177bDB).totalMinted(), 1178);
        console2.logBytes32(PoolId.unwrap(key.toId()));
        console2.log("sqrtPriceX96", sqrtP);
    }

    function testBuyOnClaimDeliversToEOAAndMeasuresTenPercentTax() public {
        distributor.notifyIMDSTR{value: 0.01 ether}(0);
        uint256 due = distributor.earned(alice, address(0));
        vm.recordLogs();
        vm.prank(alice);
        uint256 got = distributor.claimIMDSTR(due, 1, block.timestamp);
        assertEq(IERC20(IMDSTR).balanceOf(alice), got);
        assertGt(got, 0);
        assertEq(IERC20(IMDSTR).balanceOf(address(distributor)), 0);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 rawOutput;
        bytes32 swapEvent = keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == MANAGER && logs[i].topics[0] == swapEvent
                    && logs[i].topics[1] == PoolId.unwrap(key.toId())
                    && logs[i].topics[2] == bytes32(uint256(uint160(address(distributor))))
            ) {
                (, int128 out,,,,) = abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
                rawOutput = uint256(uint128(out));
            }
        }
        assertGt(rawOutput, got);
        assertApproxEqAbs(rawOutput - got, rawOutput * 1000 / 10000, 1);
        console2.log("IMDSTR hook tax bps", ((rawOutput - got) * 10000 + rawOutput - 1) / rawOutput);
        console2.log("IMDSTR delivered", got);
        vm.prank(alice);
        vm.expectRevert(bytes4(0x2f352531));
        IERC20(IMDSTR).transfer(bob, 1);
        vm.expectRevert(AdamDistributorV2.NotWhitelisted.selector);
        distributor.enableDirectDistribution();
    }

    function testExtensionScriptRealNFTSnapshotAndOneEthFloor() public {
        DeployAdamExtension script = new DeployAdamExtension();
        DeployAdamExtension.Config memory c = script.mainnetConfig(
            address(adam), address(script), bob, block.timestamp + 1 days, keccak256("fork policy fixture")
        );
        c.funder = address(this);
        adam.approve(address(script), 110_000_000e18);
        DeployAdamExtension.Deployment memory d = script.deploy(c);
        assertEq(d.nftClaim.imdSize(), 2000);
        assertEq(d.nftClaim.pepeSize(), 1178);
        assertEq(adam.balanceOf(address(d.nftClaim)), 110_000_000e18);
        address nftOwner = IERC721(c.imdNFT).ownerOf(0);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 0;
        vm.warp(c.launch);
        vm.prank(nftOwner);
        d.nftClaim.claimAndStake(0, ids);
        assertEq(d.distributor.stakedBalance(nftOwner), 5000e18);
        vm.prank(IStrategyAdmin(IMDSTR).owner());
        IStrategyAdmin(IMDSTR).setDistributor(address(d.distributor), true);
        d.distributor.enableDirectDistribution();
        uint256 floor = d.treasury.quoteMinOut(2, 1 ether);
        uint256 got = d.distributor.notifyIMDSTR{value: 1 ether}(floor);
        assertGe(got, floor);
        console2.log("IMDSTR one ETH output", got);
        console2.log("IMDSTR one ETH floor", floor);
    }

    function testDirectModeAfterOwnerWhitelist() public {
        vm.prank(IStrategyAdmin(IMDSTR).owner());
        IStrategyAdmin(IMDSTR).setDistributor(address(distributor), true);
        distributor.enableDirectDistribution();
        uint256 got = distributor.notifyIMDSTR{value: 0.01 ether}(1);
        vm.prank(alice);
        distributor.claim();
        assertApproxEqAbs(IERC20(IMDSTR).balanceOf(alice), got, 1);
    }
}
