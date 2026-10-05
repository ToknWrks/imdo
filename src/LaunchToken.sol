// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title LaunchToken ($ADAM)
/// @notice Plain fixed-supply ERC-20. 1,000,000,000 ADAM (18 decimals) minted once to the deployer.
/// @dev No owner, no mint, no pause, no blocklist, no fee, no upgrade path. Every fee in the ADAM system
/// is charged in ETH by the Uniswap v4 hook (AdamHook), never by the token, so transfers always move
/// exactly the requested amount.
/// @custom:x https://x.com/IaMaDamIMD
contract LaunchToken is ERC20 {
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000e18;

    constructor() ERC20("ADAM", "ADAM") {
        _mint(msg.sender, TOTAL_SUPPLY);
    }
}
