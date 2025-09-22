// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable, AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {AgentLib} from "../lib/AgentLib.sol";
import {IRotator} from "../interfaces/IRotator.sol";
import {IChainInfo} from "../interfaces/IChainInfo.sol";
import {IRewards} from "../interfaces/staking/IRewards.sol";
import {IPingSystem} from "../interfaces/agents/IPingSystem.sol";

/**
 * @title  Agent Manager
 * @notice Smart contract for managing agents in ACP
 */
contract AgentManager is
    Initializable,
    UUPSUpgradeable,
    AccessControlUpgradeable
{
    // ==============================
    //       ERRORS & EVENTS
    // ==============================
    error AgentManager__ZeroAddress();
    error AgentManager__InvalidType();
    error AgentManager__AlreadyDeactivated(address owner);
    error AgentManager__AgentNotRegistered(address agent);
    error AgentManager__AlreadyParticipant(address agent);
    error AgentManager__AlreadyCondidate(address agent);

    event AgentAdded(address indexed owner, AgentLib.Agent newAgent);
    event AgentLeft(uint256 indexed chainID, address indexed agent);
    event AgentStatusChanged(
        address indexed agent,
        AgentLib.AgentStatus oldStatus,
        AgentLib.AgentStatus newStatus
    );
    event ParticipantsSet(
        uint256 chainID,
        uint256 round,
        uint256 participantsLen
    );

    // ==============================
    //      ROLES & CONSTANTS
    // ==============================
    bytes32 public constant RECEPTION = keccak256("RECEPTION");
    bytes32 public constant ROTATOR   = keccak256("ROTATOR");
    bytes32 public constant ADMIN     = keccak256("ADMIN");

    uint256 public constant DEF_RATE = 5000;

    // ==============================
    //           STORAGE
    // ==============================

    /**
     * @notice This AgentRoundData struct is created 
     * for storing data for particular round
     * @param round Next round number (next epoch)
     * @param candidates Candidates to be activated in next round
     * Candidates are raw and stored time-independently 
     * After that, to become a participant agent must be filtered
     * by staking requirements and ping system
     * @param participants Candidates finally included in active agent list 
     * after turn round operation by rotator contract
     */
    struct AgentRoundData {
        address[] candidates;
        address[] participants;
        address[] forceDropped;
    }

    /// @notice Address of the chain info contract
    address public chainInfo;

    /// @notice Address of the rotator contract
    address public rotator;

    /// @notice Rewards contract
    address public rewards;

    /// @notice PingSystem contract
    address public pingSystem;

    /// @notice Mapping of round data for each chain and round
    mapping(uint256 chainID => mapping(uint256 round => AgentRoundData)) agentRoundData;

    /// @notice Number of active super agents per chain
    mapping(uint256 chainID => uint256) public activeSupers;

    /// @notice Mapping of agent addresses to agent data
    mapping(address agent => AgentLib.Agent) public allAgents;

    mapping(uint256 chainID => address[]) public activeSupersNew;

    // ==============================
    //          FUNCTIONS
    // ==============================

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize
    /// @param initAddr[0] - Admin address
    /// @param initAddr[1] - AgentRegistrator address
    function initialize(address[] calldata initAddr) public initializer {
        __UUPSUpgradeable_init();
        __AccessControl_init();
        _setRoleAdmin(ADMIN, ADMIN);
        _setRoleAdmin(RECEPTION, ADMIN);
        _setRoleAdmin(ROTATOR, ADMIN);
        _grantRole(ADMIN, initAddr[0]);
        _grantRole(RECEPTION, initAddr[1]);
    }

    /**
     * @notice Registers a new agent
     * @param masterKey Agent address
     * @param agent Agent data
     */
    function registerAgent(
        address masterKey,
        AgentLib.Agent calldata agent
    ) external onlyRole(RECEPTION) {
        _addAgent(masterKey, agent);
    }

    /**
     * @notice Registers a batch of new agents
     * @param masterKeys List of agents addresses
     * @param agents List of agent data
     */
    function registerAgentBatch(
        address[] calldata masterKeys,
        AgentLib.Agent[] calldata agents
    ) external onlyRole(RECEPTION) {
        uint256 len = agents.length;

        for (uint256 i = 0; i < len; i++) {
            _addAgent(masterKeys[i], agents[i]);
        }
    }

    /**
     * @notice Allows an agent to become a candidate for the next round
     */
    function becomeCandidate() external {
        address masterKey = msg.sender;
        AgentLib.Agent storage agent = allAgents[masterKey];

        if (agent.chainID == 0) {
            revert AgentManager__AgentNotRegistered(masterKey);
        }

        uint256 currentRound = IRotator(rotator).currentRound(agent.chainID);
        AgentRoundData storage agentData = agentRoundData[agent.chainID][currentRound];
        (bool isParticipant, ) = _arrayContains(agentData.participants, masterKey);

        if (agent.status == AgentLib.AgentStatus.PARTICIPANT || isParticipant) {
            revert AgentManager__AlreadyParticipant(masterKey);
        }
        
        _addAgent(masterKey, agent);
    }

    /**
     * @notice Sets the participants for a given round and chain
     * @param chainID Chain ID of the network in which participants will operate
     * @param round Round number
     * @param participants List of participants addresses
     */
    function setParticipants(
        uint256 chainID,
        uint256 round,
        address[] memory participants
    ) external onlyRole(ROTATOR) {
        agentRoundData[chainID][round].participants = participants;

        emit ParticipantsSet(chainID, round, participants.length);
    }

    /**
     * @notice Activates agents for the given round
     * @param agents List of agent addresses to be activated
     */
    function activateAgents(
        address[] calldata agents
    ) external onlyRole(ROTATOR) {
        uint256 len = agents.length;
        for (uint256 i = 0; i < len; i++) {
            AgentLib.Agent storage agent = allAgents[agents[i]];
            
            if (agent.chainID == 0) {
                revert AgentManager__AgentNotRegistered(agents[i]);
            }

            AgentLib.AgentStatus oldStatus = agent.status;
            agent.status = AgentLib.AgentStatus.PARTICIPANT;

            if (agent.agentType == AgentLib.AgentType.SUPER) {
                activeSupersNew[agent.chainID].push(agents[i]);
            }

            emit AgentStatusChanged(
                agents[i],
                oldStatus,
                AgentLib.AgentStatus.PARTICIPANT
            );
        }
    }

    /**
     * @notice Deactivates agents for the given round
     * @param agents List of agent addresses to be deactivated
     */
    function deactivateAgents(
        address[] memory agents
    ) public onlyRole(ROTATOR) {
        uint256 len = agents.length;
        for (uint256 i = 0; i < len; i++) {
            AgentLib.Agent storage agent = allAgents[agents[i]];

            if (agent.chainID == 0) {
                revert AgentManager__AgentNotRegistered(agents[i]);
            }

            AgentLib.AgentStatus oldStatus = agent.status;
            agent.status = AgentLib.AgentStatus.PAUSED;

            if (allAgents[agents[i]].agentType == AgentLib.AgentType.SUPER) {
                _removeSuperAgent(agent.chainID, agents[i]);
            }

            emit AgentStatusChanged(
                agents[i],
                oldStatus,
                AgentLib.AgentStatus.PAUSED
            );
        }
    }

    /**
     * @notice Marks an agent as force dropped for a given chain and round
     * @param chainID Chain ID of the network in which agent operates
     * @param round Round number
     * @param agent Address of the agent being dropped
     */
    function setForceDroppedAgent(
        uint256 chainID,
        uint256 round,
        address agent
    ) external onlyRole(ROTATOR) {
        AgentRoundData storage agentData = agentRoundData[chainID][round];
        agentData.forceDropped.push(agent);
        
        address[] memory agents = new address[](1);
        agents[0] = agent;
        deactivateAgents(agents);

        emit AgentLeft(chainID, agent);
    }


    function _addAgent(address owner, AgentLib.Agent memory agent) private {
        bool isSuper = agent.agentType == AgentLib.AgentType.SUPER;

        // Enforce pause before turn round operation
        // super-agents are also NOT activated because 
        // they can only be approved by ADMIN
        agent.status = AgentLib.AgentStatus.PAUSED;

        if (isSuper) {
            _setupSuperConsensus(agent.chainID);
        } else {
            uint256 currentRound = IRotator(rotator).currentRound(agent.chainID);
            AgentRoundData storage agentData = agentRoundData[agent.chainID][currentRound + 1];
            
            (bool contains, ) = _arrayContains(agentData.candidates, owner);
            if (contains) {
                revert AgentManager__AlreadyCondidate(owner);
            }

            agentData.candidates.push(owner);
        }

        allAgents[owner] = agent;
        emit AgentAdded(owner, agent);
    }

    function _setupSuperConsensus(uint256 chainID) private {
        IChainInfo(chainInfo).changeSuperConsensusRate(chainID, DEF_RATE);
    }

    function _arrayContains(
        address[] memory array, address element
    ) internal pure returns (bool, uint256) {
        for (uint256 i = 0; i < array.length; ++i) {
            if (array[i] == element) {
                return (true, i);
            }
        }

        return (false, array.length);
    }

    function _removeSuperAgent(
        uint256 chainId,
        address agent
    ) private {
        address[] memory supersList = activeSupersNew[chainId];
        for (uint256 j = 0; j < supersList.length; j++) {
            if (supersList[j] == agent) {
                supersList[j] = supersList[supersList.length - 1];
                supersList[supersList.length - 1] = agent;
                break;
            }
        }
        activeSupersNew[chainId] = supersList;
        activeSupersNew[chainId].pop();
    }

    // ==============================
    //          GETTERS
    // ==============================

    /**
     * @notice Retrieves candidate and participant for a given round and chain
     * @param chainID Chain ID of the network
     * @param round The round number
     * @return candidates List of candidates addresses
     * @return participants List of participants' addresses
     */
    function getRoundAgentData(
        uint256 chainID,
        uint256 round
    ) external view returns (
        address[] memory candidates,
        address[] memory participants
    ) {
        AgentRoundData storage agentData = agentRoundData[chainID][round];
        return (
            agentData.candidates,
            agentData.participants
        );
    }

    /**
     * @notice Retrieves the list of candidates for a given chain and round
     * @param chainID Chain ID of the network
     * @param round The round number
     * @return List of candidate addresses
     */
    function getCandidates(
        uint256 chainID,
        uint256 round
    ) public view returns (address[] memory) {
        return agentRoundData[chainID][round].candidates;
    }
    
    /**
     * @notice Retrieves the list of active candidates with enough funds in their vaults
     * @param chainId Chain ID
     * @param round The round number
     * @return filteredCandidates List of filtered candidate addresses
     */
    function getFilteredCandidates(
        uint256 chainId,
        uint256 round
    ) external view returns (address[] memory filteredCandidates) {
        address[] memory candidates = getCandidates(chainId, round);
        uint256 len = candidates.length;
        
        IPingSystem pingSystemContract = IPingSystem(pingSystem);
        IRewards rewardsContract = IRewards(rewards);
        
        uint256 minStake = rewardsContract.minStake();
        address[] memory tempFilteredCandidates = new address[](len);
        uint256 count = 0;
        
        for (uint256 i = 0; i < len; ++i) {
            if (
                pingSystemContract.active(candidates[i]) &&
                rewardsContract.vaultBalance(chainId, candidates[i]) >= minStake &&
                rewardsContract.vaultSelfStake(chainId, candidates[i]) != 0
            ) {
                tempFilteredCandidates[count] = candidates[i];
                count++;
            }
        }

        filteredCandidates = new address[](count);
        for (uint256 i = 0; i < count; ++i) {
            filteredCandidates[i] = tempFilteredCandidates[i];
        }
    }

    /**
     * @notice Retrieves the status of each candidate in the specified round on the given chain
     * @param chainID Chain ID
     * @param round The round number
     * @return statuses A list of statuses corresponding to each candidate
     */
    function getCandidateStatuses(
        uint256 chainID,
        uint256 round
    ) external view returns (AgentLib.AgentStatus[] memory statuses) {
        address[] memory candidates = getCandidates(chainID, round);
        
        uint256 len = candidates.length;
        statuses = new AgentLib.AgentStatus[](len);

        for (uint256 i = 0; i < len; i++) {
            statuses[i] = allAgents[candidates[i]].status;
        }
    }

    /**
     * @notice Retrieves a list of participants in the current round for the specified chain
     * @param chainID Chain ID
     * @return A list of addresses of current participants
     */
    function getCurrentParticipants(
        uint256 chainID
    ) public view returns (address[] memory) {
        return agentRoundData[chainID][IRotator(rotator).currentRound(chainID)].participants;
    }

    function getFilteredParticipants(
        uint256 chainID
    ) public view returns (address[] memory) {
        return IPingSystem(pingSystem).activeOnly(
            agentRoundData[chainID][IRotator(rotator).currentRound(chainID)].participants
        );
    }

    /**
     * @notice Retrieves the number of participants in the current round for the specified chain
     * @param chainID Chain ID
     * @return The number of participants
     */
    function getCurrentParticipantsLen(uint256 chainID) external view returns (uint256) {
        return getCurrentParticipants(chainID).length;
    }

    /**
     * @notice Retrieves the address of a participant at a given index in the current round for the specified chain
     * @param chainID Chain ID
     * @param index The index of the participant
     * @return The address of the participant
     */
    function getParticipantByIndex(
        uint256 chainID, 
        uint256 index
    ) external view returns (address) {
        return agentRoundData[chainID][IRotator(rotator).currentRound(chainID)].participants[index];
    }

    /**
     * @notice Retrieves the status of a specific agent
     * @param owner The agent address
     * @return The status of the agent
     */
    function getStatus(
        address owner
    ) external view returns (AgentLib.AgentStatus) {
        return allAgents[owner].status;
    }


    /**
     * @notice Retrieves the type of a specific agent
     * @param owner The agent address
     * @return The type of the agent
     */
    function getType(address owner) external view returns (AgentLib.AgentType) {
        return allAgents[owner].agentType;
    }

    /**
     * @notice Retrieves the chain ID of the specified agent
     * @param owner The agent address
     * @return The chain ID of the network in which agent operates
     */
    function getAgentChain(address owner) external view returns (uint256) {
        return allAgents[owner].chainID;
    }

    /**
     * @notice Retrieves a list of agents that were forcefully dropped in the specified round on the given chain
     * @param chainID Chain ID
     * @param round The round number
     * @return A list of force-dropped agents addresses
     */
    function getForceDroppedAgents(
        uint256 chainID,
        uint256 round
    ) external view returns (address[] memory) {
        return agentRoundData[chainID][round].forceDropped;
    }

    /**
     * @notice Return set of super-agents on chain
     * @param chainID Chain ID
     */
    function activeSupersAddr(
        uint256 chainID
    ) external view returns (address[] memory) {
        return activeSupersNew[chainID];
    }

    /**
     * @notice Return length of super-agents on chain
     * @param chainID Chain ID
     */
    function activeSupersLen(
        uint256 chainID
    ) external view returns (uint256) {
        return activeSupersNew[chainID].length;
    }

    // ==============================
    //          ADMIN
    // ==============================

    function debug_participants_pop(
        uint256 chainID,
        uint256 round
    ) external onlyRole(ADMIN) {
        agentRoundData[chainID][round].participants.pop();
    } 

    /**
     * @notice Forces registration of a super agent
     * @param owner The super agent address
     */
    function forceRegisterSuperAgent(
        address owner
    ) external onlyRole(ADMIN) {
        AgentLib.Agent storage saved = allAgents[owner];

        if (saved.agentType != AgentLib.AgentType.SUPER) {
            revert AgentManager__InvalidType();
        }

        AgentLib.AgentStatus status = AgentLib.AgentStatus.PARTICIPANT;
        activeSupersNew[allAgents[owner].chainID].push(owner);

        if (saved.agentType != AgentLib.AgentType.NON_AUTHORIZED) {
            // already registered and saved before
            AgentLib.AgentStatus oldStatus = saved.status;
            if (oldStatus != status) {
                saved.status = status;
                emit AgentStatusChanged(
                    owner,
                    oldStatus,
                    status
                );
            }
        }
    }

    /**
     * @notice Forces deactivation of a super agent
     * @param owner The super agent address
     */
    function forceDeactivateSuperAgent(
        address owner
    ) external onlyRole(ADMIN) {
        AgentLib.AgentStatus oldStatus = allAgents[owner].status;
        if (
            oldStatus == AgentLib.AgentStatus.PAUSED ||
            oldStatus == AgentLib.AgentStatus.BANNED
        ) {
            revert AgentManager__AlreadyDeactivated(owner);
        } else {
            allAgents[owner].status = AgentLib.AgentStatus.PAUSED;

            _removeSuperAgent(allAgents[owner].chainID, owner);

            emit AgentStatusChanged(
                owner,
                oldStatus,
                AgentLib.AgentStatus.PAUSED
            );
        }

    }

    /**
     * @notice Updates the Rewards contract address
     * @param newRewards The new address for the Rewards
     */
    function setRewards(address newRewards) external onlyRole(ADMIN) {
        if (newRewards == address(0)) {
            revert AgentManager__ZeroAddress();
        }

        rewards = newRewards;
    }

    /**
     * @notice Updates the PingSystem contract address
     * @param newPingSystem The new address for the PingSystem
     */
    function setPingSystem(address newPingSystem) external onlyRole(ADMIN) {
        if (newPingSystem == address(0)) {
            revert AgentManager__ZeroAddress();
        }

        pingSystem = newPingSystem;
    }

    /**
     * @notice Updates the Rotator contract address
     * @param newRotator The new address for the Rotator
     */
    function setRotator(address newRotator) external onlyRole(ADMIN) {
        if (newRotator == address(0)) {
            revert AgentManager__ZeroAddress();
        }
        rotator = newRotator;
        _grantRole(ROTATOR, rotator);
    }

    /**
     * @notice Updates the ChainInfo contract address
     * @param newChainInfo The new address for the ChainInfo
     */
    function setChainInfo(address newChainInfo) external onlyRole(ADMIN) {
        if (newChainInfo == address(0)) {
            revert AgentManager__ZeroAddress();
        }

        chainInfo = newChainInfo;
    }

    function _authorizeUpgrade(address) internal override onlyRole(ADMIN) {}
}
