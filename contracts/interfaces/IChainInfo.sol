// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

interface IChainInfo {
    struct GasInfo {
        uint256 defaultGas;
        uint256 oneSignatureGas;
        uint256 turnRoundGas;
    }
    struct ChainData {
        uint256 chainId;
        string name;
        uint256 blockFinalizationTime;
        string defaultRpcNode;
        bytes endpoint;
        bytes master; // empty address if no
        bytes DFEndpoint;
        string baseCoinTicker; // for DF
        uint256 nowActiveAgents;
        uint256 executorsAllowed;
        uint256 roundConsensusRate;
        uint256 defaultExecutionTime;
    }

    function setChainInfo(
        uint256 _chainId,
        uint256 _blockFinalizationTime,
        address _endpoint,
        address _master,
        address _DFEndpoint,
        string memory _name,
        string memory _baseCoinTicker,
        string memory _defaultRpcNode
    ) external;

    function changeConsensusRate(
        uint256 _chainID,
        uint256 _roundConsensusRate
    ) external;

    function changeSuperConsensusRate(
        uint256 _chainID,
        uint256 _roundSuperConsensusRate
    ) external;

    function getChainInfo(
        uint256 _chainId
    ) external view returns (ChainData memory);

    function getGasInfo(uint256 chainId) external view returns(GasInfo memory);

    function getDefaultExecutionTime(
        uint256 chainID
    ) external view returns (uint256);

    function getConsensusRate(uint256 chainID) external view returns (uint256);

    function getSuperConsensusRate(
        uint256 chainID
    ) external view returns (uint256);

    function getEndpoint(
        uint256 chainId
    ) external view returns (bytes memory);

    function getConfigurator(
        uint256 chainId
    ) external view returns (bytes memory);

    function getDecimalsByChains(
        uint256 chainId_1,
        uint256 chainId_2
    ) external view returns (uint256, uint256);

    function getActiveAgentsNumber(
        uint256 chainId
    ) external view returns (uint256);

    function isChainActive(
        uint256 chainId
    ) external view returns (bool);
}
