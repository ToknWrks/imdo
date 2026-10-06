// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {LocalV4} from "../utils/LocalV4.sol";
import {ImdoTreasury} from "../../src/ImdoTreasury.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

contract FaultyStaking {
    bool public failRegen;
    bool public failImd;
    uint256 public notified;

    function configure(bool regen, bool imd) external {
        failRegen = regen;
        failImd = imd;
    }

    function notifyRegen() external payable {
        require(!failRegen, "regen");
        notified += msg.value;
    }

    function notifyReward(address token, uint256 amount) external {
        require(!failImd, "imd");
        require(IERC20(token).transferFrom(msg.sender, address(this), amount));
    }
}

contract RejectingKeeper {
    function process(ImdoTreasury t) external {
        t.process();
    }

    function claim(ImdoTreasury t, address payable to) external {
        t.claimKeeper(to);
    }
}

contract PaymentReceiver {
    bool public reject = true;
    bool public reenter;
    ImdoTreasury public treasury;

    function configure(ImdoTreasury t, bool fail, bool recurse) external {
        treasury = t;
        reject = fail;
        reenter = recurse;
    }

    function ops() external {
        treasury.payOps();
    }

    function offsets() external {
        treasury.payOffsets();
    }

    receive() external payable {
        require(!reject, "reject");
        if (reenter) treasury.process();
    }
}

contract ImdoTreasuryTest is LocalV4 {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    function _fund(ImdoTreasury t, uint256 amount) internal {
        (bool ok,) = address(t).call{value: amount}("");
        require(ok);
    }

    function _accounting(ImdoTreasury t) internal view {
        assertEq(
            address(t).balance,
            t.opsOwed() + t.offsetsOwed() + t.totalKeeperOwed() + t.pendingRegen() + t.leg(0).pending + t.unsplitEth()
        );
    }

    function test_exactSplitBountyAndAuthorizedPulls() public {
        _fund(treasury, 1 ether);
        uint256 before = address(this).balance;
        treasury.process();
        assertEq(address(this).balance - before, 0.005 ether);
        assertEq(treasury.opsOwed(), 0.0995 ether);
        assertEq(treasury.offsetsOwed(), 0.24875 ether);
        assertEq(distributor.totalRegenNotified(), 0.24875 ether);
        assertGt(imd.balanceOf(address(distributor)), 0);
        assertEq(treasury.leg(0).pending, 0);
        assertEq(treasury.unsplitEth(), 0);
        vm.expectRevert(ImdoTreasury.Unauthorized.selector);
        treasury.payOps();
        vm.expectRevert(ImdoTreasury.Unauthorized.selector);
        treasury.payOffsets();
        vm.prank(opsWallet);
        treasury.payOps();
        vm.prank(offsetsSafe);
        treasury.payOffsets();
        assertEq(opsWallet.balance, 0.0995 ether);
        assertEq(offsetsSafe.balance, 0.24875 ether);
        assertEq(address(treasury).balance, 0);
        vm.prank(opsWallet);
        vm.expectRevert(ImdoTreasury.NothingOwed.selector);
        treasury.payOps();
    }

    function test_capOverflowAndEpochRoll() public {
        FaultyStaking sink = new FaultyStaking();
        sink.configure(false, true);
        ImdoTreasury t = _newTreasury(address(sink), address(poolManager));
        _fund(t, 2 ether);
        t.process();
        assertEq(sink.notified(), 0.4975 ether);
        vm.warp(vm.getBlockTimestamp() + 600);
        _fund(t, 1 ether);
        t.process();
        assertEq(sink.notified(), 0.5 ether);
        assertEq(t.leg(0).pending, 0.796 ether + 0.398 ether + 0.24625 ether);
        uint256 oldEpoch = vm.getBlockTimestamp() / 7 days;
        assertEq(t.regenAccrued(oldEpoch), 0.5 ether);
        vm.warp((oldEpoch + 1) * 7 days);
        _fund(t, 1 ether);
        t.process();
        assertEq(t.regenAccrued(oldEpoch + 1), 0.24875 ether);
        assertEq(sink.notified(), 0.74875 ether);
        _accounting(t);
    }

    function test_capSetterBoundsAuthAndNoRetroactiveResplit() public {
        vm.expectRevert(ImdoTreasury.Unauthorized.selector);
        treasury.setRegenCap(0.1 ether);
        vm.startPrank(regenSafe);
        vm.expectRevert(ImdoTreasury.InvalidParameter.selector);
        treasury.setRegenCap(0.05 ether - 1);
        vm.expectRevert(ImdoTreasury.InvalidParameter.selector);
        treasury.setRegenCap(5 ether + 1);
        treasury.setRegenCap(5 ether);
        treasury.setRegenCap(0.05 ether);
        vm.stopPrank();
        _fund(treasury, 1 ether);
        treasury.process();
        assertEq(distributor.totalRegenNotified(), 0.05 ether);
        vm.prank(regenSafe);
        treasury.setRegenCap(0.5 ether);
        vm.warp(vm.getBlockTimestamp() + 600);
        _fund(treasury, 1 ether);
        treasury.process();
        assertEq(distributor.totalRegenNotified(), 0.29875 ether);
    }

    function test_failedRegenRetryDoesNotChargeAgainOrBlockBuy() public {
        FaultyStaking sink = new FaultyStaking();
        sink.configure(true, false);
        ImdoTreasury t = _newTreasury(address(sink), address(poolManager));
        _fund(t, 1 ether);
        t.process();
        assertEq(t.pendingRegen(), 0.24875 ether);
        assertGt(imd.balanceOf(address(sink)), 0);
        assertEq(t.leg(0).pending, 0);
        assertEq(sink.notified(), 0);
        uint256 paid = address(this).balance;
        sink.configure(false, false);
        vm.warp(vm.getBlockTimestamp() + 600);
        t.process();
        assertEq(sink.notified(), 0.24875 ether);
        assertEq(address(this).balance, paid);
        assertEq(t.pendingRegen(), 0);
        assertEq(t.regenAccrued(vm.getBlockTimestamp() / 7 days), 0.24875 ether);
        _accounting(t);
    }

    function test_failedRewardNotifyRollsBackBuyAndHalvesRetry() public {
        FaultyStaking sink = new FaultyStaking();
        sink.configure(false, true);
        ImdoTreasury t = _newTreasury(address(sink), address(poolManager));
        (uint160 priceBefore,,,) = IPoolManager(address(poolManager)).getSlot0(imdKey.toId());
        _fund(t, 1 ether);
        t.process();
        (uint160 priceAfter,,,) = IPoolManager(address(poolManager)).getSlot0(imdKey.toId());
        assertEq(priceAfter, priceBefore);
        assertEq(t.leg(0).pending, 0.398 ether);
        assertEq(t.leg(0).retryCap, 0.199 ether);
        assertEq(imd.allowance(address(t), address(sink)), 0);
        sink.configure(false, false);
        vm.warp(vm.getBlockTimestamp() + 600);
        t.process();
        assertEq(t.leg(0).pending, 0.199 ether);
        assertGt(imd.balanceOf(address(sink)), 0);
        assertEq(t.leg(0).retryCap, 0);
        _accounting(t);
    }

    function test_staleCheckpointRecoversWithoutRerouting() public {
        uint160 checkpoint = treasury.leg(0).checkpointSqrtPriceX96;
        uint256 oldFloor = treasury.quoteMinOut(0, 0.398 ether);
        _swap(imdKey, true, -int256(8 ether), 8 ether);
        assertEq(treasury.quoteMinOut(0, 0.398 ether), oldFloor, "same-block manipulation cannot relax floor");
        _fund(treasury, 1 ether);
        treasury.process();
        assertEq(treasury.leg(0).pending, 0.398 ether);
        assertEq(treasury.leg(0).checkpointSqrtPriceX96, checkpoint);
        uint256 start = vm.getBlockTimestamp();
        for (uint256 i; i < 420; ++i) {
            vm.warp(start + (i + 1) * 600);
            treasury.process();
            if (treasury.leg(0).pending == 0) break;
        }
        assertGt(imd.balanceOf(address(distributor)), 0);
        assertEq(treasury.leg(0).pending, 0);
        assertEq(distributor.totalRegenNotified(), 0.24875 ether);
        _accounting(treasury);
    }

    function test_missingDependenciesDoNotSeedPermanentZeroCheckpoint() public {
        ImdoTreasury unavailable = _newTreasury(address(distributor), address(0x123456));
        _fund(unavailable, 1 ether);
        vm.expectRevert(ImdoTreasury.PoolUnavailable.selector);
        unavailable.process();
        assertEq(unavailable.unsplitEth(), 1 ether);
        assertEq(unavailable.opsOwed(), 0);
        PoolManager manager2 = new PoolManager(address(this));
        ImdoTreasury t = _newTreasury(address(distributor), address(manager2));
        _fund(t, 1 ether);
        vm.expectRevert(ImdoTreasury.PoolUnavailable.selector);
        t.process();
        assertEq(t.leg(0).checkpointSqrtPriceX96, 0);
        manager2.initialize(imdKey, TickMath.getSqrtPriceAtTick(54000));
        t.process(); // no liquidity: retains pending, but seeds its valid checkpoint
        assertGt(t.leg(0).checkpointSqrtPriceX96, 0);
        assertEq(t.leg(0).pending, 0.398 ether);
        _accounting(t);
    }

    function test_rejectingKeeperCanPullToAlternateRecipient() public {
        RejectingKeeper keeper = new RejectingKeeper();
        _fund(treasury, 1 ether);
        keeper.process(treasury);
        assertEq(treasury.keeperOwed(address(keeper)), 0.005 ether);
        assertEq(treasury.totalKeeperOwed(), 0.005 ether);
        keeper.claim(treasury, payable(alice));
        assertEq(alice.balance, 0.005 ether);
        assertEq(treasury.totalKeeperOwed(), 0);
        vm.expectRevert(ImdoTreasury.NothingOwed.selector);
        keeper.claim(treasury, payable(alice));
        _accounting(treasury);
    }

    function test_rejectedAndReentrantPullPaymentsPreserveOwed() public {
        PaymentReceiver receiver = new PaymentReceiver();
        ImdoTreasury t = new ImdoTreasury(
            address(distributor),
            address(receiver),
            address(receiver),
            regenSafe,
            address(poolManager),
            address(imd),
            10000,
            200,
            address(0),
            1 ether,
            300,
            600,
            0.5 ether,
            0.05 ether,
            5 ether
        );
        receiver.configure(t, true, false);
        _fund(t, 1 ether);
        t.process();
        vm.expectRevert(ImdoTreasury.TeamTransferFailed.selector);
        receiver.ops();
        assertEq(t.opsOwed(), 0.0995 ether);
        receiver.configure(t, false, true);
        vm.expectRevert(ImdoTreasury.TeamTransferFailed.selector);
        receiver.offsets();
        assertEq(t.offsetsOwed(), 0.24875 ether);
        receiver.configure(t, false, false);
        receiver.ops();
        receiver.offsets();
        assertEq(address(receiver).balance, 0.34825 ether);
        _accounting(t);
    }

    function test_cooldownAndCallbackAuthorization() public {
        _fund(treasury, 1 ether);
        treasury.process();
        uint64 at = treasury.lastProcessed() + 600;
        vm.warp(at - 1);
        _fund(treasury, 1 ether);
        vm.expectRevert(abi.encodeWithSelector(ImdoTreasury.CooldownActive.selector, at));
        treasury.process();
        vm.warp(at);
        treasury.process();
        vm.expectRevert(ImdoTreasury.NotPoolManager.selector);
        treasury.unlockCallback(abi.encode(1 ether));
        vm.prank(address(poolManager));
        vm.expectRevert(ImdoTreasury.NotProcessing.selector);
        treasury.unlockCallback(abi.encode(1 ether));
        vm.expectRevert(ImdoTreasury.NotProcessing.selector);
        treasury.executeImd(1 ether);
    }

    function test_dustAndFlush() public {
        _fund(treasury, 9);
        treasury.process();
        assertEq(treasury.leg(0).pending, 5);
        assertEq(treasury.leg(0).failures, 0);
        imd.transfer(address(treasury), 123e18);
        treasury.flushRewards();
        assertEq(imd.balanceOf(address(distributor)), 123e18);
        assertEq(imd.allowance(address(treasury), address(distributor)), 0);
        _accounting(treasury);
    }

    function testFuzz_splitConservesEveryWei(uint96 amount) public {
        uint256 value = bound(amount, 1, 2 ether);
        FaultyStaking sink = new FaultyStaking();
        sink.configure(true, true);
        ImdoTreasury t = _newTreasury(address(sink), address(poolManager));
        _fund(t, value);
        uint256 before = address(this).balance;
        t.process();
        uint256 bounty = address(this).balance - before;
        uint256 net = value - bounty;
        assertEq(bounty, value * 50 / 10000);
        assertEq(t.opsOwed(), net / 10);
        assertEq(t.offsetsOwed(), net / 4);
        assertEq(t.pendingRegen(), net / 4);
        assertEq(t.leg(0).pending, net - net / 10 - 2 * (net / 4));
        assertEq(address(t).balance, net);
        _accounting(t);
    }
}
