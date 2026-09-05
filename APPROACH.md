# Approach

## Design approach

I chose a tokenized money-market fund because it has a clear need for investor eligibility, position limits, transfer 
controls, and regulatory oversight.

The main constraint was that ERC-3643 inherits ERC-20 and therefore exposes plaintext balances and amounts. 
I chose to preserve ERC-3643's regulatory behavior by using ERC-7984 encrypted ledger with separate identity, 
compliance, and oversight components.

I also considered using a wrapper architecture, but figured out later in my research that wrap and unwrap operations 
expose amounts, and pooled custody weakens investor-level compliance. 

## Key decisions

- Keep monetary values encrypted while leaving identity and policy metadata public.
- Apply identity, pause, freeze, and compliance checks through transfer pipeline.
- Separate public compliance failures from encrypted ones: public failures revert, while confidential failures settle 
zero to avoid leaking the result.
- Give compliance modules transient ciphertext access only.
- Give auditors persistent access only to ciphertext categories allowed by their scope.
- Preserve enforcement operations such as freezing, forced transfer, and wallet recovery without decrypting balances.

## Build-slice choice

I selected auditor access as the principal build slice because ERC-7984 handles access for normal transaction 
participants but does not provide standing third-party oversight. 

Therefore, an incorrect implementation could either prevent legitimate auditing or disclose confidential financial data. 

I used the SDK test to prove that a holder and authorized auditor can decrypt permitted balances and transfer amounts 
while an unrelated account cannot.

The contracts were implemented to exercise this slice in a realistic permissioned-token context.

## What the implementation demonstrated

The reference implementation demonstrates:

- Confidential minting and transfers through the Zama SDK.
- Holder and scoped-auditor decryption.
- Rejection of unauthorized decryption.
- Public and encrypted compliance rules.
- Full and partial freezes.
- Agent forced transfers.
- Repeatable deployment and testing on a fresh local FHEVM stack.

Foundry tests verify contract behavior, while the SDK workflow verifies encryption, transaction submission, ACL grants, 
and decryption from the client side.

The local stack uses cleartext FHEVM emulation. It validates the application integration, but not production 
cryptography, relayer availability, coprocessor execution, or KMS operations.

## Trade-offs

The main trade-off is confidential failure handling. Reverting when an encrypted rule fails would reveal the result, 
so the implementation settles the transfer at zero. This protects privacy but requires applications to inspect the 
encrypted settled amount rather than relying only on transaction success.

Auditor access also has a lifecycle limitation: removing an auditor prevents access to future ciphertexts but does not 
necessarily revoke access to previously granted handles. Production use therefore requires explicit retention and 
key-rotation policies.

Finally, modular compliance and auditor enumeration improve extensibility but increase transaction cost. Both 
collections are bounded in the reference implementation.

## If I had more time

I would next:

1. Replace the simplified identity registry with ONCHAINID claim verification.
2. Add fuzz and invariant tests for supply, balances, freezes, and recovery.
3. Test against a production-like FHEVM network.
4. Benchmark the maximum module and auditor configurations.
5. Separate privileged roles across governed accounts.
6. Threat-model metadata leakage and auditor-key compromise.
7. Obtain an independent security review.

## AI assistance

- Research: I used AI to support protocol research including deeper understanding of a number of research papers
- Architecture Design: While I drafted the initial architecture of the contracts, I used AI to further challenge 
architecture choices. 
- Implementation and Docs: I used AI to implement the reference contracts, and draft documentation from the history of
the interaction that I had with the agent.
- Testing: I used AI for extensive testing of the contracts and for setting up the tooling for integration tests.
