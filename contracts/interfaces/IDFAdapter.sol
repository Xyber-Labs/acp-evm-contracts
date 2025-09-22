// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

interface IDFAdapter {
    function convertAmount(
        uint256 chainIdFrom, 
        uint256 chainIdTo, 
        uint256 amount
    ) external view returns (uint256);

    function getRate(uint256 chainId) external view returns (uint256);
    function getRates(uint256 sourceChainId, uint256 destChainId) external view returns(uint256, uint256);
}