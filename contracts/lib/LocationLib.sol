// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title A library to optimize source chain info
/// @notice This library provides functions to pack source chain id and block number into one variable and get them separately 
library LocationLib {

    bytes32 constant BLOCK_MASK = 0x000000000000000000000000000000000fffffffffffffffffffffffffffffff;


    /// @dev
    /// 16 bytes on the left = srcChainId
    /// 16 bytes on the right = srcBlockNumber
    function pack(
        uint128 srcChainID, 
        uint128 srcBlockNumber
    ) internal pure returns(uint256 packedVar) {
        assembly {
            packedVar := add(shl(128, srcChainID), srcBlockNumber)
        }
    }

    function unpack(uint256 packedVar) internal pure returns(uint128 srcChainID, uint128 srcBlockNumber){
        assembly {
            srcChainID := shr(128, packedVar)
            srcBlockNumber := and(BLOCK_MASK, packedVar)
        }
    }

    function getChain(uint256 packedVar) internal pure returns(uint128 srcChainId) {
        assembly {
            srcChainId := shr(128, packedVar)
        }
    }

    function getBlock(uint256 packedVar) internal pure returns(uint128 srcBlockNumber) {
        assembly {
            srcBlockNumber := and(BLOCK_MASK, packedVar)
        }
    }
}
