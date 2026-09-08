#!/usr/bin/env bash
# CREA n8n Hands Layer — one command to stand it all up.
#   ./go-live.sh              bring everything up (idempotent — safe to re-run)
#   ./go-live.sh --status     show what's running
#   ./go-live.sh --stop       stop the vault API (n8n and WAHA are left alone)
set -euo pipefail
cd "$(dirname "$0")"

N8N="${CREA_N8N_BASE_URL:-http://localhost:5678}"
VAULT_PORT="${VAULT_API_PORT:-5692}"
say(){ printf '\033[1m%s\033[0m\n' "$*"; }
ok(){ printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn(){ printf '  \033[33m!\033[0m %s\n' "$*"; }

if [ "${1:-}" = "--status" ]; then
  curl -sf "http://127.0.0.1:$VAULT_PORT/health" >/dev/null 2>&1 && ok "vault API up on :$VAULT_PORT" || warn "vault API not running"
  curl -sf "$N8N/healthz" >/dev/null 2>&1 && ok "n8n up ($N8N)" || warn "n8n not reachable"
  curl -sf "http://localhost:3001/api/version" >/dev/null 2>&1 && ok "WAHA up on :3001" || warn "WAHA not running (WhatsApp won't send)"
  n8n list:workflow 2>/dev/null | grep -c "^crea" | xargs -I{} echo "  {} CREA workflows imported" || true
  exit 0
fi
if [ "${1:-}" = "--stop" ]; then
  pkill -f "crea/vault-api/server.js" 2>/dev/null && ok "vault API stopped" || warn "vault API was not running"
  exit 0
fi

say "1/5  config"
if [ ! -f config.env ]; then
  cp config.example.env config.env
  warn "created config.env from the example — EDIT IT, then re-run ./go-live.sh"
  warn "  (at minimum: CREA_OWNER_WA, CREA_WAHA_API_KEY, CREA_OMNIROUTE_URL/KEY)"
  exit 1
fi
missing=$(grep -E '^CREA_(OWNER_WA|WAHA_API_KEY|OMNIROUTE_URL)=$' config.env || true)
[ -n "$missing" ] && { warn "these are still blank in config.env:"; echo "$missing" | sed 's/^/     /'; warn "fill them and re-run"; exit 1; }
ok "config.env present"

say "2/5  vault API"
if curl -sf "http://127.0.0.1:$VAULT_PORT/health" >/dev/null 2>&1; then
  ok "already running on :$VAULT_PORT"
else
  # pass Acuity creds through so /availability is real
  eval "$(grep -E '^CREA_ACUITY_(USER_ID|API_KEY)=' config.env | sed 's/^CREA_ACUITY_USER_ID/ACUITY_USER_ID/;s/^CREA_ACUITY_API_KEY/ACUITY_API_KEY/')" || true
  VAULT_API_PORT="$VAULT_PORT" KNOWLEDGE_FILE="$PWD/knowledge/crea-knowledge.md" \
    ACUITY_USER_ID="${ACUITY_USER_ID:-}" ACUITY_API_KEY="${ACUITY_API_KEY:-}" \
    nohup node vault-api/server.js > /tmp/crea-vault-api.log 2>&1 &
  sleep 1
  curl -sf "http://127.0.0.1:$VAULT_PORT/health" >/dev/null 2>&1 && ok "started on :$VAULT_PORT (log: /tmp/crea-vault-api.log)" \
    || { warn "vault API failed to start — see /tmp/crea-vault-api.log"; exit 1; }
fi

say "3/5  fill + import workflows"
./fill-config.sh config.env workflows >/dev/null
# bind any CREA credentials that already exist (created via HANDOVER step 3) to the auth
# nodes, so there's nothing to click in the n8n UI afterwards
DB="${N8N_DB:-$HOME/.n8n/database.sqlite}"
if command -v sqlite3 >/dev/null && [ -f "$DB" ]; then
  sqlite3 -json "$DB" "SELECT id,name FROM credentials_entity WHERE name LIKE 'CREA %'" > /tmp/crea-creds.json 2>/dev/null || echo '[]' > /tmp/crea-creds.json
  python3 - workflows/_filled /tmp/crea-creds.json <<'PY' || warn "credential auto-bind skipped — select them in the n8n UI"
import json,sys,glob,re
d,cf=sys.argv[1],sys.argv[2]
ids={c["name"]:c["id"] for c in json.load(open(cf))}
if not ids: raise SystemExit(0)
pick=lambda p,n: "CREA Higgsfield" if re.search("higgsfield",(p.get("url","")+n),re.I) else ("CREA OmniRoute" if p.get("genericAuthType")=="httpHeaderAuth" else "CREA Acuity")
bound=0
for f in glob.glob(d+"/*.json"):
    o=json.load(open(f)); ch=False
    for nd in o.get("nodes",[]):
        p=nd.get("parameters",{})
        if p.get("authentication")!="genericCredentialType": continue
        nm=pick(p,nd["name"]); gt=p.get("genericAuthType")
        if nm in ids: nd["credentials"]={gt:{"id":ids[nm],"name":nm}}; ch=True; bound+=1
    if ch: json.dump(o,open(f,"w"),indent=2)
print(f"  bound {bound} credential slot(s)")
PY
  rm -f /tmp/crea-creds.json
fi
before=$(n8n list:workflow 2>/dev/null | grep -c "^crea" || echo 0)
n8n import:workflow --separate --input=workflows/_filled/ 2>&1 | grep -i "imported" | sed 's/^/  /'
after=$(n8n list:workflow 2>/dev/null | grep -c "^crea" || echo 0)
ok "workflows in n8n: $after"

say "4/5  activate"
IDS="creawasend creawainbound creabookingagent creaaiassistant creaacuityintake creacardpipeline creashootconfirm creachasenoreply creamondayinvoice creamorningbrief creaapifyleads"
for id in $IDS; do n8n update:workflow --id="$id" --active=true >/dev/null 2>&1 || true; done
n8n update:workflow --id=trisglobalerrhdlr --active=true >/dev/null 2>&1 || true
ok "activated (restart n8n for webhooks to register)"
if command -v launchctl >/dev/null && launchctl list 2>/dev/null | grep -q com.tris.n8n; then
  launchctl kickstart -k "gui/$(id -u)/com.tris.n8n" >/dev/null 2>&1 || true
  for i in $(seq 1 30); do curl -sf "$N8N/healthz" >/dev/null 2>&1 && break; sleep 2; done
  ok "n8n restarted"
else
  warn "restart n8n yourself so the webhooks register"
fi

say "5/5  what's left (manual — needs your accounts)"
have_creds=$(sqlite3 "$DB" "SELECT COUNT(*) FROM credentials_entity WHERE name LIKE 'CREA %'" 2>/dev/null || echo 0)
cat <<EOF
  a. WhatsApp:  cd waha && cp .env.example .env  (set WAHA_API_KEY) && docker compose up -d
                open http://localhost:3001  → Sessions → default → Start → scan the QR
EOF
if [ "${have_creds:-0}" -ge 3 ]; then
  echo "  b. Credentials: bound automatically. (Only re-check if a workflow node shows a red 'credential' badge.)"
else
  cat <<EOF
  b. Credentials — create them so a re-run of go-live.sh binds them:
       n8n import:credentials --input=<json>  with:
       {"name":"CREA OmniRoute","type":"httpHeaderAuth","data":{"name":"Authorization","value":"Bearer <key>"}}
       {"name":"CREA Acuity","type":"httpBasicAuth","data":{"user":"<Acuity User ID>","password":"<Acuity API Key>"}}
       {"name":"CREA Higgsfield","type":"httpHeaderAuth","data":{"name":"X-Api-Key","value":"<key>"}}   (optional)
EOF
fi
cat <<EOF
  c. Acuity webhook → $N8N/webhook/crea-acuity   (event: appointment.scheduled)
  d. Fill real prices into knowledge/crea-knowledge.md when you have them (optional — works without)

  Then it's live. Test:  curl -sX POST $N8N/webhook/crea-wa-inbound -H 'content-type: application/json' \\
    -d '{"event":"message","session":"default","payload":{"from":"<your number>@c.us","body":"how much for a listing video?","fromMe":false,"type":"chat"}}'
EOF
echo
ok "vault API + workflows are up. Finish a–c above and CREA is answering WhatsApp."
