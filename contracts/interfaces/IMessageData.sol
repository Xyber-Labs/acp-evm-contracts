// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {MessageLib} from "../lib/MessageLib.sol";

interface IMessageData {
    function getMsgData(
        bytes32 hashPrefixed
    ) external view returns (MessageLib.MessageData memory);

    function getMsg(
        bytes32
    ) external view returns (MessageLib.Message memory op);

    function storeMessage(
        bytes32 hashPrefixed,
        MessageLib.MessageData calldata msgData
    ) external;

    function changeMessageStatus(
        bytes32 hashPrefixed,
        MessageLib.MessageStatus newStatus
    ) external;

    function getDestChainId(
        bytes32 hashPrefixed
    ) external view returns (uint256);

    function getSrcChainId(
        bytes32 hashPrefixed
    ) external view returns (uint256);

    function getReward(bytes32 hashPrefixed) external view returns (uint256);

    function getMsgByRawData(
        uint256 chainID,
        bytes32 txHashBase,
        bytes32 txHashExt
    ) external view returns (MessageLib.Message memory);

    function getMsgStatus(
        uint256 chainID,
        bytes32 txHashBase,
        bytes32 txHashExt
    ) external view returns (MessageLib.MessageStatus);

    function getMsgStatusByHash(
        bytes32 hashPrefixed
    ) external view returns (MessageLib.MessageStatus);

    function incrementNativeAmount(
        bytes32 msgHash,
        uint256 amount
    ) external;
}
