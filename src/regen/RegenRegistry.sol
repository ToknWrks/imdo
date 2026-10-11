// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title RegenRegistry
/// @notice Names the projects whose fees the retirement router retires credits for. Anyone registers; nothing about a
///         project changes afterwards. The router writes these fields into every retirement, so they are validated here,
///         once, against the retirement message grammar (v1): a message assembled from a registered project can never be
///         malformed.
/// @dev Grammar v1 field rules (frozen 2026-10-07 with Regen):
///        name   1..64 bytes, printable ASCII 0x20..0x7E, no '|', no leading or trailing space
///        regen  44 chars, "regen1" then 38 of the bech32 charset [02-9ac-hj-np-z] (lowercase)
///      Names are unique, first come first served: a second "IMDO" would carry a different beneficiary and confuse every
///      reader of the retirement log. No owner, no update, no delete.
contract RegenRegistry {
    struct Project {
        address beneficiary;
        string name;
        string regenAddress;
    }

    uint256 public count;
    mapping(uint256 id => Project) private _projects;
    mapping(bytes32 nameHash => uint256 id) public idByName;

    error ZeroAddress();
    error BadName();
    error NameTaken(uint256 id);
    error BadRegenAddress();
    error UnknownProject(uint256 id);

    event ProjectRegistered(
        uint256 indexed id, address indexed beneficiary, string name, string regenAddress, address registrant
    );

    /// @notice Register a project. Returns its id (1-based); id 0 is never a project.
    function register(string calldata name, string calldata regenAddress, address beneficiary)
        external
        returns (uint256 id)
    {
        if (beneficiary == address(0)) revert ZeroAddress();
        if (!validName(bytes(name))) revert BadName();
        if (!validRegenAddress(bytes(regenAddress))) revert BadRegenAddress();
        bytes32 h = keccak256(bytes(name));
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

    /// @dev "regen1" + 38 bech32 data characters. The checksum is not verified on chain; the Regen side verifies the
    ///      address before registration is final (it is also the only party that can land credits on it).
    function validRegenAddress(bytes memory s) public pure returns (bool) {
        if (s.length != 44) return false;
        bytes6 prefix;
        assembly ("memory-safe") {
            prefix := mload(add(s, 32))
        }
        if (prefix != bytes6("regen1")) return false;
        for (uint256 i = 6; i < 44; ++i) {
            if (!_bech32Char(s[i])) return false;
        }
        return true;
    }

    /// @dev bech32 charset "qpzry9x8gf2tvdw0s3jn54khce6mua7l": lowercase a-z without b, i, o; digits without 1.
    function _bech32Char(bytes1 c) private pure returns (bool) {
        if (c >= 0x61 && c <= 0x7A) return c != 0x62 && c != 0x69 && c != 0x6F;
        if (c >= 0x30 && c <= 0x39) return c != 0x31;
        return false;
    }
}
