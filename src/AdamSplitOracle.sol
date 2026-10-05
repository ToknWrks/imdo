// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";

/// @title AdamSplitOracle
/// @notice Verifies IdentityMD Oracle v2 attestations for one immutable question and signer.
/// @custom:x https://x.com/IaMaDamIMD
contract AdamSplitOracle is EIP712 {
    uint256 public constant MAX_AGE = 26 hours;
    uint16 public constant MIN_BPS = 1500;
    uint16 public constant MAX_BPS = 7000;
    bytes32 public constant TYPEHASH = keccak256(
        "OracleAttestation(bytes32 requestId,uint256 chainId,bytes32 questionHash,uint8 answerType,bytes answer,uint256 figure,uint64 fromBlock,uint64 toBlock,bytes32 blockHash,bytes32 panelJobId,uint16 panelSize,uint16 quorum,uint16 agreed,uint64 issuedAt,uint64 expiresAt)"
    );
    address public immutable signer;
    bytes32 public immutable questionHash;

    struct Attestation {
        bytes32 requestId;
        uint256 chainId;
        bytes32 questionHash;
        uint8 answerType;
        bytes answer;
        uint256 figure;
        uint64 fromBlock;
        uint64 toBlock;
        bytes32 blockHash;
        bytes32 panelJobId;
        uint16 panelSize;
        uint16 quorum;
        uint16 agreed;
        uint64 issuedAt;
        uint64 expiresAt;
    }

    uint16[3] private _weights;
    bytes32 public reportId;
    bytes32 public reasonHash;
    uint64 public issuedAt;
    uint64 public expiresAt;
    mapping(bytes32 => bool) public used;
    // source: 0 = equal fallback, 1 = signed IMD oracle.
    event SplitUpdated(
        uint16 imdBps, uint16 pnkstrBps, uint16 imdstrBps, bytes32 reportId, bytes32 reasonHash, uint8 source
    );
    event ReportRejected(bytes32 indexed reportId);
    error InvalidConfiguration();

    constructor(address signer_, bytes32 questionHash_) EIP712("IdentityMD Oracle", "2") {
        if (signer_ == address(0) || questionHash_ == bytes32(0)) revert InvalidConfiguration();
        signer = signer_;
        questionHash = questionHash_;
    }

    function digest(Attestation calldata a) public view returns (bytes32) {
        return _hashTypedDataV4(
            keccak256(
                abi.encode(
                    TYPEHASH,
                    a.requestId,
                    a.chainId,
                    a.questionHash,
                    a.answerType,
                    keccak256(a.answer),
                    a.figure,
                    a.fromBlock,
                    a.toBlock,
                    a.blockHash,
                    a.panelJobId,
                    a.panelSize,
                    a.quorum,
                    a.agreed,
                    a.issuedAt,
                    a.expiresAt
                )
            )
        );
    }

    /// @notice Anyone can relay. Invalid submissions cannot erase a still-valid accepted report.
    function submit(Attestation calldata a, bytes calldata signature, string calldata reason) external returns (bool) {
        if (!_valid(a, signature, reason)) {
            emit ReportRejected(a.requestId);
            return false;
        }
        bytes32[] memory values = abi.decode(a.answer, (bytes32[]));
        uint16[3] memory weights =
            clamp(uint16(uint256(values[0])), uint16(uint256(values[1])), uint16(uint256(values[2])));
        _weights = weights;
        reportId = a.requestId;
        reasonHash = values[3];
        issuedAt = a.issuedAt;
        expiresAt = a.expiresAt;
        used[a.requestId] = true;
        emit SplitUpdated(weights[0], weights[1], weights[2], a.requestId, values[3], 1);
        return true;
    }

    function _valid(Attestation calldata a, bytes calldata signature, string calldata reason)
        private
        view
        returns (bool)
    {
        if (
            a.requestId == 0 || used[a.requestId] || a.chainId != block.chainid || a.questionHash != questionHash
                || a.answerType != 5 || a.issuedAt > block.timestamp || a.issuedAt <= issuedAt
                || block.timestamp - a.issuedAt > MAX_AGE || a.expiresAt < block.timestamp || a.expiresAt < a.issuedAt
                || a.fromBlock > a.toBlock || a.toBlock >= block.number || a.panelSize < 5 || a.quorum < 4
                || a.agreed < a.quorum || a.agreed > a.panelSize || a.answer.length != 192 || bytes(reason).length == 0
                || bytes(reason).length > 280
        ) return false;
        // Canonical ABI bytes32[dynamic] of exactly four words. Check before decoding untrusted bytes.
        bytes calldata answer = a.answer;
        uint256 offset;
        uint256 length;
        assembly {
            offset := calldataload(answer.offset)
            length := calldataload(add(answer.offset, 32))
        }
        if (offset != 32 || length != 4) return false;
        bytes32[] memory values = abi.decode(answer, (bytes32[]));
        uint256 x = uint256(values[0]);
        uint256 y = uint256(values[1]);
        uint256 z = uint256(values[2]);
        if (x > 10000 || y > 10000 || z > 10000 || x + y + z != 10000 || values[3] != keccak256(bytes(reason))) {
            return false;
        }
        (address recovered, ECDSA.RecoverError err,) = ECDSA.tryRecover(digest(a), signature);
        return err == ECDSA.RecoverError.NoError && recovered == signer;
    }

    /// @dev Clamp then restore sum deterministically, distributing residual across available headroom.
    function clamp(uint16 x, uint16 y, uint16 z) public pure returns (uint16[3] memory w) {
        require(uint256(x) + y + z == 10000, "sum");
        w = [x, y, z];
        uint256 sum;
        for (uint256 i; i < 3; ++i) {
            if (w[i] < MIN_BPS) w[i] = MIN_BPS;
            if (w[i] > MAX_BPS) w[i] = MAX_BPS;
            sum += w[i];
        }
        for (uint256 i; i < 3 && sum != 10000; ++i) {
            uint256 room = sum > 10000 ? w[i] - MIN_BPS : MAX_BPS - w[i];
            uint256 delta = sum > 10000 ? sum - 10000 : 10000 - sum;
            if (delta > room) delta = room;
            if (sum > 10000) {
                w[i] -= uint16(delta);
                sum -= delta;
            } else {
                w[i] += uint16(delta);
                sum += delta;
            }
        }
    }

    function currentSplit() public view returns (uint16[3] memory weights, bytes32 id, bytes32 reason, uint8 source) {
        if (issuedAt == 0 || block.timestamp > uint256(issuedAt) + MAX_AGE || block.timestamp > expiresAt) {
            return ([uint16(3333), uint16(3333), uint16(3334)], bytes32(0), bytes32(0), 0);
        }
        return (_weights, reportId, reasonHash, 1);
    }

    /// @notice Emits the effective split, including a stale/missing fallback, at processing time.
    function checkpoint() external returns (uint16[3] memory weights) {
        bytes32 id;
        bytes32 reason;
        uint8 source;
        (weights, id, reason, source) = currentSplit();
        emit SplitUpdated(weights[0], weights[1], weights[2], id, reason, source);
    }
}
