// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title A library for selector management in a multi-chain environment
/// @notice This library provides structures and functions to manage selectors
/// across different blockchains
library SelectorLib {
    bytes32 constant TYPE_MASK =
        0x00ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff;

    enum SelectorType {
        SELECTOR,
        EXECUTION_CODE
    }

    function encodeDefaultSelector(
        bytes4 selector
    ) internal pure returns (bytes32 res) {
        assembly {
            let ptr := mload(0x40)
            mstore(ptr, shr(224, selector))
            res := mload(ptr)
        }
    }

    function encodeExecutionCode(
        uint256 code
    ) internal pure returns (bytes32 res) {
        res = _encodeType(SelectorType.EXECUTION_CODE, bytes32(code));
    }

    // 0x000......346546 - selector slot

    function _encodeType(
        SelectorType _selectorType,
        bytes32 slot
    ) private pure returns (bytes32 res) {
        assembly {
            let ptr := mload(0x40)
            mstore(ptr, slot)
            mstore8(ptr, _selectorType)
            res := mload(ptr)
        }
    }

    function getType(bytes32 slot) internal pure returns (SelectorType) {
        uint8 firstByte = uint8(slot[0]);
        require(
            firstByte <= uint8(type(SelectorType).max),
            "Invalid selector type"
        );
        return SelectorType(firstByte);
    }

    function unmasked(bytes32 slot) internal pure returns (bytes32 res) {
        res = TYPE_MASK & slot;
    }

    function extract(
        bytes32 slot
    ) internal pure returns (bytes4 selector, uint256 exCode) {
        SelectorType selectorType = getType(slot);
        if (selectorType == SelectorType.EXECUTION_CODE) {
            exCode = uint256(unmasked(slot));
        } else {
            selector = bytes4(unmasked(slot) << 224);
        }
    }
}
