// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable, AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {IAgentManager} from "./interfaces/agents/IAgentManager.sol";
import {IPingSystem} from "./interfaces/agents/IPingSystem.sol";

/**
 * @title  Chain Info
 * @notice Contract for storing and reading current chain info
 * @dev    Should be used mostly as public
 */
contract ChainInfo is Initializable, UUPSUpgradeable, AccessControlUpgradeable {
    // ==============================
    //       EVENTS & ERRORS
    // ==============================
    event ChainInfoChanged(
        uint256 indexed chainId,
        address DFEndpoint,
        bytes32 dataKey,
        string name,
        string baseCoinTicker,
        string defaultRpcNode,
        uint8 decimals,
        bytes endpoint,
        bytes configurator,
        bytes oracle
    );
    event ChainParamsChanged(
        uint256 indexed chainId,
        uint256 blockFinalizationTime,
        uint256 defaultExecutionTime
    );
    event ConsensusRateChanged(uint256 indexed chainID, uint256 roundConsensusRate);
    event SuperConsensusRateChanged(
        uint256 indexed chainID,
        uint256 roundConsensusRate
    );
    event ChainGasInfoChanged(
        uint256 indexed chainId,
        uint256 defaultGas,
        uint256 oneSignatureGas,
        uint256 turnRoundGas
    );

    error ChainInfo__InvalidAddressLength(bytes addr, uint256 length);
    error ChainInfo__InvalidChainId();
    error ChainInfo__ZeroAddress();
    error ChainInfo__InvalidArrays();
    error ChainInfo__InvalidNewRoundConsensusRate();

    // ==============================
    //      ROLES AND CONSTANTS
    // ==============================
    bytes32 public constant ADMIN  = keccak256("ADMIN");
    bytes32 public constant SETTER = keccak256("SETTER");

    uint256 public constant MIN_RATE = 5000;

    // ==============================
    //         STORAGE
    // ==============================

    struct ChainData {
        address DFEndpoint;
        bytes32 dataKey;
        uint256 defaultExecutionTime;
        uint256 blockFinalizationTime;
        uint256 roundConsensusRate;
        uint256 roundSuperConsensusRate;
        string  baseCoinTicker;
        string  defaultRpcNode;
        string  name;
        uint8   decimals;
        bytes   endpoint;
        bytes   configurator;
        bytes   pullOracle;
        uint256 gasLimit;
    }

    struct GasInfo {
        uint256 defaultGas;
        uint256 oneSignatureGas;
        uint256 turnRoundGas;
    }

    /// @notice Contract for managing agents in ACP
    address public agentManager;

    /// @notice Contract for tracking agent activity
    address public pingSystem;

    address public master;
    address public slasher;
    address public rotator;

    /// @notice Chain IDs of all networks
    uint256[] allChains;

    /// @notice Maping that stores supported networks
    mapping(uint256 chainId => bool exist) public chainSupported;

    /// @notice Mapping that stores networks informations
    mapping(uint256 chainID => ChainData) public chains;

    /// @notice Mapping that stores networks gas consumption infomations
    mapping(uint256 chainID => GasInfo) public chainsGas;

    /// @notice Mapping that defines amount of blocks for each of
    /// finalization options for each chain
    mapping(uint256 chainID => mapping(uint256 finalizationCode => uint256 blocks)) public finalizationOptions;


    // ==============================
    //         FUNCTIONS
    // ==============================

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize
    /// @param initAddr[0] - Admin address
    /// @param initAddr[1] - Agent manager
    /// @param initAddr[2] - Ping System address
    /// @param initAddr[3] = Rotator address
    function initialize(address[] calldata initAddr) public initializer {
        __UUPSUpgradeable_init();
        __AccessControl_init();
        _setRoleAdmin(ADMIN, ADMIN);
        _setRoleAdmin(SETTER, ADMIN);
        _grantRole(ADMIN, initAddr[0]);
        _grantRole(SETTER, initAddr[0]);
        _grantRole(SETTER, initAddr[1]);
        _grantRole(SETTER, initAddr[3]);

        agentManager = initAddr[1];
        pingSystem = initAddr[2];
    }

    /**
     * @notice Updates core chain configuration parameters
     * @dev Restricted to ADMIN role
     * @param chainId  Chain ID
     * @param _endpoint New messaging endpoint address
     * @param DFEndpoint New DF endpoint address
     * @param dataKey New data verification key
     * @param decimals Native currency decimal places
     * @param name Human-readable chain name
     * @param baseCoinTicker Native currency symbol
     * @param defaultRpcNode Default RPC endpoint URL
     * @param configurator Configurator address
     * @param pullOracle Oracle address
     */
    function setChainInfo(
        uint256 chainId,
        address DFEndpoint,
        bytes32 dataKey,
        uint8 decimals,
        string calldata name,
        string calldata baseCoinTicker,
        string calldata defaultRpcNode,
        bytes  calldata _endpoint,
        bytes  calldata configurator,
        bytes  calldata pullOracle
    ) external onlyRole(ADMIN) {
        uint256 encodedAddrLength = 32;
        if (configurator.length != encodedAddrLength) {
            revert ChainInfo__InvalidAddressLength(configurator, configurator.length);
        }
        if (DFEndpoint == address(0)) {
            revert ChainInfo__ZeroAddress();
        }
        if (pullOracle.length != encodedAddrLength) {
            revert ChainInfo__InvalidAddressLength(pullOracle, pullOracle.length);
        }
        if (_endpoint.length != encodedAddrLength) {
            revert ChainInfo__InvalidAddressLength(_endpoint, _endpoint.length);
        }
        
        chains[chainId].name = name;
        chains[chainId].defaultRpcNode = defaultRpcNode;
        chains[chainId].endpoint = _endpoint;
        chains[chainId].configurator = configurator;
        chains[chainId].DFEndpoint = DFEndpoint;
        chains[chainId].baseCoinTicker = baseCoinTicker;
        chains[chainId].dataKey = dataKey;
        chains[chainId].decimals = decimals;
        chains[chainId].pullOracle = pullOracle;

        bool isSupported = chainSupported[chainId];
        if (!isSupported) {
            chainSupported[chainId] = true;
            allChains.push(chainId);
        }

        emit ChainInfoChanged(
            chainId,
            DFEndpoint,
            dataKey,
            name,
            baseCoinTicker,
            defaultRpcNode,
            decimals,
            _endpoint,
            configurator,
            pullOracle
        );
    }

    function setInfoContracts(
        address _master,
        address _slasher,
        address _rotator
    ) external onlyRole(ADMIN) {
        master = _master;
        slasher = _slasher;
        rotator = _rotator;
    }

    /**
     * @notice Updates chain timing parameters
     * @dev Restricted to SETTER role
     * @param chainId Chain ID
     * @param blockFinalizationTime Block confirmation time (seconds)
     * @param defaultExecutionTime Execution time (seconds)
     */
    function setChainParams(
        uint256 chainId,
        uint256 blockFinalizationTime,
        uint256 defaultExecutionTime
    ) external onlyRole(SETTER) {
        chains[chainId].blockFinalizationTime = blockFinalizationTime;
        chains[chainId].defaultExecutionTime = defaultExecutionTime;

        emit ChainParamsChanged(
            chainId,
            blockFinalizationTime,
            defaultExecutionTime
        );
    }

    /**
     * @notice Updates chain gas information
     * @dev Restricted to SETTER role
     * @param chainId Chain ID
     * @param defaultGas ?
     * @param oneSignatureGas Amount of gas required to verify one agent signature
     * @param turnRoundGas Amount of gas required to proceed turn round operation
     */
    function setGasInfo(
        uint256 chainId,
        uint256 defaultGas,
        uint256 oneSignatureGas,
        uint256 turnRoundGas
    ) external onlyRole(SETTER) {
        chainsGas[chainId].defaultGas = defaultGas;
        chainsGas[chainId].oneSignatureGas = oneSignatureGas;
        chainsGas[chainId].turnRoundGas = turnRoundGas;

        emit ChainGasInfoChanged(
            chainId,
            defaultGas,
            oneSignatureGas,
            turnRoundGas
        );
    }

    /**
     * @notice Set defined finalization options
     * @param chainID Chain ID
     * @param options Finalization options codes. See `TransmitterParamsLib`.
     * @param blocks  Amount of blocks for an option
     */
    function setFinalizations(
        uint256 chainID, 
        uint256[] calldata options,
        uint256[] calldata blocks
    ) external onlyRole(SETTER) {
        uint256 len = options.length;
        if (len != blocks.length) {
            revert ChainInfo__InvalidArrays();
        }
        for (uint256 i; i < len; i++) {
            finalizationOptions[chainID][options[i]] = blocks[i]; 
        }
    }

    /**
     * @notice Updates chain consensus rate
     * @param chainID Chain ID
     * @param newRoundConsensusRate New consensus rate
     */
    function changeConsensusRate(
        uint256 chainID,
        uint256 newRoundConsensusRate
    ) external onlyRole(SETTER) {
        if (newRoundConsensusRate < MIN_RATE) {
            revert ChainInfo__InvalidNewRoundConsensusRate();
        }
        chains[chainID].roundConsensusRate = newRoundConsensusRate;
        emit ConsensusRateChanged(chainID, newRoundConsensusRate);
    }

    /**
     * @notice Updates super consensus rate
     * @param chainID Chain ID
     * @param newRoundSuperConsensusRate  New super consensus rate
     */
    function changeSuperConsensusRate(
        uint256 chainID,
        uint256 newRoundSuperConsensusRate
    ) external onlyRole(SETTER) {
        if (newRoundSuperConsensusRate < MIN_RATE) {
            revert ChainInfo__InvalidNewRoundConsensusRate();
        }
        chains[chainID].roundSuperConsensusRate = newRoundSuperConsensusRate;
        emit SuperConsensusRateChanged(chainID, newRoundSuperConsensusRate);
    }

    // ==============================
    //         GETTERS
    // ==============================

    /**
     * @notice Get finalization for finalization options
     * @param chainID Chain ID
     * @param codes Finalization option codes.
     */
    function getFinalizations(
        uint256 chainID,
        uint256[] calldata codes
    ) external view returns(uint256[] memory) {
        uint256 len = codes.length;
        uint256[] memory finalizations = new uint256[](len);
        for (uint256 i; i < len; i++) {
            finalizations[i] = finalizationOptions[chainID][codes[i]];
        }

        return finalizations;
    }

    /**
     * @notice Retrieves complete chain configuration data
     * @param chainId Chain ID
     * @return Complete ChainData structure for specified chain
     */
    function getChainInfo(
        uint256 chainId
    ) external view returns (ChainData memory) {
        return chains[chainId];
    }

    /**
     * @notice Retrieves execution time for a given chain 
     * @param chainID Chain ID
     * @return defaultExecutionTime execution time in seconds
     */
    function getDefaultExecutionTime(
        uint256 chainID
    ) external view returns (uint256) {
        return chains[chainID].defaultExecutionTime;
    }

    /**
     * @notice Retrieves consensus rate for a given chain
     * @param chainID Chain ID
     * @return roundConsensusRate Consenus rate
     */
    function getConsensusRate(uint256 chainID) external view returns (uint256) {
        return chains[chainID].roundConsensusRate;
    }

    /**
     * @notice Retrieves super consensus rate for a given chain
     * @param chainID Chain ID
     * @return roundSuperConsensusRate Super consensus rate
     */
    function getSuperConsensusRate(
        uint256 chainID
    ) external view returns (uint256) {
        return chains[chainID].roundSuperConsensusRate;
    }

    /**
     * @notice Retrieves enpdpoint address for a given chain
     * @param chainId Chain ID
     * @return enpoint Encoded endpoint address
     */
    function getEndpoint(
        uint256 chainId
    ) external view returns (bytes memory) {
        return chains[chainId].endpoint;
    }

    /**
     * @notice Retrieves configurator address for a given chain
     * @param chainId Chain ID
     * @return configurator Encoded configurator address
     */
    function getConfigurator(
        uint256 chainId
    ) external view returns (bytes memory) {
        return chains[chainId].configurator;
    }

    /**
     * @notice Retrieves decimals for given chains
     * @param chainId_1 Chain ID of first network
     * @param chainId_2 Chain ID of second network
     * @return A pair of decimals
     */
    function getDecimalsByChains(
        uint256 chainId_1,
        uint256 chainId_2
    ) external view returns (uint256, uint256) {
        return (chains[chainId_1].decimals, chains[chainId_2].decimals);
    }

    /**
     * @notice Calculates number of active agents for a chain
     * @param chainId Chain ID
     * @return activeAgentsNumber Count of currently active agents
     */
    function getActiveAgentsNumber(
        uint256 chainId
    ) public view returns (uint256) {
        address[] memory currentParticipants = IAgentManager(agentManager).getCurrentParticipants(chainId);
        IPingSystem pingSystemContract = IPingSystem(pingSystem);
        uint256 activeAgentsNumber = 0;

        for (uint256 i = 0; i < currentParticipants.length; ++i) {
            if (pingSystemContract.active(currentParticipants[i])) {
                activeAgentsNumber++;
            }
        }

        return activeAgentsNumber;
    }

     /**
     * @notice Returns amount of active super agents in current round
     */
    function getActiveSuperAgentsNumber(
        uint256 chainId
    ) public view returns (uint256, uint256) {
        address[] memory supers = IAgentManager(agentManager).activeSupersAddr(chainId);
        address[] memory activeSupers = IPingSystem(pingSystem).activeOnly(supers);

        return (supers.length, activeSupers.length);
    }

    /**
     * @notice Retrieves the list of all registered chains
     */
    function getAllChains() external view returns(uint256[] memory) {
        return allChains;
    }

    /**
     * @notice Retrieves gas information for given chain id
     */
    function getGasInfo(uint256 chainId) external view returns(GasInfo memory) {
        return chainsGas[chainId];
    }

    /**
     * @notice Checks if a chain meets minimum operational requirements
     * @param chainId Chain ID
     * @return true if the chain has at least 3 active agents and 
     *  this is at least half of the registered agents of the round, false otherwise
     */
    function isChainActive(
        uint256 chainId
    ) external view returns (bool) {
        uint256 activeAgentsNumber = getActiveAgentsNumber(chainId);
        (uint256 s, uint256 sActive) = getActiveSuperAgentsNumber(0);

        bool enoughSupers;
        if (s == 1 && sActive == 1) {
            enoughSupers = true;
        } else if (s % 2 == 0) {
            enoughSupers = sActive >= s / 2;
        } else {
            enoughSupers = sActive > s / 2;
        }

        if (
            s != 0 &&
            enoughSupers &&
            activeAgentsNumber >= 3 &&
            activeAgentsNumber > (IAgentManager(agentManager).getCurrentParticipantsLen(chainId) / 2)
        ) {
            return true;
        }

        return false;
    }

    // ==============================
    //         UPGRADES
    // ==============================
    function _authorizeUpgrade(address) internal override onlyRole(ADMIN) {}
}
