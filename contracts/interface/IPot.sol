// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

interface IPot {
    function chi() external view returns (uint256);
    function rho() external view returns (uint256);
    function dsr() external view returns (uint256);
}