#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

FOUNDRY_FUZZ_RUNS="${FOUNDRY_FUZZ_RUNS:-64}"
FOUNDRY_INVARIANT_RUNS="${FOUNDRY_INVARIANT_RUNS:-64}"

FOUNDRY_FUZZ_RUNS="$FOUNDRY_FUZZ_RUNS" \
FOUNDRY_INVARIANT_RUNS="$FOUNDRY_INVARIANT_RUNS" \
forge coverage \
  --ir-minimum \
  --report summary \
  --report lcov \
  --exclude-tests \
  --no-match-coverage "script|test|lib|src/mocks"

python3 - <<'PY'
from pathlib import Path

lcov = Path("lcov.info")
if not lcov.exists():
    raise SystemExit("lcov.info not found after forge coverage")

total = 0
hit = 0
for line in lcov.read_text().splitlines():
    if line.startswith("DA:"):
        _, rest = line.split(":", 1)
        _, hits = rest.split(",", 1)
        total += 1
        if int(hits) > 0:
            hit += 1

if total == 0:
    raise SystemExit("no executable lines found in lcov.info")

pct = (hit * 100.0) / total
print(f"[coverage] line coverage = {pct:.2f}% ({hit}/{total})")
if hit != total:
    raise SystemExit("coverage gate failed: line coverage must be 100%")
PY
