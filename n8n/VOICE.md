# VOICE.md — phone bookings (optional, on top of WhatsApp)

Same assistant, same brief, same hold→confirm→Acuity flow as [BOOKING.md](BOOKING.md) — just
answering a phone call instead of a WhatsApp message. Leave `CREA_TWILIO_ACCOUNT_SID` blank in
`config.env` and none of this runs; nothing else about CREA changes.

A customer who calls and later texts (or vice versa, same number) shares one brief — CREA
recognises them either way.

---

## Why this needs one extra piece WhatsApp doesn't

WhatsApp works because WAHA polls out to WhatsApp's servers — n8n never needs to be reachable
from the internet. A phone call is the opposite: Twilio has to reach n8n itself, the instant
someone calls, so `go-live.sh` starts a small `cloudflared` container that opens a secure
outbound tunnel from this Mac to Cloudflare — no port-forwarding, no exposed IP, no static
address needed on your home network.

## One-time setup

1. **Twilio** — console.twilio.com → Account → copy the **Account SID** and **Auth Token**.
   Buy a Voice-capable number (Phone Numbers → Buy a number). Put the number's digits in
   `CREA_TWILIO_NUMBER`.
2. **Cloudflare Tunnel** (free) — a Cloudflare account with a domain you control:
   - Zero Trust → Networks → Tunnels → **Create a tunnel** → Docker → copy the token it gives
     you into `CREA_CF_TUNNEL_TOKEN`.
   - Same screen → **Public Hostname** → pick a subdomain (e.g. `crea-voice.yourdomain.com`) →
     Service = `HTTP` → `n8n:5678`.
   - Put `https://crea-voice.yourdomain.com` in `CREA_PUBLIC_BASE_URL` (no trailing slash).
3. `./go-live.sh` — brings up `cloudflared` automatically once `CREA_CF_TUNNEL_TOKEN` is set
   (it's inert otherwise) and activates the voice workflow.
4. **`./go-live.sh --test-voice`** — run this before touching Twilio's dashboard. It builds a
   real, correctly-signed test request and posts it straight to n8n locally — no real call, no
   Twilio balance spent, nothing that can go wrong on your phone bill. A green `✓` means
   signature verification, the blocklist/flood/handoff checks, and the greeting are all
   working. A red `✗` tells you exactly which value in `config.env` is wrong — fix it and run
   it again; it's safe to run as many times as you need. **Do not do step 5 until this is green.**
5. Back in Twilio: the number's **"A call comes in"** webhook →
   `{{CREA_PUBLIC_BASE_URL}}/webhook/crea-voice-inbound`, HTTP POST. Now call the number for
   real — this is the one thing `--test-voice` can't check for you (whether Cloudflare and
   Twilio are actually configured to reach this Mac), so it's worth one real call to confirm.

## What happens on a call

1. **First turn** — a fixed greeting ("Thanks for calling {business}. Are you after photos,
   video, or both, or something else?"), no model call — fast, and free.
2. **Every turn after** — Twilio transcribes what the customer says and posts it to n8n; the
   same brain that runs WhatsApp answers, one question at a time, exactly as in BOOKING.md.
   The reply comes back as speech (Twilio `<Say>`, voice/accent set by `CREA_VOICE_NAME` /
   `CREA_VOICE_LANG` — default an Australian voice).
3. On readback + yes, or if it needs you, CREA says so and hangs up — you get the same
   WhatsApp hold-booking alert as always.

## Security

Every request is checked against Twilio's signature (HMAC over `CREA_PUBLIC_BASE_URL` +
the request, using `CREA_TWILIO_AUTH_TOKEN`) before anything runs — an unsigned or spoofed
request gets a `<Reject/>`, nothing reaches the assistant. This is the one part of CREA that's
reachable from the open internet, so don't leave `CREA_TWILIO_AUTH_TOKEN` blank once
`CREA_TWILIO_ACCOUNT_SID` is set.

## Known limitation (v1)

If Twilio hears silence and times out mid-conversation, the call re-enters at the greeting
rather than resuming exactly where it left off — the brief itself isn't lost (it's saved after
every turn), but the customer hears "Thanks for calling…" again rather than a
"sorry, didn't catch that" reprompt. Cosmetic, not a booking-accuracy issue.
