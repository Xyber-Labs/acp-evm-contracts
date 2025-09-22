// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable, AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {IAgentManager} from "./interfaces/agents/IAgentManager.sol";
import {IPingSystem} from "./interfaces/agents/IPingSystem.sol";
import {IRewards} from "./interfaces/staking/IRewards.sol";
import {IAgentManager} from "./interfaces/agents/IAgentManager.sol";
import {AgentLib} from "./lib/AgentLib.sol";

/**
 * @title  Slasher
 * @notice Contract for slashing unactive agents
 */
contract Slasher is Initializable, UUPSUpgradeable, AccessControlUpgradeable {

    // ==============================
    //       EVENTS & ERRORS
    // ==============================

    event AgentSlashed(address indexed agent, uint256 amount);

    error SLASHER__ZeroAddress();
    error SLASHER__ZeroSlashValue();
    error SLASHER__AgentNotSlashable();
    error SLASHER__SupersNotSlashable();
    

    // ==============================
    //          STORAGE
    // ==============================

    /// @notice Rewards contract address
    address public rewards;

    /// @notice PingSystem contract address
    address public pingSystem;

    /// @notice AgentManager contract address
    address public agentManager;

    /// @notice Minimum slashing value
    uint256 public slashValue;

    /// @notice This mapping saves last time when unique agent was slashed
    mapping(address agent => uint256 lastTimeSlash) public lastSlash;

    /// @notice This mapping is used to count how much times unique agent was slashed
    mapping(address agent => uint256 count) public slashCounter;


    // ==============================
    //      ROLES AND CONSTANTS
    // ==============================
    bytes32 public constant ADMIN  = keccak256("ADMIN");


    // ==============================
    //         FUNCTIONS
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
     * @notice Checks if it's possible to slash agent according to his status, stake and slash cooldown  
     * @param agent Agent address 
     * @return bool True if possible, otherwise false
     */
    function isTimeSlashable(address agent) public view returns(bool) {
        AgentLib.Agent memory objAgent = IAgentManager(agentManager).allAgents(agent);
        uint256 agentChainId = objAgent.chainID;

        if (objAgent.agentType == AgentLib.AgentType.SUPER) {
            return false;
        }

        bool isAgentActive = IPingSystem(pingSystem).active(agent);
        AgentLib.AgentStatus status = IAgentManager(agentManager).getStatus(agent);
        uint256 selfStake = IRewards(rewards).vaultSelfStake(agentChainId, agent);
        uint256 threshold = IPingSystem(pingSystem).threshold();

        if (isAgentActive ||
            status != AgentLib.AgentStatus.PARTICIPANT ||
            selfStake == 0 ||
            (block.timestamp - threshold) < lastSlash[agent]
        ) {
            return false;
        }
        return true;
    }

    /**
     * @notice Checks the slashing value for given agent  
     * @param agent Agent address 
     * @return amount SlashValue if agent's stake more than this value, otherwise full agent's staked amount
     */
    function slashAmount(address agent) public view returns(uint256 amount) {
        if (agent == address(0)) {
            revert SLASHER__ZeroAddress();
        }

        AgentLib.Agent memory objAgent = IAgentManager(agentManager).allAgents(agent);
        uint256 agentChainId = objAgent.chainID;
        uint256 selfStake = IRewards(rewards).vaultSelfStake(agentChainId, agent);

        amount = slashValue;
        if (selfStake < slashValue) {
            amount = selfStake;
        }
    }

    /**
     * @notice Slashes given agent, checking the possibility of this action and determining slashing value  
     * @param agent Agent address 
     */
    function slash(address agent) external {
        AgentLib.Agent memory objAgent = IAgentManager(agentManager).allAgents(agent);
        
        if (agent == address(0)) {
            revert SLASHER__ZeroAddress();
        }
        if (!isTimeSlashable(agent)) {
            revert SLASHER__AgentNotSlashable();
        }
        if (objAgent.agentType == AgentLib.AgentType.SUPER) {
            revert SLASHER__SupersNotSlashable();
        }

        uint256 agentChainId = objAgent.chainID;

        uint256 _slashAmount = slashAmount(agent);
        IRewards(rewards).slash(agentChainId, agent, _slashAmount);

        lastSlash[agent] = block.timestamp;
        slashCounter[agent] += 1;
        
        emit AgentSlashed(agent, _slashAmount);
    }

    // ==============================
    //           ADMIN
    // ==============================
    
    function setAgentManager(address mngr) external onlyRole(ADMIN) {
        if (mngr == address(0)) {
            revert SLASHER__ZeroAddress();
        }
        agentManager = mngr;
    }

    function setRewards(address vaults) external onlyRole(ADMIN) {
        if (vaults == address(0)) {
            revert SLASHER__ZeroAddress();
        }
        rewards = vaults;
    }

    function setPingSystem(address ping) external onlyRole(ADMIN) {
        if (ping == address(0)) {
            revert SLASHER__ZeroAddress();
        }
        pingSystem = ping;
    }

    function setSlashValue(uint256 value) external onlyRole(ADMIN) {
        if (value == 0) {
            revert SLASHER__ZeroSlashValue();
        }
        slashValue = value;
    }

    // ==============================
    //         UPGRADES
    // ==============================
    function _authorizeUpgrade(address) internal override onlyRole(ADMIN) {}
}