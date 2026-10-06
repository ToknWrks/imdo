// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {IMDOToken} from "../src/IMDOToken.sol";
import {ImdoStaking} from "../src/ImdoStaking.sol";
import {ImdoClaim} from "../src/ImdoClaim.sol";
import {ImdoTreasury} from "../src/ImdoTreasury.sol";
import {ImdoHook} from "../src/ImdoHook.sol";
import {HookMiner} from "./utils/HookMiner.sol";

interface IPermit2View {
    function permit2() external view returns (address);
}

/// @notice Manual signer deployment. All configuration arrives as arguments; no keys or environment reads.
contract DeployImdo is Script {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;
    address public constant SEAT_NFT = 0x0000eC93127BAA929E58E97dd0095A2BFb38ec1D;
    uint256 public constant SEAT_SIZE = 2000;
    uint256 public constant LIQUIDITY_IMDO = 890_000_000e18;
    uint256 public constant CLAIM_FUNDING = 110_000_000e18;
    int24 public constant TICK_SPACING = 60;

    struct Config {
        uint256 chainId;
        address deployer;
        address opsWallet;
        address offsetsSafe;
        address regenSafe;
        address hookOwner;
        address poolManager;
        address positionManager;
        address permit2;
        address create2Deployer;
        address imd;
        address imdHooks;
        address seatNFT;
        int24 openingTick;
        bytes32 holderRoot;
        uint256 launch;
    }

    struct Deployment {
        IMDOToken token;
        ImdoStaking staking;
        ImdoClaim claim;
        ImdoTreasury treasury;
        ImdoHook hook;
        bytes32 hookSalt;
        PoolKey key;
        uint128 liquidity;
        uint256 positionId;
    }

    error InvalidConfiguration();
    error HookAddressMismatch(address expected, address actual);
    error TickNotAligned();

    /// @notice Dry-run by default; broadcasting requires the operator's explicit CLI signer and flag.
    function run(Config memory c) external returns (Deployment memory d) {
        preflight(c);
        vm.startBroadcast(c.deployer);
        d = deploy(c);
        vm.stopBroadcast();
    }

    /// @notice In a direct local call set deployer/create2Deployer to this script's address.
    function deploy(Config memory c) public returns (Deployment memory d) {
        preflight(c);
        d.token = new IMDOToken();
        // Same CREATE nonce prediction as ADAM's extension; no transaction between these two creations.
        address expectedClaim = vm.computeCreateAddress(c.deployer, vm.getNonce(c.deployer) + 1);
        d.staking = new ImdoStaking(address(d.token), c.imd, c.poolManager, expectedClaim, c.regenSafe);
        d.claim = new ImdoClaim(address(d.token), address(d.staking), c.seatNFT, SEAT_SIZE, c.holderRoot, c.launch);
        if (address(d.claim) != expectedClaim) revert InvalidConfiguration();
        d.treasury = new ImdoTreasury(
            address(d.staking),
            c.opsWallet,
            c.offsetsSafe,
            c.regenSafe,
            c.poolManager,
            c.imd,
            10000,
            200,
            c.imdHooks,
            1 ether,
            300,
            600,
            0.5 ether,
            0.05 ether,
            5 ether
        );
        bytes memory args = abi.encode(c.poolManager, address(d.token), address(d.treasury), c.deployer);
        (address expectedHook, bytes32 salt) =
            HookMiner.find(c.create2Deployer, hookFlags(), type(ImdoHook).creationCode, args);
        d.hook =
            new ImdoHook{salt: salt}(IPoolManager(c.poolManager), address(d.token), address(d.treasury), c.deployer);
        if (address(d.hook) != expectedHook) revert HookAddressMismatch(expectedHook, address(d.hook));
        d.hookSalt = salt;
        d.key = PoolKey(
            Currency.wrap(address(0)), Currency.wrap(address(d.token)), 0, TICK_SPACING, IHooks(address(d.hook))
        );
        uint160 sqrtPrice = TickMath.getSqrtPriceAtTick(c.openingTick);
        int24 lowerTick = c.openingTick - 69_060;
        IPoolManager(c.poolManager).initialize(d.key, sqrtPrice);
        d.liquidity =
            LiquidityAmounts.getLiquidityForAmount1(TickMath.getSqrtPriceAtTick(lowerTick), sqrtPrice, LIQUIDITY_IMDO);
        if (d.liquidity == 0) revert InvalidConfiguration();
        d.token.approve(c.permit2, LIQUIDITY_IMDO);
        IAllowanceTransfer(c.permit2)
            .approve(address(d.token), c.positionManager, uint160(LIQUIDITY_IMDO), uint48(block.timestamp + 1 hours));
        d.positionId = IPositionManager(c.positionManager).nextTokenId();
        bytes memory actions = abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(
            d.key, lowerTick, c.openingTick, uint256(d.liquidity), uint128(0), uint128(LIQUIDITY_IMDO), DEAD, ""
        );
        params[1] = abi.encode(d.key.currency0, d.key.currency1);
        IPositionManager(c.positionManager).modifyLiquidities(abi.encode(actions, params), block.timestamp + 1 hours);
        IAllowanceTransfer(c.permit2).approve(address(d.token), c.positionManager, 0, 0);
        d.token.approve(c.permit2, 0);
        d.token.transfer(address(d.claim), CLAIM_FUNDING);
        // Integer liquidity rounds down. Irrecoverably dispose of only that rounding remainder.
        uint256 dust = d.token.balanceOf(c.deployer);
        if (dust != 0) d.token.transfer(DEAD, dust);
        d.hook.transferOwnership(c.hookOwner);
    }

    function preflight(Config memory c) public view {
        if (
            c.chainId != block.chainid || c.deployer == address(0) || c.opsWallet == address(0)
                || c.offsetsSafe == address(0) || c.regenSafe == address(0) || c.hookOwner == address(0)
                || c.create2Deployer == address(0) || c.poolManager.code.length == 0
                || c.positionManager.code.length == 0 || c.permit2.code.length == 0 || c.imd.code.length == 0
                || c.seatNFT.code.length == 0 || c.launch < block.timestamp
        ) revert InvalidConfiguration();
        if (
            c.openingTick % TICK_SPACING != 0 || c.openingTick > TickMath.MAX_TICK
                || int256(c.openingTick) - 69_060 < TickMath.MIN_TICK
        ) revert TickNotAligned();
        if (
            address(IPositionManager(c.positionManager).poolManager()) != c.poolManager
                || IPermit2View(c.positionManager).permit2() != c.permit2
        ) revert InvalidConfiguration();
        PoolKey memory imdKey = PoolKey(Currency.wrap(address(0)), Currency.wrap(c.imd), 10000, 200, IHooks(c.imdHooks));
        (uint160 price,,,) = IPoolManager(c.poolManager).getSlot0(imdKey.toId());
        if (price == 0 || IPoolManager(c.poolManager).getLiquidity(imdKey.toId()) == 0) revert InvalidConfiguration();
    }

    function hookFlags() public pure returns (uint160) {
        return 0x20cc;
    }
}
