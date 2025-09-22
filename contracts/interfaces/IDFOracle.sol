// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

interface IDFOracle {
    function getFeedPrice(
        bytes32 dataKey
    ) external view returns(uint256 price, uint256 timestamp);
}