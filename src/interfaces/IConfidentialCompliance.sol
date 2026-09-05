// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {ebool, euint64} from "@fhevm/solidity/lib/FHE.sol";

interface IConfidentialCompliance {
    function moduleCount() external view returns (uint256);
    function moduleAt(uint256 index) external view returns (address);

    function validateTransfer(address from, address to, euint64 fromBalance, euint64 toBalance, euint64 requestedAmount)
        external
        returns (bool publicAllowed, ebool confidentialAllowed);

    function transferred(address from, address to, euint64 actualAmount) external;
    function created(address to, euint64 actualAmount) external;
    function destroyed(address from, euint64 actualAmount) external;
}

interface IConfidentialComplianceModule {
    function moduleCheck(
        address token,
        address from,
        address to,
        euint64 fromBalance,
        euint64 toBalance,
        euint64 requestedAmount
    ) external returns (bool publicAllowed, ebool confidentialAllowed);

    function moduleTransferAction(address token, address from, address to, euint64 actualAmount) external;
    function moduleMintAction(address token, address to, euint64 actualAmount) external;
    function moduleBurnAction(address token, address from, euint64 actualAmount) external;
}
