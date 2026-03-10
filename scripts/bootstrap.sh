#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

TARGET_UNISWAP_COMMIT="${UNISWAP_V4_COMMIT:-a7cf038cd568801a79a9b4cf92cd5b52c95c8585}"

echo "[bootstrap] initializing submodules"
git submodule sync --recursive
git submodule update --init --recursive

for repo in lib/uniswap-hooks/lib/v4-core lib/uniswap-hooks/lib/v4-periphery; do
  echo "[bootstrap] checking $repo"
  git -C "$repo" fetch --all --tags --prune >/dev/null 2>&1 || true

  if ! git -C "$repo" rev-parse --verify "${TARGET_UNISWAP_COMMIT}^{commit}" >/dev/null 2>&1; then
    echo "required commit ${TARGET_UNISWAP_COMMIT} not found in $repo" >&2
    exit 1
  fi

  git -C "$repo" checkout -q "$TARGET_UNISWAP_COMMIT"
  actual="$(git -C "$repo" rev-parse HEAD)"

  if [[ "$actual" != "$TARGET_UNISWAP_COMMIT" ]]; then
    echo "commit mismatch in $repo: expected $TARGET_UNISWAP_COMMIT, got $actual" >&2
    exit 1
  fi

  echo "[bootstrap] pinned $repo @ $actual"
done

forge --version
forge build

echo "[bootstrap] done"
