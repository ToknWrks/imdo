// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {ExtensionFixture} from "../utils/ExtensionFixture.sol";
import {DeployAdamExtension} from "../../script/DeployAdamExtension.s.sol";
import {NFTClaim} from "../../src/NFTClaim.sol";

/// @custom:x https://x.com/IaMaDamIMD
contract ExtensionDeployTest is ExtensionFixture {
    DeployAdamExtension internal extension;

    function config() internal returns (DeployAdamExtension.Config memory c) {
        extension = new DeployAdamExtension();
        c.chainId = block.chainid;
        c.adam = address(adam);
        c.creator = address(extension);
        c.funder = address(this);
        c.imdNFT = address(nft);
        c.pepeNFT = address(pepe);
        c.imdSize = 4;
        c.pepeSize = 2;
        c.launch = block.timestamp + 1 days;
        c.signer = vm.addr(ORACLE_PK);
        c.questionHash = QUESTION;
        c.treasury = treasuryConfig();
    }

    function testExistingTokenReusedAndExactlyElevenPercentFunded() public {
        DeployAdamExtension.Config memory c = config();
        adam.approve(address(extension), 110_000_000e18);
        uint256 supplyBefore = adam.totalSupply();
        uint256 balanceBefore = adam.balanceOf(address(this));
        DeployAdamExtension.Deployment memory d = extension.deploy(c);
        assertEq(address(d.distributor.adam()), address(adam));
        assertEq(adam.totalSupply(), supplyBefore);
        assertEq(adam.balanceOf(address(d.nftClaim)), 110_000_000e18);
        assertEq(balanceBefore - adam.balanceOf(address(this)), 110_000_000e18);
        assertTrue(d.distributor.isExcluded(address(d.nftClaim)));
        assertEq(address(d.nftClaim.distributor()), address(d.distributor));
        assertEq(address(d.treasury.distributor()), address(d.distributor));
        assertEq(address(d.treasury.splitOracle()), address(d.oracle));
        vm.warp(c.launch);
        vm.prank(alice);
        d.nftClaim.claimAndStake(0, ids(0));
        assertEq(d.distributor.stakedBalance(alice), 2_500_000e18);
    }

    function testFundFromScriptCreatorAndNoMint() public {
        DeployAdamExtension.Config memory c = config();
        c.funder = address(extension);
        adam.transfer(address(extension), 110_000_000e18);
        DeployAdamExtension.Deployment memory d = extension.deploy(c);
        assertEq(adam.balanceOf(address(extension)), 0);
        assertEq(adam.balanceOf(address(d.nftClaim)), 110_000_000e18);
    }

    function testRunUsesExplicitManualSignerAndExistingSupply() public {
        DeployAdamExtension.Config memory c = config();
        address deployer = makeAddr("manual signer");
        c.creator = deployer;
        c.funder = deployer;
        adam.transfer(deployer, 110_000_000e18);
        DeployAdamExtension.Deployment memory d = extension.run(c);
        assertEq(adam.balanceOf(deployer), 0);
        assertEq(adam.balanceOf(address(d.nftClaim)), 110_000_000e18);
        assertEq(adam.totalSupply(), 1_000_000_000e18);
    }

    function testDeployFailsWrongChainMissingTokenOrUnavailableSnapshot() public {
        DeployAdamExtension.Config memory c = config();
        c.chainId++;
        vm.expectRevert(DeployAdamExtension.InvalidConfiguration.selector);
        extension.deploy(c);
        c.chainId = block.chainid;
        c.adam = address(0);
        vm.expectRevert(DeployAdamExtension.InvalidConfiguration.selector);
        extension.deploy(c);
        c.adam = address(adam);
        c.pepeSize = 3;
        vm.expectRevert(DeployAdamExtension.InvalidConfiguration.selector);
        extension.deploy(c);
    }

    function testClaimConstructorRejectsNonexcludedAddress() public {
        vm.expectRevert(NFTClaim.InvalidConfiguration.selector);
        new NFTClaim(address(adam), address(d2), address(nft), address(pepe), 4, 2, block.timestamp + 1 days);
    }
}
