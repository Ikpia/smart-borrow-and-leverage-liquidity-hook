#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT_DIR/scripts/common.sh"

load_env_file

RPC_URL="$(resolve_unichain_rpc)"
MODE="${1:-all}"
require_env PRIVATE_KEY
if [[ -z "$RPC_URL" ]]; then
  echo "set one of: SEPOLIA_RPC_URL | unichain_SEPOLIA_RPC_URL | RPC_URL" >&2
  exit 1
fi

case "$MODE" in
  all)
    export DEMO_RUN_REPAY=true
    export DEMO_RUN_LIQUIDATION=true
    ;;
  leverage)
    export DEMO_RUN_REPAY=true
    export DEMO_RUN_LIQUIDATION=false
    ;;
  liquidate)
    export DEMO_RUN_REPAY=false
    export DEMO_RUN_LIQUIDATION=true
    ;;
  *)
    echo "usage: $0 [all|leverage|liquidate]" >&2
    exit 1
    ;;
esac

"$ROOT_DIR/scripts/deploy-unichain.sh" --ensure
load_env_file

print_header "Phase 2 - Execute Demo Flow (${MODE})"

CHAIN_ID="$(cast chain-id --rpc-url "$RPC_URL")"
mkdir -p "$ROOT_DIR/logs"
DEMO_LOG="$ROOT_DIR/logs/demo-testnet-${MODE}-$(date +%Y%m%d-%H%M%S).log"

forge script script/demo/DemoUsingDeployment.s.sol:DemoUsingDeploymentScript \
  --rpc-url "$RPC_URL" \
  --private-key "$PRIVATE_KEY" \
  --broadcast \
  -vvv | tee "$DEMO_LOG"

RUN_JSON="$(broadcast_json_path "script/demo/DemoUsingDeployment.s.sol" "$CHAIN_ID")"
print_tx_report "$RUN_JSON"

print_header "Judge-Facing Summary"
echo "mode=${MODE}"
echo "chain_id=${CHAIN_ID}"
echo "rpc=${RPC_URL}"
echo "broadcast_json=${RUN_JSON}"
echo "log_file=${DEMO_LOG}"
