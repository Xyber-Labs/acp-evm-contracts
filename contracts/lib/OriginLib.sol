// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title A library for Origin management in a multi-chain environment
 * @notice This library provides structures and functions to manage
 * access for Origins across different blockchains
 */
library OriginLib {

    /**
     * @dev Origin structure representing a contract address and chain ID
     * @param contractAddress Address of the contract in original 
     * chain-native representation
     * @param chainId Chain ID of the original contract
     */
    struct Origin {
        bytes contractAddress;
        uint256 chainId;
    }

    function getOriginHashRaw(
        bytes memory contractAddress,
        uint256 chainId
    ) internal pure returns (bytes32) {
        return keccak256(
            abi.encodePacked(
                contractAddress,
                contractAddress.length,
                chainId
            )
        );
    }

    function getOriginHash(
        Origin memory origin
    ) internal pure returns (bytes32) {
        return getOriginHashRaw(origin.contractAddress, origin.chainId);
    }

    function getEVMAddress(
        bytes calldata contractAddress
    ) internal pure returns (address) {
        return abi.decode(contractAddress, (address));
    }
}
