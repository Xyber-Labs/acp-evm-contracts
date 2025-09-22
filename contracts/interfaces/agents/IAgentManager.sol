// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {AgentLib} from "../../lib/AgentLib.sol";

interface IAgentManager {
    function allAgents(
        address owner
    ) external view returns (AgentLib.Agent memory agent);

    function getStatus(
        address owner
    ) external view returns (AgentLib.AgentStatus);

    function activeSupersAddr(
        uint256 chainID
    ) external view returns (address[] memory);

    function activeSupersLen(
        uint256 chainID
    ) external view returns (uint256);

    function getType(address owner) external view returns (AgentLib.AgentType);

    function getAgentChain(address owner) external view returns (uint256);

    function getCurrentParticipants(uint256 chainID) external view returns (address[] memory);
    
    function getFilteredParticipants(
        uint256 chainID
    ) external view returns (address[] memory);

    function getCurrentParticipantsLen(uint256 chainID) external view returns (uint256);

    function getParticipantByIndex(uint256 chainID, uint256 index) external view returns (address);

    function getCandidates(uint256 chainID, uint256 round) external view returns (address[] memory);

    function getFilteredCandidates(uint256 chainID, uint256 round) external view returns (address[] memory);

    function activateAgents(
        address[] calldata agents
    ) external;

    function deactivateAgents(
        address[] calldata agents
    ) external;

    function setParticipants(
        uint256 chainID,
        uint256 round,
        address[] memory participants
    ) external;

    function getCandidateStatuses(
        uint256 chainID,
        uint256 round
    ) external view returns (AgentLib.AgentStatus[] memory statuses);

    function registerAgent(
        address masterKey,
        AgentLib.Agent calldata agent
    ) external;

    function getForceDroppedAgents(
        uint256 chainID,
        uint256 round
    ) external view returns (address[] memory);

    function setForceDroppedAgent(
        uint256 chainID,
        uint256 round,
        address agent
    ) external;

    function getRoundAgentData(
        uint256 chainID,
        uint256 round
    ) external view returns (
        address[] memory candidates,
        address[] memory participants
    );
}
