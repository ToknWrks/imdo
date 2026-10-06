// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IMDOToken} from "../../src/IMDOToken.sol";
import {ImdoStaking} from "../../src/ImdoStaking.sol";
import {ImdoTreasury} from "../../src/ImdoTreasury.sol";

/// @notice Explicit fork profile only; no environment reads. Uses actual mainnet IMD and its pool.
contract MainnetForkTest is Test {
    address constant MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    uint256 constant BLOCK = 26_126_549;
    receive() external payable {}

    function setUp() public {
        vm.createSelectFork("https://mainnet.gateway.tenderly.co", BLOCK);
    }

    function test_mainnetImdBuyCreditsAndPaysStaker() public {
        assertGt(MANAGER.code.length, 0);
        assertGt(IMD.code.length, 0);
        IMDOToken token = new IMDOToken();
        ImdoStaking staking = new ImdoStaking(address(token), IMD, MANAGER, address(0xc1a1), address(0x5afe));
        ImdoTreasury treasury = new ImdoTreasury(
            address(staking),
            address(0x1111),
            address(0x2222),
            address(0x5afe),
            MANAGER,
            IMD,
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
        token.approve(address(staking), 100_000_000e18);
        staking.stake(100_000_000e18);
        vm.deal(address(treasury), 0.01 ether);
        uint256 floor = treasury.quoteMinOut(0, 0.00398 ether);
        treasury.process();
        assertEq(treasury.leg(0).pending, 0);
        uint256 bought = IERC20(IMD).balanceOf(address(staking));
        assertGe(bought, floor);
        assertGt(bought, 0);
        uint256 before = IERC20(IMD).balanceOf(address(this));
        staking.claim();
        assertApproxEqAbs(IERC20(IMD).balanceOf(address(this)) - before, bought, 1);
        assertEq(staking.totalRegenNotified(), 0.0024875 ether);
    }
}
