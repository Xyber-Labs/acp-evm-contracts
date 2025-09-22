// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../lib/LocationLib.sol";

contract LocationMock {
    using LocationLib for uint256;

    function testPack(uint128 srcChainId, uint128 srcBlockNumber) external pure returns(uint256 packedVar) {
        packedVar = LocationLib.pack(srcChainId, srcBlockNumber);
    }

    function testUnpack(uint256 packedVar) external pure returns(uint128 srcChainId, uint128 srcBlockNumber) {
        (srcChainId, srcBlockNumber) = packedVar.unpack();
    }

    function getChainId(uint256 packedVar) external pure returns(uint128 srcChainId) {
        srcChainId = packedVar.getChain();
    }

    function getBlock(uint256 packedVar) external pure returns(uint128 srcBlockNumber) {
        srcBlockNumber = packedVar.getBlock();
    }

}