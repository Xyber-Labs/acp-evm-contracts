// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

library AddressStringConverter {
    error InvalidAddressString();
    error NotAnEvmAddress(bytes32);
    
    function stringToAddress(string memory addrStr) internal pure returns (address) {
        bytes memory strBytes = bytes(addrStr);
        uint256 length = strBytes.length;
        
        if (length != 42 || strBytes[0] != '0' || strBytes[1] != 'x') {
            revert InvalidAddressString();
        }

        bytes memory addrBytes = new bytes(20);
        uint256 index;
        
        for (uint256 i = 2; i < length; i += 2) {
            addrBytes[index] = bytes1(
                charToUint(strBytes[i]) << 4 | 
                charToUint(strBytes[i + 1])
            );

            ++index;
        }

        return address(bytes20(addrBytes));
    }

    function addressToString(address addr) internal pure returns (string memory) {
        bytes20 addrBytes = bytes20(addr);
        bytes memory strBytes = new bytes(42);
        strBytes[0] = '0';
        strBytes[1] = 'x';
        
        bytes memory hexChars = "0123456789abcdef";
        
        for (uint256 i = 0; i < 20; i++) {
            strBytes[2 + i * 2] = hexChars[uint8(addrBytes[i] >> 4)];
            strBytes[3 + i * 2] = hexChars[uint8(addrBytes[i] & 0x0f)];
        }

        return string(strBytes);
    }

    function stringToBytes(string memory addrStr) internal pure returns (bytes memory) {
        address convertedAddress = stringToAddress(addrStr);

        return abi.encode(convertedAddress);
    }

    function bytesToString(bytes memory addrBytes) internal pure returns (string memory) {
        address encodedAddress = abi.decode(addrBytes, (address));

        return addressToString(encodedAddress);
    }
    
    function charToUint(bytes1 c) private pure returns (uint8) {
        if (c >= '0' && c <= '9') return uint8(c) - 48;

        if (c >= 'A' && c <= 'F') return uint8(c) - 55;

        if (c >= 'a' && c <= 'f') return uint8(c) - 87;

        revert InvalidAddressString();
    }

    function toWormholeFormat(address addr) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(addr)));
    }

    function fromWormholeFormat(bytes32 whFormatAddress) internal pure returns (address) {
        if (uint256(whFormatAddress) >> 160 != 0)
            revert NotAnEvmAddress(whFormatAddress);
        return address(uint160(uint256(whFormatAddress)));
    }

    function fromBytesToWormholeFormat(bytes memory addrBytes) internal pure returns (bytes32) {
        address encodedAddress = abi.decode(addrBytes, (address));

        return toWormholeFormat(encodedAddress);
    }
}