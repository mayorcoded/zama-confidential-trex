// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {FHE, ebool, euint64, externalEuint64} from "@fhevm/solidity/lib/FHE.sol";
import {ZamaEthereumConfig} from "@fhevm/solidity/config/ZamaConfig.sol";
import {ERC7984} from "@openzeppelin/confidential-contracts/token/ERC7984/ERC7984.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IIdentityRegistry} from "../interfaces/IIdentityRegistry.sol";
import {IConfidentialCompliance} from "../interfaces/IConfidentialCompliance.sol";
import {IOversightController} from "../interfaces/IOversightController.sol";

/// @notice A confidential, permissioned security-token analogue of ERC-3643.
/// @dev The contract deliberately implements ERC-7984 rather than IERC3643:
/// IERC3643 inherits ERC-20 and therefore requires plaintext balances/amounts.
contract ConfidentialTREXToken is ZamaEthereumConfig, ERC7984, AccessControl, ReentrancyGuard {
    bytes32 public constant AGENT_ROLE = keccak256("AGENT_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant POLICY_ADMIN_ROLE = keccak256("POLICY_ADMIN_ROLE");

    enum Operation {
        Transfer,
        Mint,
        Burn,
        ForcedTransfer,
        Recovery
    }

    IIdentityRegistry public identityRegistry;
    IConfidentialCompliance public compliance;
    IOversightController public oversight;

    bool private _paused;
    mapping(address => bool) private _addressFrozen;
    mapping(address => euint64) private _partialFrozen;
    Operation private _activeOperation;

    event IdentityRegistrySet(address indexed registry);
    event ComplianceSet(address indexed compliance);
    event OversightSet(address indexed oversight);
    event AddressFrozen(address indexed account, bool frozen, address indexed agent);
    event PartialFreezeUpdated(address indexed account, euint64 indexed encryptedFrozenAmount, address indexed agent);
    event ConfidentialMint(address indexed agent, address indexed to, euint64 indexed actualAmount);
    event ConfidentialBurn(address indexed agent, address indexed from, euint64 indexed actualAmount);
    event ConfidentialForcedTransfer(
        address indexed agent, address indexed from, address indexed to, euint64 actualAmount
    );
    event RecoveryCompleted(
        address indexed lostWallet, address indexed newWallet, address indexed investorIdentity, euint64 amount
    );
    event Paused(address indexed account);
    event Unpaused(address indexed account);

    error ZeroAddress();
    error TokenPaused();
    error WalletFrozen(address wallet);
    error InvalidIdentity(address wallet);
    error PublicComplianceFailure();
    error SameWallet();
    error IdentityMismatch();
    error UnauthorizedEncryptedAmount(euint64 amount, address caller);

    constructor(
        string memory name_,
        string memory symbol_,
        string memory contractURI_,
        address identityRegistry_,
        address compliance_,
        address oversight_,
        address admin_
    ) ERC7984(name_, symbol_, contractURI_) {
        if (
            identityRegistry_ == address(0) || compliance_ == address(0) || oversight_ == address(0)
                || admin_ == address(0)
        ) revert ZeroAddress();
        identityRegistry = IIdentityRegistry(identityRegistry_);
        compliance = IConfidentialCompliance(compliance_);
        oversight = IOversightController(oversight_);
        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(AGENT_ROLE, admin_);
        _grantRole(PAUSER_ROLE, admin_);
        _grantRole(POLICY_ADMIN_ROLE, admin_);
    }

    function supportsInterface(bytes4 interfaceId) public view override(ERC7984, AccessControl) returns (bool) {
        return super.supportsInterface(interfaceId);
    }

    function paused() external view returns (bool) {
        return _paused;
    }

    function isFrozen(address account) external view returns (bool) {
        return _addressFrozen[account];
    }

    function confidentialFrozenTokens(address account) external view returns (euint64) {
        return _partialFrozen[account];
    }

    function setIdentityRegistry(address registry) external onlyRole(POLICY_ADMIN_ROLE) {
        if (registry == address(0)) revert ZeroAddress();
        identityRegistry = IIdentityRegistry(registry);
        emit IdentityRegistrySet(registry);
    }

    function setCompliance(address compliance_) external onlyRole(POLICY_ADMIN_ROLE) {
        if (compliance_ == address(0)) revert ZeroAddress();
        compliance = IConfidentialCompliance(compliance_);
        emit ComplianceSet(compliance_);
    }

    function setOversight(address oversight_) external onlyRole(POLICY_ADMIN_ROLE) {
        if (oversight_ == address(0)) revert ZeroAddress();
        oversight = IOversightController(oversight_);
        emit OversightSet(oversight_);
    }

    function pause() external onlyRole(PAUSER_ROLE) {
        _paused = true;
        emit Paused(msg.sender);
    }

    function unpause() external onlyRole(PAUSER_ROLE) {
        _paused = false;
        emit Unpaused(msg.sender);
    }

    function setAddressFrozen(address account, bool frozen) external onlyRole(AGENT_ROLE) {
        _addressFrozen[account] = frozen;
        emit AddressFrozen(account, frozen, msg.sender);
    }

    function mint(address to, externalEuint64 encryptedAmount, bytes calldata inputProof)
        external
        onlyRole(AGENT_ROLE)
        nonReentrant
        returns (euint64 actualAmount)
    {
        if (!identityRegistry.isVerified(to)) revert InvalidIdentity(to);
        _activeOperation = Operation.Mint;
        actualAmount = _mint(to, FHE.fromExternal(encryptedAmount, inputProof));
        _activeOperation = Operation.Transfer;
        emit ConfidentialMint(msg.sender, to, actualAmount);
    }

    function burn(address from, externalEuint64 encryptedAmount, bytes calldata inputProof)
        external
        onlyRole(AGENT_ROLE)
        nonReentrant
        returns (euint64 actualAmount)
    {
        _activeOperation = Operation.Burn;
        actualAmount = _burn(from, FHE.fromExternal(encryptedAmount, inputProof));
        _activeOperation = Operation.Transfer;
        _clampFrozenToBalance(from);
        emit ConfidentialBurn(msg.sender, from, actualAmount);
    }

    function forcedTransfer(address from, address to, externalEuint64 encryptedAmount, bytes calldata inputProof)
        external
        onlyRole(AGENT_ROLE)
        nonReentrant
        returns (euint64 actualAmount)
    {
        if (!identityRegistry.isVerified(to)) revert InvalidIdentity(to);
        _activeOperation = Operation.ForcedTransfer;
        actualAmount = _transfer(from, to, FHE.fromExternal(encryptedAmount, inputProof));
        _activeOperation = Operation.Transfer;
        _clampFrozenToBalance(from);
        emit ConfidentialForcedTransfer(msg.sender, from, to, actualAmount);
    }

    function recoverWallet(address lostWallet, address newWallet, address investorIdentity)
        external
        onlyRole(AGENT_ROLE)
        nonReentrant
        returns (euint64 recoveredAmount)
    {
        if (lostWallet == newWallet) revert SameWallet();
        if (!identityRegistry.isVerified(newWallet)) revert InvalidIdentity(newWallet);
        if (
            identityRegistry.identity(lostWallet) != investorIdentity
                || identityRegistry.identity(newWallet) != investorIdentity
        ) revert IdentityMismatch();

        _activeOperation = Operation.Recovery;
        recoveredAmount = _transfer(lostWallet, newWallet, confidentialBalanceOf(lostWallet));
        _activeOperation = Operation.Transfer;

        euint64 combinedFrozen = FHE.add(_partialFrozen[newWallet], _partialFrozen[lostWallet]);
        FHE.allowThis(combinedFrozen);
        FHE.allow(combinedFrozen, newWallet);
        _partialFrozen[newWallet] = combinedFrozen;
        _storeFrozen(lostWallet, FHE.asEuint64(0));
        _addressFrozen[newWallet] = _addressFrozen[lostWallet];
        delete _addressFrozen[lostWallet];
        identityRegistry.deleteIdentity(lostWallet);
        _grantBalanceOversight(newWallet);
        emit RecoveryCompleted(lostWallet, newWallet, investorIdentity, recoveredAmount);
    }

    function freezePartialTokens(address account, externalEuint64 encryptedAmount, bytes calldata inputProof)
        external
        onlyRole(AGENT_ROLE)
        nonReentrant
        returns (euint64 actualFrozen)
    {
        euint64 requested = FHE.fromExternal(encryptedAmount, inputProof);
        euint64 currentFrozen = _partialFrozen[account];
        euint64 available = FHE.sub(confidentialBalanceOf(account), currentFrozen);
        actualFrozen = FHE.min(requested, available);
        euint64 updated = FHE.add(currentFrozen, actualFrozen);
        _storeFrozen(account, updated);
        return actualFrozen;
    }

    function unfreezePartialTokens(address account, externalEuint64 encryptedAmount, bytes calldata inputProof)
        external
        onlyRole(AGENT_ROLE)
        nonReentrant
        returns (euint64 actualUnfrozen)
    {
        euint64 requested = FHE.fromExternal(encryptedAmount, inputProof);
        euint64 currentFrozen = _partialFrozen[account];
        actualUnfrozen = FHE.min(requested, currentFrozen);
        _storeFrozen(account, FHE.sub(currentFrozen, actualUnfrozen));
        return actualUnfrozen;
    }

    // Every inherited transfer surface is guarded. All ultimately dispatch through _update.
    function confidentialTransfer(address to, externalEuint64 amount, bytes calldata proof)
        public
        override
        nonReentrant
        returns (euint64)
    {
        return super.confidentialTransfer(to, amount, proof);
    }

    function confidentialTransfer(address to, euint64 amount) public override nonReentrant returns (euint64) {
        return super.confidentialTransfer(to, amount);
    }

    function confidentialTransferFrom(address from, address to, externalEuint64 amount, bytes calldata proof)
        public
        override
        nonReentrant
        returns (euint64)
    {
        return super.confidentialTransferFrom(from, to, amount, proof);
    }

    function confidentialTransferFrom(address from, address to, euint64 amount)
        public
        override
        nonReentrant
        returns (euint64)
    {
        return super.confidentialTransferFrom(from, to, amount);
    }

    function confidentialTransferAndCall(address to, externalEuint64 amount, bytes calldata proof, bytes calldata data)
        public
        override
        nonReentrant
        returns (euint64)
    {
        return super.confidentialTransferAndCall(to, amount, proof, data);
    }

    function confidentialTransferAndCall(address to, euint64 amount, bytes calldata data)
        public
        override
        nonReentrant
        returns (euint64)
    {
        return super.confidentialTransferAndCall(to, amount, data);
    }

    function confidentialTransferFromAndCall(
        address from,
        address to,
        externalEuint64 amount,
        bytes calldata proof,
        bytes calldata data
    ) public override nonReentrant returns (euint64) {
        return super.confidentialTransferFromAndCall(from, to, amount, proof, data);
    }

    function confidentialTransferFromAndCall(address from, address to, euint64 amount, bytes calldata data)
        public
        override
        nonReentrant
        returns (euint64)
    {
        return super.confidentialTransferFromAndCall(from, to, amount, data);
    }

    function _update(address from, address to, euint64 requestedAmount)
        internal
        override
        returns (euint64 actualAmount)
    {
        Operation operation = _activeOperation;
        bool ordinary = operation == Operation.Transfer;

        if (ordinary) {
            if (_paused) revert TokenPaused();
            if (!identityRegistry.isVerified(from)) revert InvalidIdentity(from);
            if (!identityRegistry.isVerified(to)) revert InvalidIdentity(to);
            if (_addressFrozen[from]) revert WalletFrozen(from);
            if (_addressFrozen[to]) revert WalletFrozen(to);

            euint64 fromBalance = confidentialBalanceOf(from);
            euint64 toBalance = confidentialBalanceOf(to);
            euint64 spendable = FHE.sub(fromBalance, _partialFrozen[from]);
            ebool allowed = FHE.le(requestedAmount, spendable);

            FHE.allowTransient(fromBalance, address(compliance));
            FHE.allowTransient(toBalance, address(compliance));
            FHE.allowTransient(requestedAmount, address(compliance));
            _grantModuleInputs(fromBalance, toBalance, requestedAmount);
            (bool publicAllowed, ebool moduleAllowed) =
                compliance.validateTransfer(from, to, fromBalance, toBalance, requestedAmount);
            if (!publicAllowed) revert PublicComplianceFailure();
            allowed = FHE.and(allowed, moduleAllowed);
            requestedAmount = FHE.select(allowed, requestedAmount, FHE.asEuint64(0));
        } else if (to != address(0) && !identityRegistry.isVerified(to)) {
            revert InvalidIdentity(to);
        }

        actualAmount = super._update(from, to, requestedAmount);

        FHE.allowTransient(actualAmount, address(compliance));
        _grantModuleAmount(actualAmount);
        if (from == address(0)) compliance.created(to, actualAmount);
        else if (to == address(0)) compliance.destroyed(from, actualAmount);
        else compliance.transferred(from, to, actualAmount);

        _grantOversight(actualAmount, from, to);
    }

    function _storeFrozen(address account, euint64 updated) internal {
        FHE.allowThis(updated);
        FHE.allow(updated, account);
        _partialFrozen[account] = updated;
        address[] memory viewers = oversight.activeBalanceViewers();
        for (uint256 i; i < viewers.length; ++i) {
            FHE.allow(updated, viewers[i]);
        }
        emit PartialFreezeUpdated(account, updated, msg.sender);
    }

    function _clampFrozenToBalance(address account) internal {
        _storeFrozen(account, FHE.min(_partialFrozen[account], confidentialBalanceOf(account)));
    }

    function _grantOversight(euint64 actualAmount, address from, address to) internal {
        address[] memory transferViewers = oversight.activeTransferViewers();
        for (uint256 i; i < transferViewers.length; ++i) {
            FHE.allow(actualAmount, transferViewers[i]);
        }
        if (from != address(0)) _grantBalanceOversight(from);
        if (to != address(0)) _grantBalanceOversight(to);
        if (from == address(0) || to == address(0)) {
            euint64 supply = confidentialTotalSupply();
            address[] memory supplyViewers = oversight.activeSupplyViewers();
            for (uint256 i; i < supplyViewers.length; ++i) {
                FHE.allow(supply, supplyViewers[i]);
            }
        }
    }

    function _grantBalanceOversight(address holder) internal {
        euint64 balance = confidentialBalanceOf(holder);
        address[] memory viewers = oversight.activeBalanceViewers();
        for (uint256 i; i < viewers.length; ++i) {
            FHE.allow(balance, viewers[i]);
        }
    }

    function _grantModuleInputs(euint64 fromBalance, euint64 toBalance, euint64 requestedAmount) internal {
        uint256 count = compliance.moduleCount();
        for (uint256 i; i < count; ++i) {
            address module = compliance.moduleAt(i);
            FHE.allowTransient(fromBalance, module);
            FHE.allowTransient(toBalance, module);
            FHE.allowTransient(requestedAmount, module);
        }
    }

    function _grantModuleAmount(euint64 amount) internal {
        uint256 count = compliance.moduleCount();
        for (uint256 i; i < count; ++i) {
            FHE.allowTransient(amount, compliance.moduleAt(i));
        }
    }
}
