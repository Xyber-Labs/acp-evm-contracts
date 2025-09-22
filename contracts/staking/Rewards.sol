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
import {IStaking} from "../interfaces/staking/IStaking.sol";
import {IRewardVaults} from "../interfaces/staking/IRewardVaults.sol";

/**
 * @title Rewards
 * @dev This contract is a part of reward system V2
 * @dev IRewardVaults is applied for V1 compatibility
 * @notice
 * Reward is a contract for managing rewards
 * both for agents and for delegators.
 */
contract Rewards is  
    Initializable,
    UUPSUpgradeable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    IRewardVaults 
{
    using SafeERC20 for IERC20Mintable;
    using SafeERC20 for IWNative;


    error InvalidAddress();
    error Rewards__LengthMismatch();

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

    event Harvest(
        uint256 indexed chainID,
        address agent,
        address delegator,
        uint256 amount
    );

    uint256 public constant SHARE_DENOM   = 1e18;
    uint256 public constant PERCENT_DENOM = 10_000;

    bytes32 public constant ADMIN     = keccak256("ADMIN");
    bytes32 public constant SLASHER   = keccak256("SLASHER");
    bytes32 public constant REWARDER  = keccak256("REWARDER");
    bytes32 public constant STAKING   = keccak256("STAKING");

    struct AgentNetworkSet {
        uint256[] chainIDs;
        mapping(uint256 chainID => bool receivedFrom) receivedFrom;
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
    }

    struct AgentInfo {
        AgentNetworkSet networkSet;
        mapping(uint256 chainID => Vault) vaults;
    }


    struct UserRewards {
        uint256 claimed;
        uint256 accumulated;
        uint256 rewardDebt;
    }

    struct UserInfo {
        uint256 lastClaim;
        mapping(address agent => mapping(uint256 chainID => UserRewards)) rewards;
    }

    address public ACPReserve;
    IStaking public staking;

    mapping(address agent => AgentInfo) agentInfo;
    mapping(address user => UserInfo) userInfo;
    mapping(uint256 chainID => IERC20Mintable) public tokens;

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
        _setRoleAdmin(REWARDER, ADMIN);
        _setRoleAdmin(SLASHER, ADMIN);
        _setRoleAdmin(STAKING, ADMIN);

        _grantRole(ADMIN, initAddr[0]);
        _grantRole(STAKING, initAddr[1]);

        staking = IStaking(initAddr[1]);
    }



    // ==============================
    //       RECEIVE REWARDS
    // ==============================
    function setReward(
        uint256 chainID,
        address agent,
        uint256 amount,
        bool compensation
    ) external onlyRole(REWARDER) {
        _setReward(chainID, agent, amount, compensation);
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
            _setReward(chainID, agents[i], oneEntityReward, false);
        }
    }

    /**
     * @notice Set rewards for the agent
     * @dev Triggered on message finalisation only.
     * Can only be called by REWARDER (initially - master)
     * @param chainID - Chain ID agents is getting reward from
     * @param agent   - Agent EVM address
     * @param amount  - Amount of rewards
     */
    function _setReward(
        uint256 chainID,
        address agent,
        uint256 amount,
        bool compensation
    ) private {
        uint256 aRew;
        uint256 dRew;

        if (compensation) {
            aRew = amount;
        } else {
            uint256 sharePercent = staking.getDelegationSharePercent(agent);
            dRew = (amount * sharePercent) / PERCENT_DENOM;
            aRew = amount - dRew;
        }

        // update Vault info
        Vault storage vault = agentInfo[agent].vaults[chainID];
        vault.agentRewards += aRew;
        vault.delegationRewards += dRew;
        vault.stats.totalARewardsReceived += aRew;
        vault.stats.totalDRewardsReceived += dRew;
        
        // only update if delegation rewards received
        // agent rewards is always static
        // since reward is received, only one net vault 
        // rps is updated
        if (dRew != 0) {
            _updateRPS(chainID, agent);
        }

        // update network set of agent
        AgentNetworkSet storage netSet = agentInfo[agent].networkSet;

        if (!netSet.receivedFrom[chainID]) {
            netSet.receivedFrom[chainID] = true;
            netSet.chainIDs.push(chainID);
        }

        emit Reward(chainID, agent, amount, dRew, aRew);
    }


    // ==============================
    //       HARVEST REWARDS
    // ==============================

    /// @dev harvest all agent user staked to
    function harvestAll() external {
        address[] memory agents = staking.getAgentsFromSet(_msgSender());
        uint256 len = agents.length;
        for (uint256 i; i < len; i++) {
            harvest(agents[i]);
        }
    }

    /// @dev harvest some vaults of 1 agent
    function harvestBatch(
        address agent,
        uint256[] calldata chainIDs
    ) external {
        _harvest(agent, _msgSender(), chainIDs);
    }

    /// @dev default harvest, which uses full agent network set
    function harvest(address agent) public {
        AgentNetworkSet storage netSet = agentInfo[agent].networkSet;
        _harvest(agent, _msgSender(), netSet.chainIDs);
    }

    /// @dev harvest some chain positions of 1 agent
    function _harvest(
        address agent,
        address user,
        uint256[] memory chains
    ) private {
        if (agent == address(0)) {
            revert InvalidAddress();
        }
        uint256 chainsLen = chains.length;

        // update lastClaim 
        userInfo[user].lastClaim = block.timestamp;

        if (user == agent) {
            for (uint256 i; i < chainsLen; i++) {
                _agentHarvestOnePosition(chains[i], agent);
            }
        } else {
            for (uint256 i; i < chainsLen; i++) {
                _harvestOnePosition(chains[i], agent, user);
            }
        }
    }

    /**
     * @dev Harvest all networks rewards from the vault for delegator
     */
    function _harvestOnePosition(
        uint256 chainID,
        address agent,
        address user
    ) private {
        _updateRPS(chainID, agent);
        if (address(tokens[chainID]) != address(0)) {
            // get all pending rewards inlcuding accumulated
            uint256 pending = delegatorPendingRewards(chainID, agent, user);
            
            // ensure accumulated rewards are updated
            UserRewards storage position = userInfo[user].rewards[agent][chainID];
            position.accumulated = 0;
            position.claimed += pending;

            // update position to save rewardDebt of current
            // user delegation
            _updatePosition(agent, chainID, user);

            _rewardATSMint(chainID, pending, user);

            emit Harvest(chainID, agent, user, pending);
        }
    }

    /**
     * @dev Harvest rewards from the vault for agent caller
     */
    function _agentHarvestOnePosition(
        uint256 chainID,
        address agent
    ) private {
        if (address(tokens[chainID]) != address(0)) {
            uint256 amount = agentInfo[agent].vaults[chainID].agentRewards;
            agentInfo[agent].vaults[chainID].agentRewards = 0;

            if (amount != 0) {
                _rewardATSMint(chainID, amount, agent);
                emit Harvest(chainID, agent, agent, amount);
            }
        }
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

        if (
            amount != 0
        ) {
            token.mint(to, amount);
            emit RewardReleased(chainID, address(token), to, amount);
        }
    }


    // ==============================
    //       POOL & VAULTs
    // ==============================

    /// @dev ! Since agent receives multi-chain rewards
    ///      ! RPS needs to be updated for all vaults   
    function updateVaultsRPS(
        address agent
    ) external onlyRole(STAKING) {
        uint256[] memory chains = agentInfo[agent].networkSet.chainIDs;
        uint256 len = chains.length;
        for (uint256 i = 0; i < len; i++) {
            _updateRPS(chains[i], agent);
        }
    }

    /**
     * @dev Update Vault reward per share
     */
    function _updateRPS(uint256 chainID, address agent) private {
        // use callback to a staking contract
        uint256 newTotalDelegation = staking.getPoolTotalDelegation(agent);

        Vault storage vault = agentInfo[agent].vaults[chainID];
        if (newTotalDelegation != 0) {
            uint256 rewardPerShareChange = (vault.delegationRewards * SHARE_DENOM) / newTotalDelegation;
            if (rewardPerShareChange != 0) {
                vault.rps += rewardPerShareChange;

                // flush already accounted rewards
                vault.delegationRewards = 0;
            }
        }
    }

    function getVaultRPS(
        uint256 chainID,
        address agent
    ) external view returns (uint256) {
        return agentInfo[agent].vaults[chainID].rps;
    }

    function getVaultStats(
        uint256 chainID,
        address agent
    ) external view returns(uint256, uint256) {
        VaultStats storage stats = agentInfo[agent].vaults[chainID].stats;
        return (stats.totalARewardsReceived, stats.totalDRewardsReceived);
    }


    // ==============================
    //           AGENT 
    // ==============================
    function vaultAgentRewards(
        uint256 chainID,
        address agent
    ) public view returns (uint256) {
        return agentInfo[agent].vaults[chainID].agentRewards;
    }

    function agentVaultBatchRewards(
        address agent,
        uint256[] calldata chainIDs
    ) external view returns (uint256[] memory rewards) {
        uint256 len = chainIDs.length;
        rewards = new uint256[](len);
        for (uint256 i = 0; i < len; i++) {
            rewards[i] = vaultAgentRewards(chainIDs[i], agent);
        }
    }

    function getAgentNetworkSet(
        address agent
    ) external view returns (uint256[] memory) {
        return agentInfo[agent].networkSet.chainIDs;
    }

    function agentReceivedFromChain(
        address agent,
        uint256 chainID
    ) external view returns (bool) {
        return agentInfo[agent].networkSet.receivedFrom[chainID];
    }

    // ==============================
    //           USER 
    // ==============================

    function accumulateMultiPositionRewards(
        address agent,
        address delegator
    ) external onlyRole (STAKING) {
        uint256[] memory chains = agentInfo[agent].networkSet.chainIDs;
        uint256 len = chains.length;
        for (uint256 i = 0; i < len; i++) {
            UserRewards storage position = userInfo[delegator].rewards[agent][chains[i]];
            position.accumulated = delegatorPendingRewards(chains[i], agent, delegator);
        }
    }

    /// @dev ! Since agent receives multi-chain rewards
    ///      ! position needs to be updated for all vaults   
    function updateMultiPosition(
        address agent,
        address delegator
    ) external onlyRole(STAKING) {
        // get all agent chains rewards
        uint256[] memory chains = agentInfo[agent].networkSet.chainIDs;
        uint256 len = chains.length;
        for (uint256 i = 0; i < len; i++) {
            // update rewardDebt
            _updatePosition(agent, chains[i], delegator);
        }
    }

    /**
     * @dev Update personal position based on vault rps
     */
    function _updatePosition(
        address agent,
        uint256 chainID,
        address user
    ) private {
        UserRewards storage position = userInfo[user].rewards[agent][chainID];
        position.rewardDebt = _getPendingRaw(chainID, agent, user);
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
        UserRewards storage position = userInfo[delegator].rewards[agent][chainID];
        uint256 accumulatedReward = position.accumulated;
        uint256 pendingRaw = _getPendingRaw(chainID, agent, delegator);

        if (pendingRaw <= position.rewardDebt) {
            return accumulatedReward;
        }

        return pendingRaw - position.rewardDebt + accumulatedReward;
    }

    function delegatorPendingRewardsAll(
        address agent,
        address delegator
    ) external view returns (uint256[] memory, uint256[] memory) {
        AgentNetworkSet storage netSet = agentInfo[agent].networkSet;
        uint256 len = netSet.chainIDs.length;
        uint256[] memory chains = netSet.chainIDs;
        uint256[] memory rewards = new uint256[](len);
        for (uint256 i = 0; i < len; i++) {
            rewards[i] = delegatorPendingRewards(chains[i], agent, delegator);
        }
        return (chains, rewards);
    }

    function _getPendingRaw(
        uint256 chainID,
        address agent,
        address delegator
    ) public view returns (uint256) {
        uint256 delegation = staking.getUserDelegation(delegator, agent);
        Vault storage vault = agentInfo[agent].vaults[chainID];
        return (delegation * vault.rps) / SHARE_DENOM;
    }

    function getRewardDebt(
        address user,
        uint256 chainID,
        address agent
    ) external view returns (uint256) {
        UserRewards storage position = userInfo[user].rewards[agent][chainID];
        return position.rewardDebt;
    }

    function getAccumulatedRewards(
        address user,
        uint256 chainID,
        address agent
    ) external view returns (uint256) {
        UserRewards storage position = userInfo[user].rewards[agent][chainID];
        return position.accumulated;
    }

    // ==============================
    //           ADMIN
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
            revert Rewards__LengthMismatch();
        }

        for (uint256 i = 0; i < len; i++) {
            if (newTokens[i] == address(0)) {
                revert InvalidAddress();
            }
            tokens[chainIDs[i]] = IERC20Mintable(newTokens[i]);
        }
    }

    // ==============================
    //      V1 COMPATIBILITY
    // ==============================

    function treasury() external view returns (address) {
        return staking.treasury();
    }

    function minStake() external view returns (uint256) {
        return staking.minStake();
    }

    function ACPReserve() external view returns (address) {
        return ACPReserve;
    }

    function vaultSelfStake(
        uint256 /* chainID */,
        address agent
    ) external view returns (uint256) {
        return staking.poolSelfStake(agent);
    }

    function vaultBalanceBatch(
        uint256 chainID,
        address[] calldata agents
    ) external view returns (uint256[] memory balances) {
        uint len = agents.length;
        balances = new uint256[](len);
        for (uint i = 0; i < len; i++) {
            balances[i] = vaultBalance(chainID, agents[i]);
        }
    }

    /// @dev Self stakes + delegation
    function vaultBalance(
        uint256 /* chainID */,
        address agent
    ) public view returns (uint256) {
        return staking.poolBalance(agent);
    }

    function slash(
        uint256 /* chainID */,
        address agent,
        uint256 amount
    ) external onlyRole(SLASHER) {
        staking.slash(agent, amount);
    }

    // ==============================
    //          ADMIN
    // ==============================
    function setReserve(address reserve) external onlyRole(ADMIN) {
        if (reserve == address(0)) {
            revert InvalidAddress();
        }
        ACPReserve = reserve;
    }

    function setStaking(address _staking) public onlyRole(ADMIN) {
        staking = IStaking(_staking);
    }

    // ==============================
    //          UPGRADES
    // ==============================
    function _authorizeUpgrade(address) internal override onlyRole(ADMIN) {}
}