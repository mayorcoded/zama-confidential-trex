// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {FhevmTest} from "forge-fhevm/FhevmTest.sol";
import {euint64, externalEuint64} from "@fhevm/solidity/lib/FHE.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IdentityRegistry} from "../src/identity/IdentityRegistry.sol";
import {OversightController} from "../src/oversight/OversightController.sol";
import {ConfidentialModularCompliance} from "../src/compliance/ConfidentialModularCompliance.sol";
import {MaxBalanceModule} from "../src/compliance/modules/MaxBalanceModule.sol";
import {TransferLimitModule} from "../src/compliance/modules/TransferLimitModule.sol";
import {CountryRestrictionModule} from "../src/compliance/modules/CountryRestrictionModule.sol";
import {TimeLockModule} from "../src/compliance/modules/TimeLockModule.sol";
import {ConfidentialTREXToken} from "../src/token/ConfidentialTREXToken.sol";

contract ConfidentialTREXTest is FhevmTest {
    IdentityRegistry internal registry;
    OversightController internal oversight;
    ConfidentialModularCompliance internal compliance;
    ConfidentialTREXToken internal token;
    MaxBalanceModule internal maxBalance;
    TransferLimitModule internal transferLimit;
    CountryRestrictionModule internal countryRestriction;
    TimeLockModule internal timeLock;

    address internal alice;
    uint256 internal alicePk;
    address internal bob;
    uint256 internal bobPk;
    address internal charlie;
    address internal auditor;
    uint256 internal auditorPk;
    address internal stranger;
    uint256 internal strangerPk;
    address internal investorIdentity;

    function setUp() public override {
        super.setUp();
        registry = new IdentityRegistry(address(this));
        oversight = new OversightController(address(this));
        compliance = new ConfidentialModularCompliance(address(this));
        token = new ConfidentialTREXToken(
            "Confidential TREX",
            "cTREX",
            "ipfs://token",
            address(registry),
            address(compliance),
            address(oversight),
            address(this)
        );
        compliance.bindToken(address(token));
        registry.grantRole(registry.REGISTRAR_ROLE(), address(token));

        maxBalance = new MaxBalanceModule(address(this));
        transferLimit = new TransferLimitModule(address(this));
        countryRestriction = new CountryRestrictionModule(address(this), address(registry));
        timeLock = new TimeLockModule(address(this));
        maxBalance.bindCompliance(address(compliance));
        transferLimit.bindCompliance(address(compliance));
        countryRestriction.bindCompliance(address(compliance));
        timeLock.bindCompliance(address(compliance));
        compliance.addModule(address(maxBalance));
        compliance.addModule(address(transferLimit));
        compliance.addModule(address(countryRestriction));
        compliance.addModule(address(timeLock));

        (alice, alicePk) = makeAddrAndKey("alice");
        (bob, bobPk) = makeAddrAndKey("bob");
        charlie = makeAddr("charlie");
        (auditor, auditorPk) = makeAddrAndKey("auditor");
        (stranger, strangerPk) = makeAddrAndKey("stranger");
        investorIdentity = makeAddr("investor-identity");

        registry.registerIdentity(alice, investorIdentity, 826);
        registry.registerIdentity(bob, makeAddr("bob-identity"), 250);
        oversight.configureAuditor(auditor, OversightController.Scope.Full, 0, 0);
    }

    function _mint(address to, uint64 amount) internal returns (euint64) {
        (externalEuint64 input, bytes memory proof) = encryptUint64(amount, address(this), address(token));
        return token.mint(to, input, proof);
    }

    function _transfer(address from, address to, uint64 amount) internal returns (euint64) {
        (externalEuint64 input, bytes memory proof) = encryptUint64(amount, from, address(token));
        vm.prank(from);
        return token.confidentialTransfer(to, input, proof);
    }

    function testMintAndTransferKeepAmountsEncryptedAndAuditable() public {
        _mint(alice, 1_000);
        euint64 moved = _transfer(alice, bob, 275);
        assertEq(decrypt(token.confidentialBalanceOf(alice)), 725);
        assertEq(decrypt(token.confidentialBalanceOf(bob)), 275);
        assertEq(
            userDecrypt(euint64.unwrap(moved), auditor, address(token), signUserDecrypt(auditorPk, address(token))), 275
        );
    }

    function testUnverifiedReceiverReverts() public {
        _mint(alice, 100);
        vm.expectRevert(abi.encodeWithSelector(ConfidentialTREXToken.InvalidIdentity.selector, charlie));
        _transfer(alice, charlie, 10);
    }

    function testFullFreezeAndPauseRejectOrdinaryTransfers() public {
        _mint(alice, 100);
        token.setAddressFrozen(alice, true);
        vm.expectRevert(abi.encodeWithSelector(ConfidentialTREXToken.WalletFrozen.selector, alice));
        _transfer(alice, bob, 10);
        token.setAddressFrozen(alice, false);
        token.pause();
        vm.expectRevert(ConfidentialTREXToken.TokenPaused.selector);
        _transfer(alice, bob, 10);
    }

    function testPartialFreezeRestrictsSpendableBalance() public {
        _mint(alice, 100);
        (externalEuint64 input, bytes memory proof) = encryptUint64(80, address(this), address(token));
        token.freezePartialTokens(alice, input, proof);
        euint64 moved = _transfer(alice, bob, 30);
        assertEq(decrypt(moved), 0);
        assertEq(decrypt(token.confidentialBalanceOf(alice)), 100);
        assertEq(decrypt(token.confidentialFrozenTokens(alice)), 80);
    }

    function testEncryptedModulesCompose() public {
        maxBalance.setMaxBalance(address(token), 500);
        transferLimit.setTransferLimit(address(token), 200);
        _mint(alice, 1_000);
        _mint(bob, 450);
        assertEq(decrypt(_transfer(alice, bob, 100)), 0, "balance cap");
        assertEq(decrypt(_transfer(alice, bob, 250)), 0, "transfer cap");
        assertEq(decrypt(_transfer(alice, bob, 50)), 50, "allowed");
    }

    function testPublicCountryAndTimeRulesRevert() public {
        _mint(alice, 100);
        countryRestriction.setRestricted(address(token), 250, true);
        vm.expectRevert(ConfidentialTREXToken.PublicComplianceFailure.selector);
        _transfer(alice, bob, 10);
        countryRestriction.setRestricted(address(token), 250, false);
        timeLock.setLock(address(token), alice, uint48(block.timestamp + 1 days));
        vm.expectRevert(ConfidentialTREXToken.PublicComplianceFailure.selector);
        _transfer(alice, bob, 10);
    }

    function testForcedTransferBypassesFreezeAndCompliance() public {
        maxBalance.setMaxBalance(address(token), 10);
        _mint(alice, 100);
        token.setAddressFrozen(alice, true);
        (externalEuint64 input, bytes memory proof) = encryptUint64(40, address(this), address(token));
        euint64 moved = token.forcedTransfer(alice, bob, input, proof);
        assertEq(decrypt(moved), 40);
        assertEq(decrypt(token.confidentialBalanceOf(bob)), 40);
    }

    function testBurnUpdatesSupplyAndClampsFrozenAmount() public {
        _mint(alice, 100);
        (externalEuint64 freezeInput, bytes memory freezeProof) = encryptUint64(80, address(this), address(token));
        token.freezePartialTokens(alice, freezeInput, freezeProof);
        (externalEuint64 burnInput, bytes memory burnProof) = encryptUint64(60, address(this), address(token));
        assertEq(decrypt(token.burn(alice, burnInput, burnProof)), 60);
        assertEq(decrypt(token.confidentialBalanceOf(alice)), 40);
        assertEq(decrypt(token.confidentialFrozenTokens(alice)), 40);
        assertEq(decrypt(token.confidentialTotalSupply()), 40);
    }

    function testUnfreezeRestoresSpendableBalance() public {
        _mint(alice, 100);
        (externalEuint64 freezeInput, bytes memory freezeProof) = encryptUint64(80, address(this), address(token));
        token.freezePartialTokens(alice, freezeInput, freezeProof);
        (externalEuint64 unfreezeInput, bytes memory unfreezeProof) = encryptUint64(50, address(this), address(token));
        token.unfreezePartialTokens(alice, unfreezeInput, unfreezeProof);
        assertEq(decrypt(_transfer(alice, bob, 60)), 60);
    }

    function testOperatorTransferUsesSameCompliancePipeline() public {
        _mint(alice, 100);
        vm.prank(alice);
        token.setOperator(charlie, uint48(block.timestamp + 1 days));
        (externalEuint64 input, bytes memory proof) = encryptUint64(35, charlie, address(token));
        vm.prank(charlie);
        assertEq(decrypt(token.confidentialTransferFrom(alice, bob, input, proof)), 35);
        assertEq(decrypt(token.confidentialBalanceOf(alice)), 65);
    }

    function testStrangerCannotDecryptBalance() public {
        _mint(alice, 100);
        bytes32 handle = euint64.unwrap(token.confidentialBalanceOf(alice));
        bytes memory signature = signUserDecrypt(strangerPk, address(token));
        vm.expectRevert(abi.encodeWithSelector(FhevmTest.UserNotAuthorizedForDecrypt.selector, handle, stranger));
        this.decryptAs(handle, stranger, signature);
    }

    function decryptAs(bytes32 handle, address user, bytes calldata signature) external returns (uint256) {
        return userDecrypt(handle, user, address(token), signature);
    }

    function testRecoveryMovesEntireBalanceAndFrozenStateWithoutDecrypting() public {
        registry.registerIdentity(charlie, investorIdentity, 826);
        _mint(alice, 100);
        (externalEuint64 input, bytes memory proof) = encryptUint64(30, address(this), address(token));
        token.freezePartialTokens(alice, input, proof);
        token.setAddressFrozen(alice, true);
        euint64 recovered = token.recoverWallet(alice, charlie, investorIdentity);
        assertEq(decrypt(recovered), 100);
        assertEq(decrypt(token.confidentialBalanceOf(charlie)), 100);
        assertEq(decrypt(token.confidentialFrozenTokens(charlie)), 30);
        assertTrue(token.isFrozen(charlie));
        assertFalse(registry.isVerified(alice));
    }

    function testOnlyAgentCanMint() public {
        (externalEuint64 input, bytes memory proof) = encryptUint64(10, stranger, address(token));
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, token.AGENT_ROLE()
            )
        );
        vm.prank(stranger);
        token.mint(stranger, input, proof);
    }
}
