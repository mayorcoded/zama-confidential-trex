// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Script, console2} from "forge-std/Script.sol";
import {IdentityRegistry} from "../src/identity/IdentityRegistry.sol";
import {OversightController} from "../src/oversight/OversightController.sol";
import {ConfidentialModularCompliance} from "../src/compliance/ConfidentialModularCompliance.sol";
import {MaxBalanceModule} from "../src/compliance/modules/MaxBalanceModule.sol";
import {TransferLimitModule} from "../src/compliance/modules/TransferLimitModule.sol";
import {CountryRestrictionModule} from "../src/compliance/modules/CountryRestrictionModule.sol";
import {TimeLockModule} from "../src/compliance/modules/TimeLockModule.sol";
import {ConfidentialTREXToken} from "../src/token/ConfidentialTREXToken.sol";

contract DeployConfidentialTREX is Script {
    function run() external returns (ConfidentialTREXToken token) {
        address admin = vm.envAddress("ADMIN");
        vm.startBroadcast();
        IdentityRegistry registry = new IdentityRegistry(admin);
        OversightController oversight = new OversightController(admin);
        ConfidentialModularCompliance compliance = new ConfidentialModularCompliance(admin);
        token = new ConfidentialTREXToken(
            "Confidential TREX", "cTREX", "", address(registry), address(compliance), address(oversight), admin
        );
        compliance.bindToken(address(token));
        registry.grantRole(registry.REGISTRAR_ROLE(), address(token));

        MaxBalanceModule maxBalance = new MaxBalanceModule(admin);
        TransferLimitModule transferLimit = new TransferLimitModule(admin);
        CountryRestrictionModule countries = new CountryRestrictionModule(admin, address(registry));
        TimeLockModule timeLock = new TimeLockModule(admin);
        maxBalance.bindCompliance(address(compliance));
        transferLimit.bindCompliance(address(compliance));
        countries.bindCompliance(address(compliance));
        timeLock.bindCompliance(address(compliance));
        compliance.addModule(address(maxBalance));
        compliance.addModule(address(transferLimit));
        compliance.addModule(address(countries));
        compliance.addModule(address(timeLock));
        vm.stopBroadcast();

        console2.log("Token", address(token));
        console2.log("Identity registry", address(registry));
        console2.log("Compliance", address(compliance));
        console2.log("Oversight", address(oversight));
    }
}
