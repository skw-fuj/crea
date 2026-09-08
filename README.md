# CREA — Cfilms Real Estate Adviser

An always-on voice assistant for a real estate photography and video business.
Answers out loud, tracks the job pipeline, catches bookings from calls and
WhatsApp, and runs the SD-card → Drive → Higgsfield media pipeline.

## Install

On a Mac, open Terminal and run:

```
curl -fsSL https://raw.githubusercontent.com/skw-fuj/crea/main/install.sh | bash
```

That installs everything — runtimes, command-line tools, speech models, the
background services and the integrations. It takes about 20 minutes and asks
you three optional questions near the end.

Re-running it is safe: anything already installed is left alone.

## Automations (n8n)

The WhatsApp booking assistant and the shoot-ops automations live in [`n8n/`](n8n/).
They're optional — CREA's voice + vault work without them. To turn them on, see
[`n8n/HANDOVER.md`](n8n/HANDOVER.md) (a short gather list, then one prompt you paste
into Claude Code) or [`n8n/README.md`](n8n/README.md).

## Manual

Full setup and operating manual: [docs/MANUAL.md](docs/MANUAL.md)

## Using it

```
crea ask "what have I got on this week?"   one question, spoken back
crea status                                honest health of every component
crea listen                                the always-on "Hey CREA" loop
crea connect                               add an account you skipped
```

## Requirements

- macOS on Apple Silicon
- **16 GB of memory** — 8 GB works but the voice stutters
- ~12 GB free disk

## Cost

$0/month. Speech in and out run on the machine; the thinking is routed to
free model tiers. A paid voice or a paid model is a one-line settings change.
