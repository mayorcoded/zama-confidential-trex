// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {FHE, ebool, euint64} from "@fhevm/solidity/lib/FHE.sol";
import {ZamaEthereumConfig} from "@fhevm/solidity/config/ZamaConfig.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {IConfidentialCompliance, IConfidentialComplianceModule} from "../interfaces/IConfidentialCompliance.sol";

contract ConfidentialModularCompliance is ZamaEthereumConfig, AccessControl, IConfidentialCompliance {
    using EnumerableSet for EnumerableSet.AddressSet;

    bytes32 public constant COMPLIANCE_ADMIN_ROLE = keccak256("COMPLIANCE_ADMIN_ROLE");
    uint256 public constant MAX_MODULES = 16;
    EnumerableSet.AddressSet private _modules;
    address public token;

    event TokenBound(address indexed token);
    event ModuleAdded(address indexed module);
    event ModuleRemoved(address indexed module);

    modifier onlyToken() {
        if (msg.sender != token) revert("only token");
        _;
    }

    constructor(address admin) {
        if (admin == address(0)) revert("zero admin");
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(COMPLIANCE_ADMIN_ROLE, admin);
    }

    function bindToken(address token_) external onlyRole(COMPLIANCE_ADMIN_ROLE) {
        if (token != address(0) || token_ == address(0)) revert("invalid binding");
        token = token_;
        emit TokenBound(token_);
    }

    function addModule(address module) external onlyRole(COMPLIANCE_ADMIN_ROLE) {
        if (module == address(0) || _modules.length() >= MAX_MODULES || !_modules.add(module)) {
            revert("invalid module");
        }
        emit ModuleAdded(module);
    }

    function removeModule(address module) external onlyRole(COMPLIANCE_ADMIN_ROLE) {
        if (!_modules.remove(module)) revert("unknown module");
        emit ModuleRemoved(module);
    }

    function moduleCount() external view returns (uint256) {
        return _modules.length();
    }

    function moduleAt(uint256 index) external view returns (address) {
        return _modules.at(index);
    }

    function validateTransfer(address from, address to, euint64 fromBalance, euint64 toBalance, euint64 requestedAmount)
        external
        onlyToken
        returns (bool publicAllowed, ebool confidentialAllowed)
    {
        publicAllowed = true;
        confidentialAllowed = FHE.asEbool(true);
        for (uint256 i; i < _modules.length(); ++i) {
            address module = _modules.at(i);
            IConfidentialComplianceModule complianceModule = IConfidentialComplianceModule(module);
            (bool modulePublic, ebool modulePrivate) =
                complianceModule.moduleCheck(token, from, to, fromBalance, toBalance, requestedAmount);
            publicAllowed = publicAllowed && modulePublic;
            confidentialAllowed = FHE.and(confidentialAllowed, modulePrivate);
        }
        FHE.allowTransient(confidentialAllowed, token);
    }

    function transferred(address from, address to, euint64 actualAmount) external onlyToken {
        for (uint256 i; i < _modules.length(); ++i) {
            IConfidentialComplianceModule(_modules.at(i)).moduleTransferAction(token, from, to, actualAmount);
        }
    }

    function created(address to, euint64 actualAmount) external onlyToken {
        for (uint256 i; i < _modules.length(); ++i) {
            IConfidentialComplianceModule(_modules.at(i)).moduleMintAction(token, to, actualAmount);
        }
    }

    function destroyed(address from, euint64 actualAmount) external onlyToken {
        for (uint256 i; i < _modules.length(); ++i) {
            IConfidentialComplianceModule(_modules.at(i)).moduleBurnAction(token, from, actualAmount);
        }
    }
}
