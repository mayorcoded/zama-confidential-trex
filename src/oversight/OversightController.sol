// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {IOversightController} from "../interfaces/IOversightController.sol";

contract OversightController is AccessControl, IOversightController {
    using EnumerableSet for EnumerableSet.AddressSet;

    bytes32 public constant OVERSIGHT_ADMIN_ROLE = keccak256("OVERSIGHT_ADMIN_ROLE");
    uint256 public constant MAX_AUDITORS = 8;

    enum Scope {
        None,
        Balances,
        Transfers,
        Supply,
        Full
    }

    struct Authorization {
        Scope scope;
        uint48 validFrom;
        uint48 validUntil;
    }

    EnumerableSet.AddressSet private _auditors;
    mapping(address => Authorization) public authorization;

    event AuditorConfigured(address indexed auditor, Scope scope, uint48 validFrom, uint48 validUntil);

    constructor(address admin) {
        if (admin == address(0)) revert("zero admin");
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(OVERSIGHT_ADMIN_ROLE, admin);
    }

    function configureAuditor(address auditor, Scope scope, uint48 validFrom, uint48 validUntil)
        external
        onlyRole(OVERSIGHT_ADMIN_ROLE)
    {
        if (auditor == address(0)) revert("zero auditor");
        if (validUntil != 0 && validUntil < validFrom) revert("invalid window");
        if (scope == Scope.None) {
            _auditors.remove(auditor);
            delete authorization[auditor];
        } else {
            if (!_auditors.contains(auditor) && _auditors.length() >= MAX_AUDITORS) revert("too many auditors");
            _auditors.add(auditor);
            authorization[auditor] = Authorization(scope, validFrom, validUntil);
        }
        emit AuditorConfigured(auditor, scope, validFrom, validUntil);
    }

    function activeBalanceViewers() external view returns (address[] memory) {
        return _activeFor(Scope.Balances);
    }

    function activeTransferViewers() external view returns (address[] memory) {
        return _activeFor(Scope.Transfers);
    }

    function activeSupplyViewers() external view returns (address[] memory) {
        return _activeFor(Scope.Supply);
    }

    function _activeFor(Scope needed) internal view returns (address[] memory result) {
        uint256 n = _auditors.length();
        address[] memory scratch = new address[](n);
        uint256 count;
        for (uint256 i; i < n; ++i) {
            address auditor = _auditors.at(i);
            Authorization memory auth = authorization[auditor];
            bool active =
                block.timestamp >= auth.validFrom && (auth.validUntil == 0 || block.timestamp <= auth.validUntil);
            if (active && (auth.scope == needed || auth.scope == Scope.Full)) scratch[count++] = auditor;
        }
        result = new address[](count);
        for (uint256 i; i < count; ++i) {
            result[i] = scratch[i];
        }
    }
}
