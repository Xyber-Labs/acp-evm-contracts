// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {SignatureLib} from "../lib/SignatureLib.sol";
import {MessageLib} from "../lib/MessageLib.sol";

interface IMaster {

    struct MessageStatusConfirmation {
        address approvedBySuper;
        uint256 agentsApproved;
    }

    struct MessageStatusData {
        uint256 confirmations;
        mapping(address agent => bool) statusByAgent;
    }

    struct ExecutionAttempt {
        uint256 timeSaved;
        address executor;
        bytes32[2] executionHash;
    }

    struct MessageConsensusData {
        address firstlyProposedBy;
        address[] approvedBySuper;
        SignatureLib.Signature[] transmissionSigs;
        SignatureLib.Signature[] executionSigs;
        mapping(address => bool) signed;
        mapping(MessageLib.MessageStatus => MessageStatusData) msgStatusData;
    }

    struct MessageExecutionData {
        uint256 totalTries;
        uint256 resendAttempts;
        uint256[] replenishments;
        ExecutionAttempt[] tryExecutes;
    }

    function addTransmissionSignature(
        MessageLib.Proposal calldata proposal,
        MessageLib.SrcChainDataRaw calldata srcDataRaw,
        SignatureLib.Signature calldata sig
    ) external;

    function addTransmissionSignatureNoCheck(
        bytes32 chainDataHash,
        SignatureLib.Signature calldata sig
    ) external;

    function addExecutionSignature(
        bytes32 chainDataHash,
        SignatureLib.Signature calldata sig
    ) external;

    function addPendingTx(
        bytes32 chainDataHash,
        bytes32[2] calldata destHash,
        bytes calldata executor
    ) external;

    function lowPriceProposed(bytes32 chainDataHash) external;

    function replenish(uint256 srcChainId, bytes32 msgHash, uint256 value) external;

    function resend(uint256 srcChainId, bytes32 msgHash) external;

    function approveMessageDelivery(
        bytes32 chainDataHash,
        MessageLib.MessageStatus newStatus
    ) external;

    function getSuperApprovals(
        bytes32 chainDataHash
    ) external view returns (address[] memory);

    function getTSignaturesLength(
        bytes32 chainDataHash
    ) external view returns (uint256);

    function getESignaturesLength(
        bytes32 chainDataHash
    ) external view returns (uint256);

    function getTSignatures(
        bytes32 chainDataHash
    ) external view returns (SignatureLib.Signature[] memory);

    function getESignatures(
        bytes32 chainDataHash
    ) external view returns (SignatureLib.Signature[] memory);

    function isMessageSigned(
        bytes32 chainDataHash,
        address by
    ) external view returns (bool);

    function getExecutionAttempts(
        bytes32 chainDataHash
    ) external view returns (ExecutionAttempt[] memory);

    function setAgentManager(address manager) external;

    function setMessageData(address newStorage) external;

    function setExecutorLottery(
        address newLotteryAddr
    ) external;

    function setKeyStorage(address newKeyStorage) external;

    function setChainInfo(address newChainInfo) external;

    function setBalanceTracker(
        address newBalanceTracker
    ) external;

}
