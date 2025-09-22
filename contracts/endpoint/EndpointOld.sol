// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable, AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {IWNative} from "../interfaces/external/IWNative.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {MessageLib} from "../lib/MessageLib.sol";
import {SignatureLib} from "../lib/SignatureLib.sol";
import {SelectorLib} from "../lib/SelectorLib.sol";
import {LocationLib} from "../lib/LocationLib.sol";
import {TransmitterParamsLib} from "../lib/TransmitterParamsLib.sol";
import {SafeCall} from "../lib/SafeCall.sol";
import {IConfigurator} from "../interfaces/IConfigurator.sol";
import {AddressStringConverter} from "../lib/AddressStringConverter.sol";
import {IAxelarAdapter} from "../interfaces/IAxelarAdapter.sol";
import {ILZAdapter} from "../interfaces/ILZAdapter.sol";
import {VaaKey, MessageKey} from "../interfaces/IWormholeStruct.sol";
import {IGasEstimator} from "../interfaces/IGasEstimator.sol";

/**
 * @notice Endpoint contract is a contract 
 * for message proposing and execution to destination protocol
 */
contract EndpointOld is 
    Initializable,
    UUPSUpgradeable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    IAxelarAdapter
{
    using MessageLib for MessageLib.MessageData;
    using LocationLib for uint256;
    using SafeERC20 for IWNative;

    // ==============================  
    //          ERRORS
    // ============================== 

    /* common */
    error Endpoint__ZeroAddress();
    error Endpoint__ZeroValue();
    error Endpoint__NotEnoughFunds();
    error Endpoint__ArraysLengthsMismatch();

    /* EP */
    error Endpoint__SpecifyGasLimit();

    error Endpoint__AdminCannotSetTransmittersMultipleTimes();
    error Endpoint__InvalidConsensusRate(uint256 rate);

    /* resend */
    error Endpoint__InvalidHash();
    error Endpoint__InvalidValue(uint256 sum, uint256 value);
    error Endpoint__InvalidCommission();

    /* LZ Adapter */
    error Endpoint__InvalidLzReceiveOption(uint256 length);

    /* Pauses */
    error Endpoint__ProposeReject();
    error Endpoint__ExecuteReject();

    // ==============================  
    //          EVENTS
    // ============================== 
    event InvalidDestination();
    event InvalidSelector();
    event InvalidExecutor(address executor);
    event MessageAlreadyExecuted(bytes32 msgHash);

    event ConsensusNotReached(uint256 validSigs, uint256 sigsThreshold);
    event ConsensusReached(uint256 validSigs, uint256 sigsRequired);
    event TransmitterSet(address indexed transmitter, bool status);
    event ExecutorSet(address indexed executor, bool status);
    event MessageProposed(
        uint256 indexed destChainId,
        uint256 nativeAmount,
        bytes32 selectorSlot,
        bytes transmitterParams,
        bytes senderAddr,
        bytes destAddr,
        bytes payload,
        bytes reserved
    );
    event InvalidSignature(address indexed signer, uint256 id);
    event MessageExecuted(bytes32 msgHash);
    event FailedWithData(
        bytes32 msgHash,
        bytes data
    );
    event Failed(bytes32 msgHash);
    event CustomGasLimitTooHigh(uint256 customGasLimit);
    
    event AxelarMessageExecution(bytes32 msgHash);
    event LZMessageExecution(bytes32 msgHash);
    event WormholeMessageExecution(bytes32 msgHash);

    // ==============================  
    //      ROLES AND CONSTANTS 
    // ============================== 

    bytes32 public constant CONFIG  = keccak256("CONFIG"); 
    bytes32 public constant PAUSER  = keccak256("PAUSER");
    bytes32 public constant ENDPOINT_ADAPTER = keccak256("ENDPOINT_ADAPTER");

    /* ACP specific constants */
    uint256 public constant MIN_SIGS_REQUIRED = 3;
    uint256 public constant CONSENSUS_DENOM = 10_000;
    uint256 public constant MASTER_CHAIN_ID = 5611; 
    uint16  public constant SAFECALL_RETURN_DATA_SIZE = 480;

    /*
        Gas reserved for post-call execution
        - 128 bytes to log
        - 128 * 3 -- gas for memory
        - 128 * 2 -- gas for topics
        - 128 * 8 -- gas for each byte to log
        - 375 for emit
        - storing statusCode via 'cold' SSTORE = 20k
    */
    uint256 public constant GAS_RESERVED = 22500; 


    /// @dev Status codes for messages
    uint256 public constant SUCCESS = 1;
    uint256 public constant PROTOCOL_FAILED = 2;
    uint256 public constant FAILED = 3;


    /* Message Repeater supported commands */
    uint256 public constant MR_RESEND_COMMAND_CODE    = 1;
    uint256 public constant MR_REPLENISH_COMMAND_CODE = 2;      

    uint256 public constant RESEND_GAS = 400_000;
    uint256 public constant REPLENISH_GAS = 450_000;


    // Interface-compatible
    // bytes4(keccak256("execute(bytes)"));
    bytes4 public constant DEFAULT_SELECTOR = 0x09c5eabe;

    // bytes4(keccak256("execute(bytes32,string,string,bytes)"));
    bytes4 public constant AXELAR_EXECUTE_SELECTOR = 0x49160658;

    // bytes4(keccak256("lzReceive(uint32, bytes32, uint64, bytes32, bytes, address, bytes)"));
    bytes4 public constant LZ_EXECUTE_SELECTOR = 0x13137d65;
    
    // bytes4(keccak256("receiveWormholeMessages(bytes,bytes[],bytes32,uint16,bytes32)"));
    bytes4 public constant WORMHOLE_EXECUTE_SELECTOR = 0x529dca32;

    
    bytes1 public constant AXELAR_MESSAGE_ID = hex"01";
    bytes1 public constant LZ_MESSAGE_ID = hex"02";
    bytes1 public constant WORMHOLE_MESSAGE_ID = hex"03";
    

    /// @notice Min consensus rate
    uint256 public constant MIN_RATE = 5000;

    // ==============================  
    //          STORAGE 
    // ============================== 

    struct SupersData {
        address[] supers;
        mapping(address super => bool status) supersStatus;
    }

    SupersData internal supersData;

    bool proposeReject;
    
    bool executeReject;

    /// @notice Master Chain contract responsible for resend operations
    address public repeater;

    /// @notice ATS protocol connector
    address public connector;

    /// @notice Wrapped native currency on particular chain
    address public wNative;

    /// @notice Configurator address
    address public configurator;

    /// @notice GasEstimator address
    address public gasEstimator;

    /// @notice Consensus rate
    uint256 public consensusRate;

    /// @notice Active Transmitters
    uint256 public totalActiveSigners;

    /// @notice Minimum transaction value 
    uint256 public minCommission;

    /// @notice This mapping allows signers to participate in message execution (consensus)
    mapping(address transmitter => bool status) public allowedSigners;

    /// @notice This mapping allows executors to call execute on endpoint
    mapping(address executor => bool status) public allowedExecutors;

    /// @notice This mapping stores messages execution statuses
    mapping(bytes32 msgHashPrefixed => uint256 statusCode) public messagesExecuted;

    /// @notice This mapping stores supperted functoins selectors
    mapping(uint256 executionCode => bytes4 selector) public supportedCommands;

    mapping(bytes32 chainName => uint256) public chainNameToChainID;

    mapping(uint256 chainId => string chainName) public chainIdToChainName;
    
    mapping(uint16 wormholeChainId => uint256 chainId) public wormholeChainIdToChainId;

    mapping(uint256 chainId => uint16 wormholeChainId) public chainIdToWormholeChainId;

    mapping(address emitter => uint64 sequence) public sequences;

    mapping(uint32 eid => uint256 chainId) public eidToChainId;

    mapping(uint256 chainId => uint32 eid) public chainIdToEid;

    mapping(uint256 chainId => uint256) public minTxGas;
   
    // ==============================
    //          MODIFIERS
    // ==============================

    modifier checkRound() {
        if (
            IConfigurator(configurator).currentRound() > 1
            && 
            hasRole(DEFAULT_ADMIN_ROLE, _msgSender())
        ) {
            revert Endpoint__AdminCannotSetTransmittersMultipleTimes();
        }
        _;
    }

    // ==============================  
    //          FUNCTIONS 
    // ==============================
    

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address[] calldata initAddr,
        uint256 defaultConsensusRate
    ) public initializer {
        __UUPSUpgradeable_init();
        __AccessControl_init();
        __ReentrancyGuard_init();
        _setRoleAdmin(CONFIG, DEFAULT_ADMIN_ROLE);
        _setRoleAdmin(PAUSER, DEFAULT_ADMIN_ROLE);
        _setRoleAdmin(ENDPOINT_ADAPTER, DEFAULT_ADMIN_ROLE);

        _grantRole(DEFAULT_ADMIN_ROLE, initAddr[0]);
        _grantRole(CONFIG, initAddr[0]);
        _grantRole(PAUSER, initAddr[0]);

        consensusRate = defaultConsensusRate;
    }

    /**
     * @notice Propose message to be delivered on destination chain
     * @param destChainID   Destination chain ID
     * @param selectorSlot  Encoded selector information for destination chain
     * can be either default selector or one of supported commands
     * @param transmitterParams   Params to be passed to transmitter 
     * @custom:transmitter-params blockFinalizationOption 
     * Defines amount of blocks to wait for before transmitting to ACP.
     * @custom:transmitter-params customGasLimit
     * gas to be used in call to 'destAddress' (endpoint to protocol)
     * @param destAddress   Destination address to call
     * @param payload       Protocol specific payload
     */
    function propose(
        uint256 destChainID,
        bytes32 selectorSlot,
        bytes calldata transmitterParams,
        bytes calldata destAddress,
        bytes calldata payload
    ) external payable nonReentrant() {
        _propose(
            _msgSender(), 
            destChainID, 
            selectorSlot, 
            transmitterParams, 
            destAddress, 
            payload,
            ""
        );
    }

    /**
     * @notice Same as 'propose' but can be called by any approved adapter by ACP
     * @param setFrom Original caller (smart-contract) to be used in message proposal
     */
    function proposeFor(
        address setFrom,
        uint256 destChainID,
        bytes32 selectorSlot,
        bytes calldata transmitterParams,
        bytes calldata destAddress,
        bytes calldata payload
    ) external payable nonReentrant() onlyRole(ENDPOINT_ADAPTER) {
        _propose(
            setFrom,
            destChainID, 
            selectorSlot, 
            transmitterParams, 
            destAddress, 
            payload,
            ""
        );
    }

    function _propose(
        address from,
        uint256 destChainID,
        bytes32 selectorSlot,
        bytes memory transmitterParams,
        bytes memory destAddress,
        bytes memory payload,
        bytes memory reserve
    ) internal virtual {
        if (msg.value < minCommission) {
            revert Endpoint__InvalidCommission();
        }

        if (proposeReject) {
            revert Endpoint__ProposeReject();
        }

        uint256 gas = TransmitterParamsLib.customGasLimit(transmitterParams);
        if (gas == 0) {
            revert Endpoint__SpecifyGasLimit();
        }
        
        // uint256 estimatedFee = IGasEstimator(gasEstimator).estimateExecutionWithGas(destChainID, gas);
        // if (estimatedFee > msg.value) {
        //     revert Endpoint__NotEnoughFunds();
        // } else {
        //     uint256 diff = msg.value - estimatedFee;
        //     (bool success, bytes memory ret) = SafeCall.safeCall(
        //         from,
        //         minTxGas[block.chainid],
        //         diff,
        //         SAFECALL_RETURN_DATA_SIZE,
        //         new bytes(0)
        //     );
        // }

        (bool success, bytes memory ret) = SafeCall.safeCall(
            connector,
            minTxGas[block.chainid],
            msg.value,
            SAFECALL_RETURN_DATA_SIZE,
            new bytes(0)
        );

        emit MessageProposed(
            destChainID,
            msg.value,
            selectorSlot,
            transmitterParams,
            abi.encode(from),
            destAddress,
            payload,
            reserve
        );
    }

    /**
     * @notice Main function for messsage execution
     * @param msgData Message data passed from source chain
     * @param transmitterSigs Collection of signers (transmitters), who signed the message 
     */
    function execute(
        MessageLib.MessageData calldata msgData,
        SignatureLib.Signature[] calldata superSigs,
        bytes calldata transmitterSigs
    ) external nonReentrant payable {
        if (executeReject) {
            revert Endpoint__ExecuteReject();
        }
        
        bytes32 msgHash = msgData.getHashPrefixed();

        if (msgData.initialProposal.destChainId != block.chainid) {
            emit InvalidDestination();

            _failed(msgHash);
            return;
        }

        if (!allowedExecutors[_msgSender()]) {
            emit InvalidExecutor(_msgSender());

            _failed(msgHash);
            return;
        }

        if (messagesExecuted[msgHash] == SUCCESS) {
            emit MessageAlreadyExecuted(msgHash);

            _failed(msgHash);
            return;
        }

        bool ok;

        ok = _verifySuperConsensus(msgHash, superSigs);
        if (!ok) {
            _failed(msgHash);
            return;
        }

        ok = _verifyConsensus(msgHash, transmitterSigs);
        if (!ok) {
            _failed(msgHash);
            return;
        }

        address addressToCall = abi.decode(
            msgData.initialProposal.destAddr,
            (address)
        );

        uint256 customGasLimit = TransmitterParamsLib.customGasLimit(msgData.initialProposal.transmitterParams);

        // presume that gas less than GAS_RESERVED
        // is impossible by executor (status UNDERESTIMATED)
        uint256 gasToUse = gasleft() - GAS_RESERVED;

        if (customGasLimit != 0) {
            if (customGasLimit < gasToUse) {
                gasToUse = customGasLimit;
            } else {
                emit CustomGasLimitTooHigh(customGasLimit);
            }
        }

        bool success;
        bytes memory ret;
        bytes4 selector;

        if (msgData.initialProposal.reserved.length == 0) {
            selector = _getSelector(msgData.initialProposal.selectorSlot);
            if (selector == bytes4(0)) {
                emit InvalidSelector();

                _failed(msgHash);
                return;
            }

            bytes memory internalCallData = abi.encode(
                msgData.srcChainData.location.getChain(),
                msgData.srcChainData.srcOpTxId[0],
                msgData.initialProposal.senderAddr,
                msgData.initialProposal.payload
            );

            (success, ret) = SafeCall.safeCall(
                addressToCall,
                gasToUse,
                msg.value,
                SAFECALL_RETURN_DATA_SIZE,
                abi.encodeWithSelector(selector, internalCallData)
            );

        } else if (
            msgData.initialProposal.reserved.length == 1 &&
            msgData.initialProposal.reserved[0] == AXELAR_MESSAGE_ID
        ) {
            selector = AXELAR_EXECUTE_SELECTOR;
            string memory sourceChain = chainIdToChainName[msgData.srcChainData.location.getChain()];
            string memory sourceAddress = AddressStringConverter.bytesToString(msgData.initialProposal.senderAddr);

            (success, ret) = SafeCall.safeCall(
                addressToCall,
                gasToUse,
                msg.value,
                SAFECALL_RETURN_DATA_SIZE,
                abi.encodeWithSelector(
                    selector,
                    msgHash,
                    sourceChain,
                    sourceAddress,
                    msgData.initialProposal.payload
                )
            );

            emit AxelarMessageExecution(msgHash);
        } else if (
            msgData.initialProposal.reserved.length == 1 &&
            msgData.initialProposal.reserved[0] == LZ_MESSAGE_ID
        ) {
            selector = LZ_EXECUTE_SELECTOR;

            uint32 eid = chainIdToEid[msgData.srcChainData.location.getChain()];
            
            ILZAdapter.Origin memory origin = ILZAdapter.Origin({
                srcEid: eid,
                sender: bytes32(msgData.initialProposal.senderAddr),
                nonce: 1
            });
            
            bytes32 guid = keccak256(abi.encodePacked(
                uint256(1),
                uint256(1),
                bytes32(msgData.initialProposal.senderAddr),
                msgData.initialProposal.destChainId,
                msgData.initialProposal.destAddr    
            ));

            (success, ret) = SafeCall.safeCall(
                addressToCall,
                gasToUse,
                msg.value,
                SAFECALL_RETURN_DATA_SIZE,
                abi.encodeWithSelector(
                    selector,
                    origin,
                    guid,
                    msgData.initialProposal.payload,
                    bytes32(msgData.initialProposal.senderAddr),
                    new bytes(0)
                )
            );

            emit LZMessageExecution(msgHash);
        } else if (
            msgData.initialProposal.reserved.length == 1 &&
            msgData.initialProposal.reserved[0] == WORMHOLE_MESSAGE_ID 
        ) {
            selector = WORMHOLE_EXECUTE_SELECTOR;
            bytes[] memory additionalMessages;
            bytes32 sourceAddress = AddressStringConverter.fromBytesToWormholeFormat(msgData.initialProposal.senderAddr);
            uint16 sourceChain = chainIdToWormholeChainId[msgData.srcChainData.location.getChain()];

            (success, ret) = SafeCall.safeCall(
                addressToCall,
                gasToUse,
                msg.value,
                SAFECALL_RETURN_DATA_SIZE,
                abi.encodeWithSelector(
                    selector,
                    msgData.initialProposal.payload,
                    additionalMessages,
                    sourceAddress,
                    sourceChain,
                    msgHash
                )
            );

            emit WormholeMessageExecution(msgHash);
        }
        
        if (success) {
            messagesExecuted[msgHash] = SUCCESS;
            emit MessageExecuted(msgHash);
        } else {
            messagesExecuted[msgHash] = PROTOCOL_FAILED;
            emit FailedWithData(msgHash, ret);
        }
    }

    function _failed(bytes32 msgHash) private {
        messagesExecuted[msgHash] = FAILED;
        emit Failed(msgHash);
    }

    function _verifySuperConsensus(
        bytes32 msgHash,
        SignatureLib.Signature[] calldata superSig
    ) private returns (bool) {
        uint256 len = superSig.length;
        uint256 total = supersData.supers.length;
        uint256 required;
        if (total == 0) {
            revert("SCons not set");
        } else if (total == 1) {
            required = 1;
        } else {
            uint256 half; 
            if (total % 2 == 0) {
                half = total / 2;
            } else {
                half = (total + 1) / 2;
            }

            // super-transmitters are allowed to 50% consensus
            required = half;
        }

        uint256 valid;
        for (uint256 i = 0; i < len; i++) {
            address superAddr = SignatureLib.getSignerAddress(
                msgHash,
                superSig[i]
            );

            if (supersData.supersStatus[superAddr]) valid += 1;

            if (valid >= required) {
                return true;
            }
        }

        emit ConsensusNotReached(
            valid,
            required
        );

        return false;
    }

    function _verifyConsensus(
        bytes32 msgHash,
        bytes calldata transmitterSigs
    ) private returns (bool) {
        uint256 sigsThreshold = ((consensusRate * totalActiveSigners) / CONSENSUS_DENOM);

        uint256 validSigs;
        uint256 sigLen;
        address recovered;

        assembly {
            sigLen := byte(0, calldataload(transmitterSigs.offset))
        }

        if (sigLen < MIN_SIGS_REQUIRED) {
            emit ConsensusNotReached(0, consensusRate); 
            return false;
        }

        address[] memory uniqueSigners = new address[](sigLen);

        for (uint i = 0; i < sigLen; i++) {
            uint8 v;
            bytes32 r;
            bytes32 s;

            assembly {
                v := byte(add(1, i), calldataload(transmitterSigs.offset))

                // get transmitter sigs pointer -> skip (sigLen + 1) bytes -> skip next (32*2*i) bytes -> take 32 bytes
                r := calldataload( add(add(transmitterSigs.offset, add(sigLen, 1)), mul(0x20, mul(2, i)) ) )        
                
                // get transmitter sigs pointer -> skip (sigLen + 1) bytes -> skip next (32*(2*i+1)) bytes -> take 32 bytes     
                s := calldataload( add(add(transmitterSigs.offset, add(sigLen, 1)), mul(0x20, add(mul(2, i), 1)) ) )
            }
            recovered = ecrecover(
                msgHash,
                v,
                r,
                s
            );

            (bool dublicate, ) = _arrayContains(uniqueSigners, recovered);
            if (
                allowedSigners[recovered] &&
                !dublicate
            ) {
                uniqueSigners[validSigs] = recovered;
                validSigs += 1;
            } else {
                emit InvalidSignature(recovered, i);
            }

            // Check if the amount of valid signatures exceeds the required amount of signatures
            if (validSigs > sigsThreshold) {
                emit ConsensusReached(
                    validSigs,
                    sigsThreshold
                );

                // Exit early if consensus is reached
                return true; 
            }
        }

        if (validSigs <= sigsThreshold) {
            emit ConsensusNotReached(
                validSigs,
                sigsThreshold
            );

            return false;
        }

        return true;
    }

    /**
     * @dev Selector is not checked for defined value
     * for enforce default option
     * @param selectorSlot Selector slot encoded to bytes32 with
     * ACP SelectorLib
     */
    function _getSelector(
        bytes32 selectorSlot
    ) private view returns (bytes4 selector) {
        if (
            SelectorLib.getType(selectorSlot) ==
            SelectorLib.SelectorType.SELECTOR
        ) {
            selector = DEFAULT_SELECTOR;
        } else {
            (, uint256 exCode) = SelectorLib.extract(selectorSlot);
            selector = supportedCommands[exCode];
        }
    }

    function _arrayContains(address[] memory array, address element) internal pure returns (bool, uint256) {
        for (uint256 i = 0; i < array.length; ++i) {
            if (array[i] == element) return (true, i);
        }

        return (false, 0);
    }

    /**
     * @notice Function to be used to replenish message reward for execution
     * Should be used on underestimated or low-gas message statuses
     * @param fee Amount of tokens to be used as destination fee
     * @param amount Amount to add to message reward
     * @param msgHash Hash of message to be replenished
     */
    function replenish(
        uint256 fee,
        uint256 amount,
        bytes32 msgHash
    ) external virtual payable {
        if (executeReject) {
            revert Endpoint__ExecuteReject();
        }

        if (msg.value == 0) {
            revert Endpoint__ZeroValue();
        }

        if (amount == 0) {
            revert Endpoint__ZeroValue();
        }

        if (msg.value < minCommission) {
            revert Endpoint__InvalidCommission();
        }

        if (msg.value < amount + fee) {
            revert Endpoint__InvalidValue(amount + fee, msg.value);
        }

        if (msgHash == bytes32(0)) {
            revert Endpoint__InvalidHash();
        }

        payable(connector).transfer(msg.value);

        emit MessageProposed(
            MASTER_CHAIN_ID,
            fee,
            SelectorLib.encodeExecutionCode(MR_REPLENISH_COMMAND_CODE),                   
            abi.encode(0, REPLENISH_GAS),
            abi.encode(address(this)),
            abi.encode(repeater),
            abi.encode(msgHash, amount),
            ""
        );
    }

    /**
     * @notice Try to resend message by executors
     * @param msgHash Hash of message to be resent
     */
    function resend(
        bytes32 msgHash
    ) external virtual payable {
        if (executeReject) {
            revert Endpoint__ExecuteReject();
        }

        if (msg.value == 0) {
            revert Endpoint__ZeroValue();
        }

        if (msg.value < minCommission) {
            revert Endpoint__InvalidCommission();
        }

        if (msgHash == bytes32(0)) {
            revert Endpoint__InvalidHash();
        }

        payable(connector).transfer(msg.value);

        emit MessageProposed(
            MASTER_CHAIN_ID,
            msg.value,
            SelectorLib.encodeExecutionCode(MR_RESEND_COMMAND_CODE),                   
            abi.encode(0, RESEND_GAS),
            abi.encode(address(this)),
            abi.encode(repeater),
            abi.encode(msgHash),
            ""
        );
    }

    // ==============================  
    //       ADMIN & CONFIG
    // ============================== 

    function setSupersData(
        address[] calldata supers
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        for (uint256 i = 0; i < supers.length; i++) {
            if (supers[i] == address(0)) {
                revert Endpoint__ZeroAddress();
            }
            supersData.supersStatus[supers[i]] = true;
        }

        supersData.supers = supers;
    }

    function getSupersData() external view returns(uint256, address[] memory) {
        return (supersData.supers.length, supersData.supers);
    }

    function deleteSuper(address s) external onlyRole(DEFAULT_ADMIN_ROLE) {
        supersData.supersStatus[s] = false;
        _removeSuper(s);
    }

    function _removeSuper(address s) private {
        // delete from array with pop
        for (uint256 i = 0; i < supersData.supers.length; i++) {
            if (supersData.supers[i] == s) {
                supersData.supers[i] = supersData.supers[supersData.supers.length - 1];
                supersData.supers.pop();
            }
        }
    }

    /**
     * @notice Activate or disable consensus participants
     * @param signers  Signers array 
     * @param activate Flag to activate or disable
     */
    function activateOrDisableSignerBatch(
        address[] calldata signers,
        bool[] calldata activate
    ) external onlyRole(CONFIG) checkRound() {
        uint256 len = signers.length;

        if (signers.length != activate.length) {
            revert Endpoint__ArraysLengthsMismatch();
        }
        
        for (uint256 i = 0; i < len; i++) {
            _setTransmitter(signers[i], activate[i]);
        }
    }

    /**
     * @notice Activate or disable allowed executors
     * @param executors Executors array 
     * @param activate  Flag to activate or disable
     */
    function activateOrDisableExecutorBatch(
        address[] calldata executors,
        bool[] calldata activate
    ) external onlyRole(CONFIG) checkRound() {
        uint256 len = executors.length;

        if (executors.length != activate.length) {
            revert Endpoint__ArraysLengthsMismatch();
        }

        for (uint256 i = 0; i < len; i++) {
            _setExecutor(executors[i], activate[i]);
        }
    }

    /**
     * @notice Set consensus target rate for consensus approval
     * @param rate New consensus target rate
     */
    function setConsensusTargetRate(uint256 rate) external onlyRole(CONFIG) {
        if (rate < MIN_RATE) {
            revert Endpoint__InvalidConsensusRate(rate);
        }
        consensusRate = rate;
    }

    /**
     *  @notice Set total number of active signers
     * @param signers New count of active signers
     */
    function setTotalActiveSigners(uint256 signers) external onlyRole(CONFIG){
        if (signers == 0) revert Endpoint__ZeroValue();
        totalActiveSigners = signers;
    }

    function _setTransmitter(address transmitter, bool status) private {
        if (transmitter == address(0)) {
            revert Endpoint__ZeroAddress();
        }
        allowedSigners[transmitter] = status;
        emit TransmitterSet(transmitter, status);
    }

    function _setExecutor(address executor, bool status) private {
        if (executor == address(0)) {
            revert Endpoint__ZeroAddress();
        }
        allowedExecutors[executor] = status;
        emit ExecutorSet(executor, status);
    }

    function _chainNameToChainId(string calldata chainName) internal view returns (uint256) {
        bytes32 encodedChainName = keccak256(abi.encodePacked(chainName));

        return chainNameToChainID[encodedChainName];
    }

    /**
     * @notice Set supported functions selector
     * @param executionCodes The unique identifier for the command 
     * @param selectors The function selector associated with the command 
     */
    function saveSupportedCommandBatch(
        uint256[] calldata executionCodes,
        bytes4[] calldata selectors
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        uint256 len = executionCodes.length;
        if (len != selectors.length) {
            revert Endpoint__ArraysLengthsMismatch();
        }

        for (uint256 i = 0; i < len; i++) {
            supportedCommands[executionCodes[i]] = selectors[i];
        }
    }

    /* Set addresses */

    /**
     * @notice Updates the address of the MessageRepeater contract
     * @param newRepeater The new address of the MessageRepeater contract
     */
    function setRepeater(address newRepeater) public onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newRepeater == address(0)) revert Endpoint__ZeroAddress();
        else repeater = newRepeater;
    }

    /**
     * @notice Sets the address of the ATS Connector contract
     * @param newConnector The new address of the ATS Connector contract
     */
    function setATSConnector(address newConnector) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newConnector == address(0)) revert Endpoint__ZeroAddress();
        connector = newConnector;
    }

    /**
     * @notice Sets the address of the Wrapped Native token contract
     * @param native The new address of the Wrapped Native token contract
     */
    function setWrappedNative(address native) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (native == address(0)) revert Endpoint__ZeroAddress();
        wNative = native;
    }

    /**
     * @notice Sets the address of the Configurator contract
     * @param newConfigurator The new address of the Configurator contract
     */
    function setConfigurator(address newConfigurator) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newConfigurator == address(0)) revert Endpoint__ZeroAddress();
        configurator = newConfigurator;

        _grantRole(CONFIG, configurator);
    }

    function setGasEstimator(address newEstimator) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newEstimator == address(0)) revert Endpoint__ZeroAddress();
        gasEstimator = newEstimator;
    }

    function setChainsForAxelar(string[] calldata chainsNames, uint256[] calldata chainIds) public onlyRole(DEFAULT_ADMIN_ROLE) {
        if (chainsNames.length != chainIds.length) {
            revert Endpoint__ArraysLengthsMismatch();
        }

        for (uint256 i = 0; i < chainIds.length; ++i) {
            bytes32 encodedChainName = keccak256(abi.encodePacked(chainsNames[i]));
        
            chainNameToChainID[encodedChainName] = chainIds[i];
            chainIdToChainName[chainIds[i]] = chainsNames[i];
        }
    }

    function setRejects(bool prop, bool ex) public onlyRole(PAUSER) {
        proposeReject = prop;
        executeReject = ex;
    }
    
    function setMinCommission(uint256 commission) public onlyRole(DEFAULT_ADMIN_ROLE) {
        if (commission == 0) {
            revert Endpoint__InvalidCommission();
        }
        minCommission = commission;
    }

    function setMinTxGas(uint256 chainId, uint256 newMinTxGas) public onlyRole(DEFAULT_ADMIN_ROLE) {
        if (chainId == 0 || newMinTxGas == 0) {
            revert Endpoint__ZeroValue();
        }
        minTxGas[chainId] = newMinTxGas;
    }

    // ==============================  
    //          UPGRADES 
    // ============================== 
    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}


    // ==============================  
    //      AXELAR COMPATIBILITY 
    // ==============================

    function payGas(
        address sender,
        string calldata destinationChain,
        string calldata destinationAddress,
        bytes calldata payload,
        uint256 executionGasLimit,
        bool ,
        address refundAddress,
        bytes calldata 
    ) external payable {
        if (proposeReject) {
            revert Endpoint__ProposeReject();
        }
        
        if (msg.value < minCommission) {
            revert Endpoint__InvalidCommission();
        }

        uint256 destChainId = _chainNameToChainId(destinationChain);
        bytes32 selectorSlot = SelectorLib.encodeDefaultSelector(AXELAR_EXECUTE_SELECTOR);
        bytes memory destAddress = AddressStringConverter.stringToBytes(destinationAddress);

        _propose(
            sender,
            destChainId,
            selectorSlot,
            abi.encode(0, executionGasLimit),
            destAddress,
            payload,
            abi.encodePacked(AXELAR_MESSAGE_ID)
        );

        emit GasPaidForContractCall(
            sender,
            destinationChain,
            destinationAddress,
            keccak256(payload),
            address(0),
            executionGasLimit,
            refundAddress
        );
    }

    function callContract(
        string calldata destinationChain,
        string calldata destinationContractAddress,
        bytes calldata payload
    ) public {
        emit ContractCall(
            _msgSender(),
            destinationChain,
            destinationContractAddress,
            keccak256(payload),
            payload
        );
    }

    function validateContractCall(
        bytes32 ,
        string calldata ,
        string calldata ,
        bytes32 
    ) external returns (bool) {
        return true;
    }

    function isCommandExecuted(bytes32 commandId) external view returns (bool) {
        return messagesExecuted[commandId] != 0;
    }

    function isContractCallApproved(
        bytes32 ,
        string calldata ,
        string calldata ,
        address ,
        bytes32 
    ) external view returns (bool) {
        return true;
    }

    function gasCollector() external returns (address) { return gasEstimator; }

    function estimateGasFee(
        string calldata destinationChain,
        string calldata ,
        bytes calldata ,
        uint256 executionGasLimit,
        bytes calldata 
    ) external view returns (uint256 gasEstimate) {
        uint256 destChainId = _chainNameToChainId(destinationChain);
        return IGasEstimator(gasEstimator).estimateExecutionWithGas(destChainId, executionGasLimit); 
    }

    function messageToCommandId(string calldata sourceChain, string calldata messageId) public pure returns (bytes32) {
        return keccak256(bytes(string.concat(sourceChain, '_', messageId)));
    }


    // ==============================  
    //    LAYERZERO COMPATIBILITY 
    // ==============================

    function send(
        ILZAdapter.MessagingParams calldata _params,
        address 
    ) external payable returns (ILZAdapter.MessagingReceipt memory) {
        if (proposeReject) {
            revert Endpoint__ProposeReject();
        }
        
        if (msg.value < minCommission) {
            revert Endpoint__InvalidCommission();
        }

        bytes32 selectorSlot = SelectorLib.encodeDefaultSelector(LZ_EXECUTE_SELECTOR);
        uint256 eid = 1;
        uint64 latestNonce = 1;
        (uint128 customGasLimit, ) = decodeLzReceiveOption(_params.options);

        bytes32 guid = keccak256(abi.encodePacked(
            latestNonce,
            eid,
            _msgSender(),
            _params.dstEid,
            _params.receiver    
        ));

        ILZAdapter.MessagingFee memory msgFee = ILZAdapter.MessagingFee({
            nativeFee: msg.value,
            lzTokenFee: 0
        });

        _propose(
            _msgSender(),
            eidToChainId[_params.dstEid],
            selectorSlot,
            abi.encode(0, customGasLimit),
            abi.encode(_params.receiver),
            _params.message,
            abi.encode(LZ_MESSAGE_ID)
        );

        return (ILZAdapter.MessagingReceipt(guid, latestNonce, msgFee));
    }

    function quote(
        ILZAdapter.MessagingParams calldata _params, 
        address 
    ) external view returns (ILZAdapter.MessagingFee memory) {
        (uint128 gas, ) = decodeLzReceiveOption(_params.options);
        uint256 destChainId = eidToChainId[_params.dstEid];

        uint256 estimatedGas = IGasEstimator(gasEstimator).estimateExecutionWithGas(destChainId, gas);
        return ILZAdapter.MessagingFee(estimatedGas, 0);
    }

    function decodeLzReceiveOption(bytes calldata _option) internal pure returns (uint128 gas, uint128 value) {
        if (_option.length != 16 && _option.length != 32) revert Endpoint__InvalidLzReceiveOption(_option.length);

        if (_option.length == 16) {
            unchecked {
                gas = uint128(bytes16(_option[0:16]));
                value = 0;
            }
        }
        if (_option.length == 32) {
            unchecked {
                gas = uint128(bytes16(_option[0:16]));
                value =  uint128(bytes16(_option[16:32]));
            }
        }
    }

    function setLzEids(
        uint32[] calldata eids, 
        uint256[] calldata chainIds
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (eids.length != chainIds.length) {
            revert Endpoint__ArraysLengthsMismatch();
        }

        for (uint i = 0; i < eids.length; i++) {
            eidToChainId[eids[i]] = chainIds[i];
            chainIdToEid[chainIds[i]] = eids[i];
        }
    }

    // ==============================  
    //     WORMHOLE COMPATIBILITY 
    // ============================== 

    function sendPayloadToEvm(
        uint16 targetChain,
        address targetAddress,
        bytes memory payload,
        uint256 ,
        uint256 gasLimit
    ) external payable returns (uint64 sequence) {
        return _sendWormholePropose(
            targetChain,
            targetAddress,
            payload,
            gasLimit
        );
    }

    function sendPayloadToEvm(
        uint16 targetChain,
        address targetAddress,
        bytes memory payload,
        uint256 ,
        uint256 gasLimit,
        uint16 ,
        address 
    ) external payable returns (uint64 sequence) {
        return _sendWormholePropose(
            targetChain,
            targetAddress,
            payload,
            gasLimit
        );
    }

    function sendVaasToEvm(
        uint16 targetChain,
        address targetAddress,
        bytes memory payload,
        uint256 ,
        uint256 gasLimit,
        VaaKey[] memory 
    ) external payable returns (uint64 sequence) {
        return _sendWormholePropose(
            targetChain,
            targetAddress,
            payload,
            gasLimit
        );
    }

    function sendVaasToEvm(
        uint16 targetChain,
        address targetAddress,
        bytes memory payload,
        uint256 ,
        uint256 gasLimit,
        VaaKey[] memory ,
        uint16 ,
        address 
    ) external payable returns (uint64 sequence) {
        return _sendWormholePropose(
            targetChain,
            targetAddress,
            payload,
            gasLimit
        );
    }

    function sendToEvm(
        uint16 targetChain,
        address targetAddress,
        bytes memory payload,
        uint256 ,
        uint256 ,
        uint256 gasLimit,
        uint16 ,
        address ,
        address ,
        VaaKey[] memory ,
        uint8 
    ) public payable returns (uint64 sequence) {
        return _sendWormholePropose(
            targetChain,
            targetAddress,
            payload,
            gasLimit
        );
    }

    function sendToEvm(
        uint16 targetChain,
        address targetAddress,
        bytes memory payload,
        uint256 ,
        uint256 ,
        uint256 gasLimit,
        uint16 ,
        address ,
        address ,
        MessageKey[] memory ,
        uint8 
    ) public payable returns (uint64 sequence) {
        return _sendWormholePropose(
            targetChain,
            targetAddress,
            payload,
            gasLimit
        );
    }

    function send(
        uint16 targetChain,
        bytes32 targetAddress,
        bytes memory payload,
        uint256 ,
        uint256 ,
        bytes memory encodedExecutionParameters,
        uint16 ,
        bytes32 ,
        address ,
        VaaKey[] memory ,
        uint8 
    ) public payable returns (uint64 sequence) {
        (, uint256 gasLimit) = abi.decode(encodedExecutionParameters, (uint8, uint256));
        address destAddress = AddressStringConverter.fromWormholeFormat(targetAddress);

        return _sendWormholePropose(
            targetChain,
            destAddress,
            payload,
            gasLimit
        );
    }

    function send(
        uint16 targetChain,
        bytes32 targetAddress,
        bytes memory payload,
        uint256 ,
        uint256 ,
        bytes memory encodedExecutionParameters,
        uint16 ,
        bytes32 ,
        address ,
        MessageKey[] memory ,
        uint8 
    ) public payable returns (uint64 sequence) {
        (, uint256 gasLimit) = abi.decode(encodedExecutionParameters, (uint8, uint256));
        address destAddress = AddressStringConverter.fromWormholeFormat(targetAddress);

        return _sendWormholePropose(
            targetChain,
            destAddress,
            payload,
            gasLimit
        );
    }

    function quoteEVMDeliveryPrice(
        uint16 targetChain,
        uint256 ,
        uint256 gasLimit
    ) external view returns (uint256 nativePriceQuote, uint256 targetChainRefundPerGasUnused) {
        uint256 estimatedGas = IGasEstimator(gasEstimator).estimateExecutionWithGas(targetChain, gasLimit);
        return (estimatedGas, 0);
    }

    function quoteEVMDeliveryPrice(
        uint16 targetChain,
        uint256 ,
        uint256 gasLimit,
        address 
    ) external view returns (uint256 nativePriceQuote, uint256 targetChainRefundPerGasUnused) {
        uint256 estimatedGas = IGasEstimator(gasEstimator).estimateExecutionWithGas(targetChain, gasLimit);
        return (estimatedGas, 0);
    }

    function quoteDeliveryPrice(
        uint16 targetChain,
        uint256 ,
        bytes memory encodedExecutionParameters,
        address 
    ) external view returns (uint256 nativePriceQuote, bytes memory encodedExecutionInfo) {
        (, uint256 gasLimit) = abi.decode(encodedExecutionParameters, (uint8, uint256));
        uint256 estimatedGas = IGasEstimator(gasEstimator).estimateExecutionWithGas(targetChain, gasLimit);

        return (estimatedGas, "0x00");
    }

    function setChainIdForWormhole(uint16[] memory wormholeChainIds, uint256[] memory chainIds) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (wormholeChainIds.length != chainIds.length) {
            revert Endpoint__ArraysLengthsMismatch();
        }

        for (uint256 i = 0; i < chainIds.length; ++i) {
            wormholeChainIdToChainId[wormholeChainIds[i]] = chainIds[i];
            chainIdToWormholeChainId[chainIds[i]] = wormholeChainIds[i];
        }
    }

    function _sendWormholePropose(
        uint16 targetChain,
        address targetAddress,
        bytes memory payload,
        uint256 gasLimit
    ) internal returns (uint64 sequence) {
        if (proposeReject) {
            revert Endpoint__ProposeReject();
        }

        if (msg.value < minCommission) {
            revert Endpoint__InvalidCommission();
        }

        address sender = _msgSender();
        uint256 destChainId = wormholeChainIdToChainId[targetChain];
        bytes32 selectorSlot = SelectorLib.encodeDefaultSelector(WORMHOLE_EXECUTE_SELECTOR);
        bytes memory destAddress = abi.encode(targetAddress);

        _propose(
            sender,
            destChainId,
            selectorSlot,
            abi.encode(0, gasLimit),
            destAddress,
            payload,
            abi.encodePacked(WORMHOLE_MESSAGE_ID)
        );

        sequence = sequences[sender];
        sequences[sender]++;
    }
}
