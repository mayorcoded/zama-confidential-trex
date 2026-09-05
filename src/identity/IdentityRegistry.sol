// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IIdentityRegistry} from "../interfaces/IIdentityRegistry.sol";

contract IdentityRegistry is AccessControl, IIdentityRegistry {
    bytes32 public constant REGISTRAR_ROLE = keccak256("REGISTRAR_ROLE");

    struct InvestorRecord {
        address investorIdentity;
        uint16 country;
        bool verified;
    }

    mapping(address => InvestorRecord) private _records;

    event IdentityRegistered(address indexed wallet, address indexed investorIdentity, uint16 country);
    event IdentityRemoved(address indexed wallet, address indexed investorIdentity);

    constructor(address admin) {
        if (admin == address(0)) revert("zero admin");
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(REGISTRAR_ROLE, admin);
    }

    function isVerified(address wallet) external view returns (bool) {
        return _records[wallet].verified;
    }

    function identity(address wallet) external view returns (address) {
        return _records[wallet].investorIdentity;
    }

    function investorCountry(address wallet) external view returns (uint16) {
        return _records[wallet].country;
    }

    function registerIdentity(address wallet, address investorIdentity, uint16 country)
        external
        onlyRole(REGISTRAR_ROLE)
    {
        if (wallet == address(0) || investorIdentity == address(0)) revert("zero address");
        _records[wallet] = InvestorRecord(investorIdentity, country, true);
        emit IdentityRegistered(wallet, investorIdentity, country);
    }

    function deleteIdentity(address wallet) external onlyRole(REGISTRAR_ROLE) {
        address oldIdentity = _records[wallet].investorIdentity;
        delete _records[wallet];
        emit IdentityRemoved(wallet, oldIdentity);
    }
}
