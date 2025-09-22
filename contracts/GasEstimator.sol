// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable, AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {IEndpointExtended} from "./interfaces/endpoint/IEndpointExtended.sol";
import {IDFOracle} from "./interfaces/IDFOracle.sol";

/**
 * @title  Gas Estimator
 * @notice Contract for converting destination chain gas cost into source chain native equivalent
 * @dev    Should be used mostly as Endpoint addition
 */
contract GasEstimator is 
    Initializable,
    UUPSUpgradeable,
    AccessControlUpgradeable
{
    // ==============================
    //       EVENTS & ERRORS
    // ==============================

    error GasEstimator__ChainInactive();
    error GasEstimator__ZeroActiveAgents();
    error GasEstimator__ZeroRates();
    error GasEstimator__ZeroChainId();
    error GasEstimator__InvalidChainData();
    error GasEstimator__InvalidAddress();
    error GasEstimator__ZeroGasLimit();

    // ==============================
    //        ROLES & CONST
    // ==============================

    bytes32 public constant ADMIN = keccak256("ADMIN");

    // ==============================
    //         STORAGE
    // ==============================

    struct ChainData {
        uint256 totalFee;
        uint256 decimals;
        uint256 defaultGas;
        bytes32 gasDataKey;
        bytes32 nativeDataKey;
    }

    /// @notice Endpoint address in deployment network
    address public endpoint;

    /// @notice DF oracle address in deployment network
    address public DFOracle;

    /// @notice DF price deviation multiplier
    uint256 public DFMul;

    /// @notice Comissions deviation multiplier
    uint256 public coms;

    /// @notice Gas-price fluctuation safety multiplier
    uint256 public gasMul;

    /// @notice Mapping that stores networks informations
    mapping(uint256 chainId => ChainData) public chainData;

    // ==============================
    //         FUNCTIONS
    // ==============================

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @param initAddr[0] - ADMIN
     * @param initAddr[1] - endpoint address
     */
    function initialize(address[] calldata initAddr) public initializer {
        __UUPSUpgradeable_init();
        __AccessControl_init();
        _setRoleAdmin(ADMIN, ADMIN);
        _grantRole(ADMIN, initAddr[0]);
        endpoint = initAddr[1];
    }

    /**
     * @notice Estimates execution cost on destination chain
     *         in terms of source chain native coin
     * @param destChainId  Destination chain ID
     * @param gasLimit     Maximum amount of gas to be used on destination chain
     */
    function estimateExecutionWithGas(uint256 destChainId, uint256 gasLimit) external view returns (uint256) {
        uint256 defaultPrice = 1e18;

        uint256 solMinFee = 5000;
        uint256 solPriorityFee = 1;

        uint256 solDevnetChainId = 100000000000000000000;
        uint256 solMainnetChainId = 11100000000000000501;
        uint256 genomeChainId = 491149;

        if (gasLimit == 0) {
            revert GasEstimator__ZeroGasLimit();
        }

        uint256 sigs = IEndpointExtended(endpoint).totalActiveSigners();
        if (sigs == 0) {
            revert GasEstimator__ZeroActiveAgents();
        }

        uint256 totalFee = chainData[block.chainid].totalFee;
        if (totalFee == 0) {
            revert GasEstimator__ChainInactive();
        }

        uint256 consensusGas = sigs * 4000 * 15 / 10;
        uint256 gas = chainData[destChainId].defaultGas + consensusGas + gasLimit;

        uint256 destGasPrice = getGasPrice(destChainId);
        if (destGasPrice == 0) {
            revert GasEstimator__ZeroRates();
        }

        (uint256 srcNativePrice, uint256 destNativePrice) = getNativePrices(destChainId);
        if (block.chainid == genomeChainId) {
            srcNativePrice = defaultPrice;
        }
        if (destChainId == genomeChainId) {
            destNativePrice = defaultPrice;
        }
        if (srcNativePrice == 0 || destNativePrice == 0) {
            revert GasEstimator__ZeroRates();
        }

        uint256 minComs = IEndpointExtended(endpoint).minCommission();

        uint256 destGasFee;
        if (destChainId == solDevnetChainId ||
            destChainId == solMainnetChainId 
        ) {
            destGasFee = solMinFee + solPriorityFee * gas;
        } else {
            destGasFee = destGasPrice * gas;
        }

        uint256 finalNonSafe = convertGas(srcNativePrice, destNativePrice, destChainId, destGasFee);
        uint256 finalRaw = finalNonSafe + totalFee;
        
        if (finalRaw < 100) {
            return (finalRaw + minComs + DFMul + coms + gasMul);
        } else {
            uint256 curDFMul = (finalRaw * DFMul) / 100;
            uint256 curComs = (finalRaw * coms) / 100;
            uint256 curGasMul = (finalRaw * 15) / 100;
            
            return (finalRaw + minComs + curDFMul + curComs + curGasMul);
        }
    }

    /**
     * @notice Converts destination gas price into source native
     * @param srcPrice     Source native price
     * @param destPrice    Destination native price
     * @param destChainId  Destination chain ID
     * @param amount       Destination gas price
     */
    function convertGas(
        uint256 srcPrice, 
        uint256 destPrice, 
        uint256 destChainId, 
        uint256 amount
    ) public view returns (uint256) {
        uint256 decimalsFrom = chainData[block.chainid].decimals;
        uint256 decimalsTo = chainData[destChainId].decimals;

        uint256 baseRate = (amount * destPrice) / srcPrice;

        if (decimalsFrom >= decimalsTo) {
            uint256 decimalsDiff = decimalsFrom - decimalsTo;
            return baseRate * 10 ** decimalsDiff;
        } else {
            uint256 decimalsDiff = decimalsTo - decimalsFrom;
            uint256 denom = 10 ** decimalsDiff;
            return (baseRate + denom - 1) / denom;
        }

        // return (amount * srcPrice * (10 ** decimalsTo)) / (destPrice * (10 ** decimalsFrom));
    } 

    /**
     * @notice Returns source and destination native prices
     * @param destChainId   Destination chain ID
     */
    function getNativePrices(uint256 destChainId) public view returns(uint256, uint256) {
        if (destChainId == 0) {
            revert GasEstimator__ZeroChainId();
        }
        return(getNativePrice(block.chainid), getNativePrice(destChainId));
    }

    /**
     * @notice Returns gas price by given chain ID
     * @param chainId   Network chain ID
     */
    function getGasPrice(uint256 chainId) public view returns (uint256) {
        if (chainId == 0) {
            revert GasEstimator__ZeroChainId();
        }
        bytes32 gasDataKey = chainData[chainId].gasDataKey;
        (uint256 price, /* uint256 timestamp */) = IDFOracle(DFOracle).getFeedPrice(gasDataKey);
        return price;
    }

    /**
     * @notice Returns gas price by given chain ID
     * @param chainId   Network chain ID
     */
    function getNativePrice(uint256 chainId) public view returns (uint256) {
        if (chainId == 0) {
            revert GasEstimator__ZeroChainId();
        }
        bytes32 nativeDataKey = chainData[chainId].nativeDataKey;
        (uint256 price, /* uint256 timestamp */) = IDFOracle(DFOracle).getFeedPrice(nativeDataKey);
        return price;
    }

    /**
     * @notice Sets network information by given chain ID
     * @param chainId   Network chain ID
     * @param data      Network information
     */
    function setChainData(uint256 chainId, ChainData calldata data) public onlyRole(ADMIN) {
        if (
            chainId == 0 || 
            data.totalFee == 0 ||
            data.defaultGas == 0 ||
            data.decimals == 0 ||
            data.gasDataKey == bytes32(0) ||
            data.nativeDataKey == bytes32(0)
        ) {
            revert GasEstimator__InvalidChainData();
        }
        chainData[chainId] = data;
    }

    function setChainDataBatch(uint256[] calldata chainIds, ChainData[] calldata datas) external onlyRole(ADMIN) {
        if (chainIds.length != datas.length) {
            revert GasEstimator__InvalidChainData();
        }
        if (chainIds.length == 0 || datas.length == 0) {
            revert GasEstimator__InvalidChainData();
        }

        for (uint256 i = 0; i < chainIds.length; i++) {
            setChainData(chainIds[i], datas[i]);
        }
    }

    /**
     * @notice Sets DF oracle address
     * @param newOracle   DF oracle address
     */
    function setDFOracle(address newOracle) external onlyRole(ADMIN) {
        if (newOracle == address(0)) {
            revert GasEstimator__InvalidAddress();
        }
        DFOracle = newOracle;
    }

    /**
     * @notice Sets deviation parameters
     * @param newDFMul   DF price deviation multiplier
     * @param newComs     Comissions deviation multiplier
     * @param newGasMul   Gas-price fluctuation safety multiplier
     */
    function setDeviations(uint256 newDFMul, uint256 newComs, uint256 newGasMul) external onlyRole(ADMIN) {
        DFMul = newDFMul;
        coms = newComs;
        gasMul = newGasMul;
    }

    // ==============================
    //          UPGRADES
    // ==============================
    function _authorizeUpgrade(address) internal override onlyRole(ADMIN) {}

    function changeEndpoint(address newEndpoint) external onlyRole(ADMIN) {
        endpoint = newEndpoint;
    }
}