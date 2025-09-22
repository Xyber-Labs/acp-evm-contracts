// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable, AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {MessageReceiver} from "../MessageReceiver.sol";
import {OriginLib} from "../lib/OriginLib.sol";
import {IEndpointExtended} from "../interfaces/endpoint/IEndpointExtended.sol";

/**
 * @notice Configurator contract
 * @dev Contract for endpoint configurations done by 'change round' operation
 */
contract Configurator is
    Initializable,
    UUPSUpgradeable,
    AccessControlUpgradeable,
    MessageReceiver
{
    // ==============================
    //        ERRORS & EVENTS
    // ==============================
    error Configurator__OriginNotAllowed(
        uint256 chainID,
        bytes contractAddress
    );

    event NewRound(
        uint256 indexed id,
        uint256 newConsensusRate,
        uint256 newActiveSignersLen
    );

    event OriginAdded(bytes contractAddress, uint256 indexed chainId, bytes32 oHash);

    // ==============================
    //        ROLES & CONST
    // ==============================
    bytes32 public constant ADMIN    = keccak256("ADMIN");
    bytes32 public constant ENDPOINT = keccak256("ENDPOINT");

    uint256 public constant MIN_SIGNERS  = 3;
    uint256 public constant MASTER_CHAIN_ID = 5611;

    // ==============================
    //          STORAGE
    // ==============================
    struct RoundData {
        uint256 changedAt;
        uint256 consensusRate;
        uint256 activeSignersLen;
    }

    address public endpoint;
    uint256 public currentRound;


    mapping(uint256 round => RoundData) public roundData;
    mapping(bytes32 originHash => bool status) public allowedOrigins;

    // ==============================
    //          FUNCTIONS
    // ==============================

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @param initAddr[0] - ADMIN
     * @param initAddr[1] - endpoint address
     */
    function initialize(address[] calldata initAddr) public initializer {
        __UUPSUpgradeable_init();
        __AccessControl_init();
        _setRoleAdmin(ADMIN, ADMIN);
        _setRoleAdmin(ENDPOINT, ADMIN);
        _grantRole(ADMIN, initAddr[0]);
        _grantRole(ENDPOINT, initAddr[1]);

        endpoint = initAddr[1];

        // set current round as 1, because 0 round is not
        // cross-chain configurable
        currentRound = 1;
    }

    /**
     * @notice Default function to receive cross-chain message
     * @param data Data to be processed
     */
    function execute(bytes calldata data) external payable override onlyRole(ENDPOINT) {
        bytes memory payload;
        bytes memory senderContract;
        uint256 srcChainId;
        bytes32 srcTxHash;

        (srcChainId, srcTxHash, senderContract, payload) = _decode(data);

        bool allowed = validateSource(srcChainId, senderContract);
        if (!allowed) {
            revert Configurator__OriginNotAllowed(srcChainId, senderContract);
        }

        (
            uint256 newConsensusRate,
            uint256 newParticipantLen,
            address[] memory signers,
            address[] memory executors,
            bool[] memory signersFlags,
            bool[] memory executorsFlags
        ) = abi.decode(
            payload,
            (uint256, uint256, address[], address[], bool[], bool[])
        );

        uint256 minConsensusRate = IEndpointExtended(endpoint).MIN_RATE();
        if (minConsensusRate > newConsensusRate) {
            newConsensusRate = minConsensusRate;
        }

        _changeRound(
            newConsensusRate,
            newParticipantLen,
            signers,
            executors,
            signersFlags,
            executorsFlags
        );
    }


    function _changeRound(
        uint256 newConsensusRate,
        uint256 newSignersLen,
        address[] memory signers,
        address[] memory executors,
        bool[] memory signersFlags,
        bool[] memory executorsFlags
    ) private {
        uint256 nowRound = currentRound;
        uint256 newRound = nowRound + 1;

        roundData[newRound] = RoundData({
            changedAt: block.timestamp,
            consensusRate: newConsensusRate,
            activeSignersLen: newSignersLen
        });

        currentRound = newRound;

        IEndpointExtended(endpoint).activateOrDisableSignerBatch(signers, signersFlags);
        IEndpointExtended(endpoint).activateOrDisableExecutorBatch(executors, executorsFlags);
        IEndpointExtended(endpoint).setTotalActiveSigners(newSignersLen);

        emit NewRound(newRound, newConsensusRate, newSignersLen);
    }

    /**
     * @notice Check if origin  is allowed
     * @param srcChainId Source chain ID
     * @param sender Sender contract on source chain
     */
    function validateSource(
        uint256 srcChainId,
        bytes memory sender
    ) public view returns (bool) {
        bytes32 oHash = OriginLib.getOriginHashRaw(sender, srcChainId);
        return allowedOrigins[oHash];
    }

    function getRoundData(
        uint256 round
    ) external view returns (uint256, uint256, uint256) {
        return (
            roundData[round].changedAt,
            roundData[round].consensusRate,
            roundData[round].activeSignersLen
        );
    }

    function getRoundSignersLen(uint256 round) public view returns (uint256) {
        return roundData[round].activeSignersLen;
    }

    // ==============================
    //          ADMIN
    // ==============================

    /**
     * @notice Set batch of allowed origins
     * @param origins Origins to add
     */
    function populateAllowedOrigins(
        OriginLib.Origin[] calldata origins
    ) external onlyRole(ADMIN) {
        uint256 len = origins.length;
        for (uint256 i; i < len; i++) {
            bytes32 oHash = OriginLib.getOriginHashRaw(
                origins[i].contractAddress,
                origins[i].chainId
            );
            allowedOrigins[oHash] = true;

            emit OriginAdded(
                origins[i].contractAddress,
                origins[i].chainId,
                oHash
            );
        }
    }

    // ==============================
    //          UPGRADES
    // ==============================
    function _authorizeUpgrade(address) internal override onlyRole(ADMIN) {}
}
