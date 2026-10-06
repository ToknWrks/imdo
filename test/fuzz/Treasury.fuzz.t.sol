// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {LocalV4} from "../utils/LocalV4.sol";
import {ImdoTreasury} from "../../src/ImdoTreasury.sol";

contract TreasuryFuzzTest is LocalV4 {
    function testFuzz_capAndConservation(uint96 supplied) public {
        uint256 cap = MAX_ETH_PER_BUY * 10000 * 10000 / (4000 * 9950);
        uint256 amount = bound(supplied, cap + 1, 500 ether);
        (bool ok,) = address(treasury).call{value: amount}("");
        require(ok);
        uint256 beforeManager = address(poolManager).balance;
        uint256 beforeKeeper = address(this).balance;
        treasury.process();
        assertEq(treasury.unsplitEth(), amount - cap);
        assertEq(address(this).balance - beforeKeeper, cap * 50 / 10000);
        assertLe(address(poolManager).balance - beforeManager, MAX_ETH_PER_BUY);
        assertEq(
            address(treasury).balance + address(poolManager).balance - beforeManager + distributor.totalRegenNotified()
                + address(this).balance - beforeKeeper,
            amount
        );
        assertEq(
            address(treasury).balance,
            treasury.unsplitEth() + treasury.leg(0).pending + treasury.opsOwed() + treasury.offsetsOwed()
        );
    }
}
