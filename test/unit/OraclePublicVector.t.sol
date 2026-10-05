// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {Test} from "forge-std/Test.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {AdamSplitOracle} from "../../src/AdamSplitOracle.sol";

/// @notice Real public v2 attestation, unrelated to ADAM; proves wire-format/domain interoperability offline.
/// @dev https://api.imd.fun/oracle/requests/cbb2d9c7-fd79-4033-8ebc-a76f2b256260/attestation
/// @custom:x https://x.com/IaMaDamIMD
contract OraclePublicVectorTest is Test {
    function testPublishedV2SignatureRecovery() public {
        vm.chainId(1);
        address consumer = address(uint160(0x0037bfb8ac7c960e558657871d41ca70e07e7dbfff));
        address signer = address(uint160(0x005598aa9146215bc13eb26f2c692ad1461fd32982));
        AdamSplitOracle template =
            new AdamSplitOracle(signer, 0x39eecf277118e4219d50e4352a2fcf943cf802239c546d54dd4baba53c72d787);
        vm.etch(consumer, address(template).code);
        AdamSplitOracle oracle = AdamSplitOracle(consumer);
        AdamSplitOracle.Attestation memory a;
        a.agreed = 4;
        a.answer = hex"00000000000000000000000000000000000000000000000000000000d5876420";
        a.figure = 3582420000;
        a.quorum = 4;
        a.chainId = 1;
        a.toBlock = 26122901;
        a.issuedAt = 1791211597;
        a.blockHash = 0x22cd78830715d67d27849123a084fe3b854a1af74b40cd7f73c727399eef3059;
        a.expiresAt = 1791233197;
        a.fromBlock = 26122900;
        a.panelSize = 5;
        a.requestId = 0xcbb2d9c7fd7940338ebca76f2b25626000000000000000000000000000000000;
        a.answerType = 3;
        a.panelJobId = 0x5ba008de174a482884e45854928099b400000000000000000000000000000000;
        a.questionHash = 0x39eecf277118e4219d50e4352a2fcf943cf802239c546d54dd4baba53c72d787;
        bytes memory signature =
            hex"1cbb40839cc1792682273d8dc0b197c6e227db4224bcd9ab000c023c24d3a58f62e91c62746f7c71dc4e65b796f9b9a4b8f52a926885f1d3ee7de0c8f92e084e1b";
        assertEq(ECDSA.recover(oracle.digest(a), signature), signer);
        // This signature must never authorize our unrelated bytes32[] reward policy.
        assertFalse(oracle.submit(a, signature, "unrelated report"));
    }
}
