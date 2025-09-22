// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

struct TransmitterParams {
    uint256 blockFinalizationOption;
    uint256 customGasLimit;
}

interface IEndpoint {
    function propose(
        uint256 destChainID,
        bytes32 selectorSlot,
        bytes calldata transmitterParams,
        bytes calldata destAddress,
        bytes calldata payload
    ) external payable;

    function MIN_RATE() external returns (uint256);
}
