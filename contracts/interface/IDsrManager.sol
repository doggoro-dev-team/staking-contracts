// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

interface IDsrManager {
    function join(address dst, uint256 wad) external;
    function exit(address dst, uint256 wad) external;
    function exitAll(address dst) external;
    function daiBalance(address usr) external returns (uint256 wad);
    function pot() external view returns (address);
    function pieOf(address) external view returns (uint256);
}