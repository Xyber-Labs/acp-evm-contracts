// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

contract AgentManagerMock {
    function getAgentChain(
        address agent
    ) external view returns (uint256) { 
        return 1; 
    }
}