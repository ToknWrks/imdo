// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {RegenRegistry} from "../src/regen/RegenRegistry.sol";
import {RegenRouter} from "../src/regen/RegenRouter.sol";
import {RegenReceiverFactory} from "../src/regen/RegenReceiver.sol";
import {UniswapV3Venue, ISwapRouter02} from "../src/regen/UniswapV3Venue.sol";
import {IKlimaRetirementAggregator} from "../src/regen/interfaces/IKlimaRetirementAggregator.sol";
import {IEthToTokenSwap, IPriceFeed} from "../src/regen/interfaces/IEthToTokenSwap.sol";
import {IAerodromePool} from "../src/regen/interfaces/IAerodromePool.sol";

/// @notice The Regen rail on Base, in one broadcast and in this order: registry, venue, router, receiver factory, the
///         first project registered (id 1, the same transaction sequence as the registry so nobody can take the name
///         or the id first), its receiver deployed. The receiver's address is what the Ethereum deploy
///         (`DeployImdo`, `receiverOnBase`) is then given. All configuration arrives as arguments; no keys or
///         environment reads. Dry run by default; broadcasting needs the operator's signer and flag.
contract DeployRegenRail is Script {
    struct Config {
        uint256 chainId;
        address deployer;
        address aggregator;
        address usdc;
        address kvcm;
        address kvcmPool;
        address classVault;
        address creditA;
        address creditB;
        address creditC;
        address swapRouter02;
        address weth;
        uint24 v3Fee;
        address ethUsd;
        uint256 maxFeedAge;
        uint256 minBatch;
        uint256 maxBatch;
        uint256 bountyBps;
        uint256 minOutBps;
        uint256 twapGranularity;
        uint256 minTonnesBps;
        string projectName;
        string regenAddress;
        address beneficiary;
    }

    struct Deployment {
        RegenRegistry registry;
        UniswapV3Venue venue;
        RegenRouter router;
        RegenReceiverFactory factory;
        uint256 projectId;
        address receiver;
    }

    error InvalidConfiguration();

    function run(Config memory c) external returns (Deployment memory d) {
        preflight(c);
        vm.startBroadcast(c.deployer);
        d = deploy(c);
        vm.stopBroadcast();
    }

    function deploy(Config memory c) public returns (Deployment memory d) {
        preflight(c);
        d.registry = new RegenRegistry();
        d.venue = new UniswapV3Venue(ISwapRouter02(c.swapRouter02), c.weth, c.usdc, c.v3Fee);
        d.router = new RegenRouter(
            RegenRouter.Config({
                registry: d.registry,
                aggregator: IKlimaRetirementAggregator(c.aggregator),
                usdc: IERC20(c.usdc),
                kvcm: IERC20(c.kvcm),
                kvcmPool: IAerodromePool(c.kvcmPool),
                classVault: c.classVault,
                creditA: c.creditA,
                creditB: c.creditB,
                creditC: c.creditC,
                venue: IEthToTokenSwap(address(d.venue)),
                ethUsd: IPriceFeed(c.ethUsd),
                maxFeedAge: c.maxFeedAge,
                minBatch: c.minBatch,
                maxBatch: c.maxBatch,
                bountyBps: c.bountyBps,
                minOutBps: c.minOutBps,
                twapGranularity: c.twapGranularity,
                minTonnesBps: c.minTonnesBps
            })
        );
        d.factory = new RegenReceiverFactory(d.router);
        d.projectId = d.registry.register(c.projectName, c.regenAddress, c.beneficiary);
        if (d.projectId != 1) revert InvalidConfiguration();
        address predicted = d.factory.predict(d.projectId);
        d.receiver = d.factory.deploy(d.projectId);
        if (d.receiver != predicted) revert InvalidConfiguration();
    }

    function preflight(Config memory c) public view {
        if (
            c.chainId != block.chainid || c.deployer == address(0) || c.aggregator.code.length == 0
                || c.usdc.code.length == 0 || c.kvcm.code.length == 0 || c.kvcmPool.code.length == 0
                || c.classVault.code.length == 0 || c.creditA.code.length == 0 || c.creditB.code.length == 0
                || c.creditC.code.length == 0 || c.swapRouter02.code.length == 0 || c.weth.code.length == 0
                || c.ethUsd.code.length == 0 || c.beneficiary == address(0)
        ) revert InvalidConfiguration();
        // What the router's constructor would refuse, before any creation.
        if (
            c.minBatch == 0 || c.maxBatch < c.minBatch || c.bountyBps >= 10_000 || c.minOutBps == 0
                || c.minOutBps > 10_000 || c.maxFeedAge == 0 || c.twapGranularity == 0 || c.minTonnesBps == 0
                || c.minTonnesBps > 10_000
        ) revert InvalidConfiguration();
        address t0 = IAerodromePool(c.kvcmPool).token0();
        address t1 = IAerodromePool(c.kvcmPool).token1();
        if (!((t0 == c.usdc && t1 == c.kvcm) || (t0 == c.kvcm && t1 == c.usdc))) revert InvalidConfiguration();
    }
}
