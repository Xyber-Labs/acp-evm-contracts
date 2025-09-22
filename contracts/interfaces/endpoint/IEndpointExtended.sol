// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IEndpoint} from "./IEndpoint.sol";

interface IEndpointExtended is IEndpoint {
    function activateOrDisableSignerBatch(
        address[] calldata signers,
        bool[] calldata activate
    ) external;

    function activateOrDisableExecutorBatch(
        address[] calldata executors,
        bool[] calldata activate
    ) external;

    function setTotalActiveSigners(uint256 signers) external;

    function totalActiveSigners() external view returns (uint256);

    function minCommission() external view returns (uint256);
}