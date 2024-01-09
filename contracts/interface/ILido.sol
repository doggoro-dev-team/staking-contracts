// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import { IERC20 } from "@openzeppelin/contracts/interfaces/IERC20.sol";
import { IERC20Permit } from "@openzeppelin/contracts/token/ERC20/extensions/draft-IERC20Permit.sol";

interface ILido is IERC20, IERC20Permit {
    function submit(address user) external payable;
}