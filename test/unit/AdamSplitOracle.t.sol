// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {Test} from "forge-std/Test.sol";
import {AdamSplitOracle} from "../../src/AdamSplitOracle.sol";

/// @custom:x https://x.com/IaMaDamIMD
contract AdamSplitOracleTest is Test {
    AdamSplitOracle internal oracle;
    uint256 constant PK = 1234;
    bytes32 constant QUESTION = keccak256("immutable question");
    string constant REASON = "IMD is down 12%, liquid and risk unchanged.";

    function setUp() public {
        vm.warp(1800000000);
        vm.roll(1000);
        oracle = new AdamSplitOracle(vm.addr(PK), QUESTION);
    }

    function report(uint16 x, uint16 y, uint16 z) internal view returns (AdamSplitOracle.Attestation memory a) {
        bytes32[] memory words = new bytes32[](4);
        words[0] = bytes32(uint256(x));
        words[1] = bytes32(uint256(y));
        words[2] = bytes32(uint256(z));
        words[3] = keccak256(bytes(REASON));
        a = AdamSplitOracle.Attestation(
            bytes32(uint256(1)),
            block.chainid,
            QUESTION,
            5,
            abi.encode(words),
            0,
            1,
            999,
            keccak256("block"),
            keccak256("panel"),
            5,
            4,
            4,
            uint64(block.timestamp),
            uint64(block.timestamp + 2 days)
        );
    }

    function signature(AdamSplitOracle.Attestation memory a, uint256 pk) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, oracle.digest(a));
        return abi.encodePacked(r, s, v);
    }

    function assertFallback() internal view {
        (uint16[3] memory w, bytes32 id,, uint8 source) = oracle.currentSplit();
        assertEq(w[0], 3333);
        assertEq(w[1], 3333);
        assertEq(w[2], 3334);
        assertEq(id, 0);
        assertEq(source, 0);
    }

    function testSignedClampedReportAndAgeBoundary() public {
        assertFallback();
        AdamSplitOracle.Attestation memory a = report(8500, 1000, 500);
        assertTrue(oracle.submit(a, signature(a, PK), REASON));
        (uint16[3] memory w, bytes32 id, bytes32 reason, uint8 source) = oracle.currentSplit();
        assertEq(w[0], 7000);
        assertEq(w[1], 1500);
        assertEq(w[2], 1500);
        assertEq(id, a.requestId);
        assertEq(reason, keccak256(bytes(REASON)));
        assertEq(source, 1);
        vm.warp(vm.getBlockTimestamp() + 26 hours);
        (,,, source) = oracle.currentSplit();
        assertEq(source, 1);
        vm.warp(vm.getBlockTimestamp() + 1);
        assertFallback();
    }

    function testInvalidSignatureReasonQuestionAndChain() public {
        AdamSplitOracle.Attestation memory a = report(4000, 3000, 3000);
        assertFalse(oracle.submit(a, signature(a, 4321), REASON));
        assertFalse(oracle.submit(a, hex"1234", REASON));
        assertFalse(oracle.submit(a, signature(a, PK), "forged reason"));
        a.questionHash = keccak256("wrong");
        assertFalse(oracle.submit(a, signature(a, PK), REASON));
        a.questionHash = QUESTION;
        a.chainId++;
        assertFalse(oracle.submit(a, signature(a, PK), REASON));
        assertFallback();
    }

    function testDomainReplayAndDuplicateCannotReplaceValidReport() public {
        AdamSplitOracle.Attestation memory a = report(4000, 3000, 3000);
        bytes memory sig = signature(a, PK);
        AdamSplitOracle other = new AdamSplitOracle(vm.addr(PK), QUESTION);
        assertFalse(other.submit(a, sig, REASON));
        assertTrue(oracle.submit(a, sig, REASON));
        assertFalse(oracle.submit(a, sig, REASON));
        a.requestId = keccak256("different");
        assertFalse(oracle.submit(a, signature(a, PK), REASON));
        (uint16[3] memory w,,, uint8 source) = oracle.currentSplit();
        assertEq(w[0], 4000);
        assertEq(source, 1);
    }

    function testBadTimesQuorumAndSumsFallBack() public {
        AdamSplitOracle.Attestation memory a = report(5000, 3000, 2000);
        a.issuedAt = uint64(block.timestamp + 1);
        assertFalse(oracle.submit(a, signature(a, PK), REASON));
        a.issuedAt = uint64(block.timestamp - 26 hours - 1);
        assertFalse(oracle.submit(a, signature(a, PK), REASON));
        a.issuedAt = uint64(block.timestamp);
        a.expiresAt = uint64(block.timestamp - 1);
        assertFalse(oracle.submit(a, signature(a, PK), REASON));
        a.expiresAt = uint64(block.timestamp + 1 days);
        a.agreed = 3;
        assertFalse(oracle.submit(a, signature(a, PK), REASON));
        a.agreed = 4;
        a.panelSize = 3;
        assertFalse(oracle.submit(a, signature(a, PK), REASON));
        a = report(5000, 3000, 2001);
        assertFalse(oracle.submit(a, signature(a, PK), REASON));
        a = report(5000, 3000, 2000);
        a.toBlock = uint64(block.number);
        assertFalse(oracle.submit(a, signature(a, PK), REASON));
        assertFallback();
    }

    function testMalformedAnswerNeverReverts() public {
        AdamSplitOracle.Attestation memory a = report(5000, 3000, 2000);
        a.answer = hex"01";
        assertFalse(oracle.submit(a, signature(a, PK), REASON));
        a.answer = new bytes(192);
        assertFalse(oracle.submit(a, signature(a, PK), REASON));
        a.answerType = 3;
        assertFalse(oracle.submit(a, signature(a, PK), REASON));
    }

    function testFuzzClampedWeightsAlwaysSumAndBound(uint16 x, uint16 y) public view {
        x = uint16(bound(x, 0, 10000));
        y = uint16(bound(y, 0, 10000 - x));
        uint16[3] memory w = oracle.clamp(x, y, 10000 - x - y);
        assertEq(uint256(w[0]) + w[1] + w[2], 10000);
        for (uint256 i; i < 3; ++i) {
            assertGe(w[i], 1500);
            assertLe(w[i], 7000);
        }
    }

    function testFuzzMalformedReport(bytes memory payload) public {
        AdamSplitOracle.Attestation memory a = report(5000, 3000, 2000);
        a.answer = payload;
        assertFalse(oracle.submit(a, hex"deadbeef", REASON));
    }
}
