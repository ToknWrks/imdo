// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {RegenRegistry} from "../../src/regen/RegenRegistry.sol";

contract RegenRegistryTest is Test {
    RegenRegistry internal reg;
    string internal constant REGEN = "regen183ht37fsp2fhnq3gneyjycp08c3ju4xnvxnvan";
    address internal beneficiary = makeAddr("imdo-safe");

    function setUp() public {
        reg = new RegenRegistry();
    }

    function test_registerStoresEverythingAndNumbersFromOne() public {
        vm.expectEmit(true, true, false, true);
        emit RegenRegistry.ProjectRegistered(1, beneficiary, "IMDO", REGEN, address(this));
        uint256 id = reg.register("IMDO", REGEN, beneficiary);
        assertEq(id, 1);
        assertEq(reg.count(), 1);
        RegenRegistry.Project memory p = reg.project(1);
        assertEq(p.beneficiary, beneficiary);
        assertEq(p.name, "IMDO");
        assertEq(p.regenAddress, REGEN);
        assertTrue(reg.exists(1));
        assertFalse(reg.exists(0));
        assertFalse(reg.exists(2));
        assertEq(reg.idByName(keccak256("IMDO")), 1);
        assertEq(reg.register("Second", REGEN, beneficiary), 2);
    }

    function test_unknownProjectReverts() public {
        vm.expectRevert(abi.encodeWithSelector(RegenRegistry.UnknownProject.selector, 1));
        reg.project(1);
    }

    function test_nameIsUniqueCaseSensitive() public {
        reg.register("IMDO", REGEN, beneficiary);
        vm.expectRevert(abi.encodeWithSelector(RegenRegistry.NameTaken.selector, 1));
        reg.register("IMDO", REGEN, address(0xBEEF));
        assertEq(reg.register("imdo", REGEN, beneficiary), 2);
    }

    function test_zeroBeneficiaryRefused() public {
        vm.expectRevert(RegenRegistry.ZeroAddress.selector);
        reg.register("IMDO", REGEN, address(0));
    }

    function test_nameRules() public view {
        assertTrue(reg.validName("IMDO"));
        assertTrue(reg.validName("A"));
        assertTrue(reg.validName("Name with spaces & punctuation!"));
        assertTrue(reg.validName(bytes(_repeat("x", 64))));
        assertFalse(reg.validName(""));
        assertFalse(reg.validName(bytes(_repeat("x", 65))));
        assertFalse(reg.validName(" IMDO"));
        assertFalse(reg.validName("IMDO "));
        assertFalse(reg.validName("IM|DO"));
        assertFalse(reg.validName("IM\nDO"));
        assertFalse(reg.validName("IM\tDO"));
        assertFalse(reg.validName(hex"494d444f7f")); // DEL
        assertFalse(reg.validName(unicode"IMDÖ")); // non-ASCII
    }

    function test_badNamesRevert() public {
        vm.expectRevert(RegenRegistry.BadName.selector);
        reg.register("IM|DO", REGEN, beneficiary);
        vm.expectRevert(RegenRegistry.BadName.selector);
        reg.register("", REGEN, beneficiary);
    }

    function test_regenAddressRules() public view {
        assertTrue(reg.validRegenAddress(bytes(REGEN)));
        assertFalse(reg.validRegenAddress(bytes("regen183ht37fsp2fhnq3gneyjycp08c3ju4xnvxnva"))); // 43
        assertFalse(reg.validRegenAddress(bytes("regen183ht37fsp2fhnq3gneyjycp08c3ju4xnvxnvann"))); // 45
        assertFalse(reg.validRegenAddress(bytes("cosmos83ht37fsp2fhnq3gneyjycp08c3ju4xnvxnvan"))); // prefix
        assertFalse(reg.validRegenAddress(bytes("REGEN183HT37FSP2FHNQ3GNEYJYCP08C3JU4XNVXNVAN"))); // case
        assertFalse(reg.validRegenAddress(bytes("regen1b3ht37fsp2fhnq3gneyjycp08c3ju4xnvxnvan"))); // 'b'
        assertFalse(reg.validRegenAddress(bytes("regen1i3ht37fsp2fhnq3gneyjycp08c3ju4xnvxnvan"))); // 'i'
        assertFalse(reg.validRegenAddress(bytes("regen1o3ht37fsp2fhnq3gneyjycp08c3ju4xnvxnvan"))); // 'o'
        assertFalse(reg.validRegenAddress(bytes("regen113ht37fsp2fhnq3gneyjycp08c3ju4xnvxnvan"))); // '1'
        assertFalse(reg.validRegenAddress(bytes("regen1 3ht37fsp2fhnq3gneyjycp08c3ju4xnvxnvan"))); // space
        // the whole bech32 charset once, then 6 more: 6 + 32 + 6 = 44
        assertTrue(reg.validRegenAddress(bytes("regen1qpzry9x8gf2tvdw0s3jn54khce6mua7lqpzry9")));
    }

    function test_badRegenAddressReverts() public {
        vm.expectRevert(RegenRegistry.BadRegenAddress.selector);
        reg.register("IMDO", "regen1short", beneficiary);
    }

    function testFuzz_randomBytesNeverPassAsRegenAddressUnlessCharsetHolds(bytes memory s) public view {
        bool ok = reg.validRegenAddress(s);
        if (ok) {
            assertEq(s.length, 44);
            for (uint256 i = 6; i < 44; ++i) {
                bytes1 c = s[i];
                bool lower = c >= 0x61 && c <= 0x7A && c != 0x62 && c != 0x69 && c != 0x6F;
                bool digit = c >= 0x30 && c <= 0x39 && c != 0x31;
                assertTrue(lower || digit);
            }
        }
    }

    function _repeat(string memory s, uint256 n) private pure returns (string memory out) {
        for (uint256 i; i < n; ++i) {
            out = string.concat(out, s);
        }
    }
}
