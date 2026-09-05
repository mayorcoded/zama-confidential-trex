# Confidential TREX

A Foundry reference implementation of an ERC-3643-style permissioned token using the ERC-7984 confidential ledger. Balances, transfer amounts, frozen amounts, and total supply are encrypted, while identity permissioning, modular compliance, enforcement operations, recovery, and scoped auditor access are retained.

See [DESIGN.md](./DESIGN.md) for the specification and [APPROACH.md](./APPROACH.md) for the implementation rationale and trade-offs.

## Prerequisites

- Git
- [Foundry](https://book.getfoundry.sh/getting-started/installation) with `forge`, `cast`, and `anvil`
- Node.js 22 or newer
- npm
- Bash-compatible shell

Check the installed tools:

```bash
forge --version
anvil --version
node --version
npm --version
```

## Setup

From a fresh clone:

```bash
git clone <repository-url>
cd <repository-directory>
git submodule update --init --recursive
npm ci
forge build
```

If the repository is already cloned:

```bash
git submodule update --init --recursive
npm ci
forge build
```

## Run the tests

Run the Solidity test suite:

```bash
forge test --offline
```

Run the complete end-to-end workflow:

```bash
npm run test:local:full
```

The end-to-end command automatically:

1. Starts a fresh Anvil chain.
2. Deploys the local FHEVM host contracts.
3. Deploys and configures Confidential TREX.
4. Runs the Zama SDK encryption, transfer, compliance, recovery, and decryption scenario.
5. Stops Anvil on completion or failure.

Port `8545` must be available. To use another port:

```bash
ANVIL_PORT=8546 npm run test:local:full
```

Expected final output:

```text
LOCAL FHEVM SDK INTEGRATION: PASS
```

## Run the local workflow manually

Use three terminals if you want to inspect each stage separately.

### Terminal 1: start Anvil

```bash
anvil --chain-id 31337 --port 8545
```

### Terminal 2: deploy FHEVM and the application

```bash
lib/forge-fhevm/deploy-local.sh --anvil-port 8545
```

```bash
ADMIN=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266 \
forge script script/DeployConfidentialTREX.s.sol:DeployConfidentialTREX \
  --rpc-url http://127.0.0.1:8545 \
  --private-key ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 \
  --broadcast
```

The private key above is Anvil's public development key. Never use it on a public network.

### Terminal 3: run the SDK scenario

```bash
LOCAL_RPC_URL=http://127.0.0.1:8545 npm run test:local
```

## Useful commands

```bash
# Compile contracts
forge build

# Check formatting without changing files
forge fmt --check

# Run one Solidity test
forge test --offline --match-test testMintAndTransferKeepAmountsEncryptedAndAuditable -vv

# Run the deployment script without broadcasting
ADMIN=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266 \
forge script script/DeployConfidentialTREX.s.sol:DeployConfidentialTREX
```

## Project layout

```text
src/token/          Confidential token ledger and lifecycle
src/identity/       Investor identity registry
src/compliance/     Compliance controller and modules
src/oversight/      Auditor scopes and validity windows
script/             Foundry deployment script
test/               Solidity test suite
integration/        Zama SDK scenario and local runner
```

## Local testing limitation

Forge FHEVM's local stack uses cleartext emulation. It validates contract logic, encrypted-handle flow, SDK compatibility, and ACL permissions, but it does not validate production FHE cryptography, relayer availability, coprocessor execution, or KMS operations.
