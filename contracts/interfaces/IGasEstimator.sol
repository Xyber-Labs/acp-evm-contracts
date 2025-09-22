// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

interface IGasEstimator {
    function estimateExecutionWithGas(
        uint256 destChainId, 
        uint256 gasLimit
    ) external view returns (uint256);
}