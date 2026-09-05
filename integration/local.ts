import { readFile } from "node:fs/promises";
import { strict as assert } from "node:assert";
import {
  createPublicClient,
  createWalletClient,
  http,
  getAddress,
  keccak256,
  parseAbi,
  toBytes,
  type Address,
  type Hex,
  type WalletClient,
} from "viem";
import { foundry } from "viem/chains";
import { privateKeyToAccount } from "viem/accounts";
import { ZamaSDK, memoryStorage } from "@zama-fhe/sdk";
import { cleartext } from "@zama-fhe/sdk/cleartext";
import { anvil as fheAnvil } from "@zama-fhe/sdk/chains";
import { createConfig } from "@zama-fhe/sdk/viem";

const RPC_URL = process.env.LOCAL_RPC_URL ?? "http://127.0.0.1:8545";
const DEPLOYMENT = new URL(
  "../broadcast/DeployConfidentialTREX.s.sol/31337/run-latest.json",
  import.meta.url,
);

const keys = {
  admin: "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80",
  alice: "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d",
  bob: "0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a",
  auditor: "0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6",
  stranger: "0x47e179ec197488593b187f80a00eb0da91f1b9d0b13f8733639f19c30a34926a",
  recovery: "0x8b3a350cf5c34c9194ca85829a2df0ec3153be0318b5e2d3348e872092edffba",
} as const satisfies Record<string, Hex>;

const accounts = Object.fromEntries(
  Object.entries(keys).map(([name, key]) => [name, privateKeyToAccount(key)]),
) as Record<keyof typeof keys, ReturnType<typeof privateKeyToAccount>>;

const publicClient = createPublicClient({ chain: foundry, transport: http(RPC_URL) });

function wallet(name: keyof typeof keys) {
  return createWalletClient({ account: accounts[name], chain: foundry, transport: http(RPC_URL) });
}

function sdk(name: keyof typeof keys) {
  const walletClient = wallet(name);
  const chain = { ...fheAnvil, network: RPC_URL };
  return new ZamaSDK(
    createConfig({
      chains: [chain],
      publicClient,
      walletClient,
      relayers: { [chain.id]: cleartext() },
      storage: memoryStorage,
    }),
  );
}

const registryAbi = parseAbi([
  "function registerIdentity(address wallet,address investorIdentity,uint16 country)",
  "function isVerified(address wallet) view returns (bool)",
]);
const oversightAbi = parseAbi([
  "function configureAuditor(address auditor,uint8 scope,uint48 validFrom,uint48 validUntil)",
]);
const moduleAbi = parseAbi(["function setMaxBalance(address token,uint64 limit)"]);
const tokenAbi = parseAbi([
  "function mint(address to,bytes32 encryptedAmount,bytes inputProof) returns (bytes32)",
  "function freezePartialTokens(address account,bytes32 encryptedAmount,bytes inputProof) returns (bytes32)",
  "function unfreezePartialTokens(address account,bytes32 encryptedAmount,bytes inputProof) returns (bytes32)",
  "function forcedTransfer(address from,address to,bytes32 encryptedAmount,bytes inputProof) returns (bytes32)",
  "function recoverWallet(address lostWallet,address newWallet,address investorIdentity) returns (bytes32)",
  "function setAddressFrozen(address account,bool frozen)",
  "function confidentialBalanceOf(address account) view returns (bytes32)",
  "function confidentialFrozenTokens(address account) view returns (bytes32)",
]);

type Deployment = { transactions: Array<{ contractName?: string; contractAddress?: string }> };

async function deployments() {
  const data = JSON.parse(await readFile(DEPLOYMENT, "utf8")) as Deployment;
  const addressOf = (name: string) => {
    const item = data.transactions.find(
      (tx) => tx.contractName === name && tx.contractAddress,
    );
    if (!item?.contractAddress) throw new Error(`Missing ${name} in Foundry broadcast`);
    return getAddress(item.contractAddress);
  };
  return {
    token: addressOf("ConfidentialTREXToken"),
    registry: addressOf("IdentityRegistry"),
    oversight: addressOf("OversightController"),
    maxBalance: addressOf("MaxBalanceModule"),
  };
}

async function send(
  client: WalletClient,
  address: Address,
  abi: readonly unknown[],
  functionName: string,
  args: readonly unknown[],
) {
  const hash = await client.writeContract({ address, abi, functionName, args } as never);
  const receipt = await publicClient.waitForTransactionReceipt({ hash });
  assert.equal(receipt.status, "success", `${functionName} reverted`);
  return receipt;
}

async function encryptedCall(
  actor: keyof typeof keys,
  token: Address,
  functionName: "mint" | "freezePartialTokens" | "unfreezePartialTokens" | "forcedTransfer",
  prefix: readonly Address[],
  amount: bigint,
) {
  const actorSdk = sdk(actor);
  const encrypted = await actorSdk.encrypt({
    values: [{ type: "euint64", value: amount }],
    contractAddress: token,
    userAddress: accounts[actor].address,
  });
  return send(wallet(actor), token, tokenAbi, functionName, [
    ...prefix,
    encrypted.encryptedValues[0],
    encrypted.inputProof,
  ]);
}

async function encryptedBalance(actor: keyof typeof keys, token: Address, holder: Address) {
  return sdk(actor).createToken(token).balanceOf(holder);
}

async function expectRejected(label: string, operation: () => Promise<unknown>) {
  let rejected = false;
  try {
    await operation();
  } catch {
    rejected = true;
  }
  assert.equal(rejected, true, `${label} should have been rejected`);
}

async function main() {
  assert.equal(await publicClient.getChainId(), 31337, "Expected local chain 31337");
  const d = await deployments();
  const code = await publicClient.getCode({ address: fheAnvil.aclContractAddress });
  assert(code && code !== "0x", "Local FHEVM ACL is not deployed");

  console.log("1/8 local FHEVM and deployments discovered", d);

  const investorIdentity = accounts.alice.address;
  await send(wallet("admin"), d.registry, registryAbi, "registerIdentity", [accounts.alice.address, investorIdentity, 826]);
  await send(wallet("admin"), d.registry, registryAbi, "registerIdentity", [accounts.bob.address, accounts.bob.address, 250]);
  await send(wallet("admin"), d.registry, registryAbi, "registerIdentity", [accounts.recovery.address, investorIdentity, 826]);
  await send(wallet("admin"), d.oversight, oversightAbi, "configureAuditor", [accounts.auditor.address, 4, 0, 0]);
  console.log("2/8 identities and full-scope auditor configured");

  const mintReceipt = await encryptedCall("admin", d.token, "mint", [accounts.alice.address], 1_000n);
  assert.equal(await encryptedBalance("alice", d.token, accounts.alice.address), 1_000n);
  assert.equal(await encryptedBalance("auditor", d.token, accounts.alice.address), 1_000n);
  await expectRejected("stranger balance decryption", () =>
    encryptedBalance("stranger", d.token, accounts.alice.address),
  );
  console.log("3/8 mint, holder decryption, auditor decryption, and ACL denial passed", mintReceipt.transactionHash);

  const aliceToken = sdk("alice").createToken(d.token);
  const transfer = await aliceToken.confidentialTransfer(accounts.bob.address, 250n, { skipBalanceCheck: true });
  assert.equal(await encryptedBalance("alice", d.token, accounts.alice.address), 750n);
  assert.equal(await encryptedBalance("bob", d.token, accounts.bob.address), 250n);
  const transferTopic = keccak256(toBytes("ConfidentialTransfer(address,address,bytes32)"));
  const log = transfer.receipt.logs.find((entry) => entry.topics[0] === transferTopic);
  assert(log?.topics[3], "ConfidentialTransfer handle missing from receipt");
  const decrypted = await sdk("auditor").decryption.decryptValues([
    { encryptedValue: log.topics[3], contractAddress: d.token },
  ]);
  assert.equal(decrypted[log.topics[3]], 250n);
  console.log("4/8 SDK confidential transfer and auditor amount decryption passed", transfer.txHash);

  await send(wallet("admin"), d.maxBalance, moduleAbi, "setMaxBalance", [d.token, 500]);
  await aliceToken.confidentialTransfer(accounts.bob.address, 300n, { skipBalanceCheck: true });
  assert.equal(await encryptedBalance("alice", d.token, accounts.alice.address), 750n);
  assert.equal(await encryptedBalance("bob", d.token, accounts.bob.address), 250n);
  console.log("5/8 encrypted max-balance rejection settled as zero");

  await encryptedCall("admin", d.token, "freezePartialTokens", [accounts.alice.address], 700n);
  await aliceToken.confidentialTransfer(accounts.bob.address, 100n, { skipBalanceCheck: true });
  assert.equal(await encryptedBalance("alice", d.token, accounts.alice.address), 750n);
  await encryptedCall("admin", d.token, "unfreezePartialTokens", [accounts.alice.address], 200n);
  await aliceToken.confidentialTransfer(accounts.bob.address, 100n, { skipBalanceCheck: true });
  assert.equal(await encryptedBalance("alice", d.token, accounts.alice.address), 650n);
  console.log("6/8 partial freeze and unfreeze passed");

  await send(wallet("admin"), d.token, tokenAbi, "setAddressFrozen", [accounts.alice.address, true]);
  await expectRejected("ordinary transfer from frozen wallet", () =>
    aliceToken.confidentialTransfer(accounts.bob.address, 1n, { skipBalanceCheck: true }),
  );
  await encryptedCall("admin", d.token, "forcedTransfer", [accounts.alice.address, accounts.bob.address], 50n);
  assert.equal(await encryptedBalance("bob", d.token, accounts.bob.address), 400n);
  console.log("7/8 full freeze and agent forced-transfer bypass passed");

  await send(wallet("admin"), d.token, tokenAbi, "recoverWallet", [
    accounts.alice.address,
    accounts.recovery.address,
    investorIdentity,
  ]);
  assert.equal(await encryptedBalance("recovery", d.token, accounts.recovery.address), 600n);
  assert.equal(await encryptedBalance("auditor", d.token, accounts.recovery.address), 600n);
  assert.equal(
    await publicClient.readContract({ address: d.registry, abi: registryAbi, functionName: "isVerified", args: [accounts.alice.address] }),
    false,
  );
  console.log("8/8 encrypted whole-balance recovery and identity retirement passed");
  console.log("LOCAL FHEVM SDK INTEGRATION: PASS");
}

main().catch((error) => {
  console.error("LOCAL FHEVM SDK INTEGRATION: FAIL");
  console.error(error);
  process.exitCode = 1;
});
