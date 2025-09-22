// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

interface IConfigurator {
    function currentRound() external view returns (uint256);

    function changeRound(
        uint256 newConsensusRate,
        address[] calldata newSigners
    ) external;

    function getRoundData(
        uint256 round
    ) external view returns (uint256, uint256, address[] memory);

    function getRoundSigners(
        uint256 round
    ) external view returns (address[] memory);

    function getRoundSignersLen(uint256 round) external view returns (uint256);
    function getSignersLen() external view returns (uint256);
    function getSigners() external view returns (address[] memory);
}
