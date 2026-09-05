// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

interface IOversightController {
    function activeBalanceViewers() external view returns (address[] memory);
    function activeTransferViewers() external view returns (address[] memory);
    function activeSupplyViewers() external view returns (address[] memory);
}
