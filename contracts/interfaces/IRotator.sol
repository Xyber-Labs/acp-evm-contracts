// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

interface IRotator {
    function currentRound(uint256 chainID) external view returns (uint256);
    
    function dropAgent(
        uint256 chainID,
        address agent
    ) external;
}
