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
/// @dev The treasury and this contract name each other in immutables, so the treasury is deployed with this
///      contract's address predicted from the deployer's next nonce and this contract is deployed right after it (the
///      deploy script does both and checks the pair). The constructor refuses a treasury or bridge with no code, so a
///      mispredicted address fails at deployment instead of leaving a seat nothing can pull from, and `forward()`
///      cannot later revert on the call to the treasury (Solidity checks for code before a call that returns nothing).
///      `minGasLimit` is the gas the bridge grants the delivery on Base: too little and every delivery needs a manual
///      replay there (nothing is lost), too much and the L1 portal refuses the deposit and `forward()` reverts for
///      good; so it is bounded. The bridge delivers ETH to the receiver with empty calldata; the receiver forwards it to
///      the router under its own project id. `_extraData` is informational only and is left empty. If the treasury has
///      nothing owed, `forward()` still bridges whatever this contract holds (ETH sent here directly, or left from an
///      earlier pull whose bridge call was out of gas), so nothing can be stranded.
contract OffsetsForwarder {
    uint32 public constant MIN_GAS_LIMIT = 100_000;
    uint32 public constant MAX_GAS_LIMIT = 1_000_000;

    IOffsetsSource public immutable treasury;
    IL1StandardBridge public immutable bridge;
    address public immutable receiverOnBase;
    uint32 public immutable minGasLimit;

    error ZeroAddress();
    error NoCode(address at);
    error BadGasLimit(uint32 minGasLimit);
    error NothingToForward();

    event Forwarded(uint256 amount);

    constructor(IOffsetsSource treasury_, IL1StandardBridge bridge_, address receiverOnBase_, uint32 minGasLimit_) {
        if (address(treasury_) == address(0) || address(bridge_) == address(0) || receiverOnBase_ == address(0)) {
            revert ZeroAddress();
        }
        if (address(treasury_).code.length == 0) revert NoCode(address(treasury_));
        if (address(bridge_).code.length == 0) revert NoCode(address(bridge_));
        if (minGasLimit_ < MIN_GAS_LIMIT || minGasLimit_ > MAX_GAS_LIMIT) revert BadGasLimit(minGasLimit_);
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
