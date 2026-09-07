#!/usr/bin/env bash
# Checks a Shopify collection's products.json for items that just came back
# into stock, compared to the last recorded state.
#
# Usage: ./check_stock.sh
#
# Exit codes:
#   0 - ran successfully, prints newly-in-stock items (if any) to stdout
#   1 - fetch/parse error
set -euo pipefail

COLLECTION_URL="https://plushparadise.co.uk/collections/needoh/products.json?limit=250"
STATE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/state"
STATE_FILE="$STATE_DIR/needoh_stock.json"
USER_AGENT="Mozilla/5.0 (compatible; StockChecker/1.0)"

mkdir -p "$STATE_DIR"

tmp_response="$(mktemp)"
trap 'rm -f "$tmp_response"' EXIT

http_code=$(curl -sS -L -A "$USER_AGENT" -o "$tmp_response" -w "%{http_code}" "$COLLECTION_URL")
if [[ "$http_code" != "200" ]]; then
  echo "ERROR: fetch failed with HTTP $http_code" >&2
  exit 1
fi

# Build a flat "title|variant|available" list per product/variant from the response.
current="$(jq -r '
  .products[]
  | .title as $title
  | .handle as $handle
  | .variants[]
  | [$title, $handle, .title, (.available|tostring)] | @tsv
' "$tmp_response")"

if [[ -z "$current" ]]; then
  echo "ERROR: no products parsed from response" >&2
  exit 1
fi

if [[ ! -f "$STATE_FILE" ]]; then
  # First run: just record state, nothing to compare against yet.
  echo "$current" | jq -R -s '
    split("\n") | map(select(length > 0) | split("\t")) |
    map({title: .[0], handle: .[1], variant: .[2], available: (.[3] == "true")})
  ' > "$STATE_FILE"
  echo "Initialized stock state ($(echo "$current" | wc -l) variants tracked). No comparison on first run."
  exit 0
fi

newly_in_stock=""
while IFS=$'\t' read -r title handle variant available; do
  was_available=$(jq -r --arg h "$handle" --arg v "$variant" '
    map(select(.handle == $h and .variant == $v)) | .[0].available // false
  ' "$STATE_FILE")
  if [[ "$was_available" == "false" && "$available" == "true" ]]; then
    url="https://plushparadise.co.uk/products/${handle}"
    newly_in_stock+="${title} (${variant}) - ${url}"$'\n'
  fi
done <<< "$current"

# Save new state
echo "$current" | jq -R -s '
  split("\n") | map(select(length > 0) | split("\t")) |
  map({title: .[0], handle: .[1], variant: .[2], available: (.[3] == "true")})
' > "$STATE_FILE"

if [[ -n "$newly_in_stock" ]]; then
  echo "RESTOCK DETECTED:"
  echo "$newly_in_stock"
  exit 0
else
  echo "No restocks. All tracked variants unchanged or still out of stock."
  exit 0
fi
