// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable, AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";

contract FeeCalculator is Initializable, UUPSUpgradeable, AccessControlUpgradeable {

    bytes32 public constant ADMIN = keccak256("ADMIN");

    // ==============================
    //          STORAGE
    // ==============================

    mapping(uint256 chainId => uint256 fee) public ACPFees;
    mapping(uint256 chainId => uint256 fee) public superFees;
    mapping(uint256 chainId => uint256 fee) public pointDistrFees;
    mapping(uint256 chainId => uint256 fee) public executorFees;
    
    // ==============================
    //          FUNCTIONS
    // ==============================

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize
    /// @param initAddr[0] - Admin address
    function initialize(address[] calldata initAddr) public initializer {
        __UUPSUpgradeable_init();
        __AccessControl_init();
        _setRoleAdmin(ADMIN, ADMIN);
        _grantRole(ADMIN, initAddr[0]);
    }

    function updateACPFee(uint256 chainId, uint256 fee) external onlyRole(ADMIN) {
        ACPFees[chainId] = fee;
    }

    function updateSupersFee(uint256 chainId, uint256 fee) external onlyRole(ADMIN) {
        superFees[chainId] = fee;
    }

    function updatePointsFee(uint256 chainId, uint256 fee) external onlyRole(ADMIN) {
        pointDistrFees[chainId] = fee;
    }

    function updateExecutorFee(uint256 chainId, uint256 fee) external onlyRole(ADMIN) {
        executorFees[chainId] = fee;
    }

    function getAllFees(uint256 chainID) external view returns(
        uint256 ACPFee,
        uint256 superFee,
        uint256 pointDistrFee,
        uint256 executorFee
    ) {
        ACPFee = ACPFees[chainID];
        superFee = superFees[chainID];
        pointDistrFee = pointDistrFees[chainID];
        executorFee = executorFees[chainID];
    }

    // ==============================
    //           ADMIN
    // ==============================
    function _authorizeUpgrade(address) internal override onlyRole(ADMIN) {}
}