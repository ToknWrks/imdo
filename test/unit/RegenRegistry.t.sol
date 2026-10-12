// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {RegenRegistry} from "../../src/regen/RegenRegistry.sol";

contract RegenRegistryTest is Test {
    RegenRegistry internal reg;
    string internal constant REGEN = "regen183ht37fsp2fhnq3gneyjycp08c3ju4xnvxnvan";
    /// @dev Another address with a valid checksum, made for the test (data 0,7,14,…).
    string internal constant REGEN2 = "regen1r23clxd5mzfsh79vn6pg0kaytjeq8w4usu4zh8";
    address internal beneficiary = makeAddr("imdo-safe");

    function setUp() public {
        reg = new RegenRegistry("", "", address(0));
    }

    function test_theFirstProjectCanBeRegisteredAtCreation() public {
        vm.expectEmit(true, true, false, true);
        emit RegenRegistry.ProjectRegistered(1, beneficiary, "IMDO", REGEN, address(this));
        RegenRegistry r = new RegenRegistry("IMDO", REGEN, beneficiary);
        assertEq(r.count(), 1);
        assertEq(r.project(1).name, "IMDO");
        assertEq(r.register("Second", REGEN2, beneficiary), 2);
        vm.expectRevert(RegenRegistry.BadRegenAddress.selector);
        new RegenRegistry("IMDO", "regen183ht37fsp2fhnq3gneyjycp08c3ju4xnvxnvaq", beneficiary);
        vm.expectRevert(RegenRegistry.ZeroAddress.selector);
        new RegenRegistry("IMDO", REGEN, address(0));
        assertEq(reg.count(), 0); // an empty name registers nothing
    }

    function test_aHighByteIsRefusedNotAPanic() public view {
        bytes memory s = bytes(REGEN);
        s[20] = 0xC3; // a UTF-8 lead byte pasted into the address
        assertFalse(reg.validRegenAddress(s));
        s[20] = 0x7F; // DEL
        assertFalse(reg.validRegenAddress(s));
        s[20] = 0xFF;
        assertFalse(reg.validRegenAddress(s));
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
        assertEq(reg.idByName(reg.nameKey("IMDO")), 1);
        assertEq(reg.register("Second", REGEN2, beneficiary), 2);
    }

    function test_unknownProjectReverts() public {
        vm.expectRevert(abi.encodeWithSelector(RegenRegistry.UnknownProject.selector, 1));
        reg.project(1);
    }

    function test_nameIsUniqueOnItsKey() public {
        reg.register("IM DO", REGEN, beneficiary);
        vm.expectRevert(abi.encodeWithSelector(RegenRegistry.NameTaken.selector, 1));
        reg.register("IM DO", REGEN, address(0xBEEF));
        vm.expectRevert(abi.encodeWithSelector(RegenRegistry.NameTaken.selector, 1));
        reg.register("im do", REGEN, address(0xBEEF));
        vm.expectRevert(abi.encodeWithSelector(RegenRegistry.NameTaken.selector, 1));
        reg.register("Im  Do", REGEN, address(0xBEEF));
        vm.expectRevert(abi.encodeWithSelector(RegenRegistry.NameTaken.selector, 1));
        reg.register("IM    DO", REGEN, address(0xBEEF));
        assertEq(reg.register("IMDO", REGEN, beneficiary), 2); // a different name
        assertEq(reg.register("IM-DO", REGEN, beneficiary), 3);
        assertEq(reg.project(1).name, "IM DO"); // stored as registered
    }

    function test_nameKeyLowersAndCollapsesSpacesOnly() public view {
        assertEq(reg.nameKey("IMDO"), reg.nameKey("imdo"));
        assertEq(reg.nameKey("IMDO"), reg.nameKey("Imdo"));
        assertEq(reg.nameKey("Regen  City"), reg.nameKey("regen city"));
        assertEq(reg.nameKey("a   b   c"), keccak256("a b c"));
        assertEq(reg.nameKey("ABC xyz 09!"), keccak256("abc xyz 09!"));
        assertTrue(reg.nameKey("IMDO") != reg.nameKey("IMD0"));
        assertTrue(reg.nameKey("IMDO") != reg.nameKey("IM DO"));
        assertTrue(reg.nameKey("IMDO (official)") != reg.nameKey("IMDO"));
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
        assertTrue(reg.validRegenAddress(bytes(REGEN2)));
        assertFalse(reg.validRegenAddress(bytes("regen183ht37fsp2fhnq3gneyjycp08c3ju4xnvxnva"))); // 43
        assertFalse(reg.validRegenAddress(bytes("regen183ht37fsp2fhnq3gneyjycp08c3ju4xnvxnvann"))); // 45
        assertFalse(reg.validRegenAddress(bytes("cosmos83ht37fsp2fhnq3gneyjycp08c3ju4xnvxnvan"))); // prefix
        assertFalse(reg.validRegenAddress(bytes("REGEN183HT37FSP2FHNQ3GNEYJYCP08C3JU4XNVXNVAN"))); // case
        assertFalse(reg.validRegenAddress(bytes("regen1b3ht37fsp2fhnq3gneyjycp08c3ju4xnvxnvan"))); // 'b'
        assertFalse(reg.validRegenAddress(bytes("regen1i3ht37fsp2fhnq3gneyjycp08c3ju4xnvxnvan"))); // 'i'
        assertFalse(reg.validRegenAddress(bytes("regen1o3ht37fsp2fhnq3gneyjycp08c3ju4xnvxnvan"))); // 'o'
        assertFalse(reg.validRegenAddress(bytes("regen113ht37fsp2fhnq3gneyjycp08c3ju4xnvxnvan"))); // '1'
        assertFalse(reg.validRegenAddress(bytes("regen1 3ht37fsp2fhnq3gneyjycp08c3ju4xnvxnvan"))); // space
        assertFalse(reg.validRegenAddress(bytes(unicode"regen1ö3ht37fsp2fhnq3gneyjycp08c3ju4xnvxnvan"))); // high byte
    }

    function test_checksumIsVerified() public view {
        // the charset alone is not an address
        assertFalse(reg.validRegenAddress(bytes("regen1qpzry9x8gf2tvdw0s3jn54khce6mua7lqpzry9")));
        // one character wrong at the end
        assertFalse(reg.validRegenAddress(bytes("regen183ht37fsp2fhnq3gneyjycp08c3ju4xnvxnvaq")));
        // two characters swapped near the start
        assertFalse(reg.validRegenAddress(bytes("regen138ht37fsp2fhnq3gneyjycp08c3ju4xnvxnvan")));
        // the checksum of another address
        assertFalse(reg.validRegenAddress(bytes("regen183ht37fsp2fhnq3gneyjycp08c3ju4xnvu4zh8")));
    }

    function test_badRegenAddressReverts() public {
        vm.expectRevert(RegenRegistry.BadRegenAddress.selector);
        reg.register("IMDO", "regen1short", beneficiary);
        vm.expectRevert(RegenRegistry.BadRegenAddress.selector);
        reg.register("IMDO", "regen183ht37fsp2fhnq3gneyjycp08c3ju4xnvxnvaq", beneficiary); // a typo
    }

    function testFuzz_aMutatedAddressNeverVerifies(uint8 at, uint8 to) public view {
        at = uint8(bound(at, 6, 43));
        bytes memory s = bytes(REGEN);
        bytes memory cs = "qpzry9x8gf2tvdw0s3jn54khce6mua7l";
        bytes1 c = cs[to % 32];
        vm.assume(c != s[at]);
        s[at] = c;
        assertFalse(reg.validRegenAddress(s));
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
