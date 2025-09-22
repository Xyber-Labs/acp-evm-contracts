// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IPointDistributor {
    function distributePointRewards(
        address[] calldata transmitters, 
        address[] calldata executors,
        uint256 feeAmount,
        uint256 srcChainId,
        uint256 destChainId
    ) external;
}