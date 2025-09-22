// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable, AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {IAgentManager} from "../interfaces/agents/IAgentManager.sol";
import {IChainInfo} from "../interfaces/IChainInfo.sol";
import {IMessageData} from "../interfaces/IMessageData.sol";
import {MessageLib} from "../lib/MessageLib.sol";
import {AgentLib} from "../lib/AgentLib.sol";

/**
 * @title ExecutorLottery is a lottery contract for choosing executor
 * for exact cross-chain message in ACP
 */
contract ExecutorLottery is
    Initializable,
    UUPSUpgradeable,
    AccessControlUpgradeable
{
    error InvalidAddress();
    error ExecutorLottery__NotMaster();

    // ==============================
    //      ROLES AND CONSTANTS
    // ==============================
    bytes32 public constant ADMIN = keccak256("ADMIN");
    bytes32 public constant L_TRIGGER = keccak256("L_TRIGGER");
    uint256 public constant SLOT_LEN = 32;

    // ==============================
    //         STORAGE
    // ==============================

    struct LotteryData {
        address[] agentsResponsible;
        uint256 startTime;
    }

    address public master;
    address public agentManager;
    address public chainInfo;
    address public messageData;

    mapping(bytes32 msgHash => LotteryData) messageLotteryData;

    // ==============================
    //         FUNCTIONS
    // ==============================

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize
    /// @param initAddr[0] - Admin address
    /// @param initAddr[1] - Master address
    function initialize(address[] calldata initAddr) public initializer {
        __UUPSUpgradeable_init();
        __AccessControl_init();
        _setRoleAdmin(ADMIN, ADMIN);
        _setRoleAdmin(L_TRIGGER, ADMIN);
        _grantRole(ADMIN, initAddr[0]);
        _grantRole(L_TRIGGER, initAddr[1]);
        master = initAddr[1];
    }

    /**
     * @notice Run lottery for message
     * @param msgHash - message hash
     * @param chainID - message destination chain
     * @param payload - message payload
     * @return agents - array of agents responsible for execution
     * @return startTime - lottery start time
     */
    function runLottery(
        bytes32 msgHash,
        uint256 chainID,
        bytes calldata payload
    )
        external
        onlyRole(L_TRIGGER)
        returns (address[] memory agents, uint256 startTime)
    {
        if (_isMessageFinalized(msgHash)) {
            address[] memory noAgents = new address[](0);
            return (noAgents, 0);
        }

        address[] memory filteredParticipants = IAgentManager(agentManager).getFilteredParticipants(chainID);
        bool useFilterd = filteredParticipants.length >= 2;
        uint256 numExecutors;

        if (useFilterd) {
            numExecutors = filteredParticipants.length;
        } else {
            numExecutors = IAgentManager(agentManager).getCurrentParticipantsLen(chainID);
        }

        bytes32 lHash = _lotteryHash(keccak256(abi.encodePacked(payload)));
        uint256 splitLen = SLOT_LEN / numExecutors;

        address[] memory agentsResponsible = new address[](numExecutors);

        for (uint256 i = 0; i < numExecutors; i++) {
            uint256 winnerIndex = _convertHashChunk(lHash, splitLen, i) %
                numExecutors;
            address agent;

            if (useFilterd) {
                agent = filteredParticipants[winnerIndex];
            } else {
                agent = IAgentManager(agentManager).getParticipantByIndex(chainID, winnerIndex);
            }
            
            agentsResponsible[i] = agent;
        }

        LotteryData memory data = LotteryData({
            agentsResponsible: agentsResponsible,
            startTime: block.timestamp
        });
        messageLotteryData[msgHash] = data;

        return (agentsResponsible, block.timestamp);
    }

    /**
     * @dev Check if message is finalized.
     * Lottery should not work for finalized messages
     */
    function _isMessageFinalized(bytes32 msgHash) private view returns (bool) {
        MessageLib.MessageStatus status = IMessageData(messageData).getMsgStatusByHash(
            msgHash
        );

        if (status == MessageLib.MessageStatus.SUCCESS || status == MessageLib.MessageStatus.FAILED) {
            return true;
        }

        return false;
    }

    function _convertHashChunk(
        bytes32 _hash,
        uint256 chunkLen,
        uint256 offsetMultiplier
    ) private pure returns (uint256 res) {
        assembly {
            // store bytes into free slot
            let ptr := mload(0x40)
            mstore(ptr, _hash)

            res := shr(
                // cut right part by full len - chunkLen
                sub(256, mul(chunkLen, 8)),
                // move bytes to cut left part
                // by chunkLen * partInOrder
                mload(add(ptr, mul(offsetMultiplier, chunkLen)))
            )
        }
    }

    /**
     * @dev Get pseudo-random hash for lottery 
     * @param payloadHash - hash of payload
     */
    function _lotteryHash(bytes32 payloadHash) private view returns (bytes32) {
        bytes32 blockHash = keccak256(abi.encode(block.number));
        return keccak256(abi.encodePacked(blockHash, payloadHash));
    }

    /**
     * @dev Get hash of payload
     */
    function _payloadHash(bytes memory payload) private pure returns (bytes32) {
        return keccak256(abi.encodePacked(payload));
    }

    // ==============================
    //         GETTERS
    // ==============================

    /**
     * @notice Check current agent responsible for execution
     * @dev Start time can not be set as value > block.timestamp
     * because it is always taken as current block timestamp
     * on moment of execution (no time underflow/overflow)
     */
    function currentExecutorAgent(
        bytes32 msgHash
    ) public view returns (address) {
        LotteryData memory data = messageLotteryData[msgHash];
        if (data.startTime == 0) {
            return address(0);
        }

        MessageLib.MessageStatus status = IMessageData(messageData).getMsgStatusByHash(
            msgHash
        );

        if (
            status == MessageLib.MessageStatus.FAILED ||
            status == MessageLib.MessageStatus.SUCCESS
        ) {
            return address(0);
        }

        uint256 timeDiff = block.timestamp - data.startTime;
        uint256 executionTime = IChainInfo(chainInfo).getDefaultExecutionTime(
            IMessageData(messageData).getDestChainId(msgHash)
        );
        uint256 len = data.agentsResponsible.length;

        address agent;
        uint256 index;
        if (timeDiff < executionTime) {
            agent = data.agentsResponsible[0];
        } else {
            uint256 framesPassed = timeDiff / executionTime;
            index = framesPassed % len;
            agent = data.agentsResponsible[index];
        }

        uint256 destChainId = IMessageData(messageData).getDestChainId(msgHash);
        address[] memory activeAgents = IAgentManager(agentManager).getFilteredParticipants(destChainId);

        for (uint256 i = 0; i < activeAgents.length; i++) {
            if (agent == activeAgents[i]) {
                return agent;
            }
        }

        if (index < activeAgents.length) {
            return activeAgents[index];
        }
        
        return activeAgents[0];
    }

    /**
     * @notice Get current time frame for execution
     * @return start  - start of current time frame
     * @return finish - end of current time frame
     */
    function currentTimeFrame(
        bytes32 msgHash
    ) public view returns (uint256 start, uint256 finish) {
        LotteryData memory data = messageLotteryData[msgHash];
        if (data.startTime == 0) {
            return (0, 0);
        }

        MessageLib.MessageStatus status = IMessageData(messageData).getMsgStatusByHash(
            msgHash
        );

        if (
            status == MessageLib.MessageStatus.FAILED ||
            status == MessageLib.MessageStatus.SUCCESS
        ) {
            return (0, 0);
        }

        uint256 timeDiff = block.timestamp - data.startTime;
        uint256 executionTime = IChainInfo(chainInfo).getDefaultExecutionTime(
            IMessageData(messageData).getDestChainId(msgHash)
        );

        if (timeDiff < executionTime) {
            return (data.startTime, data.startTime + executionTime);
        } else {
            uint256 framesPassed = timeDiff / executionTime;
            start = data.startTime + framesPassed * executionTime;
            finish = start + executionTime;
        }
    }

    /**
     * @notice Get current execution data 
     * ie agent responsible for execution and his timeframe
     */
    function currentExecutionData(
        bytes32 msgHash
    ) public view returns (address agent, uint256 startTime, uint256 endTime) {
        agent = currentExecutorAgent(msgHash);
        (startTime, endTime) = currentTimeFrame(msgHash);
    }

    function getMessageLotteryData(
        bytes32 msgHash
    ) public view returns (address[] memory, uint256) {
        LotteryData storage data = messageLotteryData[msgHash];
        return (data.agentsResponsible, data.startTime);        
    }

    // ==============================
    //         ADMIN
    // ==============================

    function setAgentManager(address newAgentManager) public onlyRole(ADMIN) {
        if (newAgentManager == address(0)) {
            revert InvalidAddress();
        }
        agentManager = newAgentManager;
    }

    function setChainInfo(address newChainInfo) public onlyRole(ADMIN) {
        if (newChainInfo == address(0)) {
            revert InvalidAddress();
        }
        chainInfo = newChainInfo;
    }

    function setMessageData(address newMessageData) public onlyRole(ADMIN) {
        if (newMessageData == address(0)) {
            revert InvalidAddress();
        }
        messageData = newMessageData;
    }

    // ==============================
    //         UPGRADES
    // ==============================
    function _authorizeUpgrade(address) internal override onlyRole(ADMIN) {}
}
