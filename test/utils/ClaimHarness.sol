// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IMDOToken} from "src/IMDOToken.sol";
import {ImdoStaking} from "src/ImdoStaking.sol";
import {ImdoClaim} from "src/ImdoClaim.sol";

contract ModelSeats is ERC721 {
    constructor() ERC721("Test seats", "SEAT") {}

    function mint(address to, uint256 id) external {
        _mint(to, id);
    }
}

library ClaimTree {
    function actor(uint256 i) internal pure returns (address) {
        return address(uint160(0xc100 + i % 4));
    }

    function allocation(uint256 i) internal pure returns (uint256) {
        return (i + 1) * 1_000_000e18;
    }

    function leaf(uint256 i) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(actor(i), allocation(i)))));
    }

    function pair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }

    function root() internal pure returns (bytes32) {
        return pair(pair(leaf(0), leaf(1)), pair(leaf(2), leaf(3)));
    }

    function proof(uint256 i) internal pure returns (bytes32[] memory p) {
        p = new bytes32[](2);
        p[0] = leaf(i ^ 1);
        p[1] = i < 2 ? pair(leaf(2), leaf(3)) : pair(leaf(0), leaf(1));
    }
}

abstract contract ClaimHarness is Test {
    IMDOToken internal token;
    MockERC20 internal imd;
    ModelSeats internal seats;
    ImdoStaking internal staking;
    ImdoClaim internal claim;
    uint256 internal launch;

    function setUp() public virtual {
        vm.warp(1_800_000_000);
        token = new IMDOToken();
        imd = new MockERC20("IMD", "IMD", 6);
        seats = new ModelSeats();
        for (uint256 i; i < 8; ++i) {
            seats.mint(ClaimTree.actor(i), i);
        }
        launch = vm.getBlockTimestamp() + 1 days;
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        staking = new ImdoStaking(address(token), address(imd), address(0x9000), predicted, address(0x5afe));
        claim = new ImdoClaim(address(token), address(staking), address(seats), 2000, ClaimTree.root(), launch);
        assertEq(address(claim), predicted);
        token.transfer(address(claim), 110_000_000e18);
    }

    function ids(uint256 first, uint256 second) internal pure returns (uint256[] memory list) {
        list = new uint256[](2);
        list[0] = first;
        list[1] = second;
    }
}
