// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable, AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {IDFOracle} from "./interfaces/IDFOracle.sol";
import {IChainInfo} from "./interfaces/IChainInfo.sol";

contract DFAdapter is Initializable, UUPSUpgradeable, AccessControlUpgradeable {
    // ==============================
    //          ERRORS
    // ==============================
    error ADAPTER__InvalidAddress();
    error ADAPTER__InvalidChainId();
    error ADAPTER__InvalidArraysLength();

    // ==============================
    //          STORAGE
    // ==============================
    bytes32 public constant ADMIN = keccak256("ADMIN");

    address public DFOracle;
    address public chainInfo;

    mapping(uint256 chainId => bytes32 dataKey) public dataKeys;

    // ==============================
    //          FUNCTIONS
    // ==============================

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize
    /// @param initAddr[0] - Admin address
    function initialize(address[] calldata initAddr) public initializer {
        __UUPSUpgradeable_init();
        __AccessControl_init();
        _setRoleAdmin(ADMIN, ADMIN);
        _grantRole(ADMIN, initAddr[0]);
    }

    function getRate(uint256 chainId) public view returns (uint256) {
        if (chainId == 0) {
            revert ADAPTER__InvalidChainId();
        }
        bytes32 curDataKey = dataKeys[chainId];
        (uint256 price, /* uint256 timestamp */) = IDFOracle(DFOracle).getFeedPrice(curDataKey);
        return price;
    }

    function getRates(uint256 sourceChainId, uint256 destChainId) external view returns(uint256, uint256) {
        if (sourceChainId == 0 || destChainId == 0) {
            revert ADAPTER__InvalidChainId();
        }
        
        return (getRate(sourceChainId), getRate(destChainId));
    }

    function convertAmount(uint256 chainIdFrom, uint256 chainIdTo, uint256 amount) public view returns (uint256) {
        if (chainIdFrom == 0 || chainIdTo == 0) {
            revert ADAPTER__InvalidChainId();
        }

        (uint256 decimalsFrom, uint256 decimalsTo)  = IChainInfo(chainInfo).getDecimalsByChains(chainIdFrom, chainIdTo);

        uint256 fromPrice = getRate(chainIdFrom);
        uint256 toPrice = getRate(chainIdTo);

        return (amount * fromPrice * (10 ** decimalsTo)) / (toPrice * (10 ** decimalsFrom));
    }

    function convertAmountBatch(
        uint256[] calldata chainIdsFrom, 
        uint256[] calldata chainIdsTo, 
        uint256[] calldata amounts
    ) external view returns (uint256[] memory) {
        uint256 len = amounts.length;

        if (len != chainIdsFrom.length &&
            len != chainIdsTo.length
        ) {
            revert ADAPTER__InvalidArraysLength();
        }

        uint256[] memory convAmounts = new uint256[](len);
        
        for (uint256 i; i < len; i++) {
            convAmounts[i] = convertAmount(chainIdsFrom[i], chainIdsTo[i], amounts[i]);
        }

        return convAmounts;
    }

    // ==============================
    //           ADMIN
    // ==============================

    function setDataKeyToChain(uint256 chainId, bytes32 key) external onlyRole(ADMIN) {
        if (chainId == 0) {
            revert ADAPTER__InvalidChainId();
        }
        dataKeys[chainId] = key; 
    }

    function setDFOracle(address oracle) external onlyRole(ADMIN) {
        if (oracle == address(0)) {
            revert ADAPTER__InvalidAddress();
        }
        DFOracle = oracle;
    }

    function setChainInfo(address chInfo) external onlyRole(ADMIN) {
        if (chInfo == address(0)) {
            revert ADAPTER__InvalidAddress();
        }
        chainInfo = chInfo;
    }

    function _authorizeUpgrade(address) internal override onlyRole(ADMIN) {}
}