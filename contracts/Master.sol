// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable, AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {SignatureLib} from "./lib/SignatureLib.sol";
import {IAgentManager, AgentLib} from "./interfaces/agents/IAgentManager.sol";
import {IMessageData, MessageLib } from "./interfaces/IMessageData.sol";
import {LocationLib} from "./lib/LocationLib.sol";
import {IExecutorLottery} from "./interfaces/agents/IExecutorLottery.sol";
import {IKeyStorage} from "./interfaces/agents/IKeyStorage.sol";
import {IChainInfo} from "./interfaces/IChainInfo.sol";
import {IRewards} from "./interfaces/staking/IRewards.sol";
import {IFeeCalculator} from "./interfaces/IFeeCalculator.sol";
import {IPointDistributor} from "./interfaces/IPointDistributor.sol";
import {IDFAdapter} from "./interfaces/IDFAdapter.sol";

/**
 * @notice Master Smart Contract is a contract responsible for
 * collecting messages from agents of different types
 * with appropriate signatures and verifing them as well
 * as verifying consensus.
 */
contract Master is Initializable, UUPSUpgradeable, AccessControlUpgradeable {
    using LocationLib for uint256;
    using MessageLib for MessageLib.MessageData;

    // ==============================
    //          ERRORS
    // ==============================

    /* Arg checks */
    error Master__InvalidSignature();
    error Master__LengthMismacth();
    error Master__InvalidAddress();
    error Master__InvalidHash();
    error Master__InvalidSrcData();

    /* Agent checks */
    error Master__AgentInvalidStatus();
    error Master__AgentInvalidChain(uint256 chainID);
    error Master__AgentInvalidType();
    error Master__NotCurrentExecutor();

    /* Key storage checks */
    error Master__InvalidKey(bytes key);

    /* Message checks */
    error Master__MessageAlreadyApproved(bytes32 msgHash);

    /* Tx chesks */ 
    error Master__MessageAlreadyPending(
        bytes32[2] destHash, 
        bytes32[2] attemptsDestHash
    );

    /* resend & replenish */
    error InvalidReplenish(bytes32 msgHash);
    error InvalidResend(bytes32 msgHash);

    error Master__SignatureAlreadyAdded(address by);

    /**
     * @dev Status can only be changed for messages
     * that were not written to blockchain yet (see MessageLib)
     */
    error Master__InvalidStatusChange(
        MessageLib.MessageStatus oldStatus,
        MessageLib.MessageStatus newStatus
    );

    // ==============================
    //          EVENTS
    // ==============================

    /* Signature */
    event SignatureAdded(bytes32 msgHash, address indexed by);

    /**
     * @dev This error-event means NOT_REQUIRED
     * and called when signature CAN be provided
     * and it might be still valid, but msg status
     * is not assumed to be changed -> gas saved
     */
    event MessageSignatureNR(
        bytes32 msgHash,
        MessageLib.MessageStatus status
    );

    /* Consensus */ 
    event MessageConsensusReached(
        uint256 indexed destChainID,
        bytes32 msgHash
    );
    event MessageTransmissionReached(
        uint256 indexed destChainID,
        bytes32 msgHash
    );
    event MessageApproved(address indexed superAgent);

    /* Message */
    event NewExecutionAssignment(
        address agentExecutorChosen,
        uint256 indexed destChainID,
        bytes32 msgHash,
        uint256 fromTime,
        uint256 toTime
    );
    event LowPriceProposed(bytes32 msgHash);
    event ExtensionError(bytes32 msgHash, MessageLib.MessageStatus status);
    event ResendMessage(bytes32 msgHash);


    /* Message status */
    event MessagePending(
        address indexed agent,
        bytes32 msgHash,
        bytes32[2] txPending,
        bytes executor
    );
    event StatusChangeApproved(
        bytes32 msgHash,
        address indexed byAgent,
        MessageLib.MessageStatus status
    );
    event MessageStatusChanged(
        bytes32 msgHash,
        MessageLib.MessageStatus status,
        MessageLib.MessageStatus newStatus
    );
    event InvalidMessageStatusChange(
        MessageLib.MessageStatus oldStatus,
        MessageLib.MessageStatus newStatus
    );
    event MessageStatusAlreadyApproved(address from);


    /* Lottery */
    event LotteryExecuted(bytes32 msgHash);

    event InvalidAddress();
    event InsufficientFunds();

    // ==============================
    //      ROLES AND CONSTANTS
    // ==============================

    /* Roles */
    bytes32 public constant ADMIN = keccak256("ADMIN");
    bytes32 public constant REPEATER = keccak256("REPEATER");

    /* Constants */
    uint256 public constant CONSENSUS_DENOM = 10_000;
    uint256 public constant MIN_SIGS = 3;

    // ==============================
    //           STORAGE
    // ==============================
    struct MessageStatusData {
        uint256 confirmations;
        mapping(address agent => bool) statusByAgent;
    }

    struct ExecutionAttempt {
        uint256 timeSaved;
        address executor;
        bytes32[2] executionHash;
    }

    struct MessageConsensusData {
        address firstlyProposedBy;
        address[] approvedBySuper;
        SignatureLib.Signature[] transmissionSigs;
        SignatureLib.Signature[] executionSigs;
        mapping(address agent => bool) signed;
        mapping(MessageLib.MessageStatus => MessageStatusData) msgStatusData;
    }

    struct MessageExecutionData {
        uint256 totalTries;
        uint256 resendAttempts;
        uint256[] replenishments;
        ExecutionAttempt[] tryExecutes;
    }

    /// @notice Message storage and handling contract
    IMessageData public messageData;

    /// @notice Contract for managing agents
    IAgentManager public agentManager;

    /// @notice Contract for handling agent keys
    address public keyStorage;

    /// @notice Contract for choosing executors
    address public executorLottery;

    /// @notice Contract for managing balances
    address public rewards;

    /// @notice Contract with configs
    address public chainInfo;

    /// @notice Contract with fees
    address public feeCalculator;

    /// @notice Contract for point distribution
    address public pointDistributor;

    /// @notice DF Adapter for price conversion
    address public DFAdapter;

    /// @notice Threshold for status checks
    uint256 public threshold;

    mapping(bytes32 msgHash => MessageConsensusData) public msgConsensusData;
    mapping(bytes32 msgHash => MessageExecutionData) public msgExecutionData;
    mapping(bytes32 msgHash => uint256) public statusChecks;
    mapping(bytes32 msgHash => uint256 nativeAmount) public executionNativeSpent;
    mapping(bytes32 msgHash => SignatureLib.Signature[]) superSignatures;

    // ==============================
    //          MODIFIERS
    // ==============================

    modifier onlyValidKey(bytes memory key) {
        if (!IKeyStorage(keyStorage).isKeyValid(key)) {
            revert Master__InvalidKey(key);
        }
        _;
    }

    function _onlySuperAgent(address agent) private view {
        if (
            agentManager.getType(agent) !=
            AgentLib.AgentType.SUPER
        ) {
            revert Master__AgentInvalidType();
        }
    }

    function _onlyActive(address agent) private view {
        if (
            agentManager.getStatus(agent) !=
            AgentLib.AgentStatus.PARTICIPANT
        ) {
            revert Master__AgentInvalidStatus();
        }
    }

    function _onlyCurrentExecutor(
        bytes32 msgHash,
        address agent
    ) private view {
        if (
            agent !=
            IExecutorLottery(executorLottery).currentExecutorAgent(msgHash)
        ) {
            revert Master__NotCurrentExecutor();
        }
    }

    // ==============================
    //          FUNCTIONS
    // ==============================

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize
    /// @param initAddr[0] - Admin address
    /// @param initAddr[1] - Repeater address 
    function initialize(address[] calldata initAddr) external initializer {
        __UUPSUpgradeable_init();
        __AccessControl_init();
        _setRoleAdmin(ADMIN, ADMIN);
        _grantRole(ADMIN, initAddr[0]);
        _grantRole(REPEATER, initAddr[1]);

        threshold = 3;
    }

    function addTransmissionSignatureBatch(
        MessageLib.Proposal[] calldata proposals,
        MessageLib.SrcChainDataRaw[] calldata srcDataRaw,
        SignatureLib.Signature[] calldata sigs
    ) external onlyValidKey(abi.encode(_msgSender())) {
        _verifyAgent(abi.encode(_msgSender()));

        if (
            proposals.length != srcDataRaw.length ||
            proposals.length != sigs.length
        ) {
            revert Master__LengthMismacth();
        }

        for (uint256 i = 0; i < proposals.length; ++i) {
            _addTransmissionSignature(proposals[i], srcDataRaw[i], sigs[i]);
        }
    }

    function addExecutionSignatureBatch(
        bytes32[] calldata msgHashes,
        SignatureLib.Signature[] calldata sigs
    ) external onlyValidKey(abi.encode(_msgSender())) {
        _verifyAgent(abi.encode(_msgSender()));

        if (msgHashes.length != sigs.length) {
            revert Master__LengthMismacth();
        }

        for (uint256 i = 0; i < sigs.length; ++i) {
            _addExecutionSignature(msgHashes[i], sigs[i]);
        }
    }

    /**
     * @notice Add transaction sent as an executor chosen by lottery
     * @param msgHash Message hash
     * @param destHash Destination chain hash
     * @param executor Executor key
     */
    function addPendingTx(
        bytes32 msgHash,
        bytes32[2] calldata destHash,
        bytes calldata executor
    ) external {
        address agent = _verifyAgent(abi.encode(_msgSender()));
        _onlyCurrentExecutor(msgHash, agent);

        ExecutionAttempt memory data = ExecutionAttempt(
            block.timestamp,
            _msgSender(),
            destHash
        );

        ExecutionAttempt[] memory attempts = msgExecutionData[
            msgHash
        ].tryExecutes;

        for (uint256 i; i < attempts.length; i++) {
            bytes32[2] memory attemptsDestHash = attempts[i].executionHash;
            if (destHash[0] == attemptsDestHash[0]) {
                revert Master__MessageAlreadyPending(destHash, attemptsDestHash);
            }
        }

        MessageLib.MessageStatus status = messageData.getMsgStatusByHash(msgHash);

        bool isChangeValid = MessageLib.statusChangeValid(status, MessageLib.MessageStatus.PENDING);
        if (
            !isChangeValid ||
            status == MessageLib.MessageStatus.TRANSMITTED
        ) {
            revert Master__InvalidStatusChange(status, MessageLib.MessageStatus.PENDING);
        }

        msgExecutionData[msgHash].tryExecutes.push(data);
        msgExecutionData[msgHash].totalTries += 1;
        messageData.changeMessageStatus(
            msgHash,
            MessageLib.MessageStatus.PENDING
        );

        emit MessagePending(agent, msgHash, destHash, executor);
    }

    /**
     * @notice Send new execution assignment as a super agent
     * @param msgHash Message hash
     */
    function sendNewExecutionAssignment(bytes32 msgHash) public {
        address agent = _verifyAgent(abi.encode(_msgSender()));
        _onlySuperAgent(agent);

        if (statusChecks[msgHash] >= threshold) {
            return;
        }

        _sendNewExecutionAssignment(msgHash);
    }

    function _sendNewExecutionAssignment(bytes32 msgHash) private {
        (address lotteryAgent, uint256 start, uint256 end) = IExecutorLottery(
            executorLottery
        ).currentExecutionData(msgHash);

        uint256 destChain = messageData.getDestChainId(
            msgHash
        );

        emit NewExecutionAssignment(
            lotteryAgent,
            destChain,
            msgHash,
            start,
            end
        );
    }

    /**
     * @notice Change message status to underestimated as an executor
     * @dev Estimation is made through off-chain DF module communication
     * @param msgHash Message hash
     */
    function lowPriceProposed(bytes32 msgHash) external {
        address agent = _verifyAgent(abi.encode(_msgSender()));
        _onlyCurrentExecutor(msgHash, agent);

        MessageLib.MessageStatus status = messageData.getMsgStatusByHash(msgHash);

        if (
            status != MessageLib.MessageStatus.UNDERESTIMATED &&
            status != MessageLib.MessageStatus.QUEUED
        ) {
            revert Master__InvalidStatusChange(status, MessageLib.MessageStatus.UNDERESTIMATED);
        }

        messageData.changeMessageStatus(
            msgHash,
            MessageLib.MessageStatus.UNDERESTIMATED
        );

        statusChecks[msgHash]++;

        emit LowPriceProposed(msgHash);
    }

    /**
     * @notice Change message status to extension error
     * @dev NON_EVM chains only 
     * @param msgHash Message hash
     * @param newStatus New message status 
     */
    function extensionError(
        bytes32 msgHash,
        MessageLib.MessageStatus newStatus
    ) external {
        address agent = _verifyAgent(abi.encode(_msgSender()));
        _onlyCurrentExecutor(msgHash, agent);

        MessageLib.MessageStatus status = messageData.getMsgStatusByHash(msgHash);

        if (
            newStatus != MessageLib.MessageStatus.EXTENSION_NOT_REGISTERED &&
            newStatus != MessageLib.MessageStatus.EXTENSION_NOT_REACHABLE &&
            newStatus != MessageLib.MessageStatus.EXTENSION_PANICKED
        ) {
            revert Master__InvalidStatusChange(status, newStatus);
        }

        bool changeValid = MessageLib.statusChangeValid(status, newStatus);
        if (!changeValid) {
            revert Master__InvalidStatusChange(status, newStatus);
        }

        messageData.changeMessageStatus(
            msgHash,
            newStatus
        );

        emit ExtensionError(msgHash, newStatus);
    }

    /**
     * @notice Traget function of endpoint::replenish()
     * passes value to an existing message
     * @param srcChainId Source chain id
     * @param msgHash Message hash
     * @param value Value
     */
    function replenish(
        uint256 srcChainId,
        bytes32 msgHash,
        uint256 value
    ) external onlyRole(REPEATER) {
        MessageLib.MessageStatus status = messageData.getMsgStatusByHash(msgHash);
        if (
            status == MessageLib.MessageStatus.NOT_INITIALIZED ||
            status == MessageLib.MessageStatus.INVALID ||
            status == MessageLib.MessageStatus.FAILED ||
            status == MessageLib.MessageStatus.SUCCESS ||
            status == MessageLib.MessageStatus.PROTOCOL_FAILED ||
            status == MessageLib.MessageStatus.EXTENSION_NOT_REGISTERED ||
            status == MessageLib.MessageStatus.EXTENSION_PANICKED

        ) 
        {
            revert InvalidReplenish(msgHash);
        }

        uint256 srcChain = messageData.getSrcChainId(
            msgHash
        );

        if (srcChainId != srcChain) {
            revert InvalidReplenish(msgHash);
        }

        messageData.incrementNativeAmount(
            msgHash,
            value
        );

        msgExecutionData[msgHash].replenishments.push(value);
        msgExecutionData[msgHash].resendAttempts += 1;
        statusChecks[msgHash] = 0;

        _sendNewExecutionAssignment(msgHash);

        emit ResendMessage(msgHash);
    }

    /**
     * @notice Target function of endpoint::resend()
     * resends an existing message
     * @param msgHash Message hash
     */
    function resend(uint256 /* srcChainId */, bytes32 msgHash) external onlyRole(REPEATER) {
        MessageLib.MessageStatus status = messageData.getMsgStatusByHash(msgHash);
        if (
            status == MessageLib.MessageStatus.NOT_INITIALIZED ||
            status == MessageLib.MessageStatus.INVALID ||
            status == MessageLib.MessageStatus.FAILED ||
            status == MessageLib.MessageStatus.SUCCESS ||
            status == MessageLib.MessageStatus.PROTOCOL_FAILED
        ) 
        {
            revert InvalidResend(msgHash);
        }

        msgExecutionData[msgHash].resendAttempts += 1;
        statusChecks[msgHash] = 0;
        _sendNewExecutionAssignment(msgHash);

        emit ResendMessage(msgHash);
    }


    // ==============================
    //          INTERNAL
    // ==============================

    function _addMessage(
        bytes32 msgHash,
        MessageLib.MessageData memory opData,
        MessageLib.MessageStatus status
    ) private {
        if (status == MessageLib.MessageStatus.NOT_INITIALIZED) {
            messageData.storeMessage(msgHash, opData);
            msgConsensusData[msgHash].firstlyProposedBy = _msgSender();
        }
    }

    function _addTransmissionSignature(
        MessageLib.Proposal calldata proposal,
        MessageLib.SrcChainDataRaw calldata srcDataRaw,
        SignatureLib.Signature calldata sig
    ) internal {
        MessageLib.SrcChainData memory srcData = MessageLib.SrcChainData({
            location: LocationLib.pack(srcDataRaw.srcChainId, srcDataRaw.srcBlockNumber),
            srcOpTxId: srcDataRaw.srcOpTxId
        });
        MessageLib.MessageData memory opData = MessageLib.MessageData({
            initialProposal: proposal,
            srcChainData: srcData
        });

        bytes32 msgHash = opData.getHashPrefixed();
        MessageLib.MessageStatus status = messageData.getMsgStatusByHash(msgHash);

        uint256 chain = opData.srcChainData.location.getChain();

        if (
            !agentAllowedOnChain(
                _msgSender(),
                chain
            )
        ) {
            revert Master__AgentInvalidChain(chain);
        }

        _validateSrcData(opData);

        _addMessage(msgHash, opData, status);
        _addTransmissionSignature(msgHash, status, opData, sig);
    }

    function _addTransmissionSignature(
        bytes32 msgHash,
        MessageLib.MessageStatus status,
        MessageLib.MessageData memory opData,
        SignatureLib.Signature calldata sig
    ) private {
        if (
            status != MessageLib.MessageStatus.SAVED &&
            status != MessageLib.MessageStatus.TRANSMITTED &&
            status != MessageLib.MessageStatus.NOT_INITIALIZED &&
            status != MessageLib.MessageStatus.EXTENSION_NOT_REACHABLE &&
            status != MessageLib.MessageStatus.EXTENSION_NOT_REGISTERED &&
            status != MessageLib.MessageStatus.EXTENSION_PANICKED

        ) {
            emit MessageSignatureNR(msgHash, status);
            return;
        }

        _pushTransmissionSignature(msgHash, opData, sig);
    }

    function _pushTransmissionSignature(
        bytes32 msgHash,
        MessageLib.MessageData memory opData,
        SignatureLib.Signature calldata sig
    ) private {
        MessageConsensusData storage consData = msgConsensusData[msgHash];

        if (consData.signed[_msgSender()]) {
            revert Master__SignatureAlreadyAdded(_msgSender());
        }

        _verifySignature(opData, sig);
        consData.transmissionSigs.push(sig);
        consData.signed[_msgSender()] = true;

        _checkTransmissionConsensus(
            opData.srcChainData.location.getChain(),
            msgHash
        );

        emit SignatureAdded(msgHash, _msgSender());
    }

    function _addExecutionSignature(
        bytes32 msgHash,
        SignatureLib.Signature calldata sig
    ) internal {
        if (msgHash == bytes32(0)) {
            revert Master__InvalidHash();
        }
        MessageLib.MessageStatus status = messageData.getMsgStatusByHash(msgHash);

        if (
            status != MessageLib.MessageStatus.TRANSMITTED &&
            status != MessageLib.MessageStatus.QUEUED &&
            status != MessageLib.MessageStatus.UNDERESTIMATED &&
            status != MessageLib.MessageStatus.EXTENSION_NOT_REACHABLE &&
            status != MessageLib.MessageStatus.EXTENSION_NOT_REGISTERED &&
            status != MessageLib.MessageStatus.EXTENSION_PANICKED
        ) {
            emit MessageSignatureNR(msgHash, status);
            return;
        }

        MessageLib.MessageData memory opData = messageData.getMsgData(msgHash);

        if (
            agentManager.getType(_msgSender()) == AgentLib.AgentType.SUPER
        ) {
            if (approvedBySuper(msgHash, _msgSender())) {
                revert Master__MessageAlreadyApproved(msgHash);
            }
            superSignatures[msgHash].push(sig);
            msgConsensusData[msgHash].approvedBySuper.push(_msgSender());
            _checkExecutionConsensus(opData.initialProposal.destChainId, msgHash);

            emit MessageApproved(_msgSender());
            return;
        } else {
            if (
                !agentAllowedOnChain(
                    _msgSender(),
                    opData.initialProposal.destChainId
                )
            ) {
                revert Master__AgentInvalidChain(opData.initialProposal.destChainId);
            }
        }

        _pushExecutionSignature(msgHash, opData, sig);
    }

    function _pushExecutionSignature(
        bytes32 msgHash,
        MessageLib.MessageData memory opData,
        SignatureLib.Signature calldata sig
    ) private {
        MessageConsensusData storage consData = msgConsensusData[msgHash];

        // allow agents to sign twice as transmitters & executors
        // for resend from Master Chain as src OR if path is equal src -> src
        if (
            opData.initialProposal.destChainId != 
            opData.srcChainData.location.getChain()
        ) {
            if (consData.signed[_msgSender()]) {
                revert Master__SignatureAlreadyAdded(_msgSender());
            }
        }

        _verifySignature(opData, sig);
        consData.executionSigs.push(sig);
        consData.signed[_msgSender()] = true;

        _checkExecutionConsensus(
            opData.getDestChain(),
            msgHash
        );

        emit SignatureAdded(msgHash, _msgSender());
    }

    function _checkTransmissionConsensus(
        uint256 chainID,
        bytes32 msgHash
    ) private {
        MessageConsensusData storage consData = msgConsensusData[msgHash];

        uint256 sigsNow = consData.transmissionSigs.length;
        MessageLib.MessageStatus status = messageData.getMsgStatusByHash(msgHash);

        if (_consensusReached(chainID, sigsNow)) {
            if (status != MessageLib.MessageStatus.TRANSMITTED) {
                // These statuses can be added to MASTER in parallel
                if (status != MessageLib.MessageStatus.INVALID) {
                    messageData.changeMessageStatus(
                        msgHash,
                        MessageLib.MessageStatus.TRANSMITTED
                    );
                }
                emit MessageTransmissionReached(chainID, msgHash);
            }
        }
    }

    function _checkExecutionConsensus(
        uint256 chainID,
        bytes32 msgHash
    ) private {
        MessageConsensusData storage consData = msgConsensusData[msgHash];

        uint256 sigsNow = consData.executionSigs.length;
        uint256 superSigsNow = consData.approvedBySuper.length;
        MessageLib.MessageStatus status = messageData.getMsgStatusByHash(msgHash);
        MessageLib.MessageStatus newStatus = MessageLib.MessageStatus.QUEUED;

        if (
            _consensusReached(chainID, sigsNow) &&
            _superConsensusReached(chainID, superSigsNow)
        ) {
            if (status != MessageLib.MessageStatus.QUEUED) {
                messageData.changeMessageStatus(
                    msgHash,
                    newStatus
                );
                
                emit MessageConsensusReached(chainID, msgHash);
                _lottery(msgHash);
            }
        }
    }

    function _lottery(bytes32 msgHash) private {
        MessageLib.MessageData memory opData = messageData.getMsgData(msgHash);
        uint256 destChain = opData.getDestChain();

        (
            address[] memory agentsChosen,
            uint256 startExecutionTime
        ) = IExecutorLottery(executorLottery).runLottery(
                msgHash,
                destChain,
                opData.initialProposal.payload
            );

        uint256 executionDuration = IChainInfo(chainInfo)
            .getDefaultExecutionTime(destChain);

        emit LotteryExecuted(msgHash);
        emit NewExecutionAssignment(
            agentsChosen[0],
            destChain,
            msgHash,
            startExecutionTime,
            startExecutionTime + executionDuration
        );
    }

    function _validateSrcData(MessageLib.MessageData memory opData) private pure {
        if (
            opData.srcChainData.location.getChain() == 0 ||
            opData.srcChainData.location.getBlock() == 0 ||
            opData.srcChainData.srcOpTxId[0] == bytes32(0) ||
            opData.initialProposal.destChainId == 0 ||
            opData.initialProposal.nativeAmount == 0 ||
            opData.initialProposal.senderAddr.length == 0 || 
            opData.initialProposal.destAddr.length == 0
        ) {
            revert Master__InvalidSrcData();
        }
    }

    function _approveMessageDelivery(
        bytes32 msgHash,
        MessageLib.MessageStatus newStatus,
        address agent,
        uint256 nativeSpent,
        bytes32[2] memory destHash,
        bytes memory executor
    ) internal {
        MessageLib.MessageStatus status = messageData.getMsgStatusByHash(msgHash);

        if (!MessageLib.statusChangeValid(status, newStatus)) {
            emit InvalidMessageStatusChange(status, newStatus);
            return;
        }

        MessageStatusData storage statusData = msgConsensusData[msgHash].msgStatusData[newStatus];

        bool statusApproved = statusData.statusByAgent[agent];

        if (statusApproved) {
            emit MessageStatusAlreadyApproved(agent);
            return;
        }

        ExecutionAttempt[] storage attempts = msgExecutionData[
            msgHash
        ].tryExecutes;

        address exAgent = IKeyStorage(keyStorage).ownerByKey(executor);

        if (destHash[0] != bytes32(0) && destHash[1] != bytes32(0)) {
            bool exist;

            for (uint256 i = 0; i < attempts.length; ++i) {
                bytes32[2] storage existing = attempts[i].executionHash;
                
                if (
                    existing[0] == destHash[0] &&
                    existing[1] == destHash[1]
                ) {
                    exist = true;
                }
            }

            if (!exist) {
                attempts.push(
                    ExecutionAttempt(
                        block.timestamp,
                        exAgent,
                        destHash
                    )
                );
            }
        }

        uint256 confsBefore = statusData.confirmations;

        statusData.statusByAgent[agent] = true;
        statusData.confirmations++;

        uint256 destChain = messageData.getDestChainId(
            msgHash
        );

        emit StatusChangeApproved(msgHash, agent, newStatus);

        if (_superConsensusReached(destChain, confsBefore + 1)) {
            messageData.changeMessageStatus(
                msgHash,
                newStatus
            );

            emit MessageStatusChanged(msgHash, status, newStatus);

            if (
                newStatus == MessageLib.MessageStatus.SUCCESS ||
                newStatus == MessageLib.MessageStatus.PROTOCOL_FAILED ||
                newStatus == MessageLib.MessageStatus.FAILED
            ) {
                (
                    uint256 fullNativeAmount,
                    uint256 ACPReward,
                    uint256 superReward,
                    uint256 pointReward,
                    uint256 executorRewards
                ) = getRewardComponents(msgHash);

                MessageConsensusData storage consData = msgConsensusData[msgHash];

                uint256 transmLength = consData.transmissionSigs.length;
                address[] memory transmitters = new address[](transmLength);
                for (uint i = 0; i < transmLength; i++) {
                    address transmitterAddr = SignatureLib.getSignerAddress(msgHash, consData.transmissionSigs[i]);
                    if (transmitterAddr == address(0)) {
                        emit InvalidAddress();
                        return;
                    } 
                    transmitters[i] = transmitterAddr;
                }

                uint256 execLength = consData.executionSigs.length;
                address[] memory executors = new address[](execLength);
                for (uint i = 0; i < execLength; i++) {
                    address executorAddr = SignatureLib.getSignerAddress(msgHash, consData.executionSigs[i]);
                    if (executorAddr == address(0)) {
                        emit InvalidAddress();
                        return;
                    }
                    executors[i] = SignatureLib.getSignerAddress(msgHash, consData.executionSigs[i]);
                }

                executionNativeSpent[msgHash] = nativeSpent;
                uint256 srcChain = IMessageData(messageData).getSrcChainId(msgHash);

                IRewards(rewards).setReward(
                    srcChain,
                    exAgent,
                    executorRewards,
                    false
                );

                IRewards(rewards).setReward(
                    srcChain,
                    IRewards(rewards).treasury(),
                    ACPReward,
                    false
                );

                IRewards(rewards).setRewardGroup(
                    srcChain,
                    superReward,
                    msgConsensusData[msgHash].approvedBySuper
                );

                IPointDistributor(pointDistributor).distributePointRewards(
                    transmitters, 
                    executors, 
                    pointReward, 
                    srcChain,
                    destChain
                );

                uint256 totalFees = executorRewards + ACPReward + superReward + pointReward;
                uint256 nativeSpentInSrcCoins = IDFAdapter(DFAdapter).convertAmount(destChain, srcChain, nativeSpent);

                if (fullNativeAmount < totalFees) {
                    emit InsufficientFunds();
                    return;
                }

                uint256 executorCompensation = _min(nativeSpentInSrcCoins, fullNativeAmount - totalFees);
                if (executorCompensation > 0) {
                    IRewards(rewards).setReward(
                        srcChain,
                        exAgent,
                        executorCompensation,
                        true 
                    );
                }

                if (fullNativeAmount > totalFees + executorCompensation) {
                    uint256 remaining = fullNativeAmount - totalFees - executorCompensation;
                    address ACPReserve = IRewards(rewards).ACPReserve();

                    IRewards(rewards).setReward(
                        srcChain,
                        ACPReserve,
                        remaining,
                        false
                    );
                }
            }
        }
    }

    // ==============================
    //        MSG STATUS
    // ==============================

    function approveMessageDeliveryBatch(
        bytes32[] calldata msgsHashes,
        MessageLib.MessageStatus[] calldata newStatuses,
        uint256[] calldata nativeSpents,
        bytes32[2][] memory destHashes,
        bytes[] memory executors
    ) external onlyValidKey(abi.encode(_msgSender())) {
        address agent = _verifyAgent(abi.encode(_msgSender()));
        _onlySuperAgent(agent);

        if (msgsHashes.length != newStatuses.length ||
            msgsHashes.length != nativeSpents.length ||
            destHashes.length != msgsHashes.length ||
            destHashes.length != executors.length
        ) {
            revert Master__LengthMismacth();
        }

        for (uint256 i = 0; i < msgsHashes.length; ++i) {
            _approveMessageDelivery(msgsHashes[i], newStatuses[i], agent, nativeSpents[i], destHashes[i], executors[i]);
        }
    }

    /**
     * @notice Get maximum possible reward for given executor (compensation)
     * @param msgHash Message hash
     */
    function getExecutorReward(
        bytes32 msgHash
    ) public view returns (uint256) {
        (
            uint256 reward,
            uint256 ACPReward, 
            uint256 superReward, 
            uint256 pointReward, 
            uint256 executorReward
        ) = getRewardComponents(msgHash);
        uint256 comissions = executorReward + ACPReward + superReward + pointReward;
        if (reward < comissions) {
            return 0;
        } else {
            uint256 srcChain = messageData.getSrcChainId(msgHash);
            uint256 destChain = messageData.getDestChainId(msgHash);
            return IDFAdapter(DFAdapter).convertAmount(
                srcChain, 
                destChain, 
                reward - executorReward - ACPReward - superReward - pointReward
            );
        }
    }

    function getRewardComponents(bytes32 msgHash) public view returns (
        uint256 reward,
        uint256 ACPReward,
        uint256 superReward,
        uint256 pointReward,
        uint256 executorReward
    ) {
        reward = messageData.getReward(msgHash);
        uint256 srcChainId = messageData.getSrcChainId(msgHash);
        ACPReward = IFeeCalculator(feeCalculator).ACPFees(srcChainId);
        superReward = IFeeCalculator(feeCalculator).superFees(srcChainId);
        pointReward = IFeeCalculator(feeCalculator).pointDistrFees(srcChainId);
        executorReward = IFeeCalculator(feeCalculator).executorFees(srcChainId);
    }
    // ==============================
    //        VERIFICATIONS
    // ==============================

    function _verifyAgent(bytes memory signer) private view returns (address) {
        address agent = IKeyStorage(keyStorage).ownerByKey(signer);
        _onlyActive(agent);
        return agent;
    }

    function _verifySignature(
        MessageLib.MessageData memory opData,
        SignatureLib.Signature calldata sig
    ) private view {
        bytes32 msgHash = MessageLib.getHashPrefixed(opData);
        if (!SignatureLib.verifySignature(_msgSender(), msgHash, sig)) {
            revert Master__InvalidSignature();
        }
    }

    function _consensusReached(
        uint256 forChainID,
        uint256 agentsSigned
    ) private view returns (bool) {
        if (agentsSigned < MIN_SIGS) return false;

        (uint256 rate, uint256 currentConsensusRate) = consensusRates(
            forChainID,
            agentsSigned
        );

        if (rate > currentConsensusRate) {
            return true;
        } else {
            return false;
        }
    }

    function _superConsensusReached(
        uint256 forChainID,
        uint256 superSigned
    ) private view returns (bool) {
        (uint256 rate, uint256 currentConsensusRate) = superConsensusRates(
            forChainID,
            superSigned
        );

        if (rate >= currentConsensusRate) {
            return true;
        } else {
            return false;
        } 
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        if (a > b) return b;
        return a;
    }

    // ==============================
    //           GETTERS
    // ==============================

    /**
     * @notice Get consensus info for super-agents
     * @param forChainID Chain ID for which info will be provided
     * @param superSigned Number of super-agents signed
     */
    function superConsensusRates(
        uint256 forChainID,
        uint256 superSigned
    ) public view returns (uint256, uint256) {
        uint256 activeSupers = agentManager.activeSupersLen(0);
        uint256 rate = (superSigned * CONSENSUS_DENOM) / activeSupers;
        uint256 currentConsensusRate = IChainInfo(chainInfo)
            .getSuperConsensusRate(0);

        return (rate, currentConsensusRate);
    }

    /**
     * @notice Get consensus info for agents
     * @param forChainID Chain ID for which info will be provided
     * @param agentsSigned Number of agents signed
     */
    function consensusRates(
        uint256 forChainID,
        uint256 agentsSigned
    ) public view returns (uint256, uint256) {
        uint256 activeAgents = agentManager.getCurrentParticipantsLen(forChainID);
        uint256 rate = (agentsSigned * CONSENSUS_DENOM) / activeAgents;
        uint256 currentConsensusRate = IChainInfo(chainInfo).getConsensusRate(
            forChainID
        );

        return (rate, currentConsensusRate);
    }

    /**
     * @notice Check if agent is allowed on particular chain
     * @param agent - Agent EVM address
     * @param chainID - Chain ID
     */
    function agentAllowedOnChain(
        address agent,
        uint256 chainID
    ) public view returns (bool) {
        uint256 agentChain = agentManager.getAgentChain(agent);

        if (chainID != agentChain) {
            return false;
        }

        return true;
    }

    /**
     * @notice Check if message is approved by one of the super-agents
     * @param msgHash - Message hash
     * @param superAgent - Super-agent EVM address
     */
    function approvedBySuper(
        bytes32 msgHash,
        address superAgent
    ) public view returns (bool) {
        MessageConsensusData storage consData = msgConsensusData[msgHash];

        uint256 len = consData.approvedBySuper.length;
        for (uint256 i; i < len; i++) {
            if (
                consData.approvedBySuper[i] == superAgent
            ) {
                return true;
            }
        }
        return false;
    }

    function getSuperSignatures(
        bytes32 msgHash
    ) external view returns (SignatureLib.Signature[] memory) {
        return superSignatures[msgHash];
    }

    /**
     * @notice Retrieves the transmission signatures
     * for particular message
     * @param msgHash - Message hash
     * @return An array of Signature structs containing transmission signatures
     */
    function getTSignatures(
        bytes32 msgHash
    ) external view returns (SignatureLib.Signature[] memory) {
        return msgConsensusData[msgHash].transmissionSigs;
    }

    /**
     * @notice Retrieves the execution signatures 
     * for particular message
     * @param msgHash - Message hash
     * @return An array of Signature structs containing execution signatures
     */
    function getESignatures(
        bytes32 msgHash
    ) external view returns (SignatureLib.Signature[] memory) {
        return msgConsensusData[msgHash].executionSigs;
    }

    /**
     * @notice Check is message signed by given agent 
     * @param msgHash - Message hash
     * @param by - Agent EVM address
     */
    function isMessageSigned(
        bytes32 msgHash,
        address by
    ) external view returns (bool) {
        MessageConsensusData storage consData = msgConsensusData[msgHash];
        return consData.signed[by];
    }

    /**
     * @notice Get how many times message was executed
     * @param msgHash - Message hash
     */
    function getExecutionAttempts(
        bytes32 msgHash
    ) external view returns (ExecutionAttempt[] memory) {
        return msgExecutionData[msgHash].tryExecutes;
    }

    /**
     * @notice Get execution consensus signatures in a packed format
     * @dev Used for endpoint::execute()
     * @param msgHash - Message hash
     */
    function getESignaturesPacked(bytes32 msgHash) external view returns (bytes memory) {
        return SignatureLib.encodePureSigs(
            msgConsensusData[msgHash].executionSigs
        );
    }

    // ==============================
    //            ADMIN
    // ==============================

    function setContracts(address[] memory contractsAddresses) external onlyRole(ADMIN) {
        for (uint256 i = 0; i < contractsAddresses.length; ++i) {
            if (contractsAddresses[i] == address(0)) revert Master__InvalidAddress();
        }

        pointDistributor = contractsAddresses[0];
        DFAdapter = contractsAddresses[1];
        agentManager = IAgentManager(contractsAddresses[2]);
        messageData = IMessageData(contractsAddresses[3]);
        executorLottery = contractsAddresses[4];
        feeCalculator = contractsAddresses[5];
        keyStorage = contractsAddresses[6];
        chainInfo = contractsAddresses[7];
        rewards = contractsAddresses[8];
    }

    function setThreshold(uint256 newThreshold) external onlyRole(ADMIN) {
        threshold = newThreshold;
    }

    // ==============================
    //            UPGRADES
    // ==============================
    function _authorizeUpgrade(address) internal override onlyRole(ADMIN) {}
}
