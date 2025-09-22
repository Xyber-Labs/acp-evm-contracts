// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

interface IExecutorLottery {
    function runLottery(
        bytes32 msgHashPrefixed,
        uint256 chainID,
        bytes memory payload
    ) external returns (address[] memory, uint256);

    function currentExecutorAgent(
        bytes32 msgHashPrefixed
    ) external view returns (address);

    function currentExecutionData(
        bytes32 msgHashPrefixed
    ) external view returns (address agent, uint256 startTime, uint256 endTime);
}
