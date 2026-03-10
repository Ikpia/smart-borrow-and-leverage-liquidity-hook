#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

forge build >/dev/null

mkdir -p shared/abis

contracts=(
  LeverageRouter
  RiskManager
  LiquidationModule
  MockMetricsHook
  LPVault
  BorrowingMarket
  FlashLeverageModule
  LeverageLiquidityHook
)

for c in "${contracts[@]}"; do
  file="out/${c}.sol/${c}.json"
  if [[ ! -f "$file" ]]; then
    echo "missing artifact: $file" >&2
    exit 1
  fi
  jq '.abi' "$file" > "shared/abis/${c}.json"
done

echo "ABIs exported to shared/abis"
