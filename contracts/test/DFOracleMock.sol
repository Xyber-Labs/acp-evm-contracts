// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable, AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";

contract DFOracleMock is  Initializable, UUPSUpgradeable, AccessControlUpgradeable {

    // ==============================
    //          STORAGE
    // ==============================
    bytes32 public constant ADMIN = keccak256("ADMIN");



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

    struct LatestUpdate {
        /// @notice The price for asset from latest update
        uint256 latestPrice;
        /// @notice The timestamp of latest update
        uint256 latestTimestamp;
    }

    uint256 public minimumFee;

    mapping(bytes32 dataKey => LatestUpdate) public latestUpdate;

    function setLatestUpdate(bytes32 key, uint256 k) external {
        LatestUpdate memory upd = LatestUpdate({
            latestPrice: 1 * k,
            latestTimestamp: block.timestamp
        });

        latestUpdate[key] = upd;
    }

    function getFeedPrice(bytes32 dataKey) public view returns (LatestUpdate memory) {
        return latestUpdate[dataKey];
    }

    function subscribe(bytes32 feed, uint256 deviation, uint256 heartbeat, address[] calldata readers) public payable {

    }

    function topUp(bytes32 feed) external payable {

    }

    function checkIfReadersCanRead(bytes32 feed, address[] calldata readers) external view returns(bool[] memory) {

    }

    function getSubscriberReaders(bytes32 feed, address subscriber) external view returns(address[] memory) {
        
    }

    function _authorizeUpgrade(address) internal override onlyRole(ADMIN) {}
}