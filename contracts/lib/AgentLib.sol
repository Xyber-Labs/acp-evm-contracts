// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title  Library for agent management
/// @notice This library provides structures to manage agents
library AgentLib {
    /// @notice Agent types
    /// @notice NON-AUTHORIZED - default state
    /// @notice DEFAULT - default agent, which signs operations
    /// @notice SUPER - agent, which approves execution
    enum AgentType {
        NON_AUTHORIZED,
        DEFAULT,
        SUPER
    }

    /// @notice Agent statuses
    /// @notice NON-AUTHORIZED - default state
    /// @notice PARTICIPANT - is agent active in current round
    /// @notice PAUSED      - is agent paused in current round
    /// @notice BANNED      - is agent banned from proposal execution
    enum AgentStatus {
        NON_AUTHORIZED,
        PARTICIPANT,
        PAUSED,
        BANNED
    }

    /// @notice Agent info
    /// @notice AgentType   - Agent type
    /// @notice AgentStatus - Agent status
    /// @notice chainID     - Chain ID of the network in which the agent operates
    struct Agent {
        AgentType   agentType;
        AgentStatus status;
        uint256     chainID;
    }
}
