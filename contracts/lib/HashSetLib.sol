// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @dev Data structure representing a set of unique byte arrays
 */
struct BytesHashSet {
    mapping(bytes => uint256) indexes;
    bytes[] items;
}

/**
 * @title HashSetLib
 * @dev A library for managing a set of unique byte arrays (BytesHashSet).
 */
library HashSetLib {

    /**
     * @notice Adds a new unique item to the set
     * @param set The BytesHashSet storage reference
     * @param item The byte array item to be added
     */
    function add(BytesHashSet storage set, bytes memory item) internal {
        bool isNewUniqueElement = set.items.length == 0 ||
            (set.indexes[item] == 0 && keccak256(abi.encode(set.items[0], set.items[0].length)) != keccak256(abi.encode(item, item.length)));

        if (!isNewUniqueElement) {
            return;
        }

        set.indexes[item] = set.items.length;
        set.items.push(item);
    }

    /**
     * @notice Checks if an item exists in the set
     * @param set The BytesHashSet storage reference
     * @param item The byte array item to check
     * @return true if the item exists, otherwise false
     */
    function isIn(
        BytesHashSet storage set,
        bytes memory item
    ) internal view returns (bool) {
        if (set.items.length == 0) {
            return false;
        }
        return set.indexes[item] != 0 || keccak256(abi.encode(set.items[0], set.items[0].length)) == keccak256(abi.encode(item, item.length));
    }

    /**
     * @notice Removes an item from the set
     * @param set The BytesHashSet storage reference
     * @param item The byte array item to be removed
     */
    function remove(BytesHashSet storage set, bytes memory item) internal {
        if (isIn(set, item)) {
            uint256 idx = set.indexes[item];
            bytes memory last = set.items[set.items.length - 1];

            set.items[idx] = last;
            set.indexes[last] = idx;
            set.indexes[item] = 0;
            set.items.pop();
        }
    }

    /**
     * @notice Clears all items from the set
     * @param set The BytesHashSet storage reference
     */
    function clean(BytesHashSet storage set) internal {
        for (uint256 index; index < set.items.length; index++) {
            bytes memory item = set.items[index];
            delete set.indexes[item];
        }
        delete set.items;
    }

    /**
     * @notice Retrieves the number of items in the set
     * @param set The BytesHashSet storage reference
     */
    function count(BytesHashSet storage set) internal view returns (uint256) {
        return set.items.length;
    }
}
