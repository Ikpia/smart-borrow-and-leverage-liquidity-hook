#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

load_env_file() {
  if [[ -f "$ROOT_DIR/.env" ]]; then
    # shellcheck disable=SC1091
    set -a
    source "$ROOT_DIR/.env"
    set +a
  fi
}

require_env() {
  for name in "$@"; do
    if [[ -z "${!name:-}" ]]; then
      echo "missing required env var: $name" >&2
      exit 1
    fi
  done
}

resolve_unichain_rpc() {
  if [[ -n "${SEPOLIA_RPC_URL:-}" ]]; then
    echo "$SEPOLIA_RPC_URL"
    return
  fi
  if [[ -n "${unichain_SEPOLIA_RPC_URL:-}" ]]; then
    echo "$unichain_SEPOLIA_RPC_URL"
    return
  fi
  if [[ -n "${RPC_URL:-}" ]]; then
    echo "$RPC_URL"
    return
  fi
  echo ""
}

upsert_env() {
  local key="$1"
  local value="$2"
  local env_file="$ROOT_DIR/.env"

  touch "$env_file"
  if grep -Eq "^${key}=" "$env_file"; then
    sed -i.bak -E "s|^${key}=.*$|${key}=${value}|g" "$env_file"
    rm -f "${env_file}.bak"
  else
    printf '%s=%s\n' "$key" "$value" >> "$env_file"
  fi
}

broadcast_json_path() {
  local script_path="$1"
  local chain_id="$2"
  local script_file
  script_file="$(basename "$script_path")"
  local candidate_by_file="$ROOT_DIR/broadcast/${script_file}/${chain_id}/run-latest.json"
  local candidate_by_path="$ROOT_DIR/broadcast/${script_path}/${chain_id}/run-latest.json"

  if [[ -f "$candidate_by_file" ]]; then
    echo "$candidate_by_file"
    return
  fi

  if [[ -f "$candidate_by_path" ]]; then
    echo "$candidate_by_path"
    return
  fi

  # Default to file-style path (current Foundry behavior) when no file exists yet.
  echo "$candidate_by_file"
}

print_header() {
  local title="$1"
  echo ""
  echo "============================================================"
  echo "$title"
  echo "============================================================"
}

format_tx_url() {
  local tx_hash="$1"
  if [[ -n "${EXPLORER_TX_BASE_URL:-}" ]]; then
    echo "${EXPLORER_TX_BASE_URL}${tx_hash}"
  else
    echo "TBD (set EXPLORER_TX_BASE_URL) :: ${tx_hash}"
  fi
}

format_address_url() {
  local addr="$1"
  if [[ -n "${EXPLORER_ADDRESS_BASE_URL:-}" ]]; then
    echo "${EXPLORER_ADDRESS_BASE_URL}${addr}"
  else
    echo "TBD (set EXPLORER_ADDRESS_BASE_URL) :: ${addr}"
  fi
}

print_tx_report() {
  local run_json="$1"

  if [[ ! -f "$run_json" ]]; then
    echo "broadcast json not found: $run_json" >&2
    return 1
  fi

  print_header "Transaction Report (${run_json})"

  jq -r '
    .transactions[]
    | select((.hash // "") != "")
    | [
        (.hash // ""),
        (.transactionType // "CALL"),
        (.contractName // "-"),
        (.contractAddress // "-"),
        (.function // "-")
      ]
    | @tsv
  ' "$run_json" \
  | awk -F '\t' '{printf "%03d\t%s\t%s\t%s\t%s\t%s\n", NR, $1, $2, $3, $4, $5}' \
  | while IFS=$'\t' read -r idx hash tx_type contract_name contract_addr fn; do
      echo "[$idx] ${tx_type} ${contract_name} ${fn}"
      echo "      tx: ${hash}"
      echo "      url: $(format_tx_url "$hash")"
      if [[ "$contract_addr" != "-" && "$contract_addr" != "" ]]; then
        echo "      contract: ${contract_addr}"
        echo "      contract_url: $(format_address_url "$contract_addr")"
      fi
    done
}

first_contract_address() {
  local run_json="$1"
  local contract_name="$2"
  jq -r --arg name "$contract_name" '
    [.transactions[]
      | select(.contractName == $name)
      | select((.transactionType // "") | test("CREATE"))
      | .contractAddress
      | select(. != null and . != "")
    ][0] // empty
  ' "$run_json"
}

all_contract_addresses() {
  local run_json="$1"
  local contract_name="$2"
  jq -r --arg name "$contract_name" '
    .transactions[]
    | select(.contractName == $name)
    | select((.transactionType // "") | test("CREATE"))
    | .contractAddress
    | select(. != null and . != "")
  ' "$run_json"
}
