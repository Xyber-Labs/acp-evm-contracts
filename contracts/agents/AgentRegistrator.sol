// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable, AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {IKeyStorage} from "../interfaces/agents/IKeyStorage.sol";
import {IAgentManager} from "../interfaces/agents/IAgentManager.sol";
import {AgentLib} from "../lib/AgentLib.sol";

/**
 * @title  Agent Registrator
 * @notice Smart contract for registering agents in ACP
 */
contract AgentRegistrator is
    Initializable,
    UUPSUpgradeable,
    AccessControlUpgradeable
{
    // ==============================
    //          EVENTS
    // ==============================

    event AgentRegistered(address indexed agent);

    // ==============================
    //          ERRORS
    // ==============================

    /* common */
    error Registrator__InvalidAddress(address addr);
    error Registrator__InvalidAgentAddress(address agent);
    error Registrator__InvalidMasterKey(bytes key);
    error Registrator__InvalidKeysAmount(uint256 amount);
    
    /* agents */
    error Registrator__AlreadyRegistered(address masterKey);

    // ==============================
    //      ROLES & CONSTANTS
    // ==============================

    bytes32 public constant ADMIN = keccak256("ADMIN");

    // ==============================
    //          STORAGE
    // ==============================

    /// @notice Contract for managing agent's collections of keys
    address public keyStorage;

    /// @notice Smart contract for managing agents in ACP
    address public agentManager;

    /// @notice This value determines how much keys necessary to register agent
    uint256 public defKeyLen;

    /// @notice This mapping tracks creation time of each unique agent
    mapping(address masterKey => uint256 firstSeenAt) public agentRegistered;

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

    /**
     * @notice Simplified version of agent registration without custom keys
     * @param chainId Chain id of the network agent working on
     * @param agent Agent address
     */
    function registerAgentOneKeyEVM(uint256 chainId, address agent) external {
        bytes[] memory keys = new bytes[](defKeyLen);

        for (uint i = 0; i < defKeyLen; i++) {
            keys[i] = abi.encode(agent);
        }

        _register(chainId, agent, keys);
    }

    /**
     * @notice Simplified version of super agent registration without custom keys
     * @param agent Agent address
     * @dev Chain id for super agents always = 0
     */
    function registerSuperAgentOneKeyEVM(address agent) external {
        bytes[] memory keys = new bytes[](defKeyLen);

        for (uint i = 0; i < defKeyLen; i++) {
            keys[i] = abi.encode(agent);
        }

        _register(0, agent, keys);
    }

    /**
     * @notice Common version of agent registration with opportunity to pass custom keys 
     * @param chainId Chain id of the network agent working on
     * @param agent Agent address
     * @param keys An array with agent's custom keys
     */
    function registerAgent(uint256 chainId, address agent, bytes[] calldata keys) external {
        _register(chainId, agent, keys);
    }

    /**
     * @notice Common version of super agent registration with opportunity to pass custom keys 
     * @param agent Super agent address
     * @param keys An array with super agent's custom keys
     * @dev Chain id for super agents always = 0
     */
    function registerSuperAgent(address agent, bytes[] calldata keys) external {
        _register(0, agent, keys);
    }

    /**
     * @dev Agent status would be PAUSED till registration ends in AgentManager contract
     */
    function _register(uint256 chainId, address agentAddress, bytes[] memory keys) private  {
        if (agentAddress == address(0)) {
            revert Registrator__InvalidAgentAddress(agentAddress);
        }
        if (agentRegistered[agentAddress] != 0) {
            revert Registrator__AlreadyRegistered(agentAddress);
        }
        if (keys.length != defKeyLen) {
            revert Registrator__InvalidKeysAmount(keys.length);
        }
        
        IKeyStorage.KeyType[] memory keyTypes = new IKeyStorage.KeyType[](4);
        keyTypes[0] = IKeyStorage.KeyType.SIGNER;
        keyTypes[1] = IKeyStorage.KeyType.EXECUTOR;
        keyTypes[2] = IKeyStorage.KeyType.RECEIVER;
        keyTypes[3] = IKeyStorage.KeyType.RESERVED;
        
        agentRegistered[agentAddress] = block.timestamp;
        
        AgentLib.Agent memory newAgent;

        if (chainId != 0) {
            IKeyStorage(keyStorage).addKeysFor(agentAddress, chainId, keyTypes, keys);
            newAgent.agentType = AgentLib.AgentType.DEFAULT;
        } else {
            IKeyStorage(keyStorage).superAddKeysFor(agentAddress, keyTypes, keys);
            newAgent.agentType = AgentLib.AgentType.SUPER;
        }

        newAgent.status = AgentLib.AgentStatus.PAUSED;
        newAgent.chainID = chainId;

        
        IAgentManager(agentManager).registerAgent(agentAddress, newAgent);
    }

    // ==============================  
    //       ADMIN & CONFIG
    // ============================== 

    function setKeyStorage(address _keyStorage) external onlyRole(ADMIN) {
        if (_keyStorage == address(0)) {
            revert Registrator__InvalidAddress(_keyStorage);
        }
        keyStorage = _keyStorage;
    }

    function setAgentManager(address _agentManager) external onlyRole(ADMIN) {
        if (_agentManager == address(0)) {
            revert Registrator__InvalidAddress(_agentManager);
        }
        agentManager = _agentManager;
    }

    function setDefKeyLen(uint256 len) external onlyRole(ADMIN) {
        if (len == 0) {
            revert Registrator__InvalidKeysAmount(len);
        }
        defKeyLen = len;
    }

    function debug_zeroiseRegTimestamp(address agent) external onlyRole(ADMIN) {
        agentRegistered[agent] = 0;
    }

    // ==============================  
    //          UPGRADES 
    // ============================== 

    function _authorizeUpgrade(address) internal override onlyRole(ADMIN) {}
}