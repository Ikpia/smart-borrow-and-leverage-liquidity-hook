#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT_DIR/scripts/common.sh"

load_env_file

RPC_URL="$(resolve_unichain_rpc)"
EXPECTED_CHAIN_ID="${SEPOLIA_CHAIN_ID:-1301}"
MODE="${1:-deploy}"

require_env PRIVATE_KEY OWNER_ADDRESS
if [[ -z "$RPC_URL" ]]; then
  echo "set one of: SEPOLIA_RPC_URL | unichain_SEPOLIA_RPC_URL | RPC_URL" >&2
  exit 1
fi

if [[ "$MODE" == "--ensure" ]]; then
  if [[ -n "${DEPLOYED_ROUTER_ADDRESS:-}" && -n "${DEPLOYED_MARKET_ADDRESS:-}" && -n "${DEPLOYED_RISK_MANAGER_ADDRESS:-}" ]]; then
    echo "[deploy] existing deployment found in .env, skipping deployment"
    exit 0
  fi
fi

print_header "Phase 1 - Deploy Protocol (Unichain Sepolia)"

CHAIN_ID="$(cast chain-id --rpc-url "$RPC_URL")"
if [[ "$CHAIN_ID" != "$EXPECTED_CHAIN_ID" ]]; then
  echo "unexpected chain id: got $CHAIN_ID expected $EXPECTED_CHAIN_ID" >&2
  exit 1
fi

mkdir -p "$ROOT_DIR/logs"
DEPLOY_LOG="$ROOT_DIR/logs/deploy-unichain-$(date +%Y%m%d-%H%M%S).log"

if [[ "$MODE" != "--sync-latest" ]]; then
  forge script script/deploy/DeployProtocolUnichain.s.sol:DeployProtocolUnichainScript \
    --rpc-url "$RPC_URL" \
    --private-key "$PRIVATE_KEY" \
    --broadcast \
    -vvv | tee "$DEPLOY_LOG"
else
  echo "[deploy] sync mode: using latest broadcast only"
fi

RUN_JSON="$(broadcast_json_path "script/deploy/DeployProtocolUnichain.s.sol" "$CHAIN_ID")"
if [[ ! -f "$RUN_JSON" ]]; then
  echo "missing broadcast artifact: $RUN_JSON" >&2
  exit 1
fi

HOOK_ADDRESS="$(first_contract_address "$RUN_JSON" "LeverageLiquidityHook")"
VAULT_ADDRESS="$(first_contract_address "$RUN_JSON" "LPVault")"
MARKET_ADDRESS="$(first_contract_address "$RUN_JSON" "BorrowingMarket")"
RISK_ADDRESS="$(first_contract_address "$RUN_JSON" "RiskManager")"
ROUTER_ADDRESS="$(first_contract_address "$RUN_JSON" "LeverageRouter")"
LIQUIDATION_ADDRESS="$(first_contract_address "$RUN_JSON" "LiquidationModule")"
FLASH_PROVIDER_ADDRESS="$(first_contract_address "$RUN_JSON" "MockFlashLoanProvider")"
FLASH_MODULE_ADDRESS="$(first_contract_address "$RUN_JSON" "FlashLeverageModule")"

TOKENS=()
while IFS= read -r token_addr; do
  TOKENS+=("$token_addr")
done < <(all_contract_addresses "$RUN_JSON" "MockToken" | tr '[:upper:]' '[:lower:]' | sort)
if [[ "${#TOKENS[@]}" -ne 2 ]]; then
  echo "expected exactly 2 MockToken deployments, got ${#TOKENS[@]}" >&2
  exit 1
fi
TOKEN0_ADDRESS="${TOKENS[0]}"
TOKEN1_ADDRESS="${TOKENS[1]}"

if [[ -z "$HOOK_ADDRESS" || -z "$VAULT_ADDRESS" || -z "$MARKET_ADDRESS" || -z "$RISK_ADDRESS" || -z "$ROUTER_ADDRESS" ]]; then
  echo "failed to resolve deployed addresses from $RUN_JSON" >&2
  exit 1
fi

upsert_env RPC_URL "$RPC_URL"
upsert_env SEPOLIA_RPC_URL "$RPC_URL"
upsert_env unichain_SEPOLIA_RPC_URL "$RPC_URL"
upsert_env DEPLOYED_CHAIN_ID "$CHAIN_ID"
upsert_env DEPLOYED_TOKEN0_ADDRESS "$TOKEN0_ADDRESS"
upsert_env DEPLOYED_TOKEN1_ADDRESS "$TOKEN1_ADDRESS"
upsert_env DEPLOYED_HOOK_ADDRESS "$HOOK_ADDRESS"
upsert_env DEPLOYED_VAULT_ADDRESS "$VAULT_ADDRESS"
upsert_env DEPLOYED_MARKET_ADDRESS "$MARKET_ADDRESS"
upsert_env DEPLOYED_RISK_MANAGER_ADDRESS "$RISK_ADDRESS"
upsert_env DEPLOYED_ROUTER_ADDRESS "$ROUTER_ADDRESS"
upsert_env DEPLOYED_LIQUIDATION_MODULE_ADDRESS "$LIQUIDATION_ADDRESS"
upsert_env DEPLOYED_FLASH_PROVIDER_ADDRESS "$FLASH_PROVIDER_ADDRESS"
upsert_env DEPLOYED_FLASH_MODULE_ADDRESS "$FLASH_MODULE_ADDRESS"
upsert_env DEPLOYED_POOL_FEE "3000"
upsert_env DEPLOYED_POOL_TICK_SPACING "60"
upsert_env LAST_DEPLOY_BROADCAST_JSON "$RUN_JSON"

print_header "Deployment Addresses"
echo "token0=${TOKEN0_ADDRESS}"
echo "token1=${TOKEN1_ADDRESS}"
echo "hook=${HOOK_ADDRESS}"
echo "vault=${VAULT_ADDRESS}"
echo "market=${MARKET_ADDRESS}"
echo "risk=${RISK_ADDRESS}"
echo "router=${ROUTER_ADDRESS}"
echo "liquidation=${LIQUIDATION_ADDRESS}"
echo "flash_provider=${FLASH_PROVIDER_ADDRESS}"
echo "flash_module=${FLASH_MODULE_ADDRESS}"
echo ""
echo "addresses persisted to .env"

print_tx_report "$RUN_JSON"
