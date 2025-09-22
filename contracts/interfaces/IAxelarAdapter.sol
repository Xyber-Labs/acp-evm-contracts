// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

struct GasInfo {
    uint64 gasEstimationType;
    uint64 l1FeeScalar;
    uint128 axelarBaseFee;
    uint128 relativeGasPrice;
    uint128 relativeBlobBaseFee;
    uint128 expressFee;
}

interface IAxelarAdapter {

    event ContractCall(
        address indexed sender,
        string destinationChain,
        string destinationContractAddress,
        bytes32 indexed payloadHash,
        bytes payload
    );

    event GasPaidForContractCall(
        address indexed sourceAddress,
        string destinationChain,
        string destinationAddress,
        bytes32 indexed payloadHash,
        address gasToken,
        uint256 gasFeeAmount,
        address refundAddress
    );

    function payGas(
        address sender,
        string calldata destinationChain,
        string calldata destinationAddress,
        bytes calldata payload,
        uint256 executionGasLimit,
        bool estimateOnChain,
        address refundAddress,
        bytes calldata params
    ) external payable;

    function callContract(
        string calldata destinationChain,
        string calldata destinationContractAddress,
        bytes calldata payload
    ) external;

    function validateContractCall(
        bytes32 commandId,
        string calldata sourceChain,
        string calldata sourceAddress,
        bytes32 payloadHash
    ) external returns (bool);

    function isCommandExecuted(bytes32 commandId) external view returns (bool);

    function isContractCallApproved(
        bytes32 commandId,
        string calldata sourceChain,
        string calldata sourceAddress,
        address contractAddress,
        bytes32 payloadHash
    ) external view returns (bool);

    function gasCollector() external returns (address);

    function estimateGasFee(
        string calldata destinationChain,
        string calldata destinationAddress,
        bytes calldata payload,
        uint256 executionGasLimit,
        bytes calldata params
    ) external view returns (uint256 gasEstimate);

    function messageToCommandId(string calldata sourceChain, string calldata messageId) external pure returns (bytes32);
}