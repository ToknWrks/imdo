// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {AdamSplitOracle} from "../src/AdamSplitOracle.sol";
import {AdamDistributorV2} from "../src/AdamDistributorV2.sol";
import {AdamTreasuryV2} from "../src/AdamTreasuryV2.sol";
import {NFTClaim} from "../src/NFTClaim.sol";

/// @title DeployAdamExtension
/// @notice Manual-signer script. Reuses existing ADAM; never deploys or mints a token.
/// @custom:x https://x.com/IaMaDamIMD
contract DeployAdamExtension is Script {
    using SafeERC20 for IERC20;
    uint256 public constant SNAPSHOT_BLOCK = 26_127_182;
    uint256 public constant IMD_SIZE = 2000;
    uint256 public constant PEPE_SIZE = 1178;
    address public constant IMD_NFT = 0x0000eC93127BAA929E58E97dd0095A2BFb38ec1D;
    address public constant PEPE_NFT = 0x999ce0CE8C5f7661e0c74a568FfE27CEB9177bDB;
    address public constant IMDSTR = 0x80271ce20184e38F4AFe90d4Ca134304d197Aca2;
    address public constant IMDSTR_HOOK = 0x66b05C8eecA9329F7a2332C02Ce3855cfaB72444;
    address public constant ORACLE_SIGNER = 0x5598Aa9146215Bc13eb26f2c692Ad1461Fd32982;
    uint256 public constant NFT_FUNDING = 110_000_000e18;

    struct Config {
        uint256 chainId;
        address adam;
        address creator;
        address funder;
        address imdNFT;
        address pepeNFT;
        uint256 imdSize;
        uint256 pepeSize;
        uint256 launch;
        address signer;
        bytes32 questionHash;
        AdamTreasuryV2.Config treasury;
    }

    struct Deployment {
        AdamSplitOracle oracle;
        AdamDistributorV2 distributor;
        AdamTreasuryV2 treasury;
        NFTClaim nftClaim;
    }
    error InvalidConfiguration();

    function mainnetConfig(address existingAdam, address deployer, address team, uint256 launch, bytes32 questionHash)
        public
        pure
        returns (Config memory c)
    {
        c.chainId = 1;
        c.adam = existingAdam;
        c.creator = deployer;
        c.funder = deployer;
        c.imdNFT = IMD_NFT;
        c.pepeNFT = PEPE_NFT;
        c.imdSize = IMD_SIZE;
        c.pepeSize = PEPE_SIZE;
        c.launch = launch;
        c.signer = ORACLE_SIGNER;
        c.questionHash = questionHash;
        c.treasury.team = team;
        c.treasury.manager = 0x000000000004444c5dc75cB358380D2e3dE08A90;
        c.treasury.keys[0] = PoolKey(
            Currency.wrap(address(0)),
            Currency.wrap(0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7),
            10000,
            200,
            IHooks(address(0))
        );
        c.treasury.keys[1] = PoolKey(
            Currency.wrap(address(0)),
            Currency.wrap(0xc50673EDb3A7b94E8CAD8a7d4E0cD68864E33eDF),
            0,
            60,
            IHooks(0xfAaad5B731F52cDc9746F2414c823eca9B06E844)
        );
        c.treasury.keys[2] = PoolKey(Currency.wrap(address(0)), Currency.wrap(IMDSTR), 0, 60, IHooks(IMDSTR_HOOK));
        c.treasury.taxes = [uint16(0), uint16(1000), uint16(1000)];
        c.treasury.maxEthPerBuy = 1 ether;
        c.treasury.slippageBps = 300;
        c.treasury.cooldown = 600;
    }

    /// @notice Dry run unless the deployer explicitly uses Foundry's --broadcast with their own signer.
    /// @dev No environment variables or private keys. Supply a complete reviewed configuration.
    function run(Config memory c) external returns (Deployment memory d) {
        vm.startBroadcast(c.creator);
        d = deploy(c);
        vm.stopBroadcast();
    }

    /// @notice Testable deployment path. In a local call creator must be this script; under broadcast, the signer.
    function deploy(Config memory c) public returns (Deployment memory d) {
        if (
            block.chainid != c.chainId || c.adam.code.length == 0 || c.creator == address(0) || c.funder == address(0)
                || IERC20(c.adam).totalSupply() != 1_000_000_000e18
                || keccak256(bytes(IERC20Metadata(c.adam).name())) != keccak256("ADAM")
                || keccak256(bytes(IERC20Metadata(c.adam).symbol())) != keccak256("ADAM")
                || IERC20Metadata(c.adam).decimals() != 18 || IERC20(c.adam).balanceOf(c.funder) < NFT_FUNDING
        ) {
            revert InvalidConfiguration();
        }
        // Re-read collection counters on the deployment chain. Pinned sizes may not exceed minted supply.
        if (_count(c.imdNFT, "totalSupply()") < c.imdSize || _count(c.pepeNFT, "totalMinted()") < c.pepeSize) {
            revert InvalidConfiguration();
        }
        d.oracle = new AdamSplitOracle(c.signer, c.questionHash);
        address expectedClaim = vm.computeCreateAddress(c.creator, vm.getNonce(c.creator) + 1);
        d.distributor = new AdamDistributorV2(
            c.adam,
            Currency.unwrap(c.treasury.keys[0].currency1),
            Currency.unwrap(c.treasury.keys[1].currency1),
            c.treasury.manager,
            expectedClaim,
            c.treasury.keys[2],
            c.treasury.maxEthPerBuy
        );
        d.nftClaim = new NFTClaim(c.adam, address(d.distributor), c.imdNFT, c.pepeNFT, c.imdSize, c.pepeSize, c.launch);
        if (address(d.nftClaim) != expectedClaim) revert InvalidConfiguration();
        c.treasury.distributor = address(d.distributor);
        c.treasury.oracle = address(d.oracle);
        d.treasury = new AdamTreasuryV2(c.treasury);
        if (c.funder == c.creator) IERC20(c.adam).safeTransfer(address(d.nftClaim), NFT_FUNDING);
        else IERC20(c.adam).safeTransferFrom(c.funder, address(d.nftClaim), NFT_FUNDING);
    }

    function _count(address nft, string memory selector) private view returns (uint256 n) {
        (bool ok, bytes memory result) = nft.staticcall(abi.encodeWithSelector(bytes4(keccak256(bytes(selector)))));
        if (!ok || result.length != 32) revert InvalidConfiguration();
        n = abi.decode(result, (uint256));
    }
}
