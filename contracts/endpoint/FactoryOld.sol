// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable, AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {EndpointOld} from "./EndpointOld.sol";

contract FactoryOld is 
    Initializable,
    UUPSUpgradeable,
    AccessControlUpgradeable
{

    bytes32 public constant ADMIN    = keccak256("ADMIN");

    // ==============================
    //          FUNCTIONS
    // ==============================

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @param initAddr[0] - ADMIN
     */
    function initialize(address[] calldata initAddr) public initializer {
        __UUPSUpgradeable_init();
        __AccessControl_init();
        _setRoleAdmin(ADMIN, ADMIN);
        _grantRole(ADMIN, initAddr[0]);
    }

    function deploy(
        uint256 defConsRate, 
        bytes32 salt, 
        address[] memory initAddr, 
        bytes memory bytecode
    ) external onlyRole(ADMIN) returns (address, address)  {
        address endpoint;

        assembly {
            endpoint := create2(0, add(bytecode, 0x20), mload(bytecode), salt)
            if iszero(endpoint) {
                revert (0, 0)
            }
        }

        EndpointOld proxy = EndpointOld(
            address(
                new ERC1967Proxy(endpoint, new bytes(0))
            )
        );
        proxy.initialize(initAddr, defConsRate);

        return (endpoint, address(proxy));
    } 

    function computeAddress(bytes32 salt, bytes memory bytecode) external view returns(address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(
            bytes1(0xff),
            address(this),
            salt,
            keccak256(bytecode)
        )))));
    }


    // ==============================
    //          UPGRADES
    // ==============================
    function _authorizeUpgrade(address) internal override onlyRole(ADMIN) {}
}