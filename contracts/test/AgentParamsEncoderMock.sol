// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TransmitterParamsLib} from "../lib/TransmitterParamsLib.sol";

contract AgentParamsEncoderMock {

    function encode(uint256 blockFinalizationOption, uint256 _customGasLimit) external pure returns (bytes memory packedParams) {
        TransmitterParamsLib.TransmitterParams memory params = TransmitterParamsLib.TransmitterParams({
            blockFinalizationOption: blockFinalizationOption,
            customGasLimit: _customGasLimit
        });
        return TransmitterParamsLib.encode(params);
    }
}