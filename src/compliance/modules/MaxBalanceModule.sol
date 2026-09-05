// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {FHE, ebool, euint64} from "@fhevm/solidity/lib/FHE.sol";
import {ZamaEthereumConfig} from "@fhevm/solidity/config/ZamaConfig.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IConfidentialComplianceModule} from "../../interfaces/IConfidentialCompliance.sol";

contract MaxBalanceModule is ZamaEthereumConfig, AccessControl, IConfidentialComplianceModule {
    bytes32 public constant MODULE_ADMIN_ROLE = keccak256("MODULE_ADMIN_ROLE");
    mapping(address => uint64) public maxBalance;
    address public compliance;

    modifier onlyCompliance() {
        require(msg.sender == compliance, "only compliance");
        _;
    }

    constructor(address admin) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(MODULE_ADMIN_ROLE, admin);
    }

    function setMaxBalance(address token, uint64 limit) external onlyRole(MODULE_ADMIN_ROLE) {
        maxBalance[token] = limit;
    }

    function bindCompliance(address compliance_) external onlyRole(MODULE_ADMIN_ROLE) {
        require(compliance == address(0) && compliance_ != address(0), "invalid binding");
        compliance = compliance_;
    }

    function moduleCheck(address token, address, address, euint64, euint64 toBalance, euint64 requestedAmount)
        external
        onlyCompliance
        returns (bool, ebool allowed)
    {
        uint64 limit = maxBalance[token];
        allowed = limit == 0 ? FHE.asEbool(true) : FHE.le(FHE.add(toBalance, requestedAmount), FHE.asEuint64(limit));
        FHE.allowTransient(allowed, msg.sender);
        return (true, allowed);
    }

    function moduleTransferAction(address, address, address, euint64) external onlyCompliance {}
    function moduleMintAction(address, address, euint64) external onlyCompliance {}
    function moduleBurnAction(address, address, euint64) external onlyCompliance {}
}
