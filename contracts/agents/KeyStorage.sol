// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable, AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {HashSetLib, BytesHashSet} from "../lib/HashSetLib.sol";

/**
 * @title  KeyStorage
 * @notice Contract for managing agent's collections of keys
 */
contract KeyStorage is
    Initializable,
    UUPSUpgradeable,
    AccessControlUpgradeable
{
    using HashSetLib for BytesHashSet;

    // ==============================
    //          EVENTS
    // ==============================

    event KeySet(
        address indexed owner,
        uint256 indexed chainID,
        KeyType _type,
        bytes indexed key
    );

    event KeyRemoved(
        address indexed owner,
        uint256 indexed chainID,
        KeyType _type,
        bytes indexed key
    );

    event ReceiverChanged(
        address indexed owner,
        uint256 indexed chainID,
        bytes oldReceiver,
        bytes newReceiver
    );

    event MaxKeysChanged(uint256 oldmax, uint256 newMax);

    event SignerKeyApproved(address indexed owner, uint256 indexed chainId, bytes indexed key);

    // ==============================
    //          ERRORS
    // ==============================

    /// @dev Non-existent key
    error KeyStorage__InvalidAddress();
    error KeyStorage__SlotsFull(address owner, uint256 chainID, KeyType _type);
    error KeyStorage__InvalidChainID(uint256 chainID);

    // ==============================
    //           ROLES
    // ==============================

    bytes32 public constant ADMIN  = keccak256("ADMIN");
    bytes32 public constant SETTER = keccak256("SETTER");

    // ==============================
    //           STORAGE
    // ==============================

    /**
     * @dev Key types
     * SIGNER   - signer that take part in consensus of agents
     * EXECUTOR - executor that executes a message
     * RECEIVER - receiver that receives a reward 
     * (unused for rewards since ATS & Rewards, but may be used in the future)
     * RESERVED - reserved for future use
     */
    enum KeyType {
        SIGNER,
        EXECUTOR,
        RECEIVER,
        RESERVED
    }

    /**
     * @notice Key collection
     * Stores collection of keys for agent operations
     */
    struct KeyCollection {
        uint256 totalKeysRegistered;
        bytes receiver;
        mapping(KeyType => BytesHashSet) sets;
    }

    /// @notice Max number of keys of type allowed for now
    uint256 public maxKeys;

    /// @notice Address of default agent registrator
    address public agentRegistrator;

    mapping(address owner => mapping(uint256 chainID => KeyCollection)) public keyCollection;
    
    /// @dev This mapping is for search and validity checks
    mapping(bytes key => address owner) public keyOwner;

    // ==============================
    //          FUNCTIONS
    // ==============================

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize
    /// @param initAddr[0] - Admin address
    /// @param initAddr[1] - Setter address
    /// @param newMaxKeys - Max number of keys for each type
    function initialize(
        address[] calldata initAddr,
        uint256 newMaxKeys
    ) public initializer {
        __UUPSUpgradeable_init();
        __AccessControl_init();
        _setRoleAdmin(ADMIN, ADMIN);
        _setRoleAdmin(SETTER, ADMIN);
        _grantRole(ADMIN, initAddr[0]);
        _grantRole(SETTER, initAddr[1]);
        agentRegistrator = initAddr[1];

        maxKeys = newMaxKeys;
    }

    /**
     * @notice Add key as a usual agent
     * @param chainID ChainID of the agent
     * @param keyType Key type
     * @param key     Key in bytes format
     */
    function addKey(uint256 chainID, KeyType keyType, bytes calldata key) external {
        if (key.length == 0) {
            revert KeyStorage__InvalidAddress();
        }
        if (chainID == 0) {
            revert KeyStorage__InvalidChainID(chainID);
        }

        _addKey(_msgSender(), chainID, keyType, key);
    }

    /**
     * @notice Add key as a super agent. Super-agents operate on all chains
     * @param keyType Key type
     * @param key     Key in bytes format
     */
    function superAddKey(KeyType keyType, bytes calldata key) external {
        if (key.length == 0) {
            revert KeyStorage__InvalidAddress();
        }
        
        _addKey(_msgSender(), 0, keyType, key);
    }

    /**
     * @notice Add multiple keys as an usual agent
     * @param chainID Chain ID of the agent
     * @param keyType Key types
     * @param keys Keys
     */
    function addKeyBatch(
        uint256 chainID,
        KeyType[] calldata keyType,
        bytes[] calldata keys
    ) external {
        if (chainID == 0) {
            revert KeyStorage__InvalidChainID(chainID);
        }
        uint256 len = keys.length;
        for (uint256 i = 0; i < len; i++) {
            if (keys[i].length == 0) {
                revert KeyStorage__InvalidAddress();
            }

            _addKey(_msgSender(), chainID, keyType[i], keys[i]);
        }
    }

    /**
     * @notice Add multiple keys as a super-agent
     * @param keyType Key types
     * @param keys Keys
     */
    function superAddKeyBatch(
        KeyType[] calldata keyType,
        bytes[] calldata keys
    ) external {
        uint256 len = keys.length;
        for (uint256 i = 0; i < len; i++) {
            if (keys[i].length == 0) {
                revert KeyStorage__InvalidAddress();
            }

            _addKey(_msgSender(), 0, keyType[i], keys[i]);
        }
    }

    /**
     * @dev Entry for registratoe-contracts
     * @notice Add multiple keys for super-agent
     * @param forAgent Address of the agent
     * @param keyType Key types
     * @param keys Keys
     */
    function superAddKeysFor(
        address forAgent,
        KeyType[] calldata keyType,
        bytes[] calldata keys
    ) external onlyRole(SETTER) {
        uint256 len = keys.length;
        for (uint256 i = 0; i < len; i++) {
            if (keys[i].length == 0) {
                revert KeyStorage__InvalidAddress();
            }

            _addKey(forAgent, 0, keyType[i], keys[i]);
        }
    }

    /**
     * @dev Entry function for registrator-contract
     * @notice Add multiple keys for agent
     * @param forAgent Address of the agent
     * @param chainID Chain ID of the agent
     * @param keyType Key types
     * @param keys Keys
     */
    function addKeysFor(
        address forAgent,
        uint256 chainID,
        KeyType[] calldata keyType,
        bytes[] calldata keys
    ) external onlyRole(SETTER) {
        uint256 len = keys.length;
        for (uint256 i = 0; i < len; i++) {
            if (keys[i].length == 0) {
                revert KeyStorage__InvalidAddress();
            }

            _addKey(forAgent, chainID, keyType[i], keys[i]);
        }
    }

    function _addKey(
        address owner,
        uint256 chainID,
        KeyType keyType,
        bytes memory keyB
    ) private {

        if (keyType == KeyType.SIGNER) {
            // decoded key is the proof that it's valid. otherwise decoding will revert
            abi.decode(keyB, ());
            emit SignerKeyApproved(owner, chainID, keyB);
        }

        BytesHashSet storage set = keyCollection[owner][chainID].sets[
            keyType
        ];
        uint256 len = set.count();
        if (len == maxKeys) {
            revert KeyStorage__SlotsFull(owner, chainID, keyType);
        }
        set.add(keyB);

        KeyCollection storage ownerCollection = keyCollection[owner][chainID];
        ownerCollection.totalKeysRegistered += 1;
        keyOwner[keyB] = owner;

        emit KeySet(owner, chainID, keyType, keyB);
    }

    /**
     * @notice Change Key as an agent
     * @param chainID Chain ID of the agent for changing key
     * @param keyType Key type
     * @param oldKeyB Old key
     * @param newKeyB New Key
     */
    function changeKey(
        uint256 chainID,
        KeyType keyType,
        bytes calldata oldKeyB,
        bytes calldata newKeyB
    ) external {
        if (newKeyB.length == 0) {
            revert KeyStorage__InvalidAddress();
        }
        if (chainID == 0) {
            revert KeyStorage__InvalidChainID(chainID);
        }

        _remove(_msgSender(), chainID, keyType, oldKeyB);
        _addKey(_msgSender(), chainID, keyType, newKeyB);
    }

    /**
     * @notice Change Key as a super-agent
     * @param keyType Key type
     * @param oldKeyB Old key
     * @param newKeyB New Key
     */
    function superChangeKey(
        KeyType keyType,
        bytes memory oldKeyB,
        bytes memory newKeyB
    ) external {
        if (newKeyB.length == 0) {
            revert KeyStorage__InvalidAddress();
        }

        _remove(_msgSender(), 0, keyType, oldKeyB);
        _addKey(_msgSender(), 0, keyType, newKeyB);
    }

    /**
     * @notice Change receiver key as an agent 
     * @param chainID   Chain ID of the agent
     * @param receiverB Receiver in bytes format
     */
    function changeReceiver(uint256 chainID, bytes calldata receiverB) external {
        if (receiverB.length == 0) {
            revert KeyStorage__InvalidAddress();
        }
        if (chainID == 0) {
            revert KeyStorage__InvalidChainID(chainID);
        }

        KeyCollection storage senderCollection = keyCollection[_msgSender()][chainID];
        bytes memory oldReceiver = senderCollection.receiver;
        senderCollection.receiver = receiverB;

        emit ReceiverChanged(_msgSender(), chainID, oldReceiver, receiverB);
    }

    /**
     * @notice Change receiver key as a super-agent 
     * @param receiverB Receiver in bytes format
     */
    function superChangeReceiver(bytes calldata receiverB) external {
        if (receiverB.length == 0) {
            revert KeyStorage__InvalidAddress();
        }
        
        KeyCollection storage superCollection = keyCollection[_msgSender()][0];
        bytes memory oldReceiver = superCollection.receiver;
        superCollection.receiver = receiverB;

        emit ReceiverChanged(_msgSender(), 0, oldReceiver, receiverB);
    }

    /**
     * @notice Remove key as an agent
     * @param chainID Chain ID of the agent
     * @param keyType Key type
     * @param key     Key in bytes format
     */
    function removeKey(uint256 chainID, KeyType keyType, bytes calldata key) external {
        if (chainID == 0) {
            revert KeyStorage__InvalidChainID(chainID);
        }
        _remove(_msgSender(), chainID, keyType, key);
    }

    /**
     * @notice Remove key as a super-agent
     * @param keyType Key type
     * @param key     Key in bytes format
     */
    function superRemoveKey(KeyType keyType, bytes calldata key) external {
        _remove(_msgSender(), 0, keyType, key);
    }

    function _remove(
        address owner,
        uint256 chainID,
        KeyType keyType,
        bytes memory keyB
    ) private {
        KeyCollection storage ownerCollection = keyCollection[owner][chainID];
        BytesHashSet  storage set = keyCollection[owner][chainID].sets[
            keyType
        ];
        set.remove(keyB);
        ownerCollection.totalKeysRegistered -= 1;

        emit KeyRemoved(owner, chainID, keyType, keyB);
    }


    // ==============================
    //          GETTERS
    // ==============================

    /**
     * @notice Get Items
     * @param owner   agent address
     * @param chainID Chain ID of agent
     * @param keyType Key Type
     */
    function getItems(
        address owner,
        uint256 chainID,
        KeyType keyType
    ) external view returns (bytes[] memory) {
        return keyCollection[owner][chainID].sets[keyType].items;
    }

    /**
     * @notice Get Items len
     * @param owner   agent address
     * @param chainId Chain ID of agent
     * @param keyType Key Type
     */
    function getItemsLen(
        address owner,
        uint256 chainId,
        KeyType keyType
    ) external view returns (uint256) {
        return keyCollection[owner][chainId].sets[keyType].items.length;
    }

    /**
     * @notice Get Items len of diferrent owners
     * @param owners  An array with agents addresses
     * @param keyType Key type
     */
    function getItemsLenBatch(
        uint256 chainId,
        KeyType keyType,
        address[] memory owners
    ) external view returns (uint256) {
        uint256 len;

        for (uint256 i = 0; i < owners.length; ++i) {
            len += keyCollection[owners[i]][chainId].sets[keyType].items.length;
        }

        return len;
    }

    /**
     * @notice Get keys as a super-agent
     * @param owner   Address of super-agent
     * @param keyType Key type
     */
    function superGetItems(
        address owner,
        KeyType keyType
    ) external view returns (bytes[] memory) {
        return keyCollection[owner][0].sets[keyType].items;
    }

    /**
     * @notice Valid keys are only that have owner
     * @param key Key in bytes
     */
    function isKeyValid(bytes calldata key) external view returns (bool) {
        return keyOwner[key] != address(0);
    }

    /** 
     * @notice Find owner agent of the key
     * @return address Owner address
     */
    function ownerByKey(bytes calldata key) external view returns (address) {
        return keyOwner[key];
    }

    /**
     * @notice Check if agent set some keys
     * @param owner Agent address
     * @param chainID Chain ID of the agent
     * @param types An array with agent's key types
     */
    function hasKeys(
        address owner,
        uint256 chainID,
        KeyType[] calldata types 
    ) external view returns (bool) {
        for (uint8 i = 0; i < types.length; i++) {
            KeyType _type = types[i];
            bytes[] memory items = keyCollection[owner][chainID].sets[_type].items;
            for (uint256 j; j < items.length; j++) {
                bytes memory item = items[j];
                if (item.length != 0) {
                    return true;
                }
            }
        }

        return false;
    }

    /**
     * @notice Check if super-agent set some keys
     * @param owner Super-agent address
     * @param types An array with super agent's key types
     */
    function superHasKeys(
        address owner,
        KeyType[] calldata types 
    ) external view returns (bool) {
        for (uint8 i = 0; i < types.length; i++) {
            KeyType _type = types[i];
            bytes[] memory items = keyCollection[owner][0].sets[_type].items;
            for (uint256 j; j < items.length; j++) {
                bytes memory item = items[j];
                if (item.length != 0) {
                    return true;
                }
            }
        }

        return false;
    }

    // ==============================
    //          ADMIN
    // ==============================

    /**
     * @notice Change maximum allowed keys for an agent
     * @param newMax New maximum allowed keys
     */
    function changeMaxKeys(uint256 newMax) external onlyRole(ADMIN) {
        uint256 oldMax = maxKeys;
        if (newMax <= 1) {
            revert();
        }
        maxKeys = newMax;

        emit MaxKeysChanged(oldMax, newMax);
    }

    // ==============================
    //          UPGRADES
    // ==============================
    function _authorizeUpgrade(address) internal override onlyRole(ADMIN) {}
}
