// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable, AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {IRewards} from "./interfaces/staking/IRewards.sol";
import {IFeeCalculator} from "./interfaces/IFeeCalculator.sol";
import {IDFAdapter} from "./interfaces/IDFAdapter.sol";

/**
 * @title  Point Distributor
 * @notice Contract for distribution points for transmitters and executors
 */
contract PointDistributor is Initializable, UUPSUpgradeable, AccessControlUpgradeable {
    // ==============================
    //       EVENTS & ERRORS
    // ==============================
    event PointsDistributed();
    error DISTR__ZeroAddress();
    error DISTR__InvalidPointsReward();


    // ==============================
    //          STORAGE
    // ==============================

    /// @notice Contract for managing rewards both for agents and for delegators.
    address public rewards;

    /// @notice Contract to get current rates for ATS native tokens
    address public DFAdapter;

    /// @notice Chain id of Master Chain
    uint256 public masterChainId;

    /// @notice Executors part of total points reward
    uint256 public executorPart;

    /// @notice Transmitters part of total points reward
    uint256 public transmitterPart;


    // ==============================
    //      ROLES AND CONSTANTS
    // ==============================

    bytes32 public constant ADMIN  = keccak256("ADMIN");
    bytes32 public constant MASTER  = keccak256("MASTER");


    // ==============================
    //         FUNCTIONS
    // ==============================

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize
    /// @param initAddr[0] - Admin address
    /// @param initAddr[1] - Master address
    function initialize(address[] calldata initAddr) public initializer {
        __UUPSUpgradeable_init();
        __AccessControl_init();
        _setRoleAdmin(ADMIN, ADMIN);
        _setRoleAdmin(MASTER, MASTER);
        _grantRole(ADMIN, initAddr[0]);
        _grantRole(MASTER, initAddr[1]);
    }

    /** @notice Do not distribute any points, used only for calculations 
    * @param transmitters - Transmitters addresses
    * @param executors - Executors addresses
    * @param feeAmount - Reward amount to distribute between transmitters and executors
    * @param srcChainId - Source chain id
    * @param destChainId - Destination chain id
    * @return Two arrays for transmitters and executors, which includes exact reward for each transmitter/executor 
    *         according to theirs indexes in incoming address arrays
    */         
    function distributeRewardsCalculation(
        address[] calldata transmitters, 
        address[] calldata executors,
        uint256 feeAmount,
        uint256 srcChainId,
        uint256 destChainId
    ) external view returns(uint[] memory, uint[] memory) {

        uint256[] memory transmitterRewards = new uint[](transmitters.length);
        uint256[] memory executorRewards = new uint256[](executors.length);

        uint256 transmitterTotalPart = transmitters.length * transmitterPart;
        uint256 executorTotalPart = executors.length * executorPart;

        uint256 totalPoints = transmitterTotalPart + executorTotalPart;

        for(uint i; i < transmitters.length; i++) {
            transmitterRewards[i] = transmitterTotalPart * feeAmount / totalPoints;
        }

        uint256 executorReward;
        for (uint i; i < executors.length; i++) {
            executorReward = executorTotalPart * feeAmount / totalPoints;
            executorRewards[i] = IDFAdapter(DFAdapter).convertAmount(srcChainId, destChainId, executorReward);
        }

        return (transmitterRewards, executorRewards);
    }   

    /** @notice Distribute points according to transmitters and executors predefined share 
    *   @param transmitters - Transmitters addresses
    *   @param executors - Executors addresses
    *   @param feeAmount - Reward amount to distribute between transmitters and executors
    *   @param srcChainId - Source chain id
    */
    function distributePointRewards(
        address[] calldata transmitters, 
        address[] calldata executors,
        uint256 feeAmount,
        uint256 srcChainId,
        uint256 /* destChainId */
    ) external onlyRole(MASTER) {
        uint256 transmitterTotalPoints = transmitters.length * transmitterPart;
        uint256 executorTotalPoints = executors.length * executorPart;

        uint256 totalPoints = transmitterTotalPoints + executorTotalPoints;

        uint256 transmittersReward = transmitterTotalPoints * feeAmount / totalPoints;
        uint256 executorsReward = feeAmount - transmittersReward;

        IRewards(rewards).setRewardGroup(srcChainId, transmittersReward, transmitters);
        IRewards(rewards).setRewardGroup(srcChainId, executorsReward, executors);
    }   

    // ==============================
    //            ADMIN
    // ==============================

    function setDFAdapter(address adapter) external onlyRole(ADMIN) {
        if (adapter == address(0)) {
            revert DISTR__ZeroAddress();
        }
        DFAdapter = adapter;
    }

    function setRewards(address vaults) external onlyRole(ADMIN) {
        if (vaults == address(0)) {
            revert DISTR__ZeroAddress();
        }
        rewards = vaults;
    }

    function setMasterChainId(uint256 chainId) external onlyRole(ADMIN) {
        masterChainId = chainId;
    }

    function setExecutorPart(uint256 part) external onlyRole(ADMIN) {
        executorPart = part;
    }

    function setTransmitterPart(uint256 part) external onlyRole(ADMIN) {
        transmitterPart = part;
    }


    // ==============================
    //         UPGRADES
    // ==============================
    function _authorizeUpgrade(address) internal override onlyRole(ADMIN) {}
}