#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ANVIL_PORT="${ANVIL_PORT:-8545}"
LOCAL_RPC_URL="http://127.0.0.1:${ANVIL_PORT}"
ANVIL_LOG="$(mktemp -t confidential-trex-anvil.XXXXXX)"
ANVIL_PID=""

cleanup() {
  if [[ -n "${ANVIL_PID}" ]] && kill -0 "${ANVIL_PID}" 2>/dev/null; then
    kill "${ANVIL_PID}"
    wait "${ANVIL_PID}" 2>/dev/null || true
  fi
  rm -f "${ANVIL_LOG}"
}
trap cleanup EXIT INT TERM

cd "${PROJECT_ROOT}"

anvil --chain-id 31337 --port "${ANVIL_PORT}" >"${ANVIL_LOG}" 2>&1 &
ANVIL_PID="$!"

for _ in {1..50}; do
  if cast chain-id --rpc-url "${LOCAL_RPC_URL}" >/dev/null 2>&1; then
    break
  fi
  sleep 0.1
done

if ! cast chain-id --rpc-url "${LOCAL_RPC_URL}" >/dev/null 2>&1; then
  echo "Anvil did not start. Log follows:" >&2
  sed -n '1,120p' "${ANVIL_LOG}" >&2
  exit 1
fi

echo "Deploying the cleartext local FHEVM stack..."
lib/forge-fhevm/deploy-local.sh --anvil-port "${ANVIL_PORT}"

echo "Deploying Confidential TREX..."
ADMIN=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266 \
  forge script script/DeployConfidentialTREX.s.sol:DeployConfidentialTREX \
  --rpc-url "${LOCAL_RPC_URL}" \
  --private-key ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 \
  --broadcast

echo "Running the Zama SDK integration scenario..."
LOCAL_RPC_URL="${LOCAL_RPC_URL}" \
  node_modules/node/bin/node node_modules/tsx/dist/cli.mjs integration/local.ts
