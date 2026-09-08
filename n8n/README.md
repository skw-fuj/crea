# CREA — n8n Hands Layer

The integration layer for CREA: a **WhatsApp AI booking assistant** plus the shoot-ops
automations (Acuity intake, shoot confirmations, chase, card pipeline, invoicing, morning
briefing, listing leads). n8n runs the workflows; the brain (OmniRoute) and memory (the
vault) sit outside and are reached over HTTP.

Verified end-to-end against a live model on n8n 2.30.7 — see `TEST-REPORT.md` and
`test/run-report.html`.

---

## Setting it up

**If you're Connell:** read **`HANDOVER.md`** — a 10-minute gather list, then one prompt you
paste into Claude Code that does the whole install.

**Manually:**

```bash
cd n8n
cp config.example.env config.env      # fill: CREA_OWNER_WA, CREA_WAHA_API_KEY, CREA_OMNIROUTE_URL/KEY
./go-live.sh
```

`go-live.sh` starts the vault API, fills + imports + activates every workflow, restarts n8n,
and prints the 3 steps only you can do (WhatsApp QR, credential selection, Acuity webhook).
`./go-live.sh --status` shows what's running · `--stop` stops the vault API.

Full detail — vault API contract, credential list, per-workflow test order — in `SETUP.md`.

---

## What's here

| Path | |
|---|---|
| `workflows/` | 11 workflows (see table below) |
| `vault-api/server.js` | the memory + job store — real service, no dependencies. `/knowledge`, `/availability`, and the job/lead/inbox/shoots/invoice notes (written to disk as JSON + markdown) |
| `knowledge/crea-knowledge.md` | what the assistant answers from. Ships usable; add real prices to one table when ready |
| `waha/` | WhatsApp HTTP API gateway (Docker) — unofficial personal-number pairing per the manual |
| `facet-template/` | the same shape generalised for any other assistant — `NEW-FACET.md` |
| `config.example.env` | every account/key — the only file you edit |
| `go-live.sh` · `fill-config.sh` | deploy + config substitution |
| `HANDOVER.md` · `SETUP.md` · `TEST-REPORT.md` | client handover, full setup, test evidence |
| `test/` | `mock-services.js` + `demo.sh` — reproduce the verification run offline |

## The workflows

| Workflow | Trigger | Does |
|---|---|---|
| `crea-wa-send` | called | the one place WhatsApp is sent — swap the gateway here only |
| `crea-01-whatsapp-inbound` | WAHA webhook | routes booking chats to the assistant, everything else to the owner |
| `crea-02b-ai-assistant` | (booking chat, default) | answers from the knowledge base, checks availability read-only (never confirms a slot), captures the shoot brief conversationally, hands the owner a quote-ready enquiry |
| `crea-02-booking-agent` | AI fallback | fixed 5-question qualifier — takes over automatically if OmniRoute is unreachable |
| `crea-03-acuity-intake` | Acuity webhook | new booking → job note + owner ping |
| `crea-04-shoot-confirmations` | 17:00 daily | WhatsApp-confirm tomorrow's shoots |
| `crea-05-chase-noreply` | 09/12/15 daily | nudge unconfirmed clients (max 2), then tell the owner to call |
| `crea-06-card-pipeline` | card-detect webhook | split footage by capture gap → Drive folders → **human gate** → Higgsfield → notify editor |
| `crea-07-monday-invoicing` | Mon 09:00 | draft invoices for completed jobs — **never sends** |
| `crea-08-morning-briefing` | 06:30 daily | "what to focus on" over WhatsApp |
| `crea-10-apify-leads` | 07:00 daily | new listing leads → digest |

`crea-01` routes to whichever `CREA_BOOKING_WORKFLOW_ID` names — `creaaiassistant` (default)
or `creabookingagent`. An in-progress conversation stays with the same handler.

## Design rules

- Every workflow is a MACRO with named atomic steps (`meta.trisAtoms`); sub-workflows keep it decomposed.
- Three-layer error handling: node `retryOnFail` + `onError` · a Global Error Handler as the workflow's `errorWorkflow` · a layer-3 alert.
- **Placeholders only** — no secrets in the JSON. `fill-config.sh` substitutes `config.env`.
- Conversation state + transcript live in an external store, **never model memory**.
- The assistant answers **only** from `knowledge/crea-knowledge.md` and never invents a price, a time, or a policy.
- Money and outbound publishes are human-gated (invoices draft only; card pipeline waits for the owner's OK).
