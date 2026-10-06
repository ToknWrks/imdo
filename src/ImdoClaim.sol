// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

interface IClaimStake {
    function stakeFor(address beneficiary, uint256 amount) external;
    function isExcluded(address account) external view returns (bool);
    function claimContract() external view returns (address);
}

/// @notice ADAM's ten daily claim tranches, with transferable seat rights and a fixed holder root.
contract ImdoClaim is ReentrancyGuard {
    using SafeERC20 for IERC20;
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint256 public constant SEAT_ALLOCATION = 100_000_000e18;
    uint256 public constant HOLDER_ALLOCATION = 10_000_000e18;
    IERC20 public immutable imdo;
    IClaimStake public immutable staking;
    IERC721 public immutable seatNFT;
    uint256 public immutable seatSize;
    bytes32 public immutable holderRoot;
    uint256 public immutable launch;
    uint256 public immutable deadline;
    mapping(uint256 => uint256) public seatClaimed;
    mapping(uint256 => address) public seatClaimedBy;
    mapping(address => uint256) public holderClaimed;
    uint256 public totalHolderClaimed;

    error InvalidConfiguration();
    error InvalidToken();
    error NotOwner();
    error ClaimClosed();
    error NothingUnlocked();
    error TooEarly();
    error InvalidProof();
    event SeatClaimed(uint256 indexed id, address indexed owner);
    event SeatPaid(uint256 indexed id, address indexed owner, uint256 amount, bool staked);
    event HolderClaimed(address indexed holder, uint256 amount, bool staked);
    event UnclaimedBurned(uint256 amount);

    constructor(
        address imdo_,
        address staking_,
        address seatNFT_,
        uint256 seatSize_,
        bytes32 holderRoot_,
        uint256 launch_
    ) {
        if (
            imdo_.code.length == 0 || staking_.code.length == 0 || seatNFT_.code.length == 0 || seatSize_ == 0
                || seatSize_ > SEAT_ALLOCATION || launch_ < block.timestamp
                || !IClaimStake(staking_).isExcluded(address(this))
                || IClaimStake(staking_).claimContract() != address(this)
        ) revert InvalidConfiguration();
        imdo = IERC20(imdo_);
        staking = IClaimStake(staking_);
        seatNFT = IERC721(seatNFT_);
        seatSize = seatSize_;
        holderRoot = holderRoot_;
        launch = launch_;
        deadline = launch_ + 39 days;
    }

    function seatClaimable(uint256 id) public view returns (uint256) {
        if (id >= seatSize) revert InvalidToken();
        uint256 vested = _vested(SEAT_ALLOCATION / seatSize);
        return vested > seatClaimed[id] ? vested - seatClaimed[id] : 0;
    }

    function _vested(uint256 total) private view returns (uint256) {
        if (block.timestamp < launch || block.timestamp >= deadline) return 0;
        uint256 tranches = (block.timestamp - launch) / 1 days + 1;
        if (tranches > 10) tranches = 10;
        return total * tranches / 10;
    }

    function claimSeat(uint256[] calldata ids, bool stake) external nonReentrant {
        if (block.timestamp >= deadline) revert ClaimClosed();
        if (block.timestamp < launch) revert NothingUnlocked();
        uint256 amount;
        bool changed;
        for (uint256 i; i < ids.length; ++i) {
            uint256 id = ids[i];
            uint256 due = seatClaimable(id);
            if (seatNFT.ownerOf(id) != msg.sender) revert NotOwner();
            if (seatClaimedBy[id] != msg.sender) {
                seatClaimedBy[id] = msg.sender;
                changed = true;
                emit SeatClaimed(id, msg.sender);
            }
            if (due == 0) continue;
            seatClaimed[id] += due;
            amount += due;
            emit SeatPaid(id, msg.sender, due, stake);
        }
        if (amount == 0 && !changed) revert NothingUnlocked();
        if (amount != 0) _pay(amount, stake);
    }

    function claimHolder(uint256 total, bytes32[] calldata proof, bool stake) external nonReentrant {
        if (block.timestamp >= deadline) revert ClaimClosed();
        if (
            holderRoot == bytes32(0) || total > HOLDER_ALLOCATION
                || !MerkleProof.verifyCalldata(
                    proof, holderRoot, keccak256(bytes.concat(keccak256(abi.encode(msg.sender, total))))
                )
        ) {
            revert InvalidProof();
        }
        uint256 vested = _vested(total);
        if (vested <= holderClaimed[msg.sender]) revert NothingUnlocked();
        uint256 amount = vested - holderClaimed[msg.sender];
        if (totalHolderClaimed + amount > HOLDER_ALLOCATION) revert InvalidConfiguration();
        holderClaimed[msg.sender] = vested;
        totalHolderClaimed += amount;
        emit HolderClaimed(msg.sender, amount, stake);
        _pay(amount, stake);
    }

    function _pay(uint256 amount, bool stake) private {
        if (stake) {
            imdo.forceApprove(address(staking), amount);
            staking.stakeFor(msg.sender, amount);
            imdo.forceApprove(address(staking), 0);
        } else {
            imdo.safeTransfer(msg.sender, amount);
        }
    }

    /// @notice ADAM burn convention: irrecoverably transfer remaining tokens to DEAD; supply is fixed.
    function burnUnclaimed() external nonReentrant {
        if (block.timestamp < deadline) revert TooEarly();
        uint256 amount = imdo.balanceOf(address(this));
        imdo.safeTransfer(DEAD, amount);
        emit UnclaimedBurned(amount);
    }
}
