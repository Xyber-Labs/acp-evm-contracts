// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {
    Endpoint,
    TransmitterParamsLib,
    IGasEstimator,
    SafeCall,
    IWNative,
    SafeERC20,
    SelectorLib
} from "./Endpoint.sol";

contract EndpointERC20 is Endpoint {
    using SafeERC20 for IWNative;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function _propose(
        address from,
        uint256 destChainID,
        bytes32 selectorSlot,
        bytes memory transmitterParams,
        bytes memory destAddress,
        bytes memory payload,
        bytes memory reserve
    ) internal virtual override {
        if (proposeReject) {
            revert Endpoint__ProposeReject();
        }

        uint256 gas = TransmitterParamsLib.customGasLimit(transmitterParams);
        if (gas == 0) {
            revert Endpoint__SpecifyGasLimit();
        }
        
        uint256 estimatedFee = IGasEstimator(gasEstimator).estimateExecutionWithGas(destChainID, gas);
        IWNative(wNative).safeTransferFrom(from, connector, estimatedFee);

        emit MessageProposed(
            destChainID,
            estimatedFee,
            selectorSlot,
            transmitterParams,
            abi.encode(from),
            destAddress,
            payload,
            reserve
        );
    }

    /**
     * @notice Function to be used to replenish message reward for execution
     * Should be used on underestimated or low-gas message statuses
     * @param fee Amount of tokens to be used as destination fee
     * @param amount Amount to add to message reward
     * @param msgHash Hash of message to be replenished
     */
    function replenish(
        uint256 fee,
        uint256 amount,
        bytes32 msgHash
    ) external virtual override payable {
        if (executeReject) {
            revert Endpoint__ExecuteReject();
        }

        if (amount == 0) {
            revert Endpoint__ZeroValue();
        }

        if (msgHash == bytes32(0)) {
            revert Endpoint__InvalidHash();
        }

        IWNative(wNative).safeTransferFrom(msg.sender, connector, amount + fee);

        emit MessageProposed(
            MASTER_CHAIN_ID,
            fee,
            SelectorLib.encodeExecutionCode(MR_REPLENISH_COMMAND_CODE),                   
            abi.encode(0, REPLENISH_GAS),
            abi.encode(address(this)),
            abi.encode(repeater),
            abi.encode(msgHash, amount),
            ""
        );
    }

    /**
     * @notice Try to resend message by executors
     * @param msgHash Hash of message to be resent
     */
    function resend(
        bytes32 msgHash
    ) external virtual override payable {
        if (executeReject) {
            revert Endpoint__ExecuteReject();
        }

        if (msgHash == bytes32(0)) {
            revert Endpoint__InvalidHash();
        }

        emit MessageProposed(
            MASTER_CHAIN_ID,
            msg.value,
            SelectorLib.encodeExecutionCode(MR_RESEND_COMMAND_CODE),                   
            abi.encode(0, RESEND_GAS),
            abi.encode(address(this)),
            abi.encode(repeater),
            abi.encode(msgHash),
            ""
        );
    }
}