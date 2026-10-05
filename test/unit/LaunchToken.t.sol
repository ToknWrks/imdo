// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {LaunchToken} from "../../src/LaunchToken.sol";

/// @custom:x https://x.com/IaMaDamIMD
contract LaunchTokenTest is Test {
    LaunchToken internal token;

    function setUp() public {
        token = new LaunchToken();
    }

    function test_metadata() public view {
        assertEq(token.name(), "ADAM");
        assertEq(token.symbol(), "ADAM");
        assertEq(token.decimals(), 18);
    }

    function test_mintsFixedSupplyToDeployer() public view {
        assertEq(token.totalSupply(), 1_000_000_000e18);
        assertEq(token.totalSupply(), 10 ** 27);
        assertEq(token.balanceOf(address(this)), token.totalSupply());
    }

    function test_transferMovesExactAmount() public {
        address to = makeAddr("to");
        assertTrue(token.transfer(to, 1234e18));
        assertEq(token.balanceOf(to), 1234e18);
        assertEq(token.balanceOf(address(this)), 1_000_000_000e18 - 1234e18);
        assertEq(token.totalSupply(), 1_000_000_000e18);
    }

    function test_transferRevertsOnInsufficientBalance() public {
        address poor = makeAddr("poor");
        vm.prank(poor);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, poor, 0, 1));
        token.transfer(address(this), 1);
    }

    function test_noMintOrAdminEntryPoints() public {
        bytes4[6] memory selectors = [
            bytes4(keccak256("mint(address,uint256)")),
            bytes4(keccak256("mint(uint256)")),
            bytes4(keccak256("burnFrom(address,uint256)")),
            bytes4(keccak256("owner()")),
            bytes4(keccak256("transferOwnership(address)")),
            bytes4(keccak256("pause()"))
        ];
        for (uint256 i; i < selectors.length; ++i) {
            (bool ok,) = address(token).call(abi.encodeWithSelector(selectors[i], address(this), uint256(1)));
            assertFalse(ok, "unexpected admin entry point");
        }
        assertEq(token.totalSupply(), 1_000_000_000e18);
    }

    function testFuzz_transferConservesSupply(address to, uint256 amount) public {
        vm.assume(to != address(0) && to != address(this));
        amount = bound(amount, 0, token.totalSupply());
        token.transfer(to, amount);
        assertEq(token.balanceOf(to) + token.balanceOf(address(this)), token.totalSupply());
    }
}
