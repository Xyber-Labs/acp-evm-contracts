// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable, AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20Mintable} from "../interfaces/external/IERC20Mintable.sol";
import {IWNative} from "../interfaces/external/IWNative.sol";
import {IRotator} from "../interfaces/IRotator.sol";
import {IAgentManager, AgentLib} from "../interfaces/agents/IAgentManager.sol";

/**
 * @title RewardVaults (deprecated)
 * @notice
 * Reward Vaults is a contract for managing rewards
 * both for agents and for delegators.
 */
contract RewardVaults is  
    Initializable,
    UUPSUpgradeable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable
{
    using SafeERC20 for IERC20Mintable;
    using SafeERC20 for IWNative;

    // ==============================
    //          EVENTS
    // ==============================

    event Deposit(
        uint256 indexed chainID,
        address indexed agent,
        address indexed delegator,
        uint256 amount
    );

    event Withdraw(
        uint256 indexed chainID,
        address indexed agent,
        address indexed delegator,
        uint256 amount
    );

    event Reward(
        uint256 indexed chainID,
        address indexed agent,
        uint256 amount,
        uint256 delegationRewards,
        uint256 agentRewards
    );

    event RewardReleased(
        uint256 indexed chainID, 
        address indexed token, 
        address to, 
        uint256 amount
    );

    event ShareSet(
        uint256 indexed chainID,
        address indexed agent,
        uint256 oldShare,
        uint256 newShare
    );

    event Harvest(
        uint256 indexed chainID,
        address indexed agent,
        address indexed delegator,
        address receiver,
        uint256 amount
    );

    event Slash(
        address indexed agent,
        uint256 amount
    );

    event MinStakeSet(uint256 oldMinStake, uint256 newMinStake);

    // ==============================
    //          ERRORS
    // ==============================
    error InvalidAddress();
    error InvalidAmount();
    error InvalidShare();
    error InvalidCooldown();
    error RewardVaults__Cooldown(uint256 toWait);
    error RewardVaults__LengthMismatch();

    // ==============================
    //      ROLES & CONSTANTS
    // ==============================

    uint256 public constant PERCENT_DENOM = 10_000;
    uint256 public constant SHARE_DENOM   = 1e18;

    bytes32 public constant ADMIN     = keccak256("ADMIN");
    bytes32 public constant SLASHER   = keccak256("SLASHER");
    bytes32 public constant REWARDER  = keccak256("REWARDER");
    bytes32 public constant DEPOSITOR = keccak256("DEPOSITOR");


    // ==============================
    //           STORAGE
    // ==============================

    struct Position {
        uint256 delegation;
        uint256 rewardDebt;
        uint256 lastUpdate;
    }

    struct VaultStats {
        uint256 totalARewardsReceived;
        uint256 totalDRewardsReceived;
    }

    struct Vault {
        VaultStats stats;
        uint256 rps;
        uint256 agentRewards;
        uint256 delegationRewards;
        uint256 delegationSharePercent;
        uint256 selfStake;
        uint256 totalDelegation;
        mapping(address => Position) delegators;
    }

    struct NetworkSet {
        uint256[] chainIDs;
        address[] agentList;
        mapping(address agent => bool) agentSeen;
        mapping(uint256 chainID => bool) seenOn;
    }

    /// @dev Protection from "delegation-switch" speculations
    uint256 public cooldown;

    /// @dev Minimum stake for agent to be activated
    uint256 public minStake;

    /// @dev Contract for epoch change
    address public rotator;


    /// @dev Contract or EOA for receiving agent slashes
    address public treasury;

    /// @dev Wrapped native for Master Chain
    IWNative public wNative;

    /// @dev Contract for agent management
    address public agentManager;

    address public ACPReserve;

    mapping(uint256 chainID => IERC20Mintable) public tokens;
    mapping(uint256 chainID => mapping(address => Vault)) public vaults;
    mapping(address some => NetworkSet) netInfo;
    mapping(uint256 chainId => mapping(address agent => mapping (address delegator => uint256 rewards))) public accumulatedRewards;

    // ==============================
    //          FUNCTIONS
    // ==============================

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize
    /// @param  initAddr[0] - Admin address
    /// @param initAddr[1] - Slasher address
    /// @param initAddr[2] - Point Distributor address
    /// @param initAddr[3] - Master address
    function initialize(
        address[] calldata initAddr
    ) public initializer {
        __UUPSUpgradeable_init();
        __AccessControl_init();
        __ReentrancyGuard_init();

        _setRoleAdmin(ADMIN, ADMIN);
        _setRoleAdmin(REWARDER, ADMIN);
        _setRoleAdmin(SLASHER, ADMIN);
        _setRoleAdmin(DEPOSITOR, ADMIN);

        _grantRole(ADMIN, initAddr[0]);
        _grantRole(SLASHER, initAddr[1]);
        _grantRole(REWARDER, initAddr[2]);
        _grantRole(REWARDER, initAddr[3]);
    }
    

    /**
     * @notice Deposit into the vault (make a delegation to agent)
     * @param chainID       - Chain ID agents is working on
     * @param agent         - Agent EVM address
     * @param wrappedAmount - Amount to deposit via wrapped token
     */
    function deposit(
        uint256 chainID,
        address agent,
        uint256 wrappedAmount
    ) external payable {
        uint256 amount = _transferHelper(_msgSender(), wrappedAmount);
        _deposit(chainID, agent, _msgSender(), amount);
    }

    /**
     * @notice Deposit rewards for someone
     * @dev Granted to a higher-level contracts
     * @param chainID - Chain ID agents is working on
     * @param agent - Agent EVM address
     * @param delegator - Delegator EVM address
     * @param wrappedAmount - Amount of wNative
     */
    function depositFor(
        uint256 chainID,
        address agent,
        address delegator,
        uint256 wrappedAmount
    ) external payable onlyRole(DEPOSITOR) {
        uint256 amount = _transferHelper(delegator, wrappedAmount);
        _deposit(chainID, agent, delegator, amount);
    }

    function setVaultShareFor(
        uint256 chainID,
        uint256 newSharePercent,
        address agent
    ) external payable onlyRole(DEPOSITOR) {
        if (newSharePercent > PERCENT_DENOM) {
            revert InvalidShare();
        }
        uint256 oldSharePercent = vaults[chainID][agent].delegationSharePercent;
        vaults[chainID][agent].delegationSharePercent = newSharePercent;

        emit ShareSet(chainID, agent, oldSharePercent, newSharePercent);
    }

    function _transferHelper(
        address from,
        uint256 wrappedAmount
    ) private returns (uint256) {
        uint256 amount;

        if (wrappedAmount != 0) {
            wNative.safeTransferFrom(from, address(this), wrappedAmount);
            amount += wrappedAmount;
        }

        if (msg.value != 0) {
            wNative.deposit{value: msg.value}();
            amount += msg.value;
        }

        return amount;
    }

    function _deposit(
        uint256 chainID,
        address agent,
        address delegator,
        uint256 amount
    ) private {
        if (delegator == agent) {
            vaults[chainID][agent].selfStake += amount;
        } else {
            accumulatedRewards[chainID][agent][delegator] = delegatorPendingRewards(chainID, agent, delegator);

            Position storage position =  vaults[chainID][agent].delegators[delegator];
            position.delegation += amount;
            vaults[chainID][agent].totalDelegation += amount;
            
            _updateRPS(chainID, agent);

            position.rewardDebt = _getPendingRaw(chainID, agent, delegator);
            position.lastUpdate = block.timestamp;
        }

        if (!netInfo[delegator].seenOn[chainID]) {
            netInfo[delegator].seenOn[chainID] = true;
            netInfo[delegator].chainIDs.push(chainID);
        }

        if (!netInfo[delegator].agentSeen[agent]) {
            netInfo[delegator].agentSeen[agent] = true;
            netInfo[delegator].agentList.push(agent);
        }

        emit Deposit(chainID, agent, delegator, amount);
    }

    function withdrawBatch(address[] memory agents, uint256[] memory chainIds) external nonReentrant() onlyRole(ADMIN) {
        if (agents.length != chainIds.length) revert RewardVaults__LengthMismatch();

        uint256 toTransfer;
        for (uint256 i = 0; i < agents.length; ++i) {
            uint256 chainId = chainIds[i];
            address agent = agents[i];

            uint256 selfStake = vaults[chainId][agent].selfStake;
            if (selfStake <= 1) continue;

            uint256 toWithdraw = selfStake - 11; // protect from disabling activity
            vaults[chainId][agent].selfStake -= toWithdraw;
            toTransfer += toWithdraw;
        }

        wNative.withdraw(toTransfer);
        (bool success,) = payable(_msgSender()).call{value: toTransfer}("");
        if (!success) revert("Transfer failed");
    }

    /**
     * @notice Withdraw from the vault
     * @param chainID - Chain ID agents is working on
     * @param agent   - Agent EVM address
     * @param amount  - Amount to withdraw
     * @param unwrap  - Unwrap Wrapped Token or not
     */
    function withdraw(
        uint256 chainID,
        address agent,
        uint256 amount,
        bool unwrap
    ) external nonReentrant {
        _withdraw(chainID, agent, _msgSender(), amount, unwrap);
    }

    /**
     * @notice Withdraw rewards for someone
     * @dev Granted to a higher-level contracts
     * @param chainID   - Chain ID agents is working on
     * @param agent     - Agent EVM address
     * @param delegator - Delegator EVM address
     * @param amount    - Amount to withdraw
     * @param unwrap    - Unwrap Wrapped Token or not
     */
    function withdrawFor(
        uint256 chainID,
        address agent,
        address delegator,
        uint256 amount,
        bool unwrap
    ) external nonReentrant onlyRole(DEPOSITOR) {
        _withdraw(chainID, agent, delegator, amount, unwrap);
    }

    function withdrawAll(bool unwrap) external nonReentrant {
        address delegator = _msgSender();
        address[] memory agents = netInfo[delegator].agentList;

        for (uint256 i = 0; i < agents.length; ++i) {
            if (agents[i] == delegator) { continue; }

            uint256[] memory chains = netInfo[agents[i]].chainIDs;
            for (uint256 j = 0; j < chains.length; ++j) {
                uint256 amountToWithdraw = vaults[chains[j]][agents[i]].delegators[delegator].delegation;

                if (amountToWithdraw == 0) { continue; }
                _withdraw(chains[j], agents[i], delegator, amountToWithdraw, unwrap);
            }
        }
    }

    function _withdraw(
        uint256 chainID,
        address agent,
        address delegator,
        uint256 amount,
        bool unwrap
    ) private {
        if (amount == 0) {
            revert InvalidAmount();
        }
        uint256 toWithdraw;

        if (delegator == agent) {
            uint256 selfStake = vaults[chainID][agent].selfStake;
            if (selfStake != 0) {
                toWithdraw = _min(amount, selfStake);
                vaults[chainID][agent].selfStake -= toWithdraw;
            }

            // If agent is active we dropping him automatically 
            // and unlocking round change for network
            if (vaults[chainID][agent].selfStake == 0) {
                AgentLib.AgentStatus status = IAgentManager(agentManager).getStatus(agent);

                if (status == AgentLib.AgentStatus.PARTICIPANT) {
                    _drop(chainID, agent);
                }
            }
        } else {
            uint256 lastUpdate = vaults[chainID][agent].delegators[delegator].lastUpdate;
            if (block.timestamp < lastUpdate + cooldown) {
                uint256 diff = lastUpdate + cooldown - block.timestamp;
                revert RewardVaults__Cooldown(diff);
            }
            uint256 delegationNow = vaults[chainID][agent].delegators[delegator].delegation;
            if (delegationNow != 0) {
                accumulatedRewards[chainID][agent][delegator] = delegatorPendingRewards(chainID, agent, delegator);

                toWithdraw = _min(amount, delegationNow);
                vaults[chainID][agent].delegators[delegator].delegation -= toWithdraw;
                vaults[chainID][agent].totalDelegation -= toWithdraw;

                _updateRPS(chainID, agent);

                Position storage position = vaults[chainID][agent].delegators[delegator];
                position.rewardDebt = _getPendingRaw(chainID, agent, delegator);
                position.lastUpdate = block.timestamp;
            }
        }


        if (unwrap) {
            wNative.withdraw(toWithdraw);
            (bool success,) = payable(delegator).call{value: toWithdraw}("");
            if (!success) revert("Transfer failed");
        } else {
            wNative.safeTransfer(delegator, toWithdraw);
        }

        emit Withdraw(chainID, agent, delegator, toWithdraw);
    }

    /**
     * @dev Force unlocking current round to be changed.
     * Dropped agent is prioritized for change
     * @param chainID ChainID
     * @param agent   Agent to drop
     */
    function _drop(
        uint256 chainID,
        address agent
    ) private {
        IRotator(rotator).dropAgent(chainID, agent);
    }

    /**
     * @notice Harvest rewards from the vault
     * @param chainID - Chain ID agents is working on
     * @param agent   - Agent EVM address
     */
    function harvest(
        uint256 chainID,
        address agent,
        address receiver
    ) public {
        uint256 pending;

        if (_msgSender() == agent) {
            pending = vaultAgentRewards(chainID, agent);
            _agentHarvest(chainID, agent, pending);
        } else {
            pending = delegatorPendingRewards(chainID, agent, receiver);
            _harvest(chainID, agent, receiver, pending);
        }
    }

    /**
     * @notice Harvest all rewards from all the vaults on one chain
     * @param receiver - EVM address of receiver
     */
    function harvestBatch(
        uint256 chainID,
        address receiver
    ) public {
        address[] memory agents = netInfo[_msgSender()].agentList; 
        for (uint256 i; i < agents.length; i++) {
            harvest(chainID, agents[i], receiver);
        }
    }

    /**
     * @notice Harvest all rewards from all the vaults on all chains
     */
    function harvestAll() external {
        uint256[] memory chains = netInfo[_msgSender()].chainIDs;
        for (uint256 i; i < chains.length; i++) {
            harvestBatch(chains[i], _msgSender());
        }
    }

    /**
     * @dev Harvest rewards from the vault for delegator
     */
    function _harvest(
        uint256 chainID,
        address agent,
        address receiver,
        uint256 amount
    ) private {
        _updateRPS(chainID, agent);
        
        Position storage position = vaults[chainID][agent].delegators[_msgSender()];
        position.rewardDebt = _getPendingRaw(chainID, agent, _msgSender());

        _rewardATSMint(chainID, amount, receiver);
        accumulatedRewards[chainID][agent][receiver] = 0;
        
        if (amount != 0) {
            emit Harvest(chainID, agent, _msgSender(), receiver, amount);
        }
    }

    /**
     * @dev Harvest rewards from the vault for agent caller
     */
    function _agentHarvest(
        uint256 chainID,
        address agent,
        uint256 amount
    ) private {
        vaults[chainID][agent].agentRewards -= amount;
        _rewardATSMint(chainID, amount, agent);

        emit Harvest(chainID, agent, agent, agent, amount);
    }

    /**
     * @dev Mint ATS rewards
     */
    function _rewardATSMint(
        uint256 chainID,
        uint256 amount,
        address to
    ) private {
        IERC20Mintable token = tokens[chainID];

        if (amount != 0) {
            token.mint(to, amount);
        }

        if (amount != 0) {
            emit RewardReleased(chainID, address(token), to, amount);
        }
    }

    /**
     * @notice Set rewards for the agent
     * @dev Triggered on consensus finalisation only.
     * Can only be called by REWARDER (initially - master)
     * @param chainID - Chain ID agents is working on
     * @param agent   - Agent EVM address
     * @param amount  - Amount of rewards
     */
    function setReward(
        uint256 chainID,
        address agent,
        uint256 amount,
        bool compensation
    ) public onlyRole(REWARDER) {
        uint256 aRew;
        uint256 dRew;

        if (compensation) {
            aRew = amount;
        } else {
            dRew = (amount * vaultDelegationSharePercent(chainID, agent)) / PERCENT_DENOM;
            aRew = amount - dRew;
        }

        vaults[chainID][agent].agentRewards += aRew;
        vaults[chainID][agent].delegationRewards += dRew;
        vaults[chainID][agent].stats.totalARewardsReceived += aRew;
        vaults[chainID][agent].stats.totalDRewardsReceived += dRew;

        _updateRPS(chainID, agent);

        if (!netInfo[agent].seenOn[chainID]) {
           netInfo[agent].seenOn[chainID] = true;
           netInfo[agent].chainIDs.push(chainID);
        }

        if (!netInfo[agent].agentSeen[agent]) {
           netInfo[agent].agentSeen[agent] = true; 
           netInfo[agent].agentList.push(agent);
        }

        emit Reward(chainID, agent, amount, dRew, aRew);
    }

    /**
     * @notice Set reward for group of agents. Reward is distributed equally
     * @param chainID - Chain ID agents are working on
     * @param amount  - Amount of rewards
     * @param agents  - Agent EVM addresses
     */
    function setRewardGroup(
        uint256 chainID,
        uint256 amount,
        address[] calldata agents
    ) external onlyRole(REWARDER) {
        uint256 len = agents.length;
        uint256 oneEntityReward = amount / len;
        for (uint256 i; i < len; i++) {
            setReward(chainID, agents[i], oneEntityReward, false);
        }
    }

    /**
     * @notice Slash agent self-stake as a punishment for 
     * downtime or bad behavior
     * @param chainID - Chain ID agents is working on
     * @param agent   - Agent EVM address
     * @param amount  - Amount of rewards
     */
    function slash(
        uint256 chainID,
        address agent,
        uint256 amount
    ) external onlyRole(SLASHER) {
        uint256 selfStakeNow = vaults[chainID][agent].selfStake;
        uint256 toSlash = _min(amount, selfStakeNow);

        if (toSlash != 0) {
            vaults[chainID][agent].selfStake -= toSlash;
            wNative.safeTransfer(treasury, toSlash);
        }

        emit Slash(agent, toSlash);
    }

    function _min(uint256 a, uint256 b) private pure returns (uint256) {
        if (a < b) return a;
        return b;
    }

    receive() external payable {}

    // ==============================
    //        VAULT GETTERS
    // ==============================

    /**
     * @notice Get self-stake for agent
     * @param chainID - Chain ID agent is working on
     * @param agent   - Agent EVM address
     */
    function vaultSelfStake(
        uint256 chainID,
        address agent
    ) external view returns (uint256) {
        return vaults[chainID][agent].selfStake;
    }

    /**
     * @notice Check wNative vault balances for multiple agents
     * @param chainID - Chain ID agents are working on
     * @param agent   - Agent EVM addresses
     */
    function vaultBalance(
        uint256 chainID,
        address agent
    ) public view returns (uint256) {
        return vaults[chainID][agent].selfStake + vaults[chainID][agent].totalDelegation;
    }

    /**
     * @notice Check wNative vault balances for multiple agents
     * @param chainID - Chain ID agents are working on
     * @param agents  - Agent EVM addresses
     */
    function vaultBalanceBatch(
        uint256 chainID,
        address[] calldata agents
    ) external view returns (uint256[] memory) {
        uint256 len = agents.length;
        uint256[] memory balances = new uint256[](len);
        for (uint256 i = 0; i < len; i++) {
            uint256 balance = vaultBalance(chainID, agents[i]);
            balances[i] = balance;
        }

        return balances;
    }

    /**
     * @notice Get delegation share percent which 
     * defines amount of reward for delegators
     * @param chainID - Chain ID agent is working on
     * @param agent   - Agent EVM address
     */
    function vaultDelegationSharePercent(
        uint256 chainID,
        address agent
    ) public view returns (uint256) {
        return vaults[chainID][agent].delegationSharePercent;
    }

    /**
     * @notice Get accumulated rewards for agent
     * @param chainID - Chain ID agent is working on
     * @param agent   - Agent EVM address
     */
    function vaultAgentAccumulated(
        uint256 chainID,
        address agent
    ) public view returns (uint256) {
        Vault storage vault = vaults[chainID][agent];
        return vault.stats.totalARewardsReceived;
    }

    /**
     * @notice Get accumulated rewards for delegators
     * @param chainID - Chain ID agent is working on
     * @param agent   - Agent EVM address
     */
    function vaultDelegationAccumulated(
        uint256 chainID,
        address agent
    ) public view returns (uint256) {
        Vault storage vault = vaults[chainID][agent];
        return vault.stats.totalDRewardsReceived;
    }

    /**
     * @notice Get total accumulated rewards for vault
     * @param chainID - Chain ID agent is working on
     * @param agent   - Agent EVM address
     */
    function vaultTotalAccumulated(
        uint256 chainID,
        address agent
    ) external view returns (uint256) {
        Vault storage vault = vaults[chainID][agent];
        return vault.stats.totalARewardsReceived + vault.stats.totalDRewardsReceived;
    }

    /**
     * @notice Get vault current agent rewards
     * @param chainID - Chain ID agent is working on
     * @param agent   - Agent EVM address
     */
    function vaultAgentRewards(
        uint256 chainID,
        address agent
    ) public view returns (uint256) {
        return vaults[chainID][agent].agentRewards;
    }

    /**
     * @dev Current Vault reward per share
     * @param chainID - Chain ID agent is working on
     * @param agent   - Agent EVM address
     */
    function vaultRPS(
        uint256 chainID,
        address agent
    ) public view returns (uint256) {
        return vaults[chainID][agent].rps;
    }

    /**
     * @dev Update Vault reward per share
     */
    function _updateRPS(uint256 chainID, address agent) private {
        Vault storage vault = vaults[chainID][agent];

        if (vault.totalDelegation == 0) {
            return;
        }

        uint256 rewards = vault.delegationRewards;
        uint256 totalDelegation = vault.totalDelegation;
        uint256 rewardPerShareChange = (rewards * SHARE_DENOM) / totalDelegation;

        vault.rps += rewardPerShareChange;
        vault.delegationRewards = 0;
    }

    // ==============================
    //      DELEGATOR GETTERS
    // ==============================

    /**
     * @notice Get delegation of delegator
     * @param chainID   - Chain ID agent is working on
     * @param agent     - Agent EVM address
     * @param delegator - Delegator EVM address
     */
    function delegation(
        uint256 chainID,
        address agent,
        address delegator
    ) public view returns (uint256) {
        return vaults[chainID][agent].delegators[delegator].delegation;
    }

    /**
     * @notice Get reward debt of delegator
     * @param chainID   - Chain ID agent is working on
     * @param agent     - Agent EVM address
     * @param delegator - Delegator EVM address
     */
    function delegatorRewardDebt(
        uint256 chainID,
        address agent,
        address delegator
    ) public view returns (uint256) {
        return vaults[chainID][agent].delegators[delegator].rewardDebt;
    }

    function _getPendingRaw(
        uint256 chainID,
        address agent,
        address delegator
    ) private view returns (uint256) {
        Vault storage vault = vaults[chainID][agent];
        Position storage position = vault.delegators[delegator];
        return (position.delegation * vault.rps) / SHARE_DENOM;
    }

    /**
     * @notice Get delegator share percent in particular vault
     * @param chainID   - Chain ID agents is working on
     * @param agent     - Agent EVM address
     * @param delegator - Delegator EVM address
     */
    function delegatorSharePercent(
        uint256 chainID,
        address agent,
        address delegator
    ) public view returns (uint256) {
        uint256 nowDelegation = vaults[chainID][agent].delegators[delegator].delegation;
        uint256 totalDelegations = vaults[chainID][agent].totalDelegation;

        return (nowDelegation * PERCENT_DENOM) / totalDelegations;
    }

    /**
     * @notice Get pending rewards for delegator
     * @dev If delegator has no pending rewards, return 0
     * @param chainID   - Chain ID agents is working on
     * @param agent     - Agent EVM address
     * @param delegator - Delegator EVM address
     */
    function delegatorPendingRewards(
        uint256 chainID,
        address agent,
        address delegator
    ) public view returns (uint256) {
        uint256 pendingRaw = _getPendingRaw(chainID, agent, delegator);
        Position storage position = vaults[chainID][agent].delegators[delegator];
        uint256 accumulatedReward = accumulatedRewards[chainID][agent][delegator];

        if (pendingRaw <= position.rewardDebt) {
            return accumulatedReward;
        }

        return pendingRaw - position.rewardDebt + accumulatedReward;
    }

    /**
     * @notice Get network information for some address
     * (both agents and delegators)
     * @dev Contains information for FE pages and batch harvesting
     * @param some - Address
     */
    function getNetInfo(
        address some
    ) external view returns (
        uint256[] memory,
        address[] memory
    ) {
        return (netInfo[some].chainIDs, netInfo[some].agentList);
    }

    // ==============================
    //          AGENT
    // ==============================

    /**
     * @notice Set agent delegation share
       Agent can regulate how much rewards are 
       received from vault by delegators
     * @param chainID         - Chain ID agents is working on
     * @param newSharePercent - New delegation share
     */
    function setRewardShare(
        uint256 chainID,
        uint256 newSharePercent
    ) external {
        if (newSharePercent > PERCENT_DENOM) {
            revert InvalidShare();
        }
        uint256 oldSharePercent = vaults[chainID][_msgSender()].delegationSharePercent;
        vaults[chainID][_msgSender()].delegationSharePercent = newSharePercent;

        emit ShareSet(chainID, _msgSender(), oldSharePercent, newSharePercent);
    }

    // ==============================
    //          ADMIN
    // ==============================

    /**
     * @dev Set reward ATS tokens
     * @param  chainIDs  - List of chain IDs
     * @param  newTokens - List of tokens
     */
    function populateTokens(
        uint256[] calldata chainIDs,
        address[] calldata newTokens
    ) external onlyRole(ADMIN) {
        uint256 len = chainIDs.length;

        if (len != newTokens.length) {
            revert RewardVaults__LengthMismatch();
        }

        for (uint256 i = 0; i < len; i++) {
            if (newTokens[i] == address(0)) {
                revert InvalidAddress();
            }
            tokens[chainIDs[i]] = IERC20Mintable(newTokens[i]);
        }
    }

    /**
     * @dev Set one reward token
     * @param chainID - Chain ID
     * @param token   - Token
     */
    function setToken(
        uint256 chainID,
        address token
    ) external onlyRole(ADMIN) {
        if (token == address(0)) {
            revert InvalidAddress();
        }

        tokens[chainID] = IERC20Mintable(token);
    }

    /**
     * @dev Set wNative token (Master Chain wrapped native)
     */
    function setWNative(
        address _wNative
    ) external onlyRole(ADMIN) {
        if (_wNative == address(0)) {
            revert InvalidAddress();
        }

        wNative = IWNative(_wNative);
    }

    /**
     * @dev Set rotator
     * @param newRotator Address of rotator
     */
    function setRotator(
        address newRotator
    ) external onlyRole(ADMIN) {
        if (newRotator == address(0)) {
            revert InvalidAddress();
        }

        rotator = newRotator;
    }

    /**
     * @dev Set agent manager
     * @param newAgentManager Address of agent manager
     */
    function setAgentManager(
        address newAgentManager
    ) external onlyRole(ADMIN) {
        if (newAgentManager == address(0)) {
            revert InvalidAddress();
        }

        agentManager = newAgentManager;
    }

    /**
     * @dev Set slash receiving contract
     */
    function setTreasury(
        address newTreasury
    ) external onlyRole(ADMIN) {
        if (newTreasury == address(0)) {
            revert InvalidAddress();
        }
        treasury = newTreasury;
    }

    /**
     * @dev Set withdraw cooldown
     * @param newCooldown - New cooldown timing
     */
    function setCooldown(uint256 newCooldown) external onlyRole(ADMIN) {
        if (newCooldown == 0) {
            revert InvalidCooldown();
        }
        cooldown = newCooldown;
    }

    /**
     * @dev Set minimum stake for agent to be activated
     * @param newMinStake - New minimum stake in wNative
     */
    function setMinStake(uint256 newMinStake) external onlyRole(ADMIN) {
        uint256 oldMinStake = minStake;
        minStake = newMinStake;

        emit MinStakeSet(oldMinStake, newMinStake);
    }

    function setACPReserve(address newReserve) external onlyRole(ADMIN) {
        if (newReserve == address(0)) {
            revert InvalidAddress();
        }

        ACPReserve = newReserve;
    }

    // ==============================
    //          UPGRADES
    // ==============================
    function _authorizeUpgrade(address) internal override onlyRole(ADMIN) {}
}
