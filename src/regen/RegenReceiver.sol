// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface IRegenRouterDeposit {
    function deposit(uint256 projectId) external payable;
    function projectExists(uint256 projectId) external view returns (bool);
}

/// @title RegenReceiver
/// @notice One per project, at an address known before it exists. The canonical Base bridge delivers ETH to an address
///         and drops any data attached, so the project's identity has to live in the address itself: a receiver only
///         ever forwards what it holds to the router under its own project id. Anyone may call `forward()`.
/// @dev `receive()` does nothing but accept, so the bridge's finalisation call succeeds on minimal gas; forwarding is a
///      separate permissionless step. No owner, no other function.
contract RegenReceiver {
    IRegenRouterDeposit public immutable router;
    uint256 public immutable projectId;

    error NothingToForward();

    event Forwarded(uint256 indexed projectId, uint256 amount);

    constructor(IRegenRouterDeposit router_, uint256 projectId_) {
        router = router_;
        projectId = projectId_;
    }

    receive() external payable {}

    function forward() external {
        uint256 amount = address(this).balance;
        if (amount == 0) revert NothingToForward();
        router.deposit{value: amount}(projectId);
        emit Forwarded(projectId, amount);
    }
}

/// @title RegenReceiverFactory
/// @notice Deterministic receivers: `predict(projectId)` is the address a forwarder on Ethereum may be pointed at before
///         `deploy(projectId)` has been called by anyone. Salt = project id; the init code is fixed by this factory and
///         the router it was built for, so the prediction cannot be redirected.
contract RegenReceiverFactory {
    IRegenRouterDeposit public immutable router;

    error AlreadyDeployed(address receiver);
    error UnknownProject(uint256 projectId);

    event ReceiverDeployed(uint256 indexed projectId, address receiver);

    constructor(IRegenRouterDeposit router_) {
        router = router_;
    }

    function predict(uint256 projectId) public view returns (address) {
        bytes32 initHash = keccak256(abi.encodePacked(type(RegenReceiver).creationCode, abi.encode(router, projectId)));
        return address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), bytes32(projectId), initHash))))
        );
    }

    /// @notice Deploy the receiver for a registered project. ETH sent to an unregistered id's predicted address would
    ///         belong to whoever registers that id next, so the project must exist first.
    function deploy(uint256 projectId) external returns (address receiver) {
        if (!router.projectExists(projectId)) revert UnknownProject(projectId);
        address predicted = predict(projectId);
        if (predicted.code.length != 0) revert AlreadyDeployed(predicted);
        receiver = address(new RegenReceiver{salt: bytes32(projectId)}(router, projectId));
        assert(receiver == predicted);
        emit ReceiverDeployed(projectId, receiver);
    }
}
