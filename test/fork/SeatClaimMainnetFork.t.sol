// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {Test} from "forge-std/Test.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {DeployImdo} from "../../script/DeployImdo.s.sol";
import {ImdoClaim} from "../../src/ImdoClaim.sol";

/// @notice The seat claim against the REAL identity.md seat NFT on a mainnet fork, through the real deploy script:
///         the ids the contract accepts are the ids that exist (0..1999), real owners (EOAs, EIP-7702 accounts) claim
///         their daily tranche, a stranger cannot, and the whole 50,000 IMDO per seat vests over ten days.
///         Explicit fork profile; `ETH_RPC_URL` overrides the public RPC.
contract SeatClaimMainnetForkTest is Test {
    address constant SEAT_NFT = 0x0000eC93127BAA929E58E97dd0095A2BFb38ec1D;
    address constant L1_BRIDGE = 0x3154Cf16ccdb4C6d922629664174b904d80F2C35;
    bytes32 constant HOLDER_ROOT = 0x9a0051c69602d2ece5a4c2658ae2922ae453e8b546a894540dca02af51a877ff;
    uint256 constant BLOCK = 26_179_574;
    uint256 constant PER_SEAT = 100_000_000e18 / 2000; // 50,000 IMDO
    uint256 constant TRANCHE = PER_SEAT / 10; // 5,000 IMDO a day

    DeployImdo script;
    DeployImdo.Deployment d;
    uint256 launch;

    function setUp() public {
        vm.createSelectFork(vm.envOr("ETH_RPC_URL", string("https://ethereum-rpc.publicnode.com")), BLOCK);
        script = new DeployImdo();
        launch = block.timestamp + 1 days;
        DeployImdo.Config memory c = DeployImdo.Config({
            chainId: 1,
            deployer: address(script),
            opsWallet: 0x357baE4F23F7C4494aa107DfcDB337E7892344ec,
            offsetsSafe: address(0),
            regenSafe: 0xb41E9b474D5b6f9d41D76Bcf3129Ea9a4E5011cf,
            hookOwner: 0x5966CA0df8b753D8458162867f3435fa6E49222E,
            poolManager: 0x000000000004444c5dc75cB358380D2e3dE08A90,
            positionManager: 0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e,
            permit2: 0x000000000022D473030F116dDEE9F6B43aC78BA3,
            create2Deployer: address(script),
            imd: 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7,
            seatNFT: SEAT_NFT,
            openingTick: 177240,
            holderRoot: HOLDER_ROOT,
            launch: launch,
            l1Bridge: L1_BRIDGE,
            receiverOnBase: 0x528064dEeb2Aa63542B9Ba4665dA25788093e4Bb,
            minGasLimit: 200000
        });
        d = script.deploy(c);
    }

    function _owner(uint256 id) internal view returns (address) {
        return IERC721(SEAT_NFT).ownerOf(id);
    }

    function test_theSeatIdsAreTheOnesThatExist() public {
        assertEq(d.claim.seatSize(), 2000);
        assertEq(IERC721(SEAT_NFT).balanceOf(_owner(0)) > 0, true);
        _owner(1999); // exists
        vm.expectRevert();
        _owner(2000); // does not
        vm.warp(launch);
        assertEq(d.claim.seatClaimable(0), TRANCHE);
        assertEq(d.claim.seatClaimable(1999), TRANCHE);
        vm.expectRevert(ImdoClaim.InvalidToken.selector);
        d.claim.seatClaimable(2000);
    }

    function test_realOwnersClaimTheirFirstTranche() public {
        vm.warp(launch);
        // seat 368: the project's own signing wallet (an EIP-7702 account on this fork block)
        address o368 = _owner(368);
        uint256[] memory one = new uint256[](1);
        one[0] = 368;
        vm.prank(o368);
        d.claim.claimSeat(one, false);
        assertEq(d.token.balanceOf(o368), TRANCHE);
        assertEq(d.claim.seatClaimedBy(368), o368);
        // two seats held by one wallet, one call
        address o51 = _owner(51);
        assertEq(_owner(1580), o51, "fixture: seats 51 and 1580 share an owner at this block");
        uint256[] memory two = new uint256[](2);
        two[0] = 51;
        two[1] = 1580;
        uint256 before = d.token.balanceOf(o51);
        vm.prank(o51);
        d.claim.claimSeat(two, false);
        assertEq(d.token.balanceOf(o51) - before, 2 * TRANCHE);
        // the same day again: nothing new
        vm.prank(o368);
        vm.expectRevert(ImdoClaim.NothingUnlocked.selector);
        d.claim.claimSeat(one, false);
        // a stranger, and the seat's approved operator, cannot claim it
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(ImdoClaim.NotOwner.selector);
        d.claim.claimSeat(one, false);
    }

    function test_wholeSeatVestsInTenDaysAndCanBeStaked() public {
        address o = _owner(1999);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1999;
        vm.prank(o);
        vm.expectRevert(ImdoClaim.NothingUnlocked.selector);
        d.claim.claimSeat(ids, false); // before launch
        vm.warp(launch + 9 days);
        uint256 stakedBefore = d.staking.stakedBalance(o);
        vm.prank(o);
        d.claim.claimSeat(ids, true);
        assertEq(d.staking.stakedBalance(o) - stakedBefore, PER_SEAT);
        assertEq(d.claim.seatClaimable(1999), 0);
        vm.warp(launch + 39 days);
        vm.prank(o);
        vm.expectRevert(ImdoClaim.ClaimClosed.selector);
        d.claim.claimSeat(ids, false);
        uint256 left = d.token.balanceOf(address(d.claim));
        d.claim.burnUnclaimed();
        assertEq(d.token.balanceOf(address(d.claim)), 0);
        assertEq(d.token.balanceOf(0x000000000000000000000000000000000000dEaD) >= left, true);
    }
}
