// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title A library for signature management in a multi-chain environment
/// @notice This library provides structure and functions to manage signatures
/// @custom:inheritance Inherited from ACP
library SignatureLib {
    /**
     * @dev Represents a digital signature
     * v - The recovery byte
     * r - The first 32 bytes of the signature
     * s - The second 32 bytes of the signature
     */
    struct Signature {
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    function getSignerAddress(
        bytes32 msgHash,
        // only memory works. otherwise there are errors in master::approveMessageDelivery() because of storage pointers.
        Signature memory sig
    ) internal pure returns (address) {
        return ecrecover(msgHash, sig.v, sig.r, sig.s);
    }

    function verifySignature(
        address addrToCheck,
        bytes32 msgHash,
        Signature calldata sig
    ) internal pure returns (bool) {
        return getSignerAddress(msgHash, sig) == addrToCheck;
    }

    function packSignature(
        bytes[] calldata sigs
    ) internal pure returns(bytes memory) {
        bytes memory elem;

        bytes1[] memory firstSlot = new bytes1[](sigs.length + 1);
        firstSlot[0] = bytes1(uint8(sigs.length));
        bytes32[] memory rsSigs = new bytes32[](sigs.length * 2);

        for (uint i = 0; i < sigs.length; i++) {
            bytes1 vSig;
            bytes32 rSig;
            bytes32 sSig;
            assembly {
                let offset := calldataload(add(sigs.offset, mul(0x20, i)))
                let elemLen := calldataload(add(offset, sigs.offset))
                elem := mload(0x40)
                mstore(0x40, add(elem, add(elemLen, 0x20)))
                mstore(elem, elemLen)
                calldatacopy(add(elem, 0x20), add(add(offset, sigs.offset), 0x20), elemLen)

                rSig := mload(add(elem, 0x20))
                sSig := mload(add(elem, 0x40))
                vSig := mload(add(elem, 0x60))
            }
            firstSlot[i+1] = vSig;
            rsSigs[2*i] = rSig;
            rsSigs[2*i+1] = sSig;
        }

        uint totalLength = firstSlot.length + rsSigs.length * 32;
        bytes memory result = new bytes(totalLength);
        
        assembly {
            // Pointer to the result's data section
            let resultPtr := add(result, 0x20)  

            // Pointer to firstSlot's data section
            let firstSlotPtr := add(firstSlot, 0x20) 
            
            // Pointer to rsSigs' data section
            let rsSigsPtr := add(rsSigs, 0x20) 
            
            // Length of firstSlot
            let firstSlotLen := mload(firstSlot)     
            
            // Number of elements in rsSigs (32 bytes each)
            let rsSigsLen := mload(rsSigs)

            let rsSigsOffset := add(resultPtr, firstSlotLen)


            for { let i := 0 } lt(i, rsSigsLen) { i := add(i, 1) } {
                if lt(i, firstSlotLen) {
                    mstore(add(resultPtr, i), mload(add(firstSlotPtr, mul(0x20, i))))
                }
                mstore(add(rsSigsOffset, mul(0x20, i)), mload(add(rsSigsPtr, mul(0x20, i))))
                
            }

            mstore(add(rsSigsOffset, 0), mload(add(rsSigsPtr, 0)))
        }

        return result;
    }

    function encodePureSigs(SignatureLib.Signature[] memory sigs) internal pure returns(bytes memory) {
        uint256 length = sigs.length;

        bytes1[] memory firstSlot = new bytes1[](length + 1);
        firstSlot[0] = bytes1(uint8(sigs.length));
        bytes32[] memory rsSigs = new bytes32[](length * 2);

        for (uint256 i = 0; i < length; i++) {
            firstSlot[i + 1] = bytes1(uint8(sigs[i].v)); 
            rsSigs[i * 2] = sigs[i].r;
            rsSigs[i * 2 + 1] = sigs[i].s;
        }


        uint totalLength = firstSlot.length + rsSigs.length * 32;
        bytes memory result = new bytes(totalLength);
        
        assembly {
            // Pointer to the result's data section
            let resultPtr := add(result, 0x20)  

            // Pointer to firstSlot's data section
            let firstSlotPtr := add(firstSlot, 0x20) 
            
            // Pointer to rsSigs' data section
            let rsSigsPtr := add(rsSigs, 0x20) 
            
            // Length of firstSlot
            let firstSlotLen := mload(firstSlot)     
            
            // Number of elements in rsSigs (32 bytes each)
            let rsSigsLen := mload(rsSigs)

            let rsSigsOffset := add(resultPtr, firstSlotLen)


            for { let i := 0 } lt(i, rsSigsLen) { i := add(i, 1) } {
                if lt(i, firstSlotLen) {
                    mstore(add(resultPtr, i), mload(add(firstSlotPtr, mul(0x20, i))))
                }
                mstore(add(rsSigsOffset, mul(0x20, i)), mload(add(rsSigsPtr, mul(0x20, i))))
                
            }

            mstore(add(rsSigsOffset, 0), mload(add(rsSigsPtr, 0)))
        }

        return result;
    }

    function decodePackedSigs(bytes calldata sigs) internal pure returns(SignatureLib.Signature[] memory) {
        uint256 length;

        assembly {
            length := shr(248, calldataload(sigs.offset))
        }

        SignatureLib.Signature[] memory pureSigs = new SignatureLib.Signature[](length);

        for (uint i = 0; i < length; i++) {
            SignatureLib.Signature memory sig;
            uint8 v;
            bytes32 r;
            bytes32 s;

            assembly {
                v := shr(248, calldataload(add(i, add(sigs.offset, 1))))
                r := calldataload(add(mul(0x40, i), add(sigs.offset, add(1, length))))
                s := calldataload(add(add(0x20, mul(0x40, i)), add(sigs.offset, add(1, length))))
            }

            sig.v = v;
            sig.r = r;
            sig.s = s;

            pureSigs[i] = sig;
        }

        return pureSigs;

    }
}
