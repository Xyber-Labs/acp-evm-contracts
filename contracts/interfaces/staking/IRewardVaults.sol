// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

interface IRewardVaults {
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

    function vaultSelfStake(
        uint256 chainID,
        address agent
    ) external view returns (uint256);

    function slash(
        uint256 chainID,
        address agent,
        uint256 amount
    ) external;

    function treasury() external view returns (address);
    function vaultBalanceBatch(
        uint256 chainID,
        address[] calldata agents
    ) external view returns (uint256[] memory balances);

    function minStake() external view returns (uint256);

    function vaultBalance(
        uint256 chainID,
        address agent
    ) external view returns (uint256);

    function ACPReserve() external view returns (address);
}
