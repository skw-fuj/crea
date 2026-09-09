#!/usr/bin/env bash
# CREA host watchdog. Installed by ./go-live.sh as a launchd job that runs every
# CREA_WATCHDOG_MINUTES. It fixes what it can (restart a down/wedged container, re-link a
# dropped WhatsApp session, prune disk) and pages the owner for what it can't.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 0
ROOT="$PWD"; DEPLOY="$ROOT/deploy"
export PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:$PATH"
[ -f "$DEPLOY/.env" ] && [ -f "$ROOT/config.env" ] || exit 0

LOG="$DEPLOY/_export/watchdog.log"
log(){ echo "$(date '+%F %T') $*" >> "$LOG"; }
cfg(){ grep -E "^$1=" "$ROOT/config.env" 2>/dev/null | head -1 | sed -E "s/^$1=//;s/[[:space:]]+#.*$//;s/^[[:space:]]+//;s/[[:space:]]+$//"; }
compose(){ docker compose --project-directory "$DEPLOY" --env-file "$DEPLOY/.env" "$@"; }
page(){ local wh; wh="$(cfg CREA_ALERT_WEBHOOK_URL)"; [ -n "$wh" ] && \
  curl -sf -m 10 -X POST "$wh" -H 'content-type: application/json' \
    -d "{\"workflow\":\"watchdog\",\"node\":\"host\",\"severity\":\"error\",\"message\":\"$1\"}" >/dev/null 2>&1 || true; }

docker info >/dev/null 2>&1 || { log "docker daemon not available"; exit 0; }

acted=0
# 1. every container running?
for c in crea-vault-api crea-n8n crea-waha; do
  st=$(docker inspect -f '{{.State.Status}}' "$c" 2>/dev/null || echo missing)
  if [ "$st" != "running" ]; then log "$c is '$st' — bringing the stack up"; compose up -d >/dev/null 2>&1; acted=1; sleep 8; fi
done

# 2. n8n wedged? (compose healthcheck turns it 'unhealthy')
if [ "$(docker inspect -f '{{.State.Health.Status}}' crea-n8n 2>/dev/null || echo none)" = "unhealthy" ]; then
  log "n8n unhealthy — restarting"; compose restart n8n >/dev/null 2>&1; acted=1
  page "n8n was unresponsive and has been restarted automatically."
fi

# 3. vault-api answering?
if ! compose exec -T vault-api wget -q -O /dev/null http://localhost:5692/ping 2>/dev/null; then
  log "vault-api not answering /ping — restarting"; compose restart vault-api >/dev/null 2>&1; acted=1
fi

# 4. WhatsApp session linked?
K="$(cfg CREA_WAHA_API_KEY)"; WP="$(cfg CREA_WAHA_PORT)"; WP="${WP:-3001}"
NP="$(cfg CREA_N8N_PORT)"; NP="${NP:-5678}"
sess=$(curl -sf -m 8 -H "X-Api-Key: $K" "http://localhost:$WP/api/sessions/default" 2>/dev/null || true)
status=$(printf '%s' "$sess" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("status","?"))' 2>/dev/null || echo "?")
if [ -n "$sess" ] && ! printf '%s' "$status" | grep -qE 'WORKING|STARTING|SCAN_QR_CODE'; then
  log "WhatsApp session status=$status — attempting restart"
  curl -sf -m 8 -X POST -H "X-Api-Key: $K" "http://localhost:$WP/api/sessions/default/restart" >/dev/null 2>&1 \
   || curl -sf -m 8 -X POST -H "X-Api-Key: $K" "http://localhost:$WP/api/sessions/default/start" >/dev/null 2>&1
  sleep 12
  s2=$(curl -sf -m 8 -H "X-Api-Key: $K" "http://localhost:$WP/api/sessions/default" 2>/dev/null | python3 -c 'import sys,json;print(json.load(sys.stdin).get("status","?"))' 2>/dev/null || echo "?")
  printf '%s' "$s2" | grep -qE 'WORKING|STARTING' || page "WhatsApp is disconnected (status: $s2). Run ./go-live.sh --qr and re-scan the code."
  acted=1
fi

# 5. disk
free=$(df -g / 2>/dev/null | awk 'NR==2{print $4}')
if [ -n "${free:-}" ] && [ "$free" -lt 4 ]; then
  log "disk low (${free} GB) — pruning docker + old n8n executions"
  docker image prune -f >/dev/null 2>&1 || true
  docker builder prune -f >/dev/null 2>&1 || true
  free2=$(df -g / 2>/dev/null | awk 'NR==2{print $4}')
  [ -n "${free2:-}" ] && [ "$free2" -lt 3 ] && page "Disk critically low (${free2} GB free). CREA may stop working — free space on this Mac now."
  acted=1
fi

# 6. hand off to the in-app self-check (LLM circuit, knowledge, alert pile-up -> owner)
curl -sf -m 10 -X POST "http://localhost:$NP/webhook/crea-selfcheck" -d '{}' >/dev/null 2>&1 || true

[ "$acted" = 1 ] && log "watchdog took action (see above)" || true
# keep the log bounded
if [ -f "$LOG" ]; then tail -n 400 "$LOG" > "$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG"; fi
exit 0
