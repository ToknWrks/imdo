// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev Only the Permit2 allowance path used by the real PositionManager; signature paths are not mocked.
contract Permit2Mock {
    struct Approval {
        uint160 amount;
        uint48 expiration;
    }
    mapping(address => mapping(address => mapping(address => Approval))) public allowance;

    function approve(address token, address spender, uint160 amount, uint48 expiration) external {
        allowance[msg.sender][token][spender] = Approval(amount, expiration);
    }

    function transferFrom(address from, address to, uint160 amount, address token) external {
        Approval storage a = allowance[from][token][msg.sender];
        require(a.expiration >= block.timestamp && a.amount >= amount, "permit2 allowance");
        a.amount -= amount;
        require(IERC20(token).transferFrom(from, to, amount));
    }
}
