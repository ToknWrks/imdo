// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {LocalV4} from "./LocalV4.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {LaunchToken} from "../../src/LaunchToken.sol";
import {NFTClaim} from "../../src/NFTClaim.sol";
import {AdamDistributorV2} from "../../src/AdamDistributorV2.sol";
import {AdamTreasuryV2} from "../../src/AdamTreasuryV2.sol";
import {AdamSplitOracle} from "../../src/AdamSplitOracle.sol";

/// @custom:x https://x.com/IaMaDamIMD
contract LockedStrategyMock is ERC20 {
    address public immutable manager;
    mapping(address => bool) public isDistributor;
    bool public reject;
    error InvalidTransfer();

    constructor(address pm) ERC20("IMDSTR", "IMDSTR") {
        manager = pm;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setDistributor(address who, bool value) external {
        isDistributor[who] = value;
    }

    function setReject(bool value) external {
        reject = value;
    }

    function _update(address from, address to, uint256 amount) internal override {
        if (
            from != address(0)
                && (reject || (from != manager && to != manager && !isDistributor[from] && !isDistributor[to]))
        ) revert InvalidTransfer();
        super._update(from, to, amount);
    }
}

/// @custom:x https://x.com/IaMaDamIMD
contract ClaimNFTMock is ERC721 {
    uint256 public totalSupply;
    uint256 public totalMinted;
    constructor() ERC721("NFT", "NFT") {}

    function mint(address to, uint256 id) external {
        _mint(to, id);
        ++totalSupply;
        ++totalMinted;
    }

    function burn(uint256 id) external {
        _burn(id);
        --totalSupply;
    }
}

/// @custom:x https://x.com/IaMaDamIMD
abstract contract ExtensionFixture is LocalV4 {
    LockedStrategyMock internal imdstr;
    ClaimNFTMock internal nft;
    ClaimNFTMock internal pepe;
    NFTClaim internal nftClaim;
    AdamDistributorV2 internal d2;
    AdamTreasuryV2 internal t2;
    AdamSplitOracle internal oracle;
    PoolKey internal thirdKey;
    uint256 internal constant ORACLE_PK = 0xa11ce;
    bytes32 internal constant QUESTION = keccak256("ADAM allocation question v1");

    function setUp() public virtual override {
        vm.warp(1_800_000_000);
        vm.roll(1000);
        poolManager = new PoolManager(address(this));
        swapRouter = new PoolSwapTest(poolManager);
        lpRouter = new PoolModifyLiquidityTest(poolManager);
        _deployRewardPools();
        imdstr = new LockedStrategyMock(address(poolManager));
        imdstr.mint(address(this), 1e36);
        imdstr.approve(address(lpRouter), type(uint256).max);
        thirdKey =
            PoolKey(Currency.wrap(address(0)), Currency.wrap(address(imdstr)), 0, 60, IHooks(address(pnkstrHook)));
        _initAndSeed(thirdKey, 120420, -887220, 887220, 200 ether);
        adam = new LaunchToken();
        nft = new ClaimNFTMock();
        pepe = new ClaimNFTMock();
        nft.mint(alice, 0);
        nft.mint(alice, 1);
        nft.mint(bob, 2);
        nft.mint(bob, 3);
        pepe.mint(alice, 1);
        pepe.mint(bob, 2);
        oracle = new AdamSplitOracle(vm.addr(ORACLE_PK), QUESTION);
        address expected = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        d2 = new AdamDistributorV2(
            address(adam), address(imd), address(pnkstr), address(poolManager), expected, thirdKey, 1 ether
        );
        nftClaim = new NFTClaim(address(adam), address(d2), address(nft), address(pepe), 4, 2, block.timestamp + 1 days);
        assertEq(address(nftClaim), expected);
        adam.transfer(address(nftClaim), 110_000_000e18);
        t2 = new AdamTreasuryV2(treasuryConfig());
        adam.transfer(alice, 100_000_000e18);
        adam.transfer(bob, 100_000_000e18);
        vm.prank(alice);
        adam.approve(address(d2), type(uint256).max);
        vm.prank(bob);
        adam.approve(address(d2), type(uint256).max);
    }

    function treasuryConfig() internal view returns (AdamTreasuryV2.Config memory c) {
        c.distributor = address(d2);
        c.team = teamWallet;
        c.manager = address(poolManager);
        c.keys = [imdKey, pnkstrKey, thirdKey];
        c.taxes = [uint16(0), uint16(1000), uint16(1000)];
        c.maxEthPerBuy = 1 ether;
        c.slippageBps = 300;
        c.cooldown = 600;
        c.oracle = address(oracle);
    }

    function stakeAlice(uint256 amount) internal {
        vm.prank(alice);
        d2.stake(amount);
    }

    function fundTreasury(uint256 amount) internal {
        (bool ok,) = address(t2).call{value: amount}("");
        require(ok);
    }

    function ids(uint256 a) internal pure returns (uint256[] memory list) {
        list = new uint256[](1);
        list[0] = a;
    }

    function report(uint16 x, uint16 y, uint16 z) internal view returns (AdamSplitOracle.Attestation memory a) {
        bytes32[] memory values = new bytes32[](4);
        values[0] = bytes32(uint256(x));
        values[1] = bytes32(uint256(y));
        values[2] = bytes32(uint256(z));
        values[3] = keccak256("Down over 24h; liquidity stable.");
        a = AdamSplitOracle.Attestation(
            bytes32(uint256(1)),
            block.chainid,
            QUESTION,
            5,
            abi.encode(values),
            0,
            1,
            999,
            bytes32(uint256(100)),
            bytes32(uint256(200)),
            5,
            4,
            4,
            uint64(block.timestamp),
            uint64(block.timestamp + 26 hours)
        );
    }

    function sign(AdamSplitOracle.Attestation memory a) internal view returns (bytes memory sig) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ORACLE_PK, oracle.digest(a));
        return abi.encodePacked(r, s, v);
    }

    function submit(uint16 x, uint16 y, uint16 z) internal {
        AdamSplitOracle.Attestation memory a = report(x, y, z);
        assertTrue(oracle.submit(a, sign(a), "Down over 24h; liquidity stable."));
    }
}
