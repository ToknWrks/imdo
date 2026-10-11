// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface IOffsetsSource {
    function payOffsets() external;
}

/// @dev The OP Stack L1StandardBridge (Base: 0x3154Cf16ccdb4C6d922629664174b904d80F2C35 on Ethereum mainnet).
interface IL1StandardBridge {
    function depositETHTo(address _to, uint32 _minGasLimit, bytes calldata _extraData) external payable;
}

/// @title OffsetsForwarder
/// @notice Stands in the treasury's `offsetsSafe` seat on Ethereum. Anyone calls `forward()`: it pulls the Offsets leg
///         from the treasury (the treasury pays only its `offsetsSafe`, which is this contract) and sends everything it
///         holds through the canonical bridge to the project's receiver on Base. The receiver's address is fixed at
///         construction (predicted by the receiver factory, so the receiver need not exist yet), the bridge is the
///         canonical one, and there is no owner, pause or other path for the ETH.
/// @dev The bridge delivers ETH to the receiver with empty calldata; the receiver forwards it to the router under its own
///      project id. `_extraData` is informational only and is left empty. If the treasury has nothing owed, `forward()`
///      still bridges whatever this contract holds (ETH sent here directly, or left from an earlier pull whose bridge
///      call was out of gas), so nothing can be stranded.
contract OffsetsForwarder {
    IOffsetsSource public immutable treasury;
    IL1StandardBridge public immutable bridge;
    address public immutable receiverOnBase;
    uint32 public immutable minGasLimit;

    error ZeroAddress();
    error NothingToForward();

    event Forwarded(uint256 amount);

    constructor(IOffsetsSource treasury_, IL1StandardBridge bridge_, address receiverOnBase_, uint32 minGasLimit_) {
        if (address(treasury_) == address(0) || address(bridge_) == address(0) || receiverOnBase_ == address(0)) {
            revert ZeroAddress();
        }
        treasury = treasury_;
        bridge = bridge_;
        receiverOnBase = receiverOnBase_;
        minGasLimit = minGasLimit_;
    }

    receive() external payable {}

    function forward() external {
        // A pull with nothing owed reverts in the treasury; that is not a reason to strand ETH already here.
        try treasury.payOffsets() {} catch {}
        uint256 amount = address(this).balance;
        if (amount == 0) revert NothingToForward();
        bridge.depositETHTo{value: amount}(receiverOnBase, minGasLimit, "");
        emit Forwarded(amount);
    }
}
