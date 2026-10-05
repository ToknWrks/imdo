// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IClaimStake {
    function stakeFor(address beneficiary, uint256 amount) external;
    function isExcluded(address account) external view returns (bool);
}

/// @title NFTClaim
/// @notice Immutable per-NFT ADAM allocation. Only the current owner can pull vested tokens.
/// @custom:x https://x.com/IaMaDamIMD
contract NFTClaim is ReentrancyGuard {
    using SafeERC20 for IERC20;

    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint256 public constant IMD_ALLOCATION = 100_000_000e18;
    uint256 public constant PEPE_ALLOCATION = 10_000_000e18;
    IERC20 public immutable adam;
    IClaimStake public immutable distributor;
    IERC721 public immutable imdNFT;
    IERC721 public immutable swarmPepe;
    uint256 public immutable imdSize;
    uint256 public immutable pepeSize;
    uint256 public immutable launch;
    uint256 public immutable deadline;
    mapping(uint8 collection => mapping(uint256 tokenId => uint256)) public claimed;

    error InvalidConfiguration();
    error InvalidToken();
    error NotOwner();
    error ClaimClosed();
    error NothingUnlocked();
    error TooEarly();
    event Claimed(
        address indexed owner, uint8 indexed collection, uint256 indexed tokenId, uint256 amount, bool staked
    );
    event UnclaimedBurned(uint256 amount);

    constructor(
        address adam_,
        address distributor_,
        address imd_,
        address pepe_,
        uint256 imdSize_,
        uint256 pepeSize_,
        uint256 launch_
    ) {
        if (
            adam_.code.length == 0 || distributor_.code.length == 0 || imd_.code.length == 0 || pepe_.code.length == 0
                || imd_ == pepe_ || imdSize_ == 0 || pepeSize_ == 0 || launch_ < block.timestamp
                || !IClaimStake(distributor_).isExcluded(address(this))
        ) revert InvalidConfiguration();
        adam = IERC20(adam_);
        distributor = IClaimStake(distributor_);
        imdNFT = IERC721(imd_);
        swarmPepe = IERC721(pepe_);
        imdSize = imdSize_;
        pepeSize = pepeSize_;
        launch = launch_;
        deadline = launch_ + 9 days + 30 days;
    }

    /// @dev IMD ids are [0,size); Swarm Pepe ids are [1,size]. Post-snapshot mints are ineligible.
    function share(uint8 collection, uint256 tokenId) public view returns (uint256) {
        if (collection == 0 && tokenId < imdSize) return IMD_ALLOCATION / imdSize;
        if (collection == 1 && tokenId > 0 && tokenId <= pepeSize) return PEPE_ALLOCATION / pepeSize;
        revert InvalidToken();
    }

    function claimable(uint8 collection, uint256 tokenId) public view returns (uint256) {
        uint256 allocation = share(collection, tokenId);
        if (block.timestamp < launch || block.timestamp >= deadline) return 0;
        uint256 tranches = (block.timestamp - launch) / 1 days + 1;
        if (tranches > 10) tranches = 10;
        return allocation * tranches / 10 - claimed[collection][tokenId];
    }

    function claim(uint8 collection, uint256[] calldata tokenIds) external nonReentrant {
        uint256 amount = _claim(collection, tokenIds, false);
        adam.safeTransfer(msg.sender, amount);
    }

    function claimAndStake(uint8 collection, uint256[] calldata tokenIds) external nonReentrant {
        uint256 amount = _claim(collection, tokenIds, true);
        adam.forceApprove(address(distributor), amount);
        distributor.stakeFor(msg.sender, amount);
        adam.forceApprove(address(distributor), 0);
    }

    function _claim(uint8 collection, uint256[] calldata tokenIds, bool staked) private returns (uint256 amount) {
        if (block.timestamp >= deadline) revert ClaimClosed();
        for (uint256 i; i < tokenIds.length; ++i) {
            uint256 id = tokenIds[i];
            uint256 due = claimable(collection, id);
            if ((collection == 0 ? imdNFT : swarmPepe).ownerOf(id) != msg.sender) revert NotOwner();
            // Repeated ids have zero due, so can never double-claim.
            if (due == 0) continue;
            claimed[collection][id] += due;
            amount += due;
            emit Claimed(msg.sender, collection, id, due, staked);
        }
        if (amount == 0) revert NothingUnlocked();
    }

    function burnUnclaimed() external nonReentrant {
        if (block.timestamp < deadline) revert TooEarly();
        uint256 amount = adam.balanceOf(address(this));
        adam.safeTransfer(DEAD, amount);
        emit UnclaimedBurned(amount);
    }
}
