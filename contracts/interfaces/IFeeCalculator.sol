// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

interface IFeeCalculator {
    function ACPFees(uint256 chainId) external view returns(uint256 ACPFee);
    function superFees(uint256 chainId) external view returns(uint256 superFee);
    function pointDistrFees(uint256 chainId) external view returns(uint256 fee);
    function executorFees(uint256 chainId) external view returns(uint256 fee);
    function getAllFees(uint256 chainID) external view returns(uint256 ACPFee, uint256 superFee, uint256 pointDistrFee, uint256 executorFee);
}
