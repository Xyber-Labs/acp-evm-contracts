// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable, AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {MessageReceiver} from "./MessageReceiver.sol";
import {MessageLib} from "./lib/MessageLib.sol";
import {LocationLib} from "./lib/LocationLib.sol";
import {IChainInfo} from "./interfaces/IChainInfo.sol";
import {IMaster} from "./interfaces/IMaster.sol";
import {IMessageData} from "./interfaces/IMessageData.sol";
import {SafeCall} from "./lib/SafeCall.sol";

/**
 * @notice MessageRepeater contract is a contract 
 * which provides functionality for message resending 
 * and adding additional funds to cover execution cost 
 */

contract MessageRepeater is MessageReceiver, Initializable, UUPSUpgradeable, AccessControlUpgradeable {
    using MessageLib for MessageLib.MessageData;

    // ==============================
    //          ERRORS
    // ==============================

    error MR__InvalidOrigin(bytes origin);
    error MR__InvalidAddress(address addr);

    // ==============================
    //          STORAGE
    // ==============================

    bytes32 public constant ADMIN = keccak256("ADMIN");

    /// @notice ChainInfo contract address
    address public chainInfo;

    /// @notice Master contract address
    address public master;

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
     * @notice Add extra funds to cover message execution cost
     * @param data   Encoded variable which contains necessary info for message detection
     */
    function replenish(bytes calldata data) external {
        (uint256 srcChainId, bytes32 srcTxHash, bytes memory sender, bytes memory payload) = _decode(data);
        
        _checkOrigin(srcChainId, sender);
        (bytes32 _hash, uint256 value) = abi.decode(payload, (bytes32, uint256));
        IMaster(master).replenish(srcChainId, _hash, value);
    }

    /**
     * @notice Resend existing message which got stuck or failed for some reason 
     *         as a new complete message 
     * @param data   Encoded variable which contains necessary info for message detection 
     */
    function resend(bytes calldata data) external {
        (uint256 srcChainId, bytes32 srcTxHash, bytes memory sender, bytes memory payload) = _decode(data);
        
        _checkOrigin(srcChainId, sender);

        bytes32 _hash = abi.decode(payload, (bytes32));
        IMaster(master).resend(srcChainId, _hash);
    }


    /**
     * @notice Decode message 
     * @param data   Encoded variable which contains necessary info for message detection 
     */

    function _decode(
        bytes calldata data
    )
        internal
        override
        pure
        returns (
            uint256 sourceChainId,
            bytes32 srcTxHash,
            bytes memory senderAddr,
            bytes memory payload
        )
    {
        (sourceChainId, srcTxHash, senderAddr, payload) = abi.decode(
            data,
            (uint256, bytes32, bytes, bytes)
        );
    }

    /**
     * @notice Check that resend / replenish was called by endpoint from source chain
     * @param chainId Source chain id from encoded data
     * @param origin Address who initiated replenish / resend 
     */

    function _checkOrigin(uint256 chainId, bytes memory origin) private view {
        bytes memory endpoint = IChainInfo(chainInfo).getEndpoint(chainId);

        if (
            keccak256(endpoint) != 
            keccak256(origin)
        ) {
            revert MR__InvalidOrigin(origin);
        }
    }

    // ==============================
    //           ADMIN
    // ==============================

    function setChainInfo(address _chainInfo) external onlyRole(ADMIN) {
        if (_chainInfo == address(0)) {
            revert MR__InvalidAddress(_chainInfo);
        }
        chainInfo = _chainInfo;
    }

    function setMaster(address _master) external onlyRole(ADMIN) {
        if (_master == address(0)) {
            revert MR__InvalidAddress(_master);
        }
        master = _master;
    }

    function _authorizeUpgrade(address) internal override onlyRole(ADMIN) {}
}