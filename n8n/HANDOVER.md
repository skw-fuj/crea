# CREA v3.1 — handover

Hi Connell — this is CREA's automation layer: a WhatsApp assistant that answers booking
questions, asks about the property, checks your calendar, reads the booking back to the
customer, and — if you want — holds it for your one-tap OK before it goes into Acuity.
Plus the shoot-ops automations (new-booking alerts, confirmations, chase-ups, the
card→video pipeline, Monday invoicing, a morning briefing, listing leads).

It also writes every job, client and lead into your CREA vault in CREA's own format, so
the voice assistant ("hey CREA, when's my next booking?") works off the same memory.

## What to do

**Follow `INSTALL.md` top to bottom.** It's the whole runbook — about an hour, most of it
creating a couple of free accounts and waiting for downloads. The short version:

1. Install **Docker Desktop** and **Obsidian** (+ Obsidian Sync). Set Docker to start on login.
2. Get **a WhatsApp number for the bot** (a cheap spare SIM is ideal — or use your own, see
   `BOOKING.md`) and **a free Groq API key** (console.groq.com). Optionally your **Acuity**
   User ID + API Key.
3. Unzip this folder somewhere permanent, `cp config.example.env config.env`, fill the lines
   marked `◀ REQUIRED`.
4. **Read `BOOKING.md`** and make the two calls it describes (does CREA quote a price; what
   happens when a customer confirms). The defaults are safe — CREA just hands you the enquiry.
5. `./go-live.sh` — brings the whole stack up and wires everything.
6. `./go-live.sh --qr` — scan the QR once with the bot phone.
7. `./go-live.sh --test` — proves it's live.
8. Put your real prices in `knowledge/crea-knowledge.md` (and `knowledge/pricing.json` if you
   chose the calculator in `BOOKING.md`).

That's it. After a reboot it all comes back on its own.

## The two things only you can do
- **Scan the WhatsApp QR** (step 6) — WhatsApp won't let software do this.
- **Fill in your prices and business details** in `knowledge/crea-knowledge.md` — the
  assistant only says what's in that file, and never invents a number.

## Your setup interview (what Claude Code / the install will ask you)

1. **Price in chat?** never (safe default) · a rough range · a real estimate from a formula
2. **Your package prices** — and if a real estimate, your per-bedroom / size / add-on rules
3. **Read-back** — with the price, or booking details only (you quote after)
4. **On confirm** — hold it for your one-tap CONFIRM, or just hand you the lead (v3 behaviour)
5. **Acuity appointment-type ID** — Acuity → the type's page → the number in the URL
6. **The number CREA runs on** — its own spare SIM, or your own (shared)

All six live in `config.env`; change any and re-run `./go-live.sh`.

## Optional — take bookings by phone too

Same assistant, answering calls as well as WhatsApp. **Entirely optional** — skip this whole
section and everything above still works exactly as described. If you want it:

1. Read `VOICE.md` — it walks through the two accounts you need (Twilio, Cloudflare — both
   free to set up, Twilio charges per call once live) and what to put in `config.env`.
2. `./go-live.sh` again — it activates the phone line automatically once those values are filled.
3. **`./go-live.sh --test-voice`** — proves the whole phone pipeline works *before* you dial
   anything. It doesn't make a real call and doesn't touch your Twilio balance; it just checks
   that everything is wired correctly. **If this doesn't print a green ✓, do not point your
   Twilio number at it yet** — fix whatever it tells you first, then run it again. It's safe to
   run as many times as you like.
4. Once that's green: point your Twilio number's webhook at the URL `VOICE.md` gives you, and
   make one real test call. That's the only step nothing here can do for you — same as scanning
   the WhatsApp QR.

## If you'd rather have Claude Code do the setup

If you use Claude Code, open it in the unzipped folder and paste this:

> Read INSTALL.md and BOOKING.md. I've installed Docker Desktop and it's running. Interview
> me for the six setup questions in HANDOVER.md, then write config.env (and pricing.json if
> needed), run ./go-live.sh, and report back the QR instructions and the result of
> ./go-live.sh --test. If I also want phone bookings, read VOICE.md, interview me for the
> Twilio/Cloudflare values, then run ./go-live.sh --test-voice and don't let me point a real
> Twilio number at it until that's green. Don't scan the QR — that's mine.

It still can't scan the QR, make the Twilio/Cloudflare accounts, or invent your prices —
those stay with you.

## Support
- `INSTALL.md` — one-time setup + troubleshooting
- `BOOKING.md` — the two booking decisions + `knowledge/pricing.json`
- `VOICE.md` — optional phone bookings (Twilio + Cloudflare Tunnel setup, `--test-voice`)
- `COUNTERMEASURES.md` — how CREA handles outages and abuse (nothing to configure — good to skim)
- `OPERATIONS.md` — everything after that: changing prices/wording, config, updates, new
  features, backups, disaster recovery
- `DATA-AND-BACKUP.md` — the full Obsidian + storage + sync guide
- `SETUP.md` — how the workflows fit together · `TEST-REPORT.md` — what was verified
