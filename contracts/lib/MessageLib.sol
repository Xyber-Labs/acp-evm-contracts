// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {LocationLib} from "./LocationLib.sol";
import {TransmitterParamsLib} from "./TransmitterParamsLib.sol";

/// @title  A library for message management in a multi-chain environment
/// @notice This library provides structures and functions to manage messages across different blockchains
library MessageLib {
    using LocationLib for SrcChainData;

    struct Proposal {
        uint256 destChainId;
        uint256 nativeAmount;
        bytes32 selectorSlot;
        bytes senderAddr;
        bytes destAddr;
        bytes payload;
        bytes reserved;
        bytes transmitterParams;
    }

    /// @dev Source chain data
    /// @param Location - location of the source chain (chainID + blockNumber)
    struct SrcChainData {
        uint256 location;
        bytes32[2] srcOpTxId;
    }

    struct SrcChainDataRaw {
        uint128 srcChainId;
        uint128 srcBlockNumber;
        bytes32[2] srcOpTxId;
    }

    struct MessageData {
        Proposal initialProposal;
        SrcChainData srcChainData;
    }

    /**
     * @dev Message statuses
     * @notice Different kinds of message status
     * @param NOT_INITIALIZED - message is not initialized (default)
     * @param INVALID - message is detected as invalid on consensus
     * @param SAVED - message is saved in message storage,
     * but transmission consensus is not reached
     * @param TRANSMITTED - message is proposed in Master Chain,
     * but not yet ready for execution, only consensus step 1 reached
     * @param QUEUED - message is queued for execution
     * @param PENDING - message is sent and now in mempool
     * @param PROTOCOL_FAILED - message delivered, but failed due to protocol error
     * @param CONSENSUS_NOT_REACHED - message failed to reach consensus
     * @param EXTENSION_NOT_REGISTERED - NON_EVM extension is not registered
     * by protocol
     * @param EXTENSION_NOT_REACHABLE - NON_EVM extension is registered,
     * but is not reachable due to some reason
     * @param EXTENSION_PANICKED - NON_EVM extension panicked during execution
     * @param UNDERESTIMATED - message execution is estimated as underpriced
     * and not invoked
     * @param SUCCESS - message is succesfully delivered and executed
     * @param FAILED - message execution failed
     */
    enum MessageStatus {
        NOT_INITIALIZED, // default
        INVALID, // consensus zone
        SAVED, //
        TRANSMITTED, //
        QUEUED, //
        PENDING, // executor zone
        PROTOCOL_FAILED,
        CONSENSUS_NOT_REACHED,
        EXTENSION_NOT_REGISTERED,
        EXTENSION_NOT_REACHABLE,
        EXTENSION_PANICKED,
        UNDERESTIMATED, // delivery zone
        SUCCESS, //
        FAILED //
    }

    struct Message {
        MessageStatus status;
        uint256 globalNonce;
        MessageData data;
    }

    function statusChangeValid(
        MessageLib.MessageStatus oldStatus,
        MessageLib.MessageStatus newStatus
    ) internal pure returns (bool) {
        if (newStatus == MessageLib.MessageStatus.NOT_INITIALIZED) {
            return false;
        }

        if (
            oldStatus == MessageLib.MessageStatus.INVALID ||
            oldStatus == MessageLib.MessageStatus.FAILED ||
            oldStatus == MessageLib.MessageStatus.SUCCESS || 
            oldStatus == MessageLib.MessageStatus.PROTOCOL_FAILED
        ) {
            return false;
        }

        return true;
    }

    function getDestChain(MessageData memory msgData) internal pure returns (uint256) {
        return msgData.initialProposal.destChainId;
    }

    function getLocation(MessageData memory msgData) internal pure returns (uint256) {
        return msgData.srcChainData.location;
    }

    /**
     * @notice This function creates a hash that serves as a unique
     * identifier for the message in a whole ACP network
     * @dev Bytes fields len is used in a hash to prevent collisions from 
     * shifting and falsify or faking message data
     * @param msgData The message data, including src chain data and proposal
     * @return hash Resulting hash of the message data
     */
    function getHashPrefixed(
        MessageLib.MessageData memory msgData
    ) internal pure returns (bytes32) {
        bytes32 msgHash = keccak256(
            abi.encodePacked(
                msgData.initialProposal.destChainId,
                msgData.initialProposal.nativeAmount,
                msgData.initialProposal.selectorSlot,
                msgData.initialProposal.senderAddr.length,
                msgData.initialProposal.senderAddr,
                msgData.initialProposal.destAddr.length,
                msgData.initialProposal.destAddr,
                msgData.initialProposal.payload.length,
                msgData.initialProposal.payload,
                msgData.initialProposal.reserved.length,
                msgData.initialProposal.reserved,
                msgData.initialProposal.transmitterParams.length,
                msgData.initialProposal.transmitterParams,
                msgData.srcChainData.location,
                msgData.srcChainData.srcOpTxId
            )
        );

        return
            keccak256(
                abi.encodePacked("\x19Ethereum Signed Message:\n32", msgHash)
            );
    }
}
