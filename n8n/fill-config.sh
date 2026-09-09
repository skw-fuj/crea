#!/usr/bin/env bash
# Substitute {{CREA_*}} + shared tokens from config.env into workflows/_filled/
# Usage: ./fill-config.sh [config.env] [srcdir]
set -euo pipefail
cd "$(dirname "$0")"

ENV_FILE="${1:-config.env}"
[ -f "$ENV_FILE" ] || { echo "missing $ENV_FILE — copy config.example.env to config.env and fill it"; exit 1; }

SRC="${2:-workflows}"
[ -d "$SRC" ] || SRC="."
OUT="$SRC/_filled"
mkdir -p "$OUT"

# load KEY=VALUE lines. Strip: CR, a trailing " # comment", surrounding whitespace,
# and one layer of matching surrounding quotes. This is what keeps an inline comment in
# config.env (e.g.  CREA_LLM_MODEL=gpt  # fast ) out of the workflow JSON.
declare -a KEYS VALS
while IFS= read -r line; do
  [[ "$line" =~ ^([A-Z][A-Z0-9_]*)=(.*)$ ]] || continue
  k="${BASH_REMATCH[1]}"; v="${BASH_REMATCH[2]}"
  v="${v%$'\r'}"
  v="${v%%$'\t'#*}"                     # strip  <tab>#...
  v="$(printf '%s' "$v" | sed -E 's/[[:space:]]+#.*$//; s/^[[:space:]]+//; s/[[:space:]]+$//')"
  case "$v" in
    \"*\") v="${v#\"}"; v="${v%\"}" ;;
    \'*\') v="${v#\'}"; v="${v%\'}" ;;
  esac
  KEYS+=("$k"); VALS+=("$v")
done < "$ENV_FILE"

# a blank "X_2" key inherits X's value (e.g. CREA_OMNIROUTE_URL_2 / _MODEL_2 fall back to
# the primary) so an optional-second-endpoint node still gets a valid value.
for i in "${!KEYS[@]}"; do
  case "${KEYS[$i]}" in
    *_2)
      if [ -z "${VALS[$i]}" ]; then
        base="${KEYS[$i]%_2}"
        for j in "${!KEYS[@]}"; do
          [ "${KEYS[$j]}" = "$base" ] && VALS[$i]="${VALS[$j]}"
        done
      fi ;;
  esac
done

missing=0
for f in "$SRC"/*.json; do
  [ -e "$f" ] || continue
  base=$(basename "$f")
  content=$(cat "$f")
  for i in "${!KEYS[@]}"; do
    content=${content//\{\{${KEYS[$i]}\}\}/${VALS[$i]}}
  done
  leftover=$(printf '%s' "$content" | grep -oE '\{\{[A-Z0-9_]+\}\}' | sort -u || true)
  if [ -n "$leftover" ]; then
    echo "!! $base still has unresolved tokens:"; echo "$leftover" | sed 's/^/     /'
    missing=1
  fi
  printf '%s' "$content" > "$OUT/$base"
done

echo
if [ "$missing" -eq 0 ]; then
  echo "OK — filled workflows in $OUT/"
else
  echo "Some tokens are unresolved — fill them in $ENV_FILE and re-run. Files still written to $OUT/."
  exit 1
fi
