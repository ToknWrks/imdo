// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {LocalV4} from "../utils/LocalV4.sol";
import {ImdoHook} from "../../src/ImdoHook.sol";
import {ImdoTreasury} from "../../src/ImdoTreasury.sol";
import {ImdoStaking} from "../../src/ImdoStaking.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

contract RevisionTest is LocalV4 {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    function test_partialInputBuyRevertsAndReturnsEntireFee() public {
        warpPastDecay();
        uint256 snap = vm.snapshotState();
        buyExactIn(1 ether);
        (uint160 limit,,,) = IPoolManager(address(poolManager)).getSlot0(imdoKey.toId());
        vm.revertToState(snap);
        uint256 before = address(treasury).balance;
        uint256 traderBefore = address(this).balance;
        vm.expectRevert(); // v4 wraps PartialFillNotSupported in HookCallFailed
        swapRouter.swap{value: 10 ether}(
            imdoKey, SwapParams(true, -10 ether, limit), PoolSwapTest.TestSettings(false, false), ""
        );
        assertEq(address(treasury).balance, before);
        assertEq(address(this).balance, traderBefore);
    }

    function test_emptySellCannotChargeFeeOrStartClock() public {
        uint256 before = address(treasury).balance;
        vm.expectRevert(); // no ETH liquidity yet; original code charged 0.2 ETH for this empty fill
        sellExactOut(1 ether);
        assertEq(address(treasury).balance, before);
        assertEq(hook.launchTimestamp(), 0);
    }

    function test_exactOutputAndInputBuySameGrossFeeAtLaunch() public {
        uint256 snap = vm.snapshotState();
        uint256 want = uint256(uint128(buyExactIn(1 ether).amount1()));
        vm.revertToState(snap);
        BalanceDelta d = buyExactOut(want, 2 ether);
        assertEq(address(treasury).balance, 0.2 ether);
        assertEq(d.amount0(), -1 ether);
    }

    function testFuzz_exactOutputFeesAreGrossRate(uint32 elapsed, uint128 requested) public {
        openPool();
        elapsed = uint32(bound(elapsed, 0, 1 hours));
        requested = uint128(bound(requested, 1e18, 1_000_000e18));
        vm.warp(uint256(hook.launchTimestamp()) + elapsed);
        uint256 bps = hook.currentFeeBps();
        uint256 before = address(treasury).balance;
        BalanceDelta d = buyExactOut(requested, 2 ether);
        uint256 gross = uint256(uint128(-d.amount0()));
        assertApproxEqAbs(address(treasury).balance - before, gross * bps / 10_000, 1);
    }

    function test_openStartsFullDecayAfterDeploymentDelayAndSwapsBeforeItPayTheLaunchFee() public {
        vm.warp(vm.getBlockTimestamp() + 7 days);
        assertEq(hook.launchTimestamp(), 0);
        assertEq(hook.currentFeeBps(), 2000);
        buyExactIn(1 ether);
        assertEq(address(treasury).balance, 0.2 ether);
        assertEq(hook.launchTimestamp(), 0, "a filled swap no longer starts the clock");
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        assertEq(hook.currentFeeBps(), 2000, "still the launch fee an hour after the first trade");
        openPool();
        assertEq(hook.launchTimestamp(), vm.getBlockTimestamp());
        vm.warp(uint256(hook.launchTimestamp()) + 15 minutes);
        assertEq(hook.currentFeeBps(), 1075);
    }
}
