// SPDX-License-Identifier: MIT
// Compatible with OpenZeppelin Contracts ^5.0.0
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {IWNative} from "../interfaces/external/IWNative.sol";

contract TokenMock is ERC20, ERC20Permit {
    constructor() ERC20("TokenMock", "WTOKEN") ERC20Permit("TokenMock") {
        _mint(msg.sender, 100 * 10 ** decimals());
    }

    function deposit() external payable {
        _mint(msg.sender, msg.value);
    }
    
    function withdraw(uint wad) external {
        _burn(msg.sender, wad);
        (bool ok, ) = msg.sender.call{value: wad}("");
        if (!ok) revert ();
    }

    function mint(uint256 amount) external {
        _mint(_msgSender(), amount);
    }
}