// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {SelectorLib} from "../lib/SelectorLib.sol";

contract TestSelectorLib {
    function testCode(uint256 exCode) public pure returns (bytes32) {
        return SelectorLib.encodeExecutionCode(exCode);
    }

    function testSelector(bytes4 _selector) public pure returns (bytes32) {
        return SelectorLib.encodeDefaultSelector(_selector);
    }

    function getType(
        bytes32 slot
    ) public pure returns (SelectorLib.SelectorType) {
        return SelectorLib.getType(slot);
    }

    function getUnmasked(bytes32 slot) public pure returns (bytes32) {
        return SelectorLib.unmasked(slot);
    }

    function pipelineSelector(bytes4 selector) public pure returns (bytes4) {
        bytes32 encoded = SelectorLib.encodeDefaultSelector(selector);
        (bytes4 selectorRet, ) = SelectorLib.extract(encoded);
        return selectorRet;
    }

    function pipelineExCode(uint256 exCode) public pure returns (uint256) {
        bytes32 encoded = SelectorLib.encodeExecutionCode(exCode);
        (, uint256 exCodeRet) = SelectorLib.extract(encoded);
        return exCodeRet;
    }
}
