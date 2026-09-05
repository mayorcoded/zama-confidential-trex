// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {FHE, ebool, euint64} from "@fhevm/solidity/lib/FHE.sol";
import {ZamaEthereumConfig} from "@fhevm/solidity/config/ZamaConfig.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IIdentityRegistry} from "../../interfaces/IIdentityRegistry.sol";
import {IConfidentialComplianceModule} from "../../interfaces/IConfidentialCompliance.sol";

/// @notice Plaintext jurisdiction rule. `restricted[token][country] == true` rejects the transfer.
contract CountryRestrictionModule is ZamaEthereumConfig, AccessControl, IConfidentialComplianceModule {
    bytes32 public constant MODULE_ADMIN_ROLE = keccak256("MODULE_ADMIN_ROLE");
    IIdentityRegistry public immutable identityRegistry;
    mapping(address => mapping(uint16 => bool)) public restricted;
    address public compliance;

    modifier onlyCompliance() {
        require(msg.sender == compliance, "only compliance");
        _;
    }

    constructor(address admin, address registry) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(MODULE_ADMIN_ROLE, admin);
        identityRegistry = IIdentityRegistry(registry);
    }

    function setRestricted(address token, uint16 country, bool status) external onlyRole(MODULE_ADMIN_ROLE) {
        restricted[token][country] = status;
    }

    function bindCompliance(address compliance_) external onlyRole(MODULE_ADMIN_ROLE) {
        require(compliance == address(0) && compliance_ != address(0), "invalid binding");
        compliance = compliance_;
    }

    function moduleCheck(address token, address, address to, euint64, euint64, euint64)
        external
        onlyCompliance
        returns (bool, ebool)
    {
        return (!restricted[token][identityRegistry.investorCountry(to)], FHE.asEbool(true));
    }

    function moduleTransferAction(address, address, address, euint64) external onlyCompliance {}
    function moduleMintAction(address, address, euint64) external onlyCompliance {}
    function moduleBurnAction(address, address, euint64) external onlyCompliance {}
}
