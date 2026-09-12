#!/usr/bin/env bash
# =============================================================================
#  CREA v3.1 — go live.  One command, idempotent, safe to re-run.
#
#    ./go-live.sh            bring the whole stack up and wire everything
#    ./go-live.sh --status   what's running
#    ./go-live.sh --qr       (re)print the WhatsApp pairing QR
#    ./go-live.sh --test     send a test message through the live assistant
#    ./go-live.sh --bookings           list held bookings waiting on your CONFIRM
#    ./go-live.sh --confirm <ref>      book a held booking in (creates the Acuity appt)
#    ./go-live.sh --decline <ref>      release a held booking
#    ./go-live.sh --test-voice         proves the phone pipeline works, no real call needed
#    ./go-live.sh --stop     stop the stack (data is kept)
#    ./go-live.sh --down     stop and remove containers (named volumes kept)
#    ./go-live.sh --logs [service]
#    ./go-live.sh --export   dump the live workflows to deploy/_export/<ts>/ (to keep UI edits)
#    ./go-live.sh --backup   full backup -> backups/crea-<ts>.tgz (config, key, workflows, data)
#    ./go-live.sh --restore <file>   restore config.env + encryption key from a backup
#    ./go-live.sh --selfcheck  run the health self-check now (pages you if something's wrong)
#    ./go-live.sh --watchdog [remove]   install / remove the background host watchdog
#
#  Prereq: Docker Desktop installed and running.
#  Install runbook: INSTALL.md    Day-to-day changes / updates / features: OPERATIONS.md
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
  mkdir -p "$DEPLOY/_export" "$ROOT/backups"
  # optional n8n editor login
  if [ -n "$(cfg CREA_N8N_USER)" ] && [ -n "$(cfg CREA_N8N_PASSWORD)" ]; then
    printf 'CREA_N8N_AUTH_ACTIVE=true\n' >> "$ENVCLEAN"
  else printf 'CREA_N8N_AUTH_ACTIVE=false\n' >> "$ENVCLEAN"; fi
  # WAHA ships arch-specific images; the arm64 build is NOWEB-only.
  case "$(uname -m)" in
    arm64|aarch64) printf 'CREA_WAHA_IMAGE=devlikeapro/waha:noweb-arm\nCREA_WAHA_ENGINE=NOWEB\n' >> "$ENVCLEAN" ;;
    *)             printf 'CREA_WAHA_IMAGE=devlikeapro/waha:noweb\nCREA_WAHA_ENGINE=NOWEB\n' >> "$ENVCLEAN" ;;
  esac
  local vd; vd="$(cfg CREA_VAULT_DIR)"; vd="${vd/#\~/$HOME}"
  if [ -n "$vd" ]; then mkdir -p "$vd" || die "cannot create CREA_VAULT_DIR: $vd"
    printf 'CREA_VAULT_DIR_ABS=%s\n' "$vd" >> "$ENVCLEAN"
  else printf 'CREA_VAULT_DIR_ABS=crea_vault\n' >> "$ENVCLEAN"; fi
  # voice calls need cloudflared (Twilio must reach n8n publicly — WAHA just polls out)
  [ -n "$(cfg CREA_TWILIO_ACCOUNT_SID)" ] && printf 'COMPOSE_PROFILES=voice\n' >> "$ENVCLEAN"
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
    H=$(compose exec -T vault-api wget -q -O - http://localhost:5692/health 2>/dev/null || true)
    if [ -n "$H" ]; then
      printf '%s' "$H" | python3 - <<'PY' 2>/dev/null || true
import sys,json
h=json.load(sys.stdin)
g="\033[32m"; y="\033[33m"; r="\033[31m"; n="\033[0m"
print(f"  {g if h.get('ok') else r}{'healthy' if h.get('ok') else 'NEEDS ATTENTION'}{n}  (vault-api v{h.get('version')})")
for k,v in (h.get('critical') or {}).items():
    print(f"    {g+'ok'+n if v else r+'PROBLEM'+n}  {k.replace('_',' ')}")
for k,v in (h.get('advisory') or {}).items():
    print(f"    {g+'ok'+n if v else y+'to do'+n}  {k.replace('_',' ')}")
a=h.get('activity_today') or {}
print(f"  today: {a.get('leads',0)} enquiries · {a.get('jobs',0)} bookings · {a.get('inbox',0)} inbox · {a.get('alerts',0)} alerts")
lc=h.get('llm') or {}
print(f"  LLM circuit: {'OPEN (fallback flow)' if lc.get('open') else 'closed'}  ·  disk free: {h.get('disk_free_gb')} GB  ·  last backup: {h.get('last_backup_age_h')} h ago")
PY
      echo "  full dashboard: open  http://localhost:$(cfg CREA_VAULT_PORT || echo 5692)/status.html"
    fi
    if [ -n "$(cfg CREA_TWILIO_ACCOUNT_SID)" ]; then
      compose ps cloudflared 2>/dev/null | grep -qi "up\|running" && ok "cloudflared tunnel container running" || warn "cloudflared not running — voice calls can't reach n8n. ./go-live.sh --logs cloudflared"
      echo "  voice: run ./go-live.sh --test-voice to check the phone pipeline"
    else
      echo "  voice: not configured (CREA_TWILIO_ACCOUNT_SID blank) — see VOICE.md to add phone bookings"
    fi
    launchctl list 2>/dev/null | grep -q com.crea.watchdog && ok "watchdog installed" || warn "watchdog not installed — ./go-live.sh --watchdog install"
    exit 0 ;;
  --selfcheck)
    [ -f "$ENVCLEAN" ] || build_clean_env
    curl -sf -m 15 -X POST "$(N8N_URL)/webhook/crea-selfcheck" -d '{}' >/dev/null 2>&1 && ok "self-check triggered — result in the vault _selfcheck state and (if there's a problem) your WhatsApp" || warn "could not reach the self-check webhook — is the stack up?"
    exit 0 ;;
  --watchdog)
    PL="$HOME/Library/LaunchAgents/com.crea.watchdog.plist"
    if [ "${2:-}" = "remove" ]; then launchctl bootout "gui/$(id -u)/com.crea.watchdog" 2>/dev/null || launchctl unload "$PL" 2>/dev/null || true; rm -f "$PL"; ok "watchdog removed"; exit 0; fi
    [ -f "$ENVCLEAN" ] || build_clean_env
    mins="$(cfg CREA_WATCHDOG_MINUTES)"; mins="${mins:-5}"; secs=$(( mins * 60 ))
    mkdir -p "$HOME/Library/LaunchAgents"
    sed -e "s#__WATCHDOG_SH__#$DEPLOY/watchdog.sh#" -e "s#__INTERVAL__#$secs#" -e "s#__LOG__#$DEPLOY/_export/watchdog-launchd.log#" \
      "$DEPLOY/com.crea.watchdog.plist.template" > "$PL"
    chmod +x "$DEPLOY/watchdog.sh"
    launchctl bootout "gui/$(id -u)/com.crea.watchdog" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$PL" 2>/dev/null || launchctl load "$PL" 2>/dev/null || true
    ok "watchdog installed — checks every ${mins} min (./go-live.sh --watchdog remove to stop)"
    exit 0 ;;
  --stop) compose stop; ok "stopped — data kept. ./go-live.sh to resume"; exit 0 ;;
  --down) compose down; ok "containers removed — named volumes kept"; exit 0 ;;
  --logs) shift; compose logs -f --tail=120 "$@"; exit 0 ;;
  --qr)   MODE=qr ;;
  --test) MODE=test ;;
  --confirm|--decline)
    act="${1#--}"; ref="${2:-}"
    [ -n "$ref" ] || die "usage: ./go-live.sh --$act <ref>   (the ref CREA texted you, e.g. 4A2)"
    [ -f "$ENVCLEAN" ] || build_clean_env
    code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$(N8N_URL)/webhook/crea-book-confirm" \
      -H 'content-type: application/json' -d "{\"action\":\"$act\",\"ref\":\"$ref\"}")
    [ "$code" = "200" ] && ok "sent: $act $ref  (CREA is creating the appointment + telling the customer)" \
      || die "n8n did not accept it (HTTP $code) — is the stack up? ./go-live.sh --status"
    exit 0 ;;
  --bookings)
    [ -f "$ENVCLEAN" ] || build_clean_env
    b "held bookings waiting on your CONFIRM"
    compose exec -T vault-api wget -qO- "http://localhost:5692/booking/pending" 2>/dev/null \
      | python3 -c 'import sys,json
try: r=json.load(sys.stdin)
except: r=[]
if not r: print("  (none)")
for x in r: print("  %-6s %s  %s" % (x.get("ref","?"), (x.get("brief") or {}).get("address","?"), x.get("datetime") or x.get("estimate") or ""))' \
      || warn "could not read pending bookings — ./go-live.sh --status"
    echo "  confirm one:  ./go-live.sh --confirm <ref>"
    exit 0 ;;
  --test-voice)
    [ -f "$ENVCLEAN" ] || build_clean_env
    K="$(cfg CREA_TWILIO_AUTH_TOKEN)"; [ -n "$K" ] || die "CREA_TWILIO_AUTH_TOKEN is blank — set up voice first (see VOICE.md)"
    PUB="$(cfg CREA_PUBLIC_BASE_URL)"; [ -n "$PUB" ] || die "CREA_PUBLIC_BASE_URL is blank — set up voice first (see VOICE.md)"
    b "testing the voice pipeline locally — no real call, no Twilio balance spent"
    URL="${PUB%/}/webhook/crea-voice-inbound"
    T="61400000000"; CALLSID="CAtest$(date +%s)"
    # Twilio's documented signing algorithm: url + sorted(key+value, no separator), HMAC-SHA1, base64.
    # Field order here (CallSid, CallStatus, From) IS the sorted order for exactly these 3 keys —
    # if you add fields to this test, re-sort alphabetically or the signature won't validate.
    DATA="${URL}CallSid${CALLSID}CallStatusringingFrom+${T}"
    SIG=$(printf '%s' "$DATA" | openssl dgst -sha1 -hmac "$K" -binary | base64)
    RESP=$(curl -s -X POST "$(N8N_URL)/webhook/crea-voice-inbound" \
      -H "X-Twilio-Signature: $SIG" \
      --data-urlencode "CallSid=${CALLSID}" --data-urlencode "CallStatus=ringing" --data-urlencode "From=+${T}")
    echo "$RESP" | python3 -c "import sys,xml.dom.minidom as m; print(m.parseString(sys.stdin.read()).toprettyxml(indent='  '))" 2>/dev/null || echo "$RESP"
    case "$RESP" in
      *"<Reject"*) die "signature check failed — CREA_TWILIO_AUTH_TOKEN or CREA_PUBLIC_BASE_URL in config.env won't match what Twilio sends. Fix config.env and re-run — do NOT point a real Twilio number at this until this passes." ;;
      *"<Gather"*) ok "voice pipeline OK — that's the exact greeting a caller hears first. This proves signature verification, the blocklist/flood/human-handoff checks, and the greeting all work.";
        warn "NOT proven yet: the Cloudflare Tunnel is actually reachable from the internet, and the Twilio number's webhook URL is set correctly. Do ONE real test call after this passes — that closes the loop." ;;
      *) die "unexpected response — is the stack up? ./go-live.sh --status . Got: $RESP" ;;
    esac
    exit 0 ;;
  --export)
    [ -f "$ENVCLEAN" ] || build_clean_env
    TS=$(date +%Y%m%d-%H%M%S); OUT="$DEPLOY/_export/$TS"; mkdir -p "$OUT"
    compose exec -T n8n sh -c 'rm -rf /export/live && mkdir -p /export/live && n8n export:workflow --backup --output=/export/live/' >/dev/null 2>&1 \
      && cp "$DEPLOY/_export/live/"*.json "$OUT/" 2>/dev/null \
      && ok "live workflows exported to deploy/_export/$TS/  (diff against workflows/ to fold UI edits back in)" \
      || warn "export failed — is the stack up? ./go-live.sh --status"
    exit 0 ;;
  --backup)
    [ -f "$ENVCLEAN" ] || build_clean_env
    TS=$(date +%Y%m%d-%H%M%S); B="$ROOT/backups/crea-$TS"; mkdir -p "$B"
    cp config.env "$B/" 2>/dev/null; cp "$KEYFILE" "$B/n8n-key" 2>/dev/null
    compose exec -T n8n sh -c 'rm -rf /export/bk && mkdir -p /export/bk && n8n export:workflow --backup --output=/export/bk/wf/ && n8n export:credentials --backup --decrypted=false --output=/export/bk/creds/' >/dev/null 2>&1 || warn "n8n export step had issues"
    [ -d "$DEPLOY/_export/bk" ] && cp -R "$DEPLOY/_export/bk/." "$B/n8n/" 2>/dev/null
    VD="$(cfg CREA_VAULT_DIR)"; VD="${VD/#\~/$HOME}"
    if [ -n "$VD" ] && [ -d "$VD" ]; then tar -czf "$B/vault-data.tgz" -C "$VD" . 2>/dev/null && ok "vault data archived"; \
    else compose run --rm -T -v "$B:/bk" vault-api sh -c 'tar -czf /bk/vault-data.tgz -C /vault .' >/dev/null 2>&1 && ok "vault volume archived"; fi
    ( cd "$ROOT/backups" && tar -czf "crea-$TS.tgz" "crea-$TS" && rm -rf "crea-$TS" )
    ok "backup written: backups/crea-$TS.tgz  (config.env + encryption key + workflows + credentials + booking data)"
    warn "this file contains your API keys and the encryption key — store it somewhere safe, not in the repo"
    exit 0 ;;
  --restore)
    F="${2:-}"; [ -f "$F" ] || die "usage: ./go-live.sh --restore backups/crea-YYYYMMDD-HHMMSS.tgz"
    T=$(mktemp -d); tar -xzf "$F" -C "$T"; D=$(find "$T" -maxdepth 1 -type d -name 'crea-*' | head -1)
    [ -d "$D" ] || die "not a CREA backup archive"
    [ -f "$D/config.env" ] && { cp "$D/config.env" config.env; ok "restored config.env"; }
    [ -f "$D/n8n-key" ] && { cp "$D/n8n-key" "$KEYFILE"; chmod 600 "$KEYFILE"; ok "restored deploy/.n8n-key"; }
    [ -f "$D/vault-data.tgz" ] && ok "vault data archive is at $D/vault-data.tgz — extract it into your CREA_VAULT_DIR"
    rm -rf "$T"
    warn "now run ./go-live.sh to rebuild the stack, then re-scan the WhatsApp QR"
    exit 0 ;;
  "")     MODE=full ;;
  *)      die "unknown option: $1  — see the header of this script, INSTALL.md or OPERATIONS.md" ;;
esac

# ===========================================================================
if [ "$MODE" = "full" ]; then

b "1/9  preflight"
command -v docker >/dev/null || die "Docker is not installed. INSTALL.md → Part A step 2."
docker info >/dev/null 2>&1 || die "Docker Desktop isn't running. Open it, wait for the steady whale icon, re-run."
docker compose version >/dev/null 2>&1 || die "'docker compose' missing — update Docker Desktop."
free_gb=$(df -g / 2>/dev/null | awk 'NR==2{print $4}'); free_gb="${free_gb:-99}"
[ "$free_gb" -lt 6 ] && die "only ${free_gb} GB free on this disk — the images need ~5 GB and n8n grows over time. Free up space (aim for 15 GB) and re-run."
[ "$free_gb" -lt 15 ] && warn "only ${free_gb} GB free — enough to start, but keep an eye on it (aim for 15 GB)."
if [ ! -f config.env ]; then
  cp config.example.env config.env
  warn "created config.env from the example."
  die "open config.env, fill the lines marked ◀ REQUIRED, then re-run ./go-live.sh"
fi
miss=""; for k in CREA_OWNER_WA CREA_WAHA_API_KEY CREA_OMNIROUTE_URL CREA_OMNIROUTE_KEY; do
  [ -z "$(cfg "$k")" ] && miss="$miss $k"; done
[ -n "$miss" ] && die "these REQUIRED values are blank in config.env:$miss"
# voice is all-or-nothing: a half-filled Twilio block would silently "activate" a channel
# that can never pass signature verification — catch that now, not after Connell's first call.
if [ -n "$(cfg CREA_TWILIO_ACCOUNT_SID)" ]; then
  vmiss=""; for k in CREA_TWILIO_AUTH_TOKEN CREA_TWILIO_NUMBER CREA_PUBLIC_BASE_URL CREA_CF_TUNNEL_TOKEN; do
    [ -z "$(cfg "$k")" ] && vmiss="$vmiss $k"; done
  [ -n "$vmiss" ] && die "CREA_TWILIO_ACCOUNT_SID is set but these voice values are blank:$vmiss — fill them (see VOICE.md) or clear CREA_TWILIO_ACCOUNT_SID to skip voice for now"
  pub="$(cfg CREA_PUBLIC_BASE_URL)"
  case "$pub" in
    https://*) : ;;
    http://*)  die "CREA_PUBLIC_BASE_URL must be https:// (Twilio requires it) — got: $pub" ;;
    *)         die "CREA_PUBLIC_BASE_URL doesn't look like a URL — got: $pub" ;;
  esac
  case "$pub" in */) die "CREA_PUBLIC_BASE_URL shouldn't end in / — got: $pub" ;; esac
fi
ok "Docker is running; config.env has the required values"

b "2/9  encryption key"
if [ ! -s "$KEYFILE" ]; then ( umask 077; openssl rand -hex 24 > "$KEYFILE" )
  ok "generated deploy/.n8n-key — BACK THIS UP (losing it makes saved credentials unreadable)"
else ok "using existing deploy/.n8n-key"; fi

b "3/9  fill workflows from config.env"
./fill-config.sh config.env workflows >/dev/null || die "fill-config failed — a token in the workflows has no matching line in config.env"
rm -rf "$DEPLOY/_filled"; mkdir -p "$DEPLOY/_filled"
cp workflows/_filled/*.json "$DEPLOY/_filled/"
build_clean_env
ok "workflows filled → deploy/_filled/ ; clean env → deploy/.env"

b "4/9  pull + start the stack (first run downloads ~5 GB — be patient)"
compose pull -q 2>/dev/null || warn "pull had warnings — continuing"
compose up -d
wait_http "$(N8N_URL)/healthz" "n8n up" 120
compose exec -T vault-api wget -qO- http://localhost:5692/health >/dev/null 2>&1 && ok "vault API up" || warn "vault API health inconclusive — ./go-live.sh --logs vault-api"

b "5/9  credentials"
CREDS="$DEPLOY/_filled/.creds.json"
trap 'rm -f "$CREDS"' EXIT
python3 - "$CREDS" "$(cfg CREA_OMNIROUTE_KEY)" "$(cfg CREA_ACUITY_USER_ID)" "$(cfg CREA_ACUITY_API_KEY)" "$(cfg CREA_HIGGSFIELD_API_KEY)" "$(cfg CREA_OMNIROUTE_KEY_2)" <<'PY'
import json,sys
out,okey,auid,akey,hkey,okey2=sys.argv[1:7]
c=[{"id":"creaomniroutecred","name":"CREA OmniRoute","type":"httpHeaderAuth",
    "data":{"name":"Authorization","value":"Bearer "+okey}}]
# always create cred 2 so the fallback node has a valid credential; = cred 1 unless a separate key is given
c.append({"id":"creaomniroutecred2","name":"CREA OmniRoute 2","type":"httpHeaderAuth",
    "data":{"name":"Authorization","value":"Bearer "+(okey2 or okey)}})
if auid and akey: c.append({"id":"creaacuitycred","name":"CREA Acuity","type":"httpBasicAuth",
    "data":{"user":auid,"password":akey}})
if hkey: c.append({"id":"creahiggscred","name":"CREA Higgsfield","type":"httpHeaderAuth",
    "data":{"name":"X-Api-Key","value":hkey}})
json.dump(c,open(out,"w"))
PY
n8n_cli import:credentials --input=/workflows/.creds.json >/dev/null 2>&1 && ok "credentials loaded into n8n" \
  || warn "credential import returned an error — ./go-live.sh --logs n8n"
rm -f "$CREDS"; trap - EXIT

b "6/9  import + bind + activate workflows"
n8n_cli import:workflow --separate --input=/workflows >/dev/null 2>&1 || warn "workflow import reported an issue — ./go-live.sh --logs n8n"
# bind the credentials to the auth nodes so there's nothing to click in the UI
python3 - "$DEPLOY/_filled" <<'PY'
import json,glob,re
for f in glob.glob(__import__('sys').argv[1]+"/crea-*.json"):
    o=json.load(open(f)); ch=False
    for n in o.get("nodes",[]):
        p=n.get("parameters",{})
        if p.get("authentication")!="genericCredentialType": continue
        gt=p.get("genericAuthType"); nm=(p.get("url","")+" "+n["name"]).lower()
        if "higgsfield" in nm: cid,cname=("creahiggscred","CREA Higgsfield")
        elif "fallback" in nm: cid,cname=("creaomniroutecred2","CREA OmniRoute 2")
        elif gt=="httpHeaderAuth": cid,cname=("creaomniroutecred","CREA OmniRoute")
        elif gt=="httpBasicAuth": cid,cname=("creaacuitycred","CREA Acuity")
        else: cid=None
        if cid: n["credentials"]={gt:{"id":cid,"name":cname}}; ch=True
    if ch: json.dump(o,open(f,"w"),indent=2)
PY
n8n_cli import:workflow --separate --input=/workflows >/dev/null 2>&1 || true
CORE="creaerrorhandler creawasend creallm creawainbound creabookingagent creaaiassistant creabooking creamsgclient creaselfcheck creamondayinvoice creacardpipeline"
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
if [ -n "$(cfg CREA_TWILIO_ACCOUNT_SID)" ]; then n8n_cli update:workflow --id=creavoiceinbound --active=true >/dev/null 2>&1 || true; on="$on + phone booking"
else n8n_cli update:workflow --id=creavoiceinbound --active=false >/dev/null 2>&1 || true; fi
compose restart n8n >/dev/null
wait_http "$(N8N_URL)/healthz" "n8n restarted (webhooks registered)" 120
ok "activated: $on + LLM circuit breaker + self-check"

b "7/9  host watchdog"
"$0" --watchdog >/dev/null 2>&1 && ok "watchdog installed (checks the stack every $(cfg CREA_WATCHDOG_MINUTES || echo 5) min)" \
  || warn "watchdog install skipped — run ./go-live.sh --watchdog once the stack is up"

fi   # end MODE=full

# ---------------------------------------------------------------------------
b "8/9  WhatsApp pairing"
[ -f "$ENVCLEAN" ] || build_clean_env
K="$(cfg CREA_WAHA_API_KEY)"; W="$(WAHA_URL)"
curl -sf -X POST "$W/api/sessions" -H "X-Api-Key: $K" -H 'content-type: application/json' -d '{"name":"default","start":true}' >/dev/null 2>&1 \
 || curl -sf -X POST "$W/api/sessions/default/start" -H "X-Api-Key: $K" >/dev/null 2>&1 || true
sleep 2
SESS=$(curl -sf -H "X-Api-Key: $K" "$W/api/sessions/default" 2>/dev/null || echo '{}')
STATUS=$(printf '%s' "$SESS" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("status","UNKNOWN"))' 2>/dev/null || echo UNKNOWN)
if [ "$STATUS" = "WORKING" ]; then
  ok "WhatsApp is paired and connected. Nothing to scan."
  # is CREA on the owner's own number? persist it so crea-01 stops relaying every message.
  WANT=$(printf '%s' "$SESS" | OWDIG="$(cfg CREA_OWNER_WA | tr -cd '0-9')" python3 -c '
import sys,json,re,os
d=json.load(sys.stdin); m=d.get("me") or {}
me=re.sub(r"\D","",str(m.get("id") or ""))
ow=os.environ.get("OWDIG","")
print("true" if me and ow and (me==ow or me.endswith(ow) or ow.endswith(me)) else "false")' 2>/dev/null || echo "")
  if [ -n "$WANT" ]; then
    HAVE=$(cfg CREA_SHARED_NUMBER)
    if [ "$HAVE" != "$WANT" ]; then
      if grep -q '^CREA_SHARED_NUMBER=' config.env; then
        sed -i.bak "s|^CREA_SHARED_NUMBER=.*|CREA_SHARED_NUMBER=$WANT|" config.env && rm -f config.env.bak
      else printf 'CREA_SHARED_NUMBER=%s\n' "$WANT" >> config.env; fi
      [ "$WANT" = "true" ] && ok "CREA is on your own number — set CREA_SHARED_NUMBER=true (alerts go to your 'Message Yourself' chat)" \
                           || ok "CREA is on a separate number — set CREA_SHARED_NUMBER=false"
      ./fill-config.sh config.env workflows >/dev/null 2>&1 && cp workflows/_filled/*.json "$DEPLOY/_filled/" 2>/dev/null
      n8n_cli import:workflow --separate --input=/workflows >/dev/null 2>&1 || true
      compose restart n8n >/dev/null 2>&1 || true
      wait_http "$(N8N_URL)/healthz" "n8n reloaded with the number setting" 90
    fi
  fi
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

b "9/9  self-test — a real message through the assistant"
T="61400000000"
curl -sf -X POST "$(N8N_URL)/webhook/crea-wa-inbound" -H 'content-type: application/json' \
  -d "{\"event\":\"message\",\"session\":\"default\",\"payload\":{\"id\":\"selftest-$(date +%s)\",\"from\":\"${T}@c.us\",\"body\":\"how much for a listing video?\",\"fromMe\":false,\"type\":\"chat\"}}" >/dev/null \
  && ok "crea-01 accepted the test message" || warn "crea-01 did not accept it — ./go-live.sh --logs n8n"
sleep 6
S=$(compose exec -T vault-api wget -qO- "http://localhost:5692/state?key=${T}" 2>/dev/null || echo '{}')
echo "  assistant state for the test number:"; echo "  $S"
case "$S" in *'"mode": "ai"'*|*'"mode":"ai"'*) ok "the assistant handled it — CREA is live" ;;
  *) warn "no assistant state yet — send a real WhatsApp to the bot and check ./go-live.sh --logs n8n" ;; esac
echo
echo "  Watch it work:  open $(N8N_URL)  → any CREA workflow → Executions"
echo "  Day to day:     ./go-live.sh --status | --qr | --logs | --stop"
