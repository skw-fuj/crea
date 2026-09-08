#!/usr/bin/env bash
# Substitute {{CREA_*}} + shared tokens from config.env into workflows/_filled/
# Usage: ./fill-config.sh   (reads ./config.env)
set -euo pipefail
cd "$(dirname "$0")"

ENV_FILE="${1:-config.env}"
[ -f "$ENV_FILE" ] || { echo "missing $ENV_FILE — copy config.example.env to config.env and fill it"; exit 1; }

# SRC defaults to ./workflows; pass a dir as $2 for facet-template or other layouts
SRC="${2:-workflows}"
[ -d "$SRC" ] || SRC="."
OUT="$SRC/_filled"
mkdir -p "$OUT"

# load KEY=VALUE lines (ignore comments/blanks)
declare -a KEYS VALS
while IFS='=' read -r k v; do
  [[ "$k" =~ ^[A-Z] ]] || continue
  KEYS+=("$k"); VALS+=("${v%%$'\r'}")
done < <(grep -E '^[A-Z][A-Z0-9_]*=' "$ENV_FILE")

missing=0
for f in "$SRC"/*.json; do
  [ -e "$f" ] || continue
  base=$(basename "$f")
  content=$(cat "$f")
  for i in "${!KEYS[@]}"; do
    content=${content//\{\{${KEYS[$i]}\}\}/${VALS[$i]}}
  done
  # warn on any leftover tokens
  leftover=$(printf '%s' "$content" | grep -oE '\{\{[A-Z0-9_]+\}\}' | sort -u || true)
  if [ -n "$leftover" ]; then
    echo "!! $base still has unresolved tokens:"; echo "$leftover" | sed 's/^/     /'
    missing=1
  fi
  printf '%s' "$content" > "$OUT/$base"
done

echo
if [ "$missing" -eq 0 ]; then
  echo "OK — filled workflows in $OUT/  (import order in SETUP.md)"
else
  echo "Some tokens unresolved — fill them in $ENV_FILE and re-run. Files still written to $OUT/."
fi
