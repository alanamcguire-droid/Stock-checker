#!/usr/bin/env bash
# Checks one or more Shopify collections' products.json for items that just
# came back into stock, compared to the last recorded state per site.
#
# Usage: ./check_stock.sh
#
# Exit codes:
#   0 - ran successfully, prints newly-in-stock items (if any) to stdout
#   1 - fetch/parse error on at least one site
set -uo pipefail

# key|base_url|collection_handle
SITES=(
  "jukupop|https://jukupop.com|needoh-squishy-fidget-toys-shop-stress-balls-fidget-fun"
  "thekidcollective|https://thekidcollective.co.uk|needoh"
)

STATE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/state"
USER_AGENT="Mozilla/5.0 (compatible; StockChecker/1.0)"

mkdir -p "$STATE_DIR"

overall_status=0
all_newly_in_stock=""

for site in "${SITES[@]}"; do
  IFS='|' read -r key base_url collection <<< "$site"
  collection_url="${base_url}/collections/${collection}/products.json?limit=250"
  state_file="$STATE_DIR/${key}_${collection}_stock.json"

  tmp_response="$(mktemp)"
  http_code=$(curl -sS -L -A "$USER_AGENT" -o "$tmp_response" -w "%{http_code}" "$collection_url")
  if [[ "$http_code" != "200" ]]; then
    echo "ERROR [$key]: fetch failed with HTTP $http_code" >&2
    rm -f "$tmp_response"
    overall_status=1
    continue
  fi

  # Confirm the response is a well-formed products.json payload before trusting
  # an empty product list (some collections hide out-of-stock items entirely,
  # so 0 products is a legitimate "nothing in stock right now" state).
  if ! jq -e '.products | type == "array"' "$tmp_response" >/dev/null 2>&1; then
    echo "ERROR [$key]: malformed response (no .products array)" >&2
    rm -f "$tmp_response"
    overall_status=1
    continue
  fi

  # Build a flat "title|handle|variant|available" list per product/variant.
  # May be empty if the collection currently has no (visible) products.
  current="$(jq -r '
    .products[]
    | .title as $title
    | .handle as $handle
    | .variants[]
    | [$title, $handle, .title, (.available|tostring)] | @tsv
  ' "$tmp_response")"
  rm -f "$tmp_response"

  variant_count=0
  [[ -n "$current" ]] && variant_count=$(echo "$current" | wc -l)

  if [[ ! -f "$state_file" ]]; then
    # First run for this site: just record state, nothing to compare against yet.
    echo "$current" | jq -R -s '
      split("\n") | map(select(length > 0) | split("\t")) |
      map({title: .[0], handle: .[1], variant: .[2], available: (.[3] == "true")})
    ' > "$state_file"
    echo "Initialized stock state for $key ($variant_count variants tracked). No comparison on first run."
    continue
  fi

  if [[ -n "$current" ]]; then
    while IFS=$'\t' read -r title handle variant available; do
      was_available=$(jq -r --arg h "$handle" --arg v "$variant" '
        map(select(.handle == $h and .variant == $v)) | .[0].available // false
      ' "$state_file")
      if [[ "$was_available" == "false" && "$available" == "true" ]]; then
        url="${base_url}/products/${handle}"
        all_newly_in_stock+="[$key] ${title} (${variant}) - ${url}"$'\n'
      fi
    done <<< "$current"
  fi

  # Save new state for this site
  echo "$current" | jq -R -s '
    split("\n") | map(select(length > 0) | split("\t")) |
    map({title: .[0], handle: .[1], variant: .[2], available: (.[3] == "true")})
  ' > "$state_file"
done

if [[ -n "$all_newly_in_stock" ]]; then
  echo "RESTOCK DETECTED:"
  echo "$all_newly_in_stock"
elif [[ "$overall_status" == "0" ]]; then
  echo "No restocks. All tracked variants unchanged or still out of stock."
fi

exit "$overall_status"
