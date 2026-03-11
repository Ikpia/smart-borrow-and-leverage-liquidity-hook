#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT_DIR/scripts/common.sh"

load_env_file
require_env PRIVATE_KEY
RPC_URL="${RPC_URL:-http://127.0.0.1:8545}"

print_header "Local Demo - Leverage + Repay"

forge script script/demo/DemoLeverageOnly.s.sol:DemoLeverageOnlyScript \
  --rpc-url "$RPC_URL" \
  --private-key "$PRIVATE_KEY" \
  --broadcast \
  -vvv

CHAIN_ID="$(cast chain-id --rpc-url "$RPC_URL")"
RUN_JSON="$(broadcast_json_path "script/demo/DemoLeverageOnly.s.sol" "$CHAIN_ID")"
print_tx_report "$RUN_JSON"
