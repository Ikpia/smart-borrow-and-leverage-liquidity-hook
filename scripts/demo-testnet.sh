#!/usr/bin/env bash
set -euo pipefail

: "${PRIVATE_KEY:?set PRIVATE_KEY}"
: "${BASE_SEPOLIA_RPC_URL:?set BASE_SEPOLIA_RPC_URL}"

forge script script/demo/DemoAll.s.sol:DemoAllScript \
  --rpc-url "$BASE_SEPOLIA_RPC_URL" \
  --private-key "$PRIVATE_KEY" \
  --broadcast \
  -vvv
