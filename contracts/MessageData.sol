//SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable, AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {MessageLib} from "./lib/MessageLib.sol";
import {LocationLib} from "./lib/LocationLib.sol";

/**
 * @notice MessageData is a contract which stores and handles
 * messages and it's statuses.
 */
contract MessageData is
    Initializable,
    UUPSUpgradeable,
    AccessControlUpgradeable
{
    using MessageLib for MessageLib.MessageData;
    using LocationLib for uint256;

    // ==============================
    //       EVENTS & ERRORS
    // ==============================

    event StatusChanged(
        MessageLib.MessageStatus statusOld,
        MessageLib.MessageStatus statusNew
    );
    event MessageStored(bytes32 msgHash);

    // ==============================
    //      ROLES & CONSTANTS
    // ==============================
    bytes32 public constant ADMIN     = keccak256("ADMIN");
    bytes32 public constant PRESERVER = keccak256("PRESERVER");

    // ==============================
    //           STORAGE
    // ==============================

    /// @dev Stores unique sources (protocols) for each chain 
    struct ChainSources {
        uint256 totalInThisChain;
        mapping (bytes source => bool) origins;
    }

    /// @dev Stats of each network message amounts
    struct MessageAmount {
        uint256 sentFrom;
        uint256 queuedToChain;
        uint256 received;
    }

    /// @notice Public global Message identifier
    uint256 public globalNonce;

    /// @notice Unique protocol addresses in whole ACP
    uint256 public totalSources;

    mapping(uint256 chainId => ChainSources) public uniqueOrigins;
    mapping(uint256 chainId => MessageAmount) public messageCounter;
    mapping(bytes32 msgHash => MessageLib.Message op) private msgs;
    mapping(bytes32 msgHash => uint256 replenishAmount) public replenishments;

    // ==============================
    //          FUNCTIONS
    // ==============================

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize
    /// @param initAddr[0] - Admin address
    /// @param initAddr[1] - Master address
    function initialize(address[] calldata initAddr) external initializer {
        __AccessControl_init();
        __UUPSUpgradeable_init();
        _setRoleAdmin(ADMIN, ADMIN);
        _setRoleAdmin(PRESERVER, ADMIN);
        
        _grantRole(ADMIN, initAddr[0]);
        _grantRole(PRESERVER, initAddr[1]);
    }

    // ==============================
    //          GETTERS
    // ==============================

    /** 
     * @notice Get full message by hash
     * @param msgHash Hash of the message
     */
    function getMsg(
        bytes32 msgHash
    ) external view returns (MessageLib.Message memory) {
        return msgs[msgHash];
    }

    /**
     * @notice Get message data by hash
     * @param msgHash Hash of the message
     */
    function getMsgData(
        bytes32 msgHash
    ) external view returns (MessageLib.MessageData memory) {
        return msgs[msgHash].data;
    }

    /**
     * @notice Get full message by raw data
     * @param opData Message data
     */
    function getMsgByRawData(
        MessageLib.MessageData calldata opData
    ) public view returns (MessageLib.Message memory) {
        bytes32 msgHash = opData.getHashPrefixed();
        return msgs[msgHash];
    }

    /**
     * @notice Get message status by hash
     * @param msgHash Hash of the message
     */
    function getMsgStatusByHash(
        bytes32 msgHash
    ) external view returns (MessageLib.MessageStatus) {
        return msgs[msgHash].status;
    }

    /**
     * @notice Get amount of sent messages from chain
     * @param chainId Chain id
     */
    function getSentMsgAmount(
        uint256 chainId
    ) external view returns (uint256) {
        return messageCounter[chainId].sentFrom;
    }

    /**
     * @notice Get amount of messages queued to chain but not executed
     * @param chainID Chain id
     */
    function getQueuedTo(uint256 chainID) external view returns (uint256) {
        return messageCounter[chainID].queuedToChain;
    }

    /**
     * @notice Get amount of received messages by chain via ACP
     * @param chainId Chain id
     */
    function getReceivedMsgAmount(
        uint256 chainId
    ) external view returns (uint256) {
        return messageCounter[chainId].received;
    }

    /**
     * @notice Get destination chain id by message hash
     * @param msgHash Hash of the message
     */
    function getDestChainId(
        bytes32 msgHash
    ) public view returns (uint256) {
        return msgs[msgHash].data.initialProposal.destChainId;
    }

    /**
     * @notice Get source chain id by message hash
     * @param msgHash Hash of the message
     */
    function getSrcChainId(
        bytes32 msgHash
    ) public view returns (uint256) {
        return msgs[msgHash].data.srcChainData.location.getChain();
    }

    /**
     * @notice Get full reward of the message
     * @param msgHash Hash of the message
     */
    function getReward(bytes32 msgHash) external view returns (uint256) {
        return msgs[msgHash].data.initialProposal.nativeAmount + replenishments[msgHash];
    }

    /**
     * @notice Create or re-create or check message hash by its data
     * @param opData Message data parsed from proposal
     */
    function getHash(
        MessageLib.MessageData calldata opData
    ) external pure returns (bytes32) {
        return opData.getHashPrefixed();
    }

    // ==============================
    //          SETTERS
    // ==============================

    /**
     * @notice Store previously unknown message for further processing
     * @param msgHash Message hash
     * @param opData  Message data parsed from proposal
     */
    function storeMessage(
        bytes32 msgHash,
        MessageLib.MessageData calldata opData
    ) external onlyRole(PRESERVER) {
        MessageLib.Message memory op = MessageLib.Message(
            MessageLib.MessageStatus.SAVED,
            globalNonce,
            opData
        );

        msgs[msgHash] = op;
        globalNonce++;

        uint256 chainId = opData.srcChainData.location.getChain();
        bytes memory source = opData.initialProposal.senderAddr;

        if (!uniqueOrigins[chainId].origins[source]) {
            uniqueOrigins[chainId].origins[source] = true;
            uniqueOrigins[chainId].totalInThisChain++;
            totalSources++;
        }

        emit MessageStored(msgHash);
    }

    /**
     * @notice Chenge message status
     * @param  msgHash Hash of the message
     * @param  newStatus New message status
     */
    function changeMessageStatus(
        bytes32 msgHash,
        MessageLib.MessageStatus newStatus
    ) external onlyRole(PRESERVER) {
        MessageLib.MessageStatus oldStatus = msgs[msgHash].status;
        msgs[msgHash].status = newStatus;

        if (newStatus == MessageLib.MessageStatus.TRANSMITTED) {
            messageCounter[getSrcChainId(msgHash)].sentFrom += 1;
        }

        if (newStatus == MessageLib.MessageStatus.QUEUED) {
            messageCounter[getDestChainId(msgHash)].queuedToChain += 1;
        }

        if (newStatus == MessageLib.MessageStatus.SUCCESS) {
            messageCounter[getDestChainId(msgHash)].received += 1;
        }

        emit StatusChanged(oldStatus, newStatus);
    }

    /**
     * @notice Incerements message reward
     * @param msgHash Hash of the message
     * @param value   Value to add
     */
    function incrementNativeAmount(
        bytes32 msgHash,
        uint256 value
    ) external onlyRole(PRESERVER) {
        replenishments[msgHash] += value;
    }

    // ==============================
    //          UPGRADES
    // ==============================

    function _authorizeUpgrade(address) internal override onlyRole(ADMIN) {}
}
