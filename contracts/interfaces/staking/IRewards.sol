// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

interface IRewards {
    function accumulateMultiPositionRewards(
        address agent,
        address delegator
    ) external;

    function updateVaultsRPS(
        address agent
    ) external;

    function updateMultiPosition(
        address agent,
        address delegator
    ) external;

    function setReward(
        uint256 chainID,
        address agent,
        uint256 amount,
        bool compensation
    ) external;

    function setRewardGroup(
        uint256 chainID,
        uint256 amount,
        address[] calldata agents
    ) external;

    function treasury() external view returns (address);

    function ACPReserve() external view returns (address);

    function minStake() external view returns (uint256);

    function vaultBalance(
        uint256 /* chainID */,
        address agent
    ) external view returns (uint256);

    function vaultSelfStake(
        uint256 /* chainID */,
        address agent
    ) external view returns (uint256);

    function vaultBalanceBatch(
        uint256 chainID,
        address[] calldata agents
    ) external view returns (uint256[] memory balances);

    function slash(
        uint256 /* chainID */,
        address agent,
        uint256 amount
    ) external;
}