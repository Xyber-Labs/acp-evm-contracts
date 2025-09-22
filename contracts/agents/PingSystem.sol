// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable, AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {IKeyStorage} from "../interfaces/agents/IKeyStorage.sol";

/**
 * @title  PingSystem
 * @notice Contract for tracking agent activity
 */
contract PingSystem is
    Initializable,
    UUPSUpgradeable,
    AccessControlUpgradeable
{
    // ==============================
    //       ERRORS & EVENTS
    // ==============================
    error Ping__InvalidThreshold();
    error Ping__InvalidAddress();
    error Ping__AgentNotFoundFor(bytes key);

    event Ping(address indexed agent);
    event ThresholdChanged(uint256 oldThreshold, uint256 newThreshold);

    // ==============================
    //           ROLES
    // ==============================
    bytes32 public constant ADMIN = keccak256("ADMIN");

    // ==============================
    //           STORAGE
    // ==============================

    /**
     * @dev Stores ping data for an agent
     * @param totalPings The total number of pings recorded
     * @param pings Mapping from index to ping timestamp
     */
    struct PingData {
        uint256 totalPings;
        mapping(uint256 index => uint256 pingTime) pings;
    }

    /// @notice The timing threshold (in seconds) for determining agent activity
    uint256 public threshold;

    /// @notice The address of the key storage contract
    address public keyStorage;

    /// @notice Mapping from agent address to their ping data
    mapping(address agent => PingData) public pingData;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize
    /// @param initAddr[0] - Admin address
    /// @param newThreshold - The timing threshold in seconds
    function initialize(
        address[] calldata initAddr,
        uint256 newThreshold
    ) public initializer {
        __UUPSUpgradeable_init();
        __AccessControl_init();
        _setRoleAdmin(ADMIN, ADMIN);
        _grantRole(ADMIN, initAddr[0]);

        threshold = newThreshold;
    }

    /**
     * @notice Records an agent ping
     */
    function ping() external {
        bytes memory key = abi.encode(_msgSender());
        address agent = IKeyStorage(keyStorage).ownerByKey(key);

        if (agent == address(0)) {
            revert Ping__AgentNotFoundFor(key);
        }

        uint256 indexNow = pingData[agent].totalPings;

        pingData[agent].pings[indexNow] = block.timestamp;
        pingData[agent].totalPings += 1;

        emit Ping(agent);
    }

    /**
     * @notice Checks if an agent is currently active
     * @param agent The address of the agent
     * @return true if the agent is active, otherwise false
     */
    function active(address agent) public view returns (bool) {
        uint256 timeDiff = block.timestamp - lastPingTime(agent);
        if (timeDiff < threshold) {
            return true;
        } else {
            return false;
        }
    }

    /**
     * @notice Checks the active status of multiple agents
     * @param agents The list of agent addresses
     * @return An array of booleans indicating the active status of each agent
     */
    function activeBatch(
        address[] calldata agents
    ) external view returns (bool[] memory) {
        uint256 len = agents.length;
        bool[] memory activeAgents = new bool[](len);
        for (uint256 i = 0; i < len; i++) {
            activeAgents[i] = active(agents[i]);
        }
        return activeAgents;
    }

    /**
     * @notice Returns a filtered list of only active agents
     * @param agents The list of agent addresses
     * @return An array of active agent addresses
     */
    function activeOnly(
        address[] calldata agents
    ) external view returns (address[] memory) {
        uint256 len = agents.length;
        address[] memory temp = new address[](len);
        uint256 count = 0;
        
        for (uint256 i = 0; i < len; i++) {
            if (active(agents[i])) {
                temp[count] = agents[i];
                count++;
            }
        }
        
        address[] memory activeAgents = new address[](count);
        for (uint256 i = 0; i < count; i++) {
            activeAgents[i] = temp[i];
        }
        
        return activeAgents;
    }

    /**
     * @notice Returns the last ping index for an agent
     * @param agent The address of the agent
     * @return The index of the last recorded ping
     */
    function lastPingIndex(address agent) public view returns (uint256) {
        uint256 pings = pingData[agent].totalPings;
        if (pings != 0) {
            return pings - 1;
        }
        return 0;
    }

    /**
     * @notice Returns the last recorded ping timestamp of an agent
     * @param agent The address of the agent
     * @return The timestamp of the last ping
     */
    function lastPingTime(address agent) public view returns (uint256) {
        return pingData[agent].pings[lastPingIndex(agent)];
    }

    // ==============================
    //          ADMIN
    // ==============================

    /**
     * @notice Sets the KeyStorage contract address
     * @param keystorage The address of the KeyStorage contract
     */
    function setKeyStorage(address keystorage) external onlyRole(ADMIN) {
        if (keystorage == address(0)) {
            revert Ping__InvalidAddress();
        }
        keyStorage = keystorage;
    }

    /**
     * @notice Sets the timing threshold for agent activity
     * @param newThreshold The new timing threshold in seconds
     */
    function setTimingThreshold(
        uint256 newThreshold
    ) external onlyRole(ADMIN) {
        if (newThreshold == 0) {
            revert Ping__InvalidThreshold();
        }

        uint256 oldThreshold = threshold;
        threshold = newThreshold;

        emit ThresholdChanged(oldThreshold, newThreshold);
    }

    // ==============================
    //          UPGRADES
    // ==============================
    function _authorizeUpgrade(address) internal override onlyRole(ADMIN) {}
}