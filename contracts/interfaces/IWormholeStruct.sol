// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

struct VaaKey {
	uint16 chainId;
	bytes32 emitterAddress;
	uint64 sequence;
}

struct MessageKey {
    uint8 keyType; // 0-127 are reserved for standardized KeyTypes, 128-255 are for custom use
    bytes encodedKey;
}

