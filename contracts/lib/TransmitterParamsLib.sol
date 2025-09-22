// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title TransmitterParamsLib
 * @dev Library for encoding and decoding transmitter parameters used in network operations.
 */
library TransmitterParamsLib {
    /**
     *  FINALIZATION OPTIONS:
     * 
     *  0 - Fast Finalization (DEFAULT):
     *  
     *  Description: 
     *  Prioritizes speed while maintaining a reasonable level of safety. 
     *  It uses a reduced finalization process that is less strict than Standard Finalization,
     *  but still guarantees secure delivery.
     * 
     *  Behavior: Confirmation occurs after a minimal finalization process, 
     *  ensuring the block sequence is unlikely to be reverted.
     * 
     *  Use Case: Suitable for most applications.
     * 
     * 
     *  1 - Standard Finalization:
     * 
     *  Description: 
     *  The default and safest option. It adheres to the full 
     *  finalization process defined by the source network. 
     *  This ensures the highest level of security and immutability.
     * 
     *  Behavior: Confirmation occurs only after the standard block 
     *  finalization period (or block depth) specified by the source network has elapsed.
     * 
     *  Use Case: Recommended for applications handling high-value transactions or where data integrity is paramount.
     * 
     * 
     *  2 - Unsafe Finalization:
     * 
     *  Description: 
     *  The fastest option, but it bypasses standard finalization processes. 
     *  This dramatically reduces confirmation time but introduces the risk of block restructuring (reorgs).
     * 
     *  Behavior: 
     *  Confirmation is immediate or near-immediate, based on minimal criteria. 
     *  There's no guarantee that the confirmed transaction will be permanent.
     * 
     *  !!! Warning: 
     *  Use with EXTREME CAUTION. By selecting this option, you explicitly 
     *  acknowledge and accept the risk that the transaction or event might be 
     *  reverted due to a block reorg. This could lead to data inconsistency or financial loss.
     * 
     *  Use Case: 
     *  Only recommended for experimental purposes, low-value 
     *  transactions where the risk of reorg is acceptable, 
     *  or in specific scenarios where immediate confirmation is more 
     *  critical than data integrity (e.g., certain types of data feeds where eventual consistency is sufficient).
     *  Thoroughly understand the implications before using this option.
     */
    struct TransmitterParams {
        uint256 blockFinalizationOption;
        uint256 customGasLimit;
    }

    /**
     * @notice Encodes an `TransmitterParams` struct into a packed bytes format
     * @param params The `TransmitterParams` struct to encode
     * @return packedParams The encoded byte representation of the transmitter parameters
     */
    function encode(TransmitterParamsLib.TransmitterParams memory params) internal pure returns(bytes memory packedParams) {
        return abi.encode(params.blockFinalizationOption, params.customGasLimit);
    }

    /**
     * @notice Decodes a packed bytes representation into an `TransmitterParams` struct
     * @param packedParams The encoded byte representation of the transmitter parameters
     * @return params The decoded `TransmitterParams` struct
     */
    function decode(bytes calldata packedParams) internal pure returns(TransmitterParamsLib.TransmitterParams memory params) {
        (params.blockFinalizationOption, params.customGasLimit) = abi.decode(packedParams, (uint256, uint256));
    }

    /**
     * @notice Extracts the `blockFinalizationOption` value from the packed transmitter parameters
     * @param packedParams The encoded byte representation of the transmitter parameters
     * @return waitFor The extracted `blockFinalizationOption` value
     */
    function blockFinalizationOption(bytes calldata packedParams) internal pure returns(uint256 waitFor) {
        (waitFor, ) = abi.decode(packedParams, (uint256, uint256));
    }

    /**
     * @notice Extracts the `customGasLimit` value from the packed transmitter parameters
     * @param packedParams The encoded byte representation of the transmitter parameters
     * @return gasLimit The extracted `customGasLimit` value
     */
    function customGasLimit(bytes memory packedParams) internal pure returns(uint256 gasLimit) {
        (, gasLimit) = abi.decode(packedParams, (uint256, uint256));
    }
}
