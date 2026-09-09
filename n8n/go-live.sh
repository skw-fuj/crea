#!/usr/bin/env bash
# =============================================================================
#  CREA v2 — go live.  One command, idempotent, safe to re-run.
#
#    ./go-live.sh            bring the whole stack up and wire everything
#    ./go-live.sh --status   what's running
#    ./go-live.sh --qr       (re)print the WhatsApp pairing QR
#    ./go-live.sh --test     send a test message through the live assistant
#    ./go-live.sh --stop     stop the stack (data is kept)
#    ./go-live.sh --down     stop and remove containers (named volumes kept)
#    ./go-live.sh --logs [service]
#
#  Prereq: Docker Desktop installed and running.  Full runbook: INSTALL.md
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$PWD"
DEPLOY="$ROOT/deploy"
ENVCLEAN="$DEPLOY/.env"                 # comment-free KEY=VALUE for docker compose
KEYFILE="$DEPLOY/.n8n-key"

b(){ printf '\033[1m%s\033[0m\n' "$*"; }
ok(){ printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn(){ printf '  \033[33m!\033[0m %s\n' "$*"; }
die(){ printf '  \033[31m✗ %s\033[0m\n' "$*"; exit 1; }

# read one value from config.env, stripped of an inline "# comment" and whitespace
cfg(){ grep -E "^$1=" config.env 2>/dev/null | head -1 | sed -E "s/^$1=//; s/[[:space:]]+#.*$//; s/^[[:space:]]+//; s/[[:space:]]+$//"; }

compose(){ docker compose --project-directory "$DEPLOY" --env-file "$ENVCLEAN" "$@"; }
n8n_cli(){ compose exec -T n8n n8n "$@"; }
N8N_PORT_DEFAULT=5678
n8n_port(){ local p; p="$(cfg CREA_N8N_PORT)"; echo "${p:-$N8N_PORT_DEFAULT}"; }
waha_port(){ local p; p="$(cfg CREA_WAHA_PORT)"; echo "${p:-3001}"; }
N8N_URL(){ echo "http://localhost:$(n8n_port)"; }
WAHA_URL(){ echo "http://localhost:$(waha_port)"; }

wait_http(){ local url="$1" name="$2" tries="${3:-60}" i; for i in $(seq 1 "$tries"); do
  curl -sf -o /dev/null "$url" && { ok "$name"; return 0; }; sleep 2; done
  warn "$name — not responding at $url after $((tries*2))s"; return 1; }

build_clean_env(){
  [ -f config.env ] || die "no config.env — run ./go-live.sh with no args first, it will create one"
  : > "$ENVCLEAN"; chmod 600 "$ENVCLEAN"
  while IFS= read -r line; do
    [[ "$line" =~ ^([A-Z][A-Z0-9_]*)=(.*)$ ]] || continue
    local k="${BASH_REMATCH[1]}" v="${BASH_REMATCH[2]}"
    v="${v%$'\r'}"
    v="$(printf '%s' "$v" | sed -E 's/[[:space:]]+#.*$//; s/^[[:space:]]+//; s/[[:space:]]+$//')"
    printf '%s=%s\n' "$k" "$v" >> "$ENVCLEAN"
  done < config.env
  printf 'N8N_ENCRYPTION_KEY=%s\n' "$(cat "$KEYFILE")" >> "$ENVCLEAN"
  local vd; vd="$(cfg CREA_VAULT_DIR)"; vd="${vd/#\~/$HOME}"
  if [ -n "$vd" ]; then mkdir -p "$vd" || die "cannot create CREA_VAULT_DIR: $vd"
    printf 'CREA_VAULT_DIR_ABS=%s\n' "$vd" >> "$ENVCLEAN"
  else printf 'CREA_VAULT_DIR_ABS=crea_vault\n' >> "$ENVCLEAN"; fi
}

# ---------------------------------------------------------------------------
case "${1:-}" in
  --status)
    [ -f "$ENVCLEAN" ] || build_clean_env 2>/dev/null || true
    compose ps 2>/dev/null || warn "stack not created yet — run ./go-live.sh"
    curl -sf -o /dev/null "$(N8N_URL)/healthz" && ok "n8n reachable at $(N8N_URL)" || warn "n8n not reachable"
    K="$(cfg CREA_WAHA_API_KEY)"
    s=$(curl -sf -H "X-Api-Key: $K" "$(WAHA_URL)/api/sessions/default" 2>/dev/null || true)
    [ -n "$s" ] && ok "WhatsApp session: $(printf '%s' "$s" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("status","?"))' 2>/dev/null)" \
                || warn "WAHA not reachable / no session"
    exit 0 ;;
  --stop) compose stop; ok "stopped — data kept. ./go-live.sh to resume"; exit 0 ;;
  --down) compose down; ok "containers removed — named volumes kept"; exit 0 ;;
  --logs) shift; compose logs -f --tail=120 "$@"; exit 0 ;;
  --qr)   MODE=qr ;;
  --test) MODE=test ;;
  "")     MODE=full ;;
  *)      die "unknown option: $1  — see the header of this script or INSTALL.md" ;;
esac

# ===========================================================================
if [ "$MODE" = "full" ]; then

b "1/8  preflight"
command -v docker >/dev/null || die "Docker is not installed. INSTALL.md → Part A step 2."
docker info >/dev/null 2>&1 || die "Docker Desktop isn't running. Open it, wait for the steady whale icon, re-run."
docker compose version >/dev/null 2>&1 || die "'docker compose' missing — update Docker Desktop."
if [ ! -f config.env ]; then
  cp config.example.env config.env
  warn "created config.env from the example."
  die "open config.env, fill the lines marked ◀ REQUIRED, then re-run ./go-live.sh"
fi
miss=""; for k in CREA_OWNER_WA CREA_WAHA_API_KEY CREA_OMNIROUTE_URL CREA_OMNIROUTE_KEY; do
  [ -z "$(cfg "$k")" ] && miss="$miss $k"; done
[ -n "$miss" ] && die "these REQUIRED values are blank in config.env:$miss"
ok "Docker is running; config.env has the required values"

b "2/8  encryption key"
if [ ! -s "$KEYFILE" ]; then ( umask 077; openssl rand -hex 24 > "$KEYFILE" )
  ok "generated deploy/.n8n-key — BACK THIS UP (losing it makes saved credentials unreadable)"
else ok "using existing deploy/.n8n-key"; fi

b "3/8  fill workflows from config.env"
./fill-config.sh config.env workflows >/dev/null || die "fill-config failed — a token in the workflows has no matching line in config.env"
rm -rf "$DEPLOY/_filled"; mkdir -p "$DEPLOY/_filled"
cp workflows/_filled/*.json "$DEPLOY/_filled/"
build_clean_env
ok "workflows filled → deploy/_filled/ ; clean env → deploy/.env"

b "4/8  pull + start the stack (first run downloads ~2 GB — be patient)"
compose pull -q 2>/dev/null || warn "pull had warnings — continuing"
compose up -d
wait_http "$(N8N_URL)/healthz" "n8n up" 120
compose exec -T vault-api wget -qO- http://localhost:5692/health >/dev/null 2>&1 && ok "vault API up" || warn "vault API health inconclusive — ./go-live.sh --logs vault-api"

b "5/8  credentials"
CREDS="$DEPLOY/_filled/.creds.json"
trap 'rm -f "$CREDS"' EXIT
python3 - "$CREDS" "$(cfg CREA_OMNIROUTE_KEY)" "$(cfg CREA_ACUITY_USER_ID)" "$(cfg CREA_ACUITY_API_KEY)" "$(cfg CREA_HIGGSFIELD_API_KEY)" <<'PY'
import json,sys
out,okey,auid,akey,hkey=sys.argv[1:6]
c=[{"id":"creaomniroutecred","name":"CREA OmniRoute","type":"httpHeaderAuth",
    "data":{"name":"Authorization","value":"Bearer "+okey}}]
if auid and akey: c.append({"id":"creaacuitycred","name":"CREA Acuity","type":"httpBasicAuth",
    "data":{"user":auid,"password":akey}})
if hkey: c.append({"id":"creahiggscred","name":"CREA Higgsfield","type":"httpHeaderAuth",
    "data":{"name":"X-Api-Key","value":hkey}})
json.dump(c,open(out,"w"))
PY
n8n_cli import:credentials --input=/workflows/.creds.json >/dev/null 2>&1 && ok "credentials loaded into n8n" \
  || warn "credential import returned an error — ./go-live.sh --logs n8n"
rm -f "$CREDS"; trap - EXIT

b "6/8  import + bind + activate workflows"
n8n_cli import:workflow --separate --input=/workflows >/dev/null 2>&1 || warn "workflow import reported an issue — ./go-live.sh --logs n8n"
# bind the credentials to the auth nodes so there's nothing to click in the UI
python3 - "$DEPLOY/_filled" <<'PY'
import json,glob,re
BIND={"httpHeaderAuth":("creaomniroutecred","CREA OmniRoute"),
      "httpBasicAuth":("creaacuitycred","CREA Acuity")}
HIGG=("creahiggscred","CREA Higgsfield")
for f in glob.glob(__import__('sys').argv[1]+"/crea-*.json"):
    o=json.load(open(f)); ch=False
    for n in o.get("nodes",[]):
        p=n.get("parameters",{})
        if p.get("authentication")!="genericCredentialType": continue
        gt=p.get("genericAuthType")
        cid,cname = HIGG if re.search("higgsfield",(p.get("url","")+n["name"]),re.I) else BIND.get(gt,(None,None))
        if cid: n["credentials"]={gt:{"id":cid,"name":cname}}; ch=True
    if ch: json.dump(o,open(f,"w"),indent=2)
PY
n8n_cli import:workflow --separate --input=/workflows >/dev/null 2>&1 || true
CORE="creaerrorhandler creawasend creawainbound creabookingagent creaaiassistant creamondayinvoice creacardpipeline"
for id in $CORE; do n8n_cli update:workflow --id="$id" --active=true >/dev/null 2>&1 || true; done
on="core booking loop + error handler + invoicing + card pipeline"
if [ -n "$(cfg CREA_ACUITY_USER_ID)" ]; then
  for id in creaacuityintake creashootconfirm creachasenoreply creamorningbrief; do n8n_cli update:workflow --id="$id" --active=true >/dev/null 2>&1 || true; done
  on="$on + Acuity shoot-ops"
else
  for id in creaacuityintake creashootconfirm creachasenoreply creamorningbrief; do n8n_cli update:workflow --id="$id" --active=false >/dev/null 2>&1 || true; done
fi
if [ -n "$(cfg CREA_APIFY_TOKEN)" ]; then n8n_cli update:workflow --id=creaapifyleads --active=true >/dev/null 2>&1 || true; on="$on + listing leads"
else n8n_cli update:workflow --id=creaapifyleads --active=false >/dev/null 2>&1 || true; fi
compose restart n8n >/dev/null
wait_http "$(N8N_URL)/healthz" "n8n restarted (webhooks registered)" 120
ok "activated: $on"

fi   # end MODE=full

# ---------------------------------------------------------------------------
b "WhatsApp pairing"
[ -f "$ENVCLEAN" ] || build_clean_env
K="$(cfg CREA_WAHA_API_KEY)"; W="$(WAHA_URL)"
curl -sf -X POST "$W/api/sessions" -H "X-Api-Key: $K" -H 'content-type: application/json' -d '{"name":"default","start":true}' >/dev/null 2>&1 \
 || curl -sf -X POST "$W/api/sessions/default/start" -H "X-Api-Key: $K" >/dev/null 2>&1 || true
sleep 2
STATUS=$(curl -sf -H "X-Api-Key: $K" "$W/api/sessions/default" 2>/dev/null | python3 -c 'import sys,json;print(json.load(sys.stdin).get("status","UNKNOWN"))' 2>/dev/null || echo UNKNOWN)
if [ "$STATUS" = "WORKING" ]; then
  ok "WhatsApp is paired and connected. Nothing to scan."
else
  QR="$DEPLOY/whatsapp-qr.png"
  curl -sf -H "X-Api-Key: $K" "$W/api/default/auth/qr?format=image" -o "$QR" 2>/dev/null || true
  warn "WhatsApp not paired yet (status: $STATUS)"
  echo "     1. open  $W/dashboard"
  echo "     2. click the session called 'default'"
  echo "     3. scan the QR with the bot phone:  WhatsApp → Settings → Linked Devices → Link a Device"
  [ -s "$QR" ] && echo "     (QR also saved to deploy/whatsapp-qr.png)"
fi
[ "${MODE:-}" = "qr" ] && exit 0

# ---------------------------------------------------------------------------
if [ "$STATUS" != "WORKING" ] && [ "${MODE:-}" != "test" ]; then
  echo; b "Almost there"
  echo "  Everything is up and every workflow is active. Pair WhatsApp (above), then:  ./go-live.sh --test"
  exit 0
fi

b "self-test — a real message through the assistant"
T="61400000000"
curl -sf -X POST "$(N8N_URL)/webhook/crea-wa-inbound" -H 'content-type: application/json' \
  -d "{\"event\":\"message\",\"session\":\"default\",\"payload\":{\"id\":\"selftest-$(date +%s)\",\"from\":\"${T}@c.us\",\"body\":\"how much for a listing video?\",\"fromMe\":false,\"type\":\"chat\"}}" >/dev/null \
  && ok "crea-01 accepted the test message" || warn "crea-01 did not accept it — ./go-live.sh --logs n8n"
sleep 6
S=$(compose exec -T vault-api wget -qO- "http://localhost:5692/state?key=${T}" 2>/dev/null || echo '{}')
echo "  assistant state for the test number:"; echo "  $S"
case "$S" in *'"mode": "ai"'*|*'"mode":"ai"'*) ok "the assistant handled it — CREA v2 is live" ;;
  *) warn "no assistant state yet — send a real WhatsApp to the bot and check ./go-live.sh --logs n8n" ;; esac
echo
echo "  Watch it work:  open $(N8N_URL)  → any CREA workflow → Executions"
echo "  Day to day:     ./go-live.sh --status | --qr | --logs | --stop"
