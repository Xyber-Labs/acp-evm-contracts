// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

interface IStaking {
    function getUserDelegation(
        address user,
        address agent
    ) external view returns (uint256);

    function getPoolTotalDelegation(
        address agent
    ) external view returns (uint256);

    function getDelegationSharePercent(
        address agent
    ) external view returns (uint256);

    function poolBalance(
        address agent
    ) external view returns (uint256);

    function poolSelfStake(
        address agent
    ) external view returns (uint256);

    function slash(
        address agent,
        uint256 amount
    ) external;

    function getAgentsFromSet(
        address delegator
    ) external view returns (address[] memory);

    function treasury() external view returns (address);
    function minStake() external view returns (uint256);
}