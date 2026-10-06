// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {Test} from "forge-std/Test.sol";
import {LocalV4} from "../utils/LocalV4.sol";
import {ImdoTreasury} from "../../src/ImdoTreasury.sol";
import {ImdoStaking} from "../../src/ImdoStaking.sol";

contract TreasuryHandler is Test {
    ImdoTreasury public treasury;
    ImdoStaking public staking;
    uint256 public totalFunded;
    uint256 public keeperPaid;
    uint256 public clock;
    bool public rejectBounty;

    constructor(ImdoTreasury t, ImdoStaking s) {
        treasury = t;
        staking = s;
        clock = vm.getBlockTimestamp();
    }

    receive() external payable {
        require(!rejectBounty, "bounty");
        keeperPaid += msg.value;
    }

    function fund(uint96 amount) external {
        uint256 value = bound(amount, 1, 5 ether);
        vm.deal(address(this), value);
        (bool ok,) = address(treasury).call{value: value}("");
        require(ok);
        totalFunded += value;
    }

    function process(uint32 elapsed, bool reject) external {
        clock += bound(elapsed, 600, 10 days);
        vm.warp(clock);
        rejectBounty = reject;
        if (treasury.unsplitEth() != 0 || treasury.leg(0).pending != 0 || treasury.pendingRegen() != 0) {
            treasury.process();
        }
    }

    function pay(bool offsets) external {
        if (offsets && treasury.offsetsOwed() != 0) {
            vm.prank(treasury.offsetsSafe());
            treasury.payOffsets();
        } else if (!offsets && treasury.opsOwed() != 0) {
            vm.prank(treasury.opsWallet());
            treasury.payOps();
        }
    }

    function keeper() external {
        if (treasury.keeperOwed(address(this)) == 0) return;
        rejectBounty = false;
        treasury.claimKeeper(payable(address(this)));
    }

    function cap(uint96 value) external {
        uint256 amount = bound(value, treasury.regenCapMin(), treasury.regenCapMax());
        vm.prank(treasury.regenSafe());
        treasury.setRegenCap(amount);
    }

    function withdraw(uint96 value) external {
        uint256 available = staking.totalRegenNotified() - staking.totalRegenWithdrawn();
        if (available == 0) return;
        uint256 amount = bound(value, 1, available);
        vm.prank(staking.regenSafe());
        staking.withdrawRegen(amount);
    }
}

/// forge-config: default.invariant.runs = 128
/// forge-config: default.invariant.depth = 48
/// forge-config: default.invariant.fail-on-revert = true
contract TreasuryInvariantTest is LocalV4 {
    TreasuryHandler handler;
    uint256 managerInitial;

    function setUp() public override {
        super.setUp();
        managerInitial = address(poolManager).balance;
        handler = new TreasuryHandler(treasury, distributor);
        targetContract(address(handler));
    }

    function invariant_ethEqualsOwedPlusPendingAndUnsplit() public view {
        assertEq(
            address(treasury).balance,
            treasury.opsOwed() + treasury.offsetsOwed() + treasury.totalKeeperOwed() + treasury.leg(0).pending
                + treasury.pendingRegen() + treasury.unsplitEth()
        );
        assertEq(
            address(treasury).balance + opsWallet.balance + offsetsSafe.balance + distributor.totalRegenNotified()
                + handler.keeperPaid() + address(poolManager).balance - managerInitial,
            handler.totalFunded()
        );
        assertGe(address(distributor).balance, distributor.totalRegenNotified() - distributor.totalRegenWithdrawn());
    }
}
