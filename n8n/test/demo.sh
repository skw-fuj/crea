#!/usr/bin/env bash
# One command to reproduce the verification run against the LOCAL n8n.
#   ./demo.sh          run the full suite
#   ./demo.sh revert   put n8n back to delivery state (clean templates, inactive)
set -euo pipefail
cd "$(dirname "$0")/.."
N8N=http://localhost:5678

activate(){ for id in "$@"; do n8n update:workflow --id="$id" --active=true >/dev/null 2>&1 || true; done; }
restart(){ lbl=$(launchctl list 2>/dev/null | awk 'tolower($3) ~ /n8n/ {print $3; exit}'); [ -n "$lbl" ] && launchctl kickstart -k "gui/$(id -u)/$lbl" >/dev/null 2>&1 || true
  for i in $(seq 1 30); do [ "$(curl -s -o /dev/null -w '%{http_code}' $N8N/healthz)" = "200" ] && break; sleep 2; done
  # healthz is up before the webhooks + sub-workflow registry are warm. Poll the real
  # inbound webhook with a throwaway message until it round-trips, then settle.
  for i in $(seq 1 20); do
    code=$(curl -s -o /dev/null -w '%{http_code}' -X POST $N8N/webhook/crea-wa-inbound \
      -H 'content-type: application/json' \
      -d '{"event":"message","session":"default","payload":{"id":"warmup","from":"60000000000@c.us","body":"warmup","fromMe":true,"type":"chat"}}')
    [ "$code" = "200" ] && break; sleep 2
  done; sleep 5; }

if [ "${1:-}" = "revert" ]; then
  echo "reverting to delivery state…"
  n8n import:workflow --separate --input=workflows/ >/dev/null 2>&1   # unfilled templates, import deactivates
  for id in t-crea04 t-crea05 t-crea07 t-crea08 t-crea10; do n8n update:workflow --id=$id --active=false >/dev/null 2>&1 || true; done
  pkill -f "test/mock-services.js" 2>/dev/null || true
  restart
  echo "done. CREA workflows are the clean templates, inactive. mock stopped."
  exit 0
fi

echo "1/4  mock services…"
pkill -9 -f "test/mock-services.js" 2>/dev/null || true; sleep 1
CREA_KB_FILE=$PWD/test/crea-knowledge.test.md node test/mock-services.js > /tmp/crea-mock.log 2>&1 &
disown; sleep 2

curl -sf localhost:5699/waha/api/version >/dev/null && echo "     up on :5699"

echo "2/4  fill test config + import…"
./fill-config.sh test/test.config.env workflows >/dev/null
python3 test/attach-test-creds.py workflows/_filled >/dev/null
n8n import:workflow --separate --input=workflows/_filled/ >/dev/null 2>&1

echo "3/4  activate + restart n8n…"
activate creawasend creawainbound creabookingagent creaaiassistant creaacuityintake creacardpipeline \
         creashootconfirm creachasenoreply creamondayinvoice creamorningbrief creaerrorhandler creaapifyleads
restart

echo "4/4  drive traffic…"
curl -s localhost:5699/_reset >/dev/null
msg(){ curl -s -o /dev/null -X POST $N8N/webhook/crea-wa-inbound -H 'content-type: application/json' \
  -d "{\"event\":\"message\",\"session\":\"default\",\"payload\":{\"id\":\"$1\",\"from\":\"$2@c.us\",\"body\":\"$3\",\"fromMe\":false,\"type\":\"chat\"}}"; }

# --- AI assistant (default handler): real model, ~25s/turn ---
# State starts empty: the mock's /vault/state returns {} for a new key, so no seed needed.
A=61400556677
msg ai1 $A "Hi, how much is a listing video for a 3 bedroom house?";      sleep 25
msg ai2 $A "Its 40 Awaba St, Mosman. Are you free this Saturday?";        sleep 25
msg ai3 $A "Lets do it. Owner home, side gate open.";                     sleep 25

# --- deterministic qualifier (set CREA_BOOKING_WORKFLOW_ID=creabookingagent to route here) ---
F=61400778899
for m in "d1|Hi, I need a video shot for a new listing" "d2|Video and a 3D tour" \
         "d3|4 bedroom house, about 280sqm, 18 Hillcrest Ave Mosman" "d4|This Saturday at 10am" \
         "d5|Lockbox code 4471, owner will be home"; do
  msg "${m%%|*}" "$F" "${m#*|}"; sleep 2.5
done
curl -s -o /dev/null -X POST $N8N/webhook/crea-acuity -H 'content-type: application/json' -d '{"action":"appointment.scheduled","id":"9042"}'; sleep 3
curl -s -o /dev/null -X POST $N8N/webhook/crea-card -H 'content-type: application/json' \
  -d '{"cardId":"CARD-DEMO","files":[{"name":"MVI_001.MP4","capturedAt":"2026-09-08T08:05:00Z"},{"name":"MVI_002.MP4","capturedAt":"2026-09-08T08:31:00Z"},{"name":"MVI_010.MP4","capturedAt":"2026-09-08T13:15:00Z"},{"name":"MVI_011.MP4","capturedAt":"2026-09-08T13:44:00Z"}]}'
sleep 3

echo
echo "── WhatsApp CREA sent ──"
curl -s localhost:5699/_calls | python3 -c "import sys,json;[print('  →',c['payload'].get('chatId'),'|',c['payload'].get('text','').split(chr(10))[0][:80]) for c in json.load(sys.stdin) if c['path']=='/waha/api/sendText']"
echo
echo "open $N8N  →  any CREA workflow  →  Executions   to see the runs."
