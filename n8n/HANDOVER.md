# CREA v2 — handover

Hi Connell — this is CREA's automation layer: a WhatsApp assistant that answers booking
questions, quotes your prices, checks your calendar, captures the shoot brief, and hands you
a quote-ready enquiry — plus the shoot-ops automations (new-booking alerts, confirmations,
chase-ups, the card→video pipeline, Monday invoicing, a morning briefing, listing leads).

## What to do

**Follow `INSTALL.md` top to bottom.** It's the whole runbook — about an hour, most of it
creating a couple of free accounts and waiting for downloads. The short version:

1. Install **Docker Desktop** and **Obsidian** (+ Obsidian Sync). Set Docker to start on login.
2. Get **a WhatsApp number for the bot** (a cheap spare SIM is ideal) and **a free Groq API
   key** (console.groq.com). Optionally your **Acuity** User ID + API Key.
3. Unzip this folder somewhere permanent, `cp config.example.env config.env`, fill the lines
   marked `◀ REQUIRED`.
4. `./go-live.sh` — brings the whole stack up and wires everything.
5. `./go-live.sh --qr` — scan the QR once with the bot phone.
6. `./go-live.sh --test` — proves it's live.
7. Put your real prices in `knowledge/crea-knowledge.md`.

That's it. After a reboot it all comes back on its own.

## The two things only you can do
- **Scan the WhatsApp QR** (step 5) — WhatsApp won't let software do this.
- **Fill in your prices and business details** in `knowledge/crea-knowledge.md` — the
  assistant only says what's in that file, and never invents a number.

## If you'd rather have Claude Code do the setup

If you use Claude Code, open it in the unzipped folder and paste this:

> Read INSTALL.md. I've installed Docker Desktop and it's running. Here are my values:
> WhatsApp bot number = `<digits>`, Groq API key = `<gsk_...>`, Acuity User ID = `<...>`,
> Acuity API Key = `<...>`, my WhatsApp = `<digits>`, Obsidian vault folder for CREA data =
> `<absolute path>`.
> Do everything in INSTALL.md Part C: write config.env, run ./go-live.sh, and report back
> the QR instructions and the result of ./go-live.sh --test. Don't scan the QR — that's mine.

It still can't scan the QR or invent your prices — those stay with you.

## Support
Everything is in `INSTALL.md` (install + troubleshooting), `SETUP.md` (how the workflows
fit together), `DATA-AND-BACKUP.md` (keeping your bookings safe), `TEST-REPORT.md` (what was
verified).
