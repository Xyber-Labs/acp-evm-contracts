// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

interface IPingSystem {
    function active(address agent) external view returns (bool);

    function activeBatch(
        address[] calldata agents
    ) external view returns (bool[] memory);

    function activeOnly(
        address[] calldata agents
    ) external view returns (address[] memory);

    function threshold() external view returns (uint256);
}
