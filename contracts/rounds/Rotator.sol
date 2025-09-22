// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable, AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {IEndpoint} from "../interfaces/endpoint/IEndpoint.sol";
import {IAgentManager} from "../interfaces/agents/IAgentManager.sol";
import {IRewards} from "../interfaces/staking/IRewards.sol";
import {IKeyStorage} from "../interfaces/agents/IKeyStorage.sol";
import {IChainInfo} from "../interfaces/IChainInfo.sol";

/**
 * @title  Rotator
 * @notice Rotator is a contract that changes Rounds (aka epochs)
 * @dev
   The Rotator contract manages the assignment of agents to slots based on 
   provided data and a defined set of rules. 

   The input data for each operation includes:
   - slotsToChange: A list of slots where agents may be replaced by higher-stake candidates.
   - openSlots: A list of slots that are currently vacant and available for agent assignment. 
   - slotToClose: A list of slots that are to be deactivated, potentially requiring agent removal. 


   The contract operates according to the following logic:

   * Slot Operation Precedence:

   1. Closure Priority: If slotsToClose is not empty, 
   both openSlots and slotsToChange must be empty. Slot closures take precedence,
   ensuring immediate deactivation of specified slots. 
   No other slot manipulation (opening or changing) is permitted during this phase.
   At least, until change percent is less than maxPercentChange.

   2. Change Only: If slotsToClose and openSlots are empty, 
   then slotsToChange may be populated with slots for agents replacement.

   3. Opening and Changing Allowed: If openSlots is not empty, 
   slotsToChange may be populated with slots for agents replacement.

   * Agent Replacement Rules:

   The contract utilizes the concept of "agents" (existing participants) and 
   "candidates" (potential replacements) to manage changes. 
   Candidates are prioritized for replacement based on having a larger stake
   than the agents they are replacing. The following rules govern how agents 
   are replaced with candidates:

   1. Agent Reduction: 
   When slotsToClose is specified, the contract shrinks 
   the agent array to a size equal to (total agents - slotsToClose). 
   This effectively removes the agents assigned to the closing slots.

   2. Slot Changes (without Open Slots): 
   Stake-Based Replacement: When only slotsToChange are specified and openSlots is empty,
   agents assigned to slots in slotsToChange can be replaced by candidates with larger stakes,
   up to the number of agents for the specified slotsToChange. 

   3. Slot Changes with Open Slots:
   Combined Replacement: When both openSlots and slotsToChange are specified,
   the total number of candidate slots used is equal to (openSlots count + slotsToChange count).
   Agents in this combined set can be replaced by candidates with a higher stake.
 */
contract Rotator is Initializable, UUPSUpgradeable, AccessControlUpgradeable {
    // ==============================
    //          ERRORS
    // ==============================

    /* Info */
    error ConfiguratorNotSet();

    /* Slots & expansions */
    error Rotator__TooManySlots();
    error Rotator__TooLowSlots(uint256 _new);
    error Rotator__SlotChangeTooLarge(uint256 slotDiff, uint256 diffPercent);

    /* Timings */
    error Rotator__ShouldWaitFor(uint256 time);

    /* Common */
    error InvalidAddress();
    error InvalidValue();

    error InitializeNoPending(uint256 chainID);

    // ==============================
    //          EVENTS
    // ==============================
    event NetworkInitialized(uint256 chainID);
    event RoundChanged(
        uint256 indexed chainID,
        uint256 newRound,
        uint256 oldRound,
        uint256 newAgentLen
    );
    event NewSlotsSet(uint256 oldSlots, uint256 newOpenSlots);
    event SlotOverrideSet(
        uint256 indexed chainID,
        uint256 slotsSet,
        uint256 newOpenSlots
    );
    event NoPending(uint256 indexed chainID);
    event CannotExpand(uint256 indexed chainID);

    // ==============================
    //        ROLES & CONST
    // ==============================

    bytes32 public constant ADMIN   = keccak256("ADMIN");
    bytes32 public constant REWARDS = keccak256("REWARDS");

    uint256 public constant MAX_SLOTS = 16;
    uint256 public constant MIN_SLOTS = 3;
    uint256 public constant DENOM = 10_000;
    uint256 public constant DEF_3_RATE = 6700;
    uint256 public constant DEF_RATE = 5000;
    uint256 public constant DEF_ROUND_GAS = 400_000;

    // ==============================
    //          STORAGE
    // ==============================

    /// @dev Only for sorting
    struct AccountStake {
        address agent;
        uint256 stake;
    }

    struct RoundData {
        uint256 startTime;
        uint256 endTime;
    }

    struct Overrides {
        uint256 duration;
        uint256 slots;
        bool forceUnlocked;
    }

    /* Addresses of Master Chain */
    address public localEndpoint;
    address public agentManager;
    address public rewards;
    address public keyStorage;
    address public chainInfo;

    /* Agent restrictions */
    uint256 public maxPercentChange;

    /* Timings restrictions */
    uint256 public defaultMinimalDuration;

    mapping(uint256 chainID => mapping(uint256 round => Overrides)) public overrides;
    mapping(uint256 chainID => mapping(uint256 round => RoundData)) public rounds;
    mapping(uint256 chainID => bool) public nonEVMChain;
    mapping(uint256 chainID => uint256) public currentRound;

    bytes32 public constant STAKING = keccak256("STAKING");
    address public staking;

    // ==============================
    //          Functions
    // ==============================

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address[] calldata initAddr) public initializer {
        __UUPSUpgradeable_init();
        __AccessControl_init();
        _setRoleAdmin(ADMIN, ADMIN);
        _grantRole(ADMIN, initAddr[0]);
    }

    /**
     * @notice Main function, which changes round and round data,
     * affecting whole agent system and their communication with SC
     * @param chainID Chain ID
     */
    function changeRound(uint256 chainID) external payable {

        if (currentRound[chainID] == 0) {
            // initializing new network
            _initializeNew(chainID);
            return;
        }

        (bool timingPossible, uint256 diff) = canTurnRound(chainID);
        if (!timingPossible) {
            revert Rotator__ShouldWaitFor(diff);
        }

        (bool _canExpand, uint256 freeSlots) = canExpand(chainID);
        if (!_canExpand) {
            emit CannotExpand(chainID);
        }

        address[] memory activeAgents = IAgentManager(agentManager)
            .getCurrentParticipants(chainID);
        address[] memory pendingCandidates = IAgentManager(agentManager)
            .getFilteredCandidates(chainID, currentRound[chainID] + 1);

        if (
            pendingCandidates.length == 0 &&
            !overrides[chainID][currentRound[chainID]].forceUnlocked
        ) {
            emit NoPending(chainID);
            return;
        }

        (
            address[] memory _final,
            address[] memory activate,
            address[] memory disable
        ) = revolveAgents(
            chainID,
            freeSlots,
            activeAgents,
            pendingCandidates
        );

        uint256 aLen = activate.length;
        uint256 dLen = disable.length;

        if (aLen != 0) {
            IAgentManager(agentManager).activateAgents(activate);
        }
        if (dLen != 0) {
            IAgentManager(agentManager).deactivateAgents(disable);
        }

        IKeyStorage.KeyType _typeEx = IKeyStorage.KeyType.EXECUTOR;
        IKeyStorage.KeyType _typeSig = IKeyStorage.KeyType.SIGNER;

        uint256 totalSigners = IKeyStorage(keyStorage).getItemsLenBatch(chainID, _typeSig, activate);
        totalSigners += IKeyStorage(keyStorage).getItemsLenBatch(chainID, _typeSig, disable);

        uint256 totalExecutors = IKeyStorage(keyStorage).getItemsLenBatch(chainID, _typeEx, activate);
        totalExecutors += IKeyStorage(keyStorage).getItemsLenBatch(chainID, _typeEx, disable);

        address[] memory signers = new address[](totalSigners);
        bool[] memory signerFlags = new bool[](totalSigners);

        bytes[] memory executors = new bytes[](totalExecutors);
        bool[] memory executorFlags = new bool[](totalExecutors);

        uint256 signerLen;
        uint256 executorLen;

        for (uint256 i; i < aLen; i++) {
            bytes[] memory nowSigners = IKeyStorage(keyStorage).getItems(
                activate[i],
                chainID,
                _typeSig
            );

            if (nowSigners.length != 0) {
                for (uint256 j; j < nowSigners.length; j++) {
                    signers[signerLen] = abi.decode(nowSigners[j], (address));
                    signerFlags[signerLen] = true;
                    signerLen++;
                }
            }

            bytes[] memory nowEx = IKeyStorage(keyStorage).getItems(
                activate[i],
                chainID,
                _typeEx
            );

            if (nowEx.length != 0) {
                for (uint256 j; j < nowEx.length; j++) {
                    executors[executorLen] = nowEx[j];
                    executorFlags[executorLen] = true;
                    executorLen++;
                }
            }
        }

        for (uint256 i; i < dLen; i++) {
            bytes[] memory nowSigners = IKeyStorage(keyStorage).getItems(
                disable[i],
                chainID,
                _typeSig
            );

            if (nowSigners.length != 0) {
                for (uint256 j; j < nowSigners.length; j++) {
                    signers[signerLen] = abi.decode(nowSigners[j], (address));
                    signerFlags[signerLen] = false;
                    signerLen++;
                }
            }

            bytes[] memory nowEx = IKeyStorage(keyStorage).getItems(
                disable[i],
                chainID,
                _typeEx
            );

            if (nowEx.length != 0) {
                for (uint256 j; j < nowEx.length; j++) {
                    executors[executorLen] = nowEx[j];
                    executorFlags[executorLen] = false;
                    executorLen++;
                }
            }
        }

        // change consensus chainInfo
        uint256 consensus = _final.length > MIN_SLOTS ? DEF_RATE : DEF_3_RATE;
        IChainInfo(chainInfo).changeConsensusRate(chainID, consensus);

        uint256 curr = currentRound[chainID];
        uint256 newRound = curr + 1;

        // set participants
        IAgentManager(agentManager).setParticipants(
            chainID,
            newRound,
            _final
        );

        // change currentRound
        rounds[chainID][curr].endTime = block.timestamp;
        rounds[chainID][newRound].startTime = block.timestamp;

        currentRound[chainID] = newRound;

        bytes memory payload;

        if (nonEVMChain[chainID]) {
            payload = abi.encode(
                consensus,
                _final.length,
                signers,
                executors,
                signerFlags,
                executorFlags
            );
        } else {
            address[] memory decodedExecutors = new address[](executorLen); 
            for (uint256 i = 0; i < executorLen; i++) {
                decodedExecutors[i] = abi.decode(executors[i], (address));
            }
            payload = abi.encode(
                consensus,
                _final.length,
                signers,
                decodedExecutors,
                signerFlags,
                executorFlags
            );
        }

        bytes memory configurator = IChainInfo(chainInfo).getConfigurator(chainID);

        if (configurator.length == 0) {
            revert ConfiguratorNotSet();
        }

        uint256 gasToUse;
        IChainInfo.GasInfo memory gasInfo = IChainInfo(chainInfo).getGasInfo(chainID);
        if (gasInfo.turnRoundGas != 0) {
            gasToUse = gasInfo.turnRoundGas;
        } else {
            gasToUse = DEF_ROUND_GAS;
        }

        IEndpoint(localEndpoint).propose{value: msg.value}(
            chainID,
            bytes32(0),
            abi.encode(0, gasToUse),
            configurator,
            payload
        );

        emit RoundChanged(chainID, newRound, newRound - 1, _final.length);
    }

    function debug_ep_round(
        uint256 chainID,
        bytes calldata configurator,
        bytes calldata payload
    ) external payable onlyRole(ADMIN) {
        uint256 gasToUse;
        IChainInfo.GasInfo memory gasInfo = IChainInfo(chainInfo).getGasInfo(chainID);
        if (gasInfo.turnRoundGas != 0) {
            gasToUse = gasInfo.turnRoundGas;
        } else {
            gasToUse = DEF_ROUND_GAS;
        }

        if (configurator.length == 0) {
            revert ConfiguratorNotSet();
        }

        IEndpoint(localEndpoint).propose{value: msg.value}(
            chainID,
            bytes32(0),
            abi.encode(0, gasToUse),
            configurator,
            payload
        );
    }

    function debug_round_num(
        uint256 chainID,
        uint256 newRound
    ) external onlyRole(ADMIN) {
        currentRound[chainID] = newRound;
    }

    /// @dev Special function to initialize new network 
    /// (changeRound() for 0 to 1 round)
    function _initializeNew(uint256 chainID) private {
        address[] memory pendingCandidates = IAgentManager(agentManager)
            .getFilteredCandidates(chainID, currentRound[chainID] + 1);

        if (pendingCandidates.length < MIN_SLOTS) {
            revert InitializeNoPending(chainID);
        }

        if (pendingCandidates.length != 0) {
            IAgentManager(agentManager).activateAgents(pendingCandidates);
            IAgentManager(agentManager).setParticipants(
                chainID,
                1,
                pendingCandidates
            );
        }

        uint256 consensus = pendingCandidates.length > MIN_SLOTS ? DEF_RATE : DEF_3_RATE;
        IChainInfo(chainInfo).changeConsensusRate(chainID, consensus);

        currentRound[chainID] = 1;
        rounds[chainID][1].startTime = block.timestamp;

        emit NetworkInitialized(chainID);
    }

    /**
     * @notice Function for defining final list of agent to a new round
     * and also th elist of agent to disable and to activate within next round
     * @param chainID Chain ID
     * @param freeSlots Number of free slots (can be occupated)
     * @param agents List of agents (participants of round)
     * @param candidates List of agents-candidates for activation (for next round)
     */
    function revolveAgents(
        uint256 chainID,
        uint256 freeSlots,
        address[] memory agents,
        address[] memory candidates
    ) public view returns (
        address[] memory,
        address[] memory,
        address[] memory
    ) {
        (uint256 canBeChanged, uint256 toAdd) = estimateSlotChange(
            chainID,
            agents.length,
            freeSlots
        );
        uint256 toClose = getClosedSlots(chainID, agents.length);
        
        uint256 alen = agents.length;
        uint256 clen = candidates.length;

        uint256[] memory aBalances = IRewards(rewards)
            .vaultBalanceBatch(chainID, agents);
        uint256[] memory cBalances = IRewards(rewards)
            .vaultBalanceBatch(chainID, candidates);

        AccountStake[] memory aStakes = new AccountStake[](alen);
        AccountStake[] memory cStakes = new AccountStake[](clen);

        for (uint256 i; i < alen; i++) {
            aStakes[i] = AccountStake({agent: agents[i], stake: aBalances[i]});
        }

        for (uint256 i; i < clen; i++) {
            cStakes[i] = AccountStake({
                agent: candidates[i],
                stake: cBalances[i]
            });
        }

        address[] memory aStakesSorted = sortStakes(aStakes);
        address[] memory cStakesSorted = sortStakes(cStakes);

        (
            address[] memory _final,
            address[] memory activate,
            address[] memory disable
        ) = mixAgents(
            aStakesSorted,
            cStakesSorted,
            canBeChanged,
            toAdd,
            toClose
        );

        address[] memory droppedAgents = IAgentManager(agentManager).getForceDroppedAgents(chainID, currentRound[chainID]);
        if (droppedAgents.length != 0) {
            address[] memory temDisable = new address[](disable.length + droppedAgents.length);
            address[] memory temFinal = new address[](_final.length - droppedAgents.length);

            for (uint256 i = 0; i < disable.length; ++i) {
                temDisable[i] = disable[i];
            }

            for (uint256 i = 0; i < droppedAgents.length; ++i) {
                temDisable[i + disable.length] = droppedAgents[i];
            }

            for (uint256 i = 0; i < temFinal.length; ++i) {
                temFinal[i] = _final[i];
            }

            return (temFinal, activate, temDisable);
        }

        return (_final, activate, disable);
    }

    /**
     * @notice Sort given agents by their stakes in staking system 
     * (descending order)
     * @param accounts List of agents' AccountStakes
     */
    function sortStakes(
        AccountStake[] memory accounts
    ) public pure returns (address[] memory) {
        uint256 n = accounts.length;
        address[] memory sortedAgents = new address[](n);

        if (n == 0) {
            return sortedAgents;
        }

        uint256[] memory stakes = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            stakes[i] = accounts[i].stake;
            sortedAgents[i] = accounts[i].agent;
        }

        for (uint256 i = 0; i < n - 1; i++) {
            uint256 maxIndex = i;
            for (uint256 j = i + 1; j < n; j++) {
                if (stakes[j] > stakes[maxIndex]) {
                    maxIndex = j;
                }
            }
            if (maxIndex != i) {
                // Swap stake values
                (stakes[i], stakes[maxIndex]) = (stakes[maxIndex], stakes[i]);

                // Swap agent addresses using a temp variable
                address temp = sortedAgents[i];
                sortedAgents[i] = sortedAgents[maxIndex];
                sortedAgents[maxIndex] = temp;
            }
        }

        return sortedAgents;
    }

    /**
     * @notice Mix given agents and candidates
     * @param agents List of agents
     * @param candidates List of candidates
     * @param slotsToChange Number of slots to be changed within active slots
     * @param openSlots Number of open slots to be occupated
     * @param slotsToClose Number of slots to be closed within active slots
     */
    function mixAgents(
        address[] memory agents,
        address[] memory candidates,
        uint256 slotsToChange,
        uint256 openSlots,
        uint256 slotsToClose
    ) public pure returns (
        address[] memory, /* main list */
        address[] memory, /* diff to include (activate)   */
        address[] memory  /* diff to disable (deactivate) */
    ) {
        uint256 agentsLength = agents.length;
        uint256 candidatesLength = candidates.length;
        address[] memory result;
        address[] memory activateDiff;
        address[] memory disableDiff;

        if (slotsToClose > 0) {
            // Condition 1: Close Only
            uint256 newAgentsLength = agentsLength > slotsToClose
                ? agentsLength - slotsToClose
                : 0;

            result = new address[](newAgentsLength);
            disableDiff = new address[](slotsToClose);

            for (uint256 i; i < newAgentsLength; i++) {
                result[i] = agents[i];
            }

            for (uint256 i; i < slotsToClose; i++) {
                disableDiff[i] = agents[agentsLength - 1 - i];
            }
        } else if (openSlots == 0) {
            // Condition 2: Change Only
            result = new address[](agentsLength);
            for (uint256 i = 0; i < agentsLength; i++) {
                result[i] = agents[i];
            }

            uint256 actualChanges = candidatesLength > slotsToChange
                ? slotsToChange
                : candidatesLength;

            activateDiff = new address[](actualChanges);
            disableDiff  = new address[](actualChanges);

            uint256 start = agentsLength - actualChanges;

            for (uint256 i; i < actualChanges; i++) {
                uint256 agentIndex = start + i;
                uint256 candidateIndex = i;
                address candidate = candidates[candidateIndex];

                result[agentIndex] = candidate;
                disableDiff[i] = agents[agentIndex];
                activateDiff[i] = candidate;
            }
        } else if (openSlots >= candidatesLength) {
            // Condition 3: Open Only
            uint256 resultSize = agentsLength + candidatesLength;
            result = new address[](resultSize);
            activateDiff = new address[](candidatesLength);
            
            for (uint256 i = 0; i < agentsLength; ++i) {
                result[i] = agents[i];
            }

            for (uint256 i = 0; i < candidatesLength; ++i) {
                result[agentsLength + i] = candidates[i];
                activateDiff[i] = candidates[i];
            }
        } else {
            // Condition 4: Open and Change
            uint256 totalSlots = openSlots + slotsToChange;
            disableDiff = new address[](slotsToChange);
            uint256 start = agentsLength - slotsToChange;

            uint256 actualChanges = candidatesLength > totalSlots
                ? totalSlots
                : candidatesLength;

            result = new address[](start + actualChanges);

            for (uint256 i; i < start; i++) {
                result[i] = agents[i];
            }

            for (uint256 i = start; i < agentsLength; i++) {
                uint256 disableIndex = i - start;
                disableDiff[disableIndex] = agents[i];
            }

            activateDiff = new address[](actualChanges);

            for (uint256 i; i < actualChanges; i++) {
                uint256 agentIndex = start + i;
                uint256 candidateIndex = i;
                address candidate = candidates[candidateIndex];
                result[agentIndex] = candidate;
                activateDiff[i] = candidate;
            }
        }

        return (result, activateDiff, disableDiff);
    }

    /**
     * @notice "Drop" agent, who decided to leave current round, 
     * being a participant
     * @param chainID Chain ID
     * @param agent Address of agent
     */
    function dropAgent(
        uint256 chainID,
        address agent
    ) external onlyRole(STAKING) {
        uint256 curr = currentRound[chainID];
        overrides[chainID][curr].forceUnlocked = true;
        IAgentManager(agentManager).setForceDroppedAgent(chainID, curr, agent);
    }

    /**
     * @notice Estimates how much slots will be changed 
     * or added in the next round
     * @param chainID Chain ID
     * @param lenParticipants Number of participants
     * @param freeSlots Number of free slots 
     * (defined by default value or overriden by admin)
     */
    function estimateSlotChange(
        uint256 chainID,
        uint256 lenParticipants,
        uint256 freeSlots
    ) public view returns (uint256, uint256) {
        uint256 toChange;
        uint256 toAdd;

        uint256 curr = currentRound[chainID];

        if (overrides[chainID][curr].forceUnlocked) {
            address[] memory fda = IAgentManager(agentManager)
                .getForceDroppedAgents(chainID, curr);
            uint256 fdaLen = fda.length;
            uint256 fdaCap = (fdaLen * DENOM) / lenParticipants;

            if (fdaCap >= maxPercentChange) {
                toChange = (lenParticipants * maxPercentChange) / DENOM;

                return (toChange, 0);
            } else {
                toChange = (lenParticipants * fdaCap) / DENOM;
                uint256 additionLen = (lenParticipants *
                    (maxPercentChange - fdaCap)) / DENOM;
                if (additionLen != 0) {
                    toAdd = additionLen;
                }

                return (toChange, toAdd);
            }
        } else {
            if (freeSlots == 0) {
                toChange = (maxPercentChange * lenParticipants) / DENOM;

                return (toChange, 0);
            } else {
                uint256 maxChangeNoSlots = (maxPercentChange *
                    lenParticipants) / DENOM;

                toAdd = freeSlots;

                // maxChangeNoSlots is max cap 
                if (maxChangeNoSlots > freeSlots) {
                    toChange = maxChangeNoSlots - freeSlots;
                } else {
                    toChange = maxChangeNoSlots;
                }

                // when no slots to change (3 participants)
                // we want to shrink free slots for 1 agent for expansion
                if (toChange == 0) {
                    toAdd = 1;
                }

                return (toChange, toAdd);
            }
        }
    }

    /**
     * @notice Checks if it is possible to turn round on this chain
     * @param chainID Chain ID
     * @return (false, time to wait)
     */
    function canTurnRound(
        uint256 chainID
    ) public view returns (bool, uint256 toWait) {
        if (checkAgentsActivity(chainID)) {
            return (true, 0);
        }
        
        if (overrides[chainID][currentRound[chainID]].forceUnlocked) {
            return (true, 0);
        }

        uint256 duration = currentRoundDuration(chainID);
        uint256 threshold = getTimingThreshold(chainID);
        if (duration < threshold) {
            return (false, threshold - duration);
        } else {
            return (true, 0);
        }
    }

    function checkAgentsActivity(uint256 chainID) public view returns (bool) {
        address[] memory activeParticipants = IAgentManager(agentManager).getFilteredParticipants(chainID);
        address[] memory activeCandidates = IAgentManager(agentManager).getFilteredCandidates(chainID, currentRound[chainID] + 1);

        if (
            activeParticipants.length < MIN_SLOTS &&
            (activeParticipants.length + activeCandidates.length >= MIN_SLOTS)
        ) {
            return true;
        }

        return false;
    }

    /**
     * @notice Checks if it is possible to expand participants for next round
     * based on free slots
     * @param chainID Chain ID
     * @return (true and free slots) if it is possible, (false, 0) otherwise
     */
    function canExpand(
        uint256 chainID
    ) public view returns (bool, uint256) {
        uint256 participantsLen = IAgentManager(agentManager)
            .getCurrentParticipantsLen(chainID);
        if (participantsLen >= getSlots(chainID)) {
            return (false, 0);
        } else {
            uint256 freeSlots = getSlots(chainID) - participantsLen;
            return (true, freeSlots);
        }
    }

    /**
     * @notice Get closed slots for chain if there are any
     * @param chainID Chain ID
     */
    function getClosedSlots(
        uint256 chainID,
        uint256 participants
    ) public view returns (uint256) {
        uint256 slotOverride = overrides[chainID][currentRound[chainID]].slots;
        uint256 totalSlots;
        if (slotOverride != 0) {
            totalSlots = slotOverride;
        } else {
            totalSlots = MAX_SLOTS;
        }

        if (participants <= totalSlots) {
            return 0;
        } else {
            return participants - totalSlots;
        }
    }

    /**
     * @notice Get slots defined for chain 
     */
    function getSlots(uint256 chainID) public view returns (uint256) {
        uint256 slotOverride = overrides[chainID][currentRound[chainID]].slots;
        if (slotOverride != 0) return slotOverride;
        else return MAX_SLOTS;
    }

    /**
     * @notice Get minimal duration of round for chain
     */
    function getTimingThreshold(uint256 chainID) public view returns (uint256) {
        uint256 timingOverride = overrides[chainID][currentRound[chainID]].duration;
        if (timingOverride != 0) return timingOverride;
        else return defaultMinimalDuration;
    }

    /**
     * @notice Get duration of current round
     */
    function currentRoundDuration(
        uint256 chainID
    ) public view returns (uint256) {
        return roundDuration(chainID, currentRound[chainID]);
    }

    /**
     * @notice Get duration of round
     */
    function roundDuration(
        uint256 chainID,
        uint256 round
    ) public view returns (uint256) {
        uint256 endTime = rounds[chainID][round].endTime;
        uint256 startTime = rounds[chainID][round].startTime;

        if (endTime != 0) {
            return endTime - startTime;
        } else if (block.timestamp > startTime) {
            return block.timestamp - startTime;
        } else {
            return 0;
        }
    }

    /// @dev Check if change of number of slots is valid
    function _validateSlotChange(
        uint256 oldSlots,
        uint256 newSlots
    ) private view {
        if (newSlots > MAX_SLOTS) {
            revert Rotator__TooManySlots();
        }

        if (newSlots < MIN_SLOTS) {
            revert Rotator__TooLowSlots(newSlots);
        }

        if (newSlots == oldSlots) {
            return;
        }

        uint256 diff;
        if (newSlots > oldSlots) diff = newSlots - oldSlots;
        else diff = oldSlots - newSlots;

        uint256 diffPercent = (diff * DENOM) / oldSlots;

        if (diffPercent > maxPercentChange) {
            revert Rotator__SlotChangeTooLarge(diff, diffPercent);
        }
    }

    // ==============================
    //          ADMIN
    // ==============================

    /**
     * @notice Set current slots for chain
     */
    function setSlotOverride(
        uint256 chainID,
        uint256 newOpenSlots
    ) external onlyRole(ADMIN) {
        uint256 slotsSet;

        uint256 curr = currentRound[chainID];

        uint256 slotOverride = overrides[chainID][curr].slots;
        if (slotOverride != 0) {
            slotsSet = slotOverride;
        } else {
            slotsSet = MAX_SLOTS;
        }

        _validateSlotChange(slotsSet, newOpenSlots);
        overrides[chainID][curr].slots = newOpenSlots;

        emit SlotOverrideSet(chainID, slotsSet, newOpenSlots);
    }

    function setAgentManager(address newAgentManager) external onlyRole(ADMIN) {
        if (newAgentManager == address(0)) {
            revert InvalidAddress();
        }

        agentManager = newAgentManager;
    }

    function setRewards(address newRewards) external onlyRole(ADMIN) {
        if (newRewards == address(0)) {
            revert InvalidAddress();
        }

        rewards = newRewards;
        _grantRole(REWARDS, newRewards);
    }

    function setEndpoint(address newEndpoint) external onlyRole(ADMIN) {
        if (newEndpoint == address(0)) {
            revert InvalidAddress();
        }

        localEndpoint = newEndpoint;
    }

    function setChainInfo(address newChainInfo) external onlyRole(ADMIN) {
        if (newChainInfo == address(0)) {
            revert InvalidAddress();
        }
        chainInfo = newChainInfo;
    }

    function setKeyStorage(address newKeyStorage) external onlyRole(ADMIN) {
        if (newKeyStorage == address(0)) {
            revert InvalidAddress();
        }
        keyStorage = newKeyStorage;
    }

    function setStaking(address newStaking) external onlyRole(ADMIN) {
        if (newStaking == address(0)) {
            revert InvalidAddress();
        }
        staking = newStaking;
        _grantRole(STAKING, newStaking);
    }

    /**
     * @notice Set max percent change of slots per 1 changeRound()
     */
    function setMaxPercentChange(uint256 newPercent) external onlyRole(ADMIN) {
        if (newPercent == 0) {
            revert InvalidValue();
        }

        maxPercentChange = newPercent;
    }

    /**
     * @notice Set minimal duration of round
     */
    function setDefaultMinimalDuration(uint256 newDefaultMinimalDuration) external onlyRole(ADMIN) {
        defaultMinimalDuration = newDefaultMinimalDuration;
    }

    function setNonEvmChain(uint256 chainID) external onlyRole(ADMIN) {
        nonEVMChain[chainID] = true;
    }

    // ==============================
    //          UPGRADES
    // ==============================
    function _authorizeUpgrade(address) internal override onlyRole(ADMIN) {}
}
