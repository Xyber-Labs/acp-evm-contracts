// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable, AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {IAgentManager} from "../interfaces/agents/IAgentManager.sol";
import {IChainInfo} from "../interfaces/IChainInfo.sol";
import {IMessageData} from "../interfaces/IMessageData.sol";

/**
 * @title ExecutorLottery is a lottery contract for choosing executor
 * for exact cross-chain message in Photon V2
 */
contract ExecutorLotteryTest is
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

    address public agentManager;
    address public chainInfo;
    address public messageData;

    mapping(bytes32 chainDataHash => LotteryData) public messageLotteryData;

    // ==============================
    //         FUNCTIONS
    // ==============================

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
    }

    /**
     * @param payload - message payload
     */
    function runLottery(
        bytes32 chainDataHash,
        uint256,
        bytes calldata payload
    )
        external
        onlyRole(L_TRIGGER)
        returns (address[] memory agents, uint256 startTime)
    {
        uint256 numExecutors = 5;

        bytes32 lHash = _lotteryHash(keccak256(abi.encodePacked(payload)));
        uint256 splitLen = SLOT_LEN / numExecutors;

        address[] memory agentsResponsible = new address[](numExecutors);

        for (uint256 i = 0; i < numExecutors; i++) {
            uint256 winnerIndex = _convertHashChunk(lHash, splitLen, i) %
                numExecutors;
            address agent = getAgentByIndex(
                winnerIndex
            );
            agentsResponsible[i] = agent;
        }

        LotteryData memory data = LotteryData({
            agentsResponsible: agentsResponsible,
            startTime: block.timestamp
        });
        messageLotteryData[chainDataHash] = data;

        return (agentsResponsible, block.timestamp);
    }

    function getAgentByIndex(uint256 i) public pure returns(address) {
        if (i == 0) return 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
        else if (i == 1) return 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC;
        else if (i == 2) return 0x90F79bf6EB2c4f870365E785982E1f101E93b906;
        else if (i == 3) return 0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65;
        else if (i == 4) return 0x9965507D1a55bcC2695C58ba16FB37d819B0A4dc;
        else if (i == 5) return 0x976EA74026E726554dB657fA54763abd0C3a0aa9;
        else return 0x14dC79964da2C08b23698B3D3cc7Ca32193d9955;
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

    function _lotteryHash(bytes32 payloadHash) private view returns (bytes32) {
        bytes32 blockHash = keccak256(abi.encode(block.number));
        return keccak256(abi.encodePacked(blockHash, payloadHash));
    }

    function _payloadHash(bytes memory payload) private pure returns (bytes32) {
        return keccak256(abi.encodePacked(payload));
    }

    // ==============================
    //         GETTERS
    // ==============================

    /**
     *
     * @dev Start time can not be set as value > block.timestamp
     * because it is always taken as current block timestamp
     * on moment of execution (no time underflow/overflow)
     */
    function currentExecutor(
        bytes32 chainDataHash
    ) public view returns (address) {
        LotteryData memory data = messageLotteryData[chainDataHash];
        if (data.startTime == 0) {
            return address(0);
        }
        uint256 timeDiff = block.timestamp - data.startTime;
        uint256 executionTime = 60;
        uint256 len = data.agentsResponsible.length;

        if (timeDiff < executionTime) {
            return data.agentsResponsible[0];
        } else {
            uint256 framesPassed = timeDiff / executionTime;
            uint256 index = framesPassed % len;
            return data.agentsResponsible[index];
        }
    }

    function currentTimeFrame(
        bytes32 chainDataHash
    ) public view returns (uint256 start, uint256 finish) {
        LotteryData memory data = messageLotteryData[chainDataHash];
        if (data.startTime == 0) {
            return (0, 0);
        }
        uint256 timeDiff = block.timestamp - data.startTime;
        uint256 executionTime = 60;

        if (timeDiff < executionTime) {
            return (data.startTime, data.startTime + executionTime);
        } else {
            uint256 framesPassed = timeDiff / executionTime;
            start = data.startTime + framesPassed * executionTime;
            finish = start + executionTime;
        }
    }

    function currentExecutionData(
        bytes32 chainDataHash
    ) public view returns (address agent, uint256 startTime, uint256 endTime) {
        agent = currentExecutor(chainDataHash);
        (startTime, endTime) = currentTimeFrame(chainDataHash);
    }

    function getLotteryHash(
        bytes memory payload
    ) external view returns (bytes32) {
        return _lotteryHash(_payloadHash(payload));
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

    function setMessageStorage(address newStorage) public onlyRole(ADMIN) {
        if (newStorage == address(0)) {
            revert InvalidAddress();
        }
        messageData = newStorage;
    }

    // ==============================
    //         UPGRADES
    // ==============================
    function _authorizeUpgrade(address) internal override onlyRole(ADMIN) {}
}
