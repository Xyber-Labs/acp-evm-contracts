// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

interface IKeyStorage {
    enum KeyType {
        SIGNER,
        EXECUTOR,
        RECEIVER,
        RESERVED
    }
    
    function addKeysFor(
        address forAgent,
        uint256 chainID,
        KeyType[] calldata keyType,
        bytes[] calldata keys
    ) external;

    function superAddKeysFor(
        address forAgent,
        KeyType[] calldata keyType,
        bytes[] calldata keys
    ) external;

    function getItems(
        address owner,
        uint256 chainID,
        KeyType keyType
    ) external view returns (bytes[] memory);

    function getItemsLen(
        address owner,
        uint256 chainId,
        KeyType keyType
    ) external view returns (uint256);

    function getItemsLenBatch(
        uint256 chainId,
        KeyType keyType,
        address[] memory owners
    ) external view returns (uint256);

    function addKey(uint256 chainID, KeyType keyType, bytes calldata key) external;
    function isKeyValid(bytes calldata key) external view returns (bool);
    function ownerByKey(bytes calldata key) external view returns (address);
}
