# Confidential ERC-3643 (T-REX) Design


## 1. Introduction

This document specifies the design of the confidential version of the ERC3643 T-REX. The implementation of this design
focuses on the encryption of token balances and transfer amounts using ERC-7984 encrypted types, while preserving the 
compliance features of the ERC-3643 like identity eligibility checks, enforcement operations, and named-auditor 
oversight.

This design defines the requirements, protocol boundary, architecture, dependencies, delivery sequence, and a reference 
build slice to guide the technical team with it's implementation. 

## 2. Design Overview

### Asset Archetype Choice

This design chooses a tokenized money-market fund because ownership its ownership is permissioned and investors have
legitimate requirements for confidentiality such as: 
- Eligibility and jurisdiction requirements
- Position and transfer limits
- Regulatory oversight requirements on balances and transactions.

### Functional Requirements

- **FR1:** Only verified investors may receive value.
- **FR2:** Holders and operators can transfer encrypted amounts without revealing monetary data.
- **FR3:** Administrators can grant named auditors scoped, time-bounded oversight.
- **FR4:** Holders and auditors decrypt only granted categories; unrelated accounts cannot.
- **FR5:** Token transfers follow public and encrypted compliance rules.
- **FR6:** Agents can mint, burn, freeze, force-transfer, and recover without decryption.

### Non-functional Requirements

- **NFR1: Separation of duties:** Admin capabilities remain independently assignable.
- **NFR2: Reproducibility:** Build slice test command always performs a clean local end-to-end simulation.

### Protocol Scope

During my research, I figured out that ERC-3643 and ERC-7984 can functionally co-exist through inheritance. 
However, there was a limitation to this co-existence: the `IERC3643` interface inherits the ERC-20 interface defines
functions such as balance, transfers, mint, burn, etc., using plain `uint256` as parameters, meanwhile, the `IERC7984` 
interface defines these functions using the encrypted unsigned integer `euint64`. 

Therefore, implementing the `IERC3643` interface functions uing plain uin256 would reveal the values this integration is
meant to protect. The implication of this realization mean that I had to reuse, replace, extend and defer some concept
from the standard `IERC3643` interface to support the confidentiality of `IERC7984`.

The table below highlights the components that were reused, replaced, extended, not supported, or deferred:

| Category | Capability | Decision |
|---|---|---|
| Reused | Identity and roles | Public address-based authorization is compatible with FHE. |
| Reused | Pause, freeze, forced transfer, recovery | Reimplemented around encrypted balances and inputs. |
| Replaced | ERC-20 amount-bearing APIs | Use ERC-7984 confidential APIs and encrypted input proofs. |
| Replaced | Plaintext `canTransfer` | Return a public `bool` and confidential `ebool`. |
| Extended | Auditor oversight | Grant selected balance, movement, and supply ciphertexts. |
| Not supported | Literal `IERC3643` conformance | Structurally incompatible with confidential amounts. |
| Deferred | Full ONCHAINID and batch operations | Outside the reference slice. |


### Out of Scope

- Direct ERC-20 or `IERC3643` conformance.
- Full ONCHAINID claim and trusted-issuer management.
- Batch operations.
- Upgradeability and encrypted-state migration.
- Production multisig, timelock, HSM, and key rotation.
- Production relayer, coprocessor, and KMS deployment.
- Formal verification and independent security audit.

### Push Back on Brief
The first push back on the brief is that implementing a compliant `ERC3643` token means that the implementation must
have a one-to-one conformity with the standard `ERC3643`. Unfortunately, this conformity cannot be mapped one-to-one due
to the reasons highlighted in the `protocol scope` above. 

Another push back is that although the balances are encrypted, contract reverts could leak encrypted values, therefore,
the integrating partner must accept some tradeoffs where reverts carry zero amounts instead of the encrypted value.

The final push back is that even though the compliant ERC3643 token permits an auditor to have oversight on balances and
other parameters, the integrating partner must continue to oversight authorization, historical access, retention, 
and key rotation.


## 3. Target Architecture
![Target-Architecture](https://github.com/user-attachments/assets/77649235-9fe9-43c0-af34-4a96dc5c04d0)

```text
                       Zama SDK
                  encrypt / decrypt
                           |
                           v
                 ConfidentialTREXToken
                /          |           \
               v           v            v
       IdentityRegistry  Compliance   OversightController
                             |
          +------------------+------------------+
          |                  |                  |
     Country/Time      Transfer Limit      Max Balance
```

The target architecture of this implementation comprises 4 contracts: `ConfidentialTREXToken`, `IdentityRegistry`
`ConfidentialModularCompliance`, and `OversightController`. Below, we briefly discuss the role of each contract and
how it interacts with other. 

#### ConfidentialTREXToken

This contract acts as the sole encrypted ledger. It extends `ERC-7984` and coordinates identity checks, pause and 
freeze state, compliance, agent operations, recovery, and ciphertext grants. 
Every inherited transfer variant ultimately passes through its overridden update pipeline.

#### IdentityRegistry

This contract associates wallets with investor identities and countries. It is a simplified integration module for
demo purposes, it is not a replacement for production 
[ONCHAINID](https://github.com/fullstack-development/blockchain-wiki-en/blob/main/protocols/onchain-id/README.md) 
protocol reference.

#### ConfidentialModularCompliance

This contract maintains a set of policy modules. It composes public decisions into a `bool`, confidential decisions 
into an `ebool`, and invokes post-operation hooks with the actual settled amount. 
It binds once to a token, which is its only authorized caller. These are the modules that it maintains and the rules
that they implement:

| Module | Decision | Rule |
|---|---|---|
| Country restriction | Public | Reject a restricted receiver country. |
| Time lock | Public | Reject a sender before its unlock time. |
| Transfer limit | Confidential | Deny a requested amount above the limit. |
| Maximum balance | Confidential | Deny a transfer that exceeds the receiver cap. |


#### OversightController

This contract stores auditor scopes and validity windows and returns active viewers of balances, movements, and supply. 
It separates oversight policy from token accounting.

### Confidential Transaction Flow

An ordinary transfer proceeds as follows:

1. Encrypt and submit (Zama SDK → ConfidentialTREXToken): The client encrypts the euint64 using amount and submits its 
ciphertext handle and input proof through the Zama SDK. The ConfidentialTREXToken verifies and imports the encrypted input.

2. Enforce permission (ConfidentialTREXToken → IdentityRegistry): The ConfidentialTREXToken contract checks pause and 
freeze status, confirms sender and receiver eligibility through the IdentityRegistry contract, and computes the sender’s 
encrypted spendable balance after partial freezes.

3. Evaluate compliance (ConfidentialModularCompliance → compliance modules): The ConfidentialTREXToken grants transient 
ciphertext access to the ConfidentialModularCompliance contract to check  public rules such as country restrictions and
encrypted rules such as transfer-limit and maximum-balance.

4. Settle the transfer (ConfidentialTREXToken / ERC-7984): FHE.select converts a confidential denial into encrypted zero. 
ERC-7984 settles the permitted amount, updates encrypted balances, and the compliance controller receives the actual 
settled amount through its hooks.

5. Grant visibility (ConfidentialTREXToken → OversightController): The ConfidentialTREXToken contract preserves holder 
access, and through the OversightController contract grants persistent access to the resulting balance and 
settled-amount handles for currently active auditors whose scopes allow it.

## 4. Build Spec and Dependencies

### Install dependencies

Install Node.js 22, Foundry, the Solidity libraries, and the Zama SDK:
```shell
forge install
npm install
forge build
```


Key dependencies are: ERC-7984, @fhevm/solidity, Forge FHEVM, @zama-fhe/sdk, and Viem.

### Implement the contracts

Build in this order:

1. IdentityRegistry — investor eligibility and country.
2. ConfidentialModularCompliance — combines public and encrypted rules.
3. Compliance modules — country, time lock, transfer limit, and maximum balance.
4. OversightController — manages scoped auditor access.
5. ConfidentialTREXToken — ERC-7984 ledger, permissioning, freezes, enforcement, recovery, and ACL grants.

See the corresponding implementations under src/.

### Deploy and configure

Deploy the registry, compliance controller, oversight controller, token, and modules. Bind their relationships, 
configure policies, and assign roles:

```shell
forge script script/DeployConfidentialTREX.s.sol:DeployConfidentialTREX
```

### Test locally

Run the contract tests:
```shell
forge test --offline

```

Run the complete local FHEVM and Zama SDK workflow:
```shell
npm run test:local:full
```

### Prepare for production

Replace the simplified identity registry, test on a production-like FHEVM network, separate administrative roles, define 
auditor key and retention policies, and complete security, privacy, operational, and regulatory reviews.

NOTE: The current repository is a locally verified reference implementation, not a production-ready deployment.


## 5. Open Partner Decisions

- Which organization is the named auditor, and which scopes are required?
- Which claims and trusted issuers replace the simplified registry?
- Can modules and parameters change after issuance, and under what governance?
- Which address, identity, event, and authorization metadata may remain public?
- What value ranges must the encrypted integer types support?

## 6. Resources

- ERC-3643: https://eips.ethereum.org/EIPS/eip-3643
- OpenZeppelin confidential contracts: https://github.com/OpenZeppelin/openzeppelin-confidential-contracts
- T-REX: https://github.com/ERC-3643/ERC-3643
- FHEVM Solidity: https://github.com/zama-ai/fhevm-solidity
- Forge FHEVM: https://github.com/zama-ai/forge-fhevm
- Zama SDK: https://github.com/zama-ai/sdk
