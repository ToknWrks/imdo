// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title RegenRegistry
/// @notice Names the projects whose fees the retirement router retires credits for. Anyone registers; nothing about a
///         project changes afterwards. The router writes these fields into every retirement, so they are validated here,
///         once, against the retirement message grammar (v1): a message assembled from a registered project can never be
///         malformed.
/// @dev Grammar v1 field rules (frozen 2026-10-07 with Regen):
///        name   1..64 bytes, printable ASCII 0x20..0x7E, no '|', no leading or trailing space
///        regen  44 chars, "regen1" then 38 of the bech32 charset [02-9ac-hj-np-z] (lowercase), bech32 checksum valid
///      Names are unique, first come first served: a second "IMDO" would carry a different beneficiary and confuse every
///      reader of the retirement log. Uniqueness is judged on the name's KEY (`nameKey`: ASCII lower-cased, runs of
///      spaces collapsed to one), so "imdo", "Imdo" and "IM  DO" are the same name as "IMDO"; the name is stored and
///      written into retirements exactly as registered. No owner, no update, no delete: a project's name is taken for
///      good by whoever registers it first, so the FIRST project is registered by the constructor, in the registry's
///      own creation transaction (the rail's deploy script does this; nobody can get in between), and checks its regen
///      address before sending. The checksum is verified on chain, so a mistyped address cannot be registered; an
///      address that is valid but not the project's own still can, and would then carry every retirement for that id
///      (nothing can correct it).
contract RegenRegistry {
    struct Project {
        address beneficiary;
        string name;
        string regenAddress;
    }

    uint256 public count;
    mapping(uint256 id => Project) private _projects;
    /// @notice Project id by `nameKey(name)`.
    mapping(bytes32 nameKey => uint256 id) public idByName;

    /// @dev bech32 generator polynomial (BIP-173).
    uint256 private constant GEN0 = 0x3b6a57b2;
    uint256 private constant GEN1 = 0x26508e6d;
    uint256 private constant GEN2 = 0x1ea119fa;
    uint256 private constant GEN3 = 0x3d4233dd;
    uint256 private constant GEN4 = 0x2a1462b3;
    /// @dev Character value by ASCII code for the charset "qpzry9x8gf2tvdw0s3jn54khce6mua7l"; 0xff = not in it.
    bytes private constant CHARSET_VALUE =
        hex"ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff0fff0a1115141a1e0705ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff1dff180d19090817ff12161f1b13ff010003100b1c0c0e060402ffffffffff";

    error ZeroAddress();
    error BadName();
    error NameTaken(uint256 id);
    error BadRegenAddress();
    error UnknownProject(uint256 id);

    event ProjectRegistered(
        uint256 indexed id, address indexed beneficiary, string name, string regenAddress, address registrant
    );

    /// @param name The first project, registered as id 1 in this very transaction; empty = none.
    constructor(string memory name, string memory regenAddress, address beneficiary) {
        if (bytes(name).length != 0) _register(name, regenAddress, beneficiary);
    }

    /// @notice Register a project. Returns its id (1-based); id 0 is never a project.
    function register(string calldata name, string calldata regenAddress, address beneficiary)
        external
        returns (uint256 id)
    {
        return _register(name, regenAddress, beneficiary);
    }

    function _register(string memory name, string memory regenAddress, address beneficiary)
        private
        returns (uint256 id)
    {
        if (beneficiary == address(0)) revert ZeroAddress();
        if (!validName(bytes(name))) revert BadName();
        if (!validRegenAddress(bytes(regenAddress))) revert BadRegenAddress();
        bytes32 h = nameKey(bytes(name));
        if (idByName[h] != 0) revert NameTaken(idByName[h]);
        id = ++count;
        idByName[h] = id;
        _projects[id] = Project({beneficiary: beneficiary, name: name, regenAddress: regenAddress});
        emit ProjectRegistered(id, beneficiary, name, regenAddress, msg.sender);
    }

    function project(uint256 id) external view returns (Project memory p) {
        p = _projects[id];
        if (p.beneficiary == address(0)) revert UnknownProject(id);
    }

    function exists(uint256 id) external view returns (bool) {
        return _projects[id].beneficiary != address(0);
    }

    /// @dev 1..64 bytes of printable ASCII, no pipe, no leading or trailing space.
    function validName(bytes memory s) public pure returns (bool) {
        uint256 n = s.length;
        if (n == 0 || n > 64) return false;
        if (s[0] == 0x20 || s[n - 1] == 0x20) return false;
        for (uint256 i; i < n; ++i) {
            bytes1 c = s[i];
            if (c < 0x20 || c > 0x7E || c == 0x7C) return false;
        }
        return true;
    }

    /// @notice The key two names are compared on: ASCII letters lower-cased, every run of spaces one space.
    function nameKey(bytes memory s) public pure returns (bytes32) {
        bytes memory k = new bytes(s.length);
        uint256 n;
        bool space;
        for (uint256 i; i < s.length; ++i) {
            bytes1 c = s[i];
            if (c == 0x20) {
                if (space) continue;
                space = true;
            } else {
                space = false;
                if (c >= 0x41 && c <= 0x5A) c = bytes1(uint8(c) + 32);
            }
            k[n++] = c;
        }
        assembly ("memory-safe") {
            mstore(k, n)
        }
        return keccak256(k);
    }

    /// @dev "regen1" + 38 bech32 data characters whose bech32 checksum (BIP-173, constant 1) verifies.
    function validRegenAddress(bytes memory s) public pure returns (bool) {
        if (s.length != 44) return false;
        bytes6 prefix;
        assembly ("memory-safe") {
            prefix := mload(add(s, 32))
        }
        if (prefix != bytes6("regen1")) return false;
        // hrp "regen" expanded: high bits, a zero, low bits; then the data part.
        uint256 chk = 1;
        for (uint256 i; i < 5; ++i) {
            chk = _polymodStep(chk) ^ (uint8(s[i]) >> 5);
        }
        chk = _polymodStep(chk);
        for (uint256 i; i < 5; ++i) {
            chk = _polymodStep(chk) ^ (uint8(s[i]) & 31);
        }
        for (uint256 i = 6; i < 44; ++i) {
            uint8 c = uint8(s[i]);
            if (c >= 0x80) return false;
            uint8 v = uint8(CHARSET_VALUE[c]);
            if (v == 0xff) return false;
            chk = _polymodStep(chk) ^ v;
        }
        return chk == 1;
    }

    function _polymodStep(uint256 pre) private pure returns (uint256 chk) {
        uint256 b = pre >> 25;
        chk = (pre & 0x1ffffff) << 5;
        if (b & 1 != 0) chk ^= GEN0;
        if (b & 2 != 0) chk ^= GEN1;
        if (b & 4 != 0) chk ^= GEN2;
        if (b & 8 != 0) chk ^= GEN3;
        if (b & 16 != 0) chk ^= GEN4;
    }
}
