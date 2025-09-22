// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

contract WrappedNative is ERC20, ERC20Permit {
    event Deposit(address indexed user, uint256 amount);
    event Withdrawal(address indexed user, uint256 amount);

    constructor(string memory name, string memory symbol) ERC20 (name, symbol) ERC20Permit(name) {
        _mint(msg.sender, 100 * 10 ** decimals());
    }

    function deposit() public payable {
        _mint(msg.sender, msg.value);
        
        emit Deposit(msg.sender, msg.value);
    }
    
    function withdraw(uint256 amount) external {
        _burn(msg.sender, amount);
        (bool status, ) = msg.sender.call{value: amount}("");
        if (!status) revert ();

        emit Withdrawal(msg.sender, amount);
    }

    receive() external payable {
        deposit();
    }
}