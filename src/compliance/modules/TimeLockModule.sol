// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {FHE, ebool, euint64} from "@fhevm/solidity/lib/FHE.sol";
import {ZamaEthereumConfig} from "@fhevm/solidity/config/ZamaConfig.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IConfidentialComplianceModule} from "../../interfaces/IConfidentialCompliance.sol";

contract TimeLockModule is ZamaEthereumConfig, AccessControl, IConfidentialComplianceModule {
    bytes32 public constant MODULE_ADMIN_ROLE = keccak256("MODULE_ADMIN_ROLE");
    mapping(address => mapping(address => uint48)) public lockedUntil;
    address public compliance;

    modifier onlyCompliance() {
        require(msg.sender == compliance, "only compliance");
        _;
    }

    constructor(address admin) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(MODULE_ADMIN_ROLE, admin);
    }

    function setLock(address token, address holder, uint48 until) external onlyRole(MODULE_ADMIN_ROLE) {
        lockedUntil[token][holder] = until;
    }

    function bindCompliance(address compliance_) external onlyRole(MODULE_ADMIN_ROLE) {
        require(compliance == address(0) && compliance_ != address(0), "invalid binding");
        compliance = compliance_;
    }

    function moduleCheck(address token, address from, address, euint64, euint64, euint64)
        external
        onlyCompliance
        returns (bool, ebool)
    {
        return (block.timestamp >= lockedUntil[token][from], FHE.asEbool(true));
    }

    function moduleTransferAction(address, address, address, euint64) external onlyCompliance {}
    function moduleMintAction(address, address, euint64) external onlyCompliance {}
    function moduleBurnAction(address, address, euint64) external onlyCompliance {}
}
