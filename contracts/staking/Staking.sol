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
import {IRewards} from "../interfaces/staking/IRewards.sol";

/**
 * @title Staking
 * @dev This contract is a part of reward system V2
 * @notice
 * Staking is a contract for managing stake
 * both for agents and for delegators.
 */
contract Staking is  
    Initializable,
    UUPSUpgradeable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable
{
    using SafeERC20 for IERC20Mintable;
    using SafeERC20 for IWNative;

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

    event ShareSet(
        address indexed agent,
        uint256 oldShare,
        uint256 newShare
    );

    event Slash(
        address indexed agent,
        uint256 amount
    );

    event MinStakeSet(uint256 oldMinStake, uint256 newMinStake);

    error InvalidAddress();
    error InvalidAmount();
    error InvalidShare();
    error InvalidCooldown();
    error Staking__Cooldown(uint256 toWait);
    error MinStakeNotSet();

    uint256 public constant PERCENT_DENOM = 10_000;

    bytes32 public constant ADMIN     = keccak256("ADMIN");
    bytes32 public constant SLASHER   = keccak256("SLASHER");
    bytes32 public constant DEPOSITOR = keccak256("DEPOSITOR");

    /// @notice minimal cooldown for withdraw
    uint256 public cooldown;

    /// @dev Minimum stake for agent to be activated
    uint256 public minStake;

    /// @notice Contract for epoch change
    address public rotator;

    address public agentManager;

    /// @notice Contract for managing rewards
    IRewards public rewards;

    /// @notice Slash collector
    address public treasury;

    /// @notice wrapped native contract
    IWNative public wNative;

    struct Position {
        uint256 delegation;
        uint256 lastUpdate;
    }

    struct AgentPool {
        uint256 selfStake;
        uint256 totalDelegation;
        uint256 delegationSharePercent;
        mapping(address => Position) positions;
    }

    struct AgentSet {
        address[] agents;
        mapping(address agent => bool) stakedTo;
    }

    mapping(address agent => AgentPool) public agentPools;
    mapping(address user => AgentSet) agentSet;


    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    } 

    function initialize(
        address[] calldata initAddr
    ) public initializer {
        __UUPSUpgradeable_init();
        __AccessControl_init();
        __ReentrancyGuard_init();

        _setRoleAdmin(ADMIN, ADMIN);
        _setRoleAdmin(SLASHER, ADMIN);
        _setRoleAdmin(DEPOSITOR, ADMIN);
        _grantRole(ADMIN, initAddr[0]);
    }


    // ==============================
    //          DEPOSITS
    // ==============================
    /**
     * @notice Deposit into the vault (make a delegation to agent)
     * @param agent         - Agent EVM address
     * @param wrappedAmount - Amount to deposit via wrapped token
     */
    function deposit(
        address agent,
        uint256 wrappedAmount
    ) external payable {
        uint256 amount = _transferHelper(_msgSender(), wrappedAmount);
        _deposit(agent, _msgSender(), amount);
    }

    /**
     * @notice Withdraw rewards for someone
     * @dev Granted to a higher-level contracts
     * @param agent - Agent EVM address
     * @param delegator - Delegator EVM address
     * @param wrappedAmount - Amount of wNative
     */
    function depositFor(
        address agent,
        address delegator,
        uint256 wrappedAmount
    ) external payable onlyRole(DEPOSITOR) {
        uint256 amount = _transferHelper(delegator, wrappedAmount);
        _deposit(agent, delegator, amount);
    }

    function _deposit(
        address agent,
        address delegator,
        uint256 amount
    ) private {
        _depositAndWithdrawCheck(agent, delegator, amount);
        uint256 chainID = IAgentManager(agentManager).getAgentChain(agent);

        if (minStake == 0) {
            revert MinStakeNotSet();
        }

        AgentPool storage pool = agentPools[agent];
        if (delegator == agent) {
            // ensure agent will be included to round
            // as valid staker when filters applied
            if (amount < minStake) {
                revert InvalidAmount();
            }
            pool.selfStake += amount;
        } else {
            rewards.accumulateMultiPositionRewards(agent, delegator);

            // update pool info
            pool.totalDelegation += amount;

            // update position info
            Position storage position = pool.positions[delegator];
            position.delegation += amount;
            position.lastUpdate = block.timestamp;


            // update Vault RPS based on new totalDelegation
            rewards.updateVaultsRPS(agent);
            
            // update reward debt info for this user and this vault
            rewards.updateMultiPosition(agent, delegator);
        }

        if (!agentSet[delegator].stakedTo[agent]) {
            agentSet[delegator].stakedTo[agent] = true;
            agentSet[delegator].agents.push(agent);
        }

        emit Deposit(chainID, agent, delegator, amount);
    }


    // ==============================
    //        WITHDRAWALS
    // ==============================
    function withdrawAll(bool unwrap) external nonReentrant {
        address[] memory agents = agentSet[_msgSender()].agents;
        for (uint256 i = 0; i < agents.length; ++i) {
            // do not allow agent to withdraw all 
            // since he can withdraw his own stake
            if (agents[i] == _msgSender()) { continue; }

            uint256 amount = agentPools[agents[i]].positions[_msgSender()].delegation;
            _withdraw(agents[i], _msgSender(), amount, unwrap);
        }
    }

    /**
     * @notice Withdraw from the pool
     * @param agent   - Agent EVM address
     * @param amount  - Amount to withdraw
     * @param unwrap  - Unwrap Wrapped Token or not
     */
    function withdraw(
        address agent,
        uint256 amount,
        bool unwrap
    ) public nonReentrant {
        _withdraw(agent, _msgSender(), amount, unwrap);
    }

    function _withdraw(
        address agent,
        address delegator,
        uint256 amount,
        bool unwrap
    ) private {
        _depositAndWithdrawCheck(agent, delegator, amount);

        uint256 toWithdraw;
        AgentPool storage pool = agentPools[agent];
        uint256 chainID = IAgentManager(agentManager).getAgentChain(agent);

        if (delegator == agent) {
            uint256 selfStake = pool.selfStake;
            if (selfStake != 0) {
                toWithdraw = _min(amount, selfStake);
                pool.selfStake -= toWithdraw;
            }

            // If agent is active we dropping him automatically 
            // and unlocking round change for network
            if (pool.selfStake == 0) {
                AgentLib.AgentStatus status = IAgentManager(agentManager).getStatus(agent);

                if (status == AgentLib.AgentStatus.PARTICIPANT) {
                    _drop(chainID, agent);
                }
            }
        } else {
            // block on cooldown
            Position storage position = pool.positions[delegator];
            uint256 lastUpdate = position.lastUpdate;
            if (block.timestamp < lastUpdate + cooldown) {
                uint256 diff = lastUpdate + cooldown - block.timestamp;
                revert Staking__Cooldown(diff);
            }

            uint256 delegationNow = position.delegation;
            if (delegationNow != 0) {
                // update rewards
                rewards.accumulateMultiPositionRewards(agent, delegator);

                toWithdraw = _min(amount, delegationNow);

                // update position
                position.delegation -= toWithdraw;
                position.lastUpdate = block.timestamp;

                // update agent pool 
                pool.totalDelegation -= toWithdraw;

                // update agentSet
                if (position.delegation == 0) {
                    agentSet[delegator].stakedTo[agent] = false;
                    _removeAgentFromSet(delegator, agent);
                }

                // update Vault RPS
                rewards.updateVaultsRPS(agent);

                // updateRewardDebt
                rewards.updateMultiPosition(agent, delegator);
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

    function _depositAndWithdrawCheck(
        address agent,
        address delegator,
        uint256 amount
    ) private view {
        if (
            address(wNative) == address(0) ||
            agent == address(0) ||
            delegator == address(0)
        ) {
            revert InvalidAddress();
        }

        if (amount == 0) {
            revert InvalidAmount();
        }
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

    function _min(uint256 a, uint256 b) private pure returns (uint256) {
        if (a < b) return a;
        return b;
    }

    /**
     * @notice Slash agent self-stake as a punishment for 
     * downtime or bad behavior
     * @param agent   - Agent EVM address
     * @param amount  - Amount of rewards
     */
    function slash(
        address agent,
        uint256 amount
    ) external onlyRole(SLASHER) {
        AgentPool storage pool = agentPools[agent];
        uint256 selfStakeNow = pool.selfStake;
        uint256 toSlash = _min(amount, selfStakeNow);

        if (toSlash == 0) {
            return;
        }

        pool.selfStake -= toSlash;
        wNative.safeTransfer(treasury, toSlash);

        emit Slash(agent, toSlash);
    }

    // ==============================
    //          POOL
    // ==============================
    function setRewardShare(
        uint256 sharePercent
    ) external {
        _setRewardShare(_msgSender(), sharePercent);
    }

    function setRewardShareFor(
        address agent,
        uint256 sharePercent
    ) external onlyRole (DEPOSITOR) {
        _setRewardShare(agent, sharePercent);
    }

    /**
     * @notice Set agent delegation share
       Agent can regulate how much rewards are 
       received from vault by delegators
     * @param newSharePercent - New delegation share
     */
    function _setRewardShare(
        address agent,
        uint256 newSharePercent
    ) private {
        if (newSharePercent > PERCENT_DENOM) {
            revert InvalidShare();
        }
        AgentPool storage pool = agentPools[agent];

        uint256 oldSharePercent = pool.delegationSharePercent;
        pool.delegationSharePercent = newSharePercent;

        emit ShareSet(agent, oldSharePercent, newSharePercent);
    }

    function getDelegationSharePercent(
        address agent
    ) public view returns (uint256) {
        AgentPool storage pool = agentPools[agent];
        return pool.delegationSharePercent;
    }

    function getPoolTotalDelegation(
        address agent
    ) public view returns (uint256) {
        AgentPool storage pool = agentPools[agent];
        return pool.totalDelegation;
    }

    function poolBalance(
        address agent
    ) external view returns (uint256) {
        AgentPool storage pool = agentPools[agent];
        return pool.selfStake + pool.totalDelegation;
    }

    function poolSelfStake(
        address agent
    ) external view returns (uint256) {
        AgentPool storage pool = agentPools[agent];
        return pool.selfStake;
    }

    function getAgentWorkingChain(
        address agent
    ) external view returns(uint256) {
        return IAgentManager(agentManager).getAgentChain(agent);
    }

    // ==============================
    //          USER
    // ==============================
    function getUserDelegation(
        address user,
        address agent
    ) public view returns (uint256) {
        Position storage position = agentPools[agent].positions[user];
        return position.delegation;
    }

    function getLastPoisitionUpdate(
        address user,
        address agent
    ) external view returns (uint256) {
        Position storage position = agentPools[agent].positions[user];
        return position.lastUpdate;
    }

    function getUserDelegationSharePercent(
        address user,
        address agent
    ) external view returns (uint256) {
        Position storage position = agentPools[agent].positions[user];
        return position.delegation * PERCENT_DENOM / getPoolTotalDelegation(agent);
    }

    function getAgentsFromSet(
        address delegator
    ) external view returns (address[] memory) {
        return agentSet[delegator].agents;
    }

    function _removeAgentFromSet(
        address delegator,
        address agent
    ) private {
        AgentSet storage set = agentSet[delegator];
        address[] memory agents = set.agents;
        uint256 len = agents.length;
        for (uint256 i = 0; i < len; ++i) {
            if (agents[i] == agent) {
                // delete from set 
                set.agents[i] = agents[len - 1];
                set.agents.pop();
                break;
            }
        }
    }

    // ==============================
    //          ADMIN
    // ==============================
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

    function setRewardsContract(
        address _rewards
    ) external onlyRole(ADMIN) {
        if (_rewards == address(0)) {
            revert InvalidAddress();
        }

        rewards = IRewards(_rewards);
        _grantRole(SLASHER, _rewards);
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

    function setAgentManager(
        address newAgentManager
    ) external onlyRole(ADMIN) {
        if (newAgentManager == address(0)) {
            revert InvalidAddress();
        }   

        agentManager = newAgentManager;
    }

    function setRotator(
        address newRotator
    ) external onlyRole(ADMIN) {
        if (newRotator == address(0)) {
            revert InvalidAddress();
        }
        rotator = newRotator;
    }

    receive() external payable {}

    // ==============================
    //          UPGRADES
    // ==============================
    function _authorizeUpgrade(address) internal override onlyRole(ADMIN) {}
}