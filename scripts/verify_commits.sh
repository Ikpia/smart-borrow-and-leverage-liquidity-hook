#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

EXPECTED="${EXPECTED_COMMITS:-67}"
COUNT="$(git rev-list --count HEAD)"

if [[ "$COUNT" != "$EXPECTED" ]]; then
  echo "commit count mismatch: expected $EXPECTED, got $COUNT" >&2
  exit 1
fi

echo "commit count verified: $COUNT"
