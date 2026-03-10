#!/usr/bin/env bash
set -euo pipefail

: "${PRIVATE_KEY:?set PRIVATE_KEY}"

forge script script/demo/DemoLeverageOnly.s.sol:DemoLeverageOnlyScript \
  --rpc-url "${RPC_URL:-http://127.0.0.1:8545}" \
  --private-key "$PRIVATE_KEY" \
  --broadcast \
  -vvv
