// SPDX-License-Identifier: UNLICENSED

pragma solidity 0.8.16;

interface ILender {
    function approve(
        address,
        address,
        address,
        address
    ) external;

    function transferFYTs(address, uint256) external;
}
