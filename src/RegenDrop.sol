// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

/// @title RegenDrop
/// @notice Pays stakers the axlREGEN the REGEN safe bought for them, on Base, from a cumulative Merkle root.
/// @dev Trusted leg: the safe buys, builds and posts the roots. What the contract enforces is narrow. A root only
///      becomes claimable `ACTIVATION_DELAY` after it is posted, so a wrong root can be seen and replaced first. Every
///      root holds each account's running total, so a missed week is never lost. A root cannot promise more than the
///      contract has ever held, and the committed total never shrinks. The safe cannot withdraw: tokens only leave
///      through `claim`, and only to the account named in the proof. No upgrade, no rescue, no other setter.
contract RegenDrop is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint64 public constant ACTIVATION_DELAY = 24 hours;

    IERC20 public immutable token;
    address public immutable safe;

    /// @notice The root claims are checked against, and the total it commits to pay in all.
    bytes32 public root;
    uint256 public committed;
    /// @notice A posted root waiting out its delay (activeAt == 0 means none).
    bytes32 public pendingRoot;
    uint256 public pendingCommitted;
    uint64 public pendingActiveAt;

    mapping(address account => uint256) public claimed;
    uint256 public totalClaimed;

    error ZeroAddress();
    error OnlySafe();
    error NoPendingRoot();
    error CommittedBelowLive(uint256 committed, uint256 live);
    error Underfunded(uint256 committed, uint256 funded);
    error InvalidProof();
    error NothingToClaim();

    event RootPosted(bytes32 root, uint256 committed, uint64 activeAt);
    event RootCancelled(bytes32 root);
    event RootActivated(bytes32 root, uint256 committed);
    event Claimed(address indexed account, uint256 amount, uint256 cumulative);

    constructor(address token_, address safe_) {
        if (token_ == address(0) || safe_ == address(0)) revert ZeroAddress();
        token = IERC20(token_);
        safe = safe_;
    }

    /// @notice Post the next root. Replaces any root still waiting. `committed_` is every account's running total summed.
    function postRoot(bytes32 root_, uint256 committed_) external {
        if (msg.sender != safe) revert OnlySafe();
        // A pending root that is already due is live first, so the checks below compare with what claimants can use.
        _activate();
        if (committed_ < committed) revert CommittedBelowLive(committed_, committed);
        uint256 funded = token.balanceOf(address(this)) + totalClaimed;
        if (committed_ > funded) revert Underfunded(committed_, funded);
        pendingRoot = root_;
        pendingCommitted = committed_;
        pendingActiveAt = uint64(block.timestamp) + ACTIVATION_DELAY;
        emit RootPosted(root_, committed_, pendingActiveAt);
    }

    /// @notice Drop the waiting root; the live root keeps working.
    function cancelPending() external {
        if (msg.sender != safe) revert OnlySafe();
        if (pendingActiveAt == 0) revert NoPendingRoot();
        emit RootCancelled(pendingRoot);
        delete pendingRoot;
        delete pendingCommitted;
        delete pendingActiveAt;
    }

    /// @notice Make a due pending root live. Open to anyone; `claim` does it too.
    function activate() external {
        _activate();
    }

    /// @notice Pay `account` what its running total in the live root exceeds what it already took. Anyone may call;
    ///         the tokens only ever go to `account`.
    function claim(address account, uint256 cumulative, bytes32[] calldata proof) external nonReentrant {
        _activate();
        if (!MerkleProof.verifyCalldata(
                proof, root, keccak256(bytes.concat(keccak256(abi.encode(account, cumulative))))
            )) revert InvalidProof();
        uint256 already = claimed[account];
        if (cumulative <= already) revert NothingToClaim();
        uint256 amount = cumulative - already;
        claimed[account] = cumulative;
        totalClaimed += amount;
        emit Claimed(account, amount, cumulative);
        token.safeTransfer(account, amount);
    }

    /// @notice What `account` could take now with a proof for `cumulative`.
    function claimable(address account, uint256 cumulative) external view returns (uint256) {
        uint256 already = claimed[account];
        return cumulative > already ? cumulative - already : 0;
    }

    function _activate() private {
        uint64 at = pendingActiveAt;
        if (at == 0 || block.timestamp < at) return;
        root = pendingRoot;
        committed = pendingCommitted;
        emit RootActivated(pendingRoot, pendingCommitted);
        delete pendingRoot;
        delete pendingCommitted;
        delete pendingActiveAt;
    }
}
