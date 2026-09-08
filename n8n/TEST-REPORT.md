# CREA n8n — Test Report

**Run:** 2026-09-08, against the live local n8n **2.30.7** (`launchd com.tris.n8n`, `localhost:5678`)
and the real TRIS OS state store (`:5691`). External SaaS (WAHA, Acuity, OmniRoute, Apify,
Higgsfield, the vault API) stood in by a local mock (`test/mock-services.js`, `:5699`) that
captures every call. Scheduled workflows were exercised via webhook-triggered test copies.

## Result — all 10 workflows pass end-to-end

| Workflow | Executions | Evidence |
|---|---|---|
| `crea-01` WhatsApp Inbound | 7 ✓ | routed booking-intent → agent; non-booking → `POST /vault/inbox` + owner ping; `fromMe` ignored; dedupe by msg id |
| `crea-02` Booking Agent | 5 ✓ | 5-turn conversation greeting→service→property→scheduling→access→**close**; brief `POST /vault/lead` with all 4 answers; state persisted in the real store |
| `crea-wa-send` | 16 ✓ | every WhatsApp send in the suite went through this one node |
| `crea-03` Acuity Intake | 3 ✓ | webhook → `GET /acuity/appointments/9042` → `POST /vault/job` → owner WhatsApp |
| `crea-04` Shoot Confirmations | 3 ✓ | pulled tomorrow's appts → 2 confirmation WhatsApps → 2 × `POST /vault/pending` |
| `crea-05` Chase Non-Replies | 2 ✓ | read `/vault/pending` → chase the overdue one → `POST /vault/pending/update` (chases:1); 2-nudge row escalates to owner |
| `crea-06` Card Pipeline | 1 **waiting** ✓ | 4 files gap-split into **2 shoots** (06:00–06:20 / 12:10–12:30) → 2 × `POST /vault/shoots` → **paused at the human gate** (correct — resumes on owner approval) |
| `crea-07` Monday Invoicing | 2 ✓ | selected 2 completed-unpaid jobs → 2 × `POST /vault/invoice-draft` → 2 × `/vault/job/invoiced` (draft) → owner summary "2 invoice draft(s) ready ($770 total)" — **never sends** |
| `crea-08` Morning Briefing | 2 ✓ | today's shoots + tracker counts → `POST /omniroute` → briefing WhatsApp to owner |
| `crea-10` Apify Leads | 2 ✓ | `POST /apify/.../run-sync-get-dataset-items` → deduped 2 scraped against 1 known → `POST /vault/leads` (1 new) → digest WhatsApp |

**Totals for one suite run:** 13 WhatsApp messages sent · 13 vault writes · Acuity/Apify/OmniRoute
all called · state machine reached `close` with the full brief.

## Bugs found by testing and fixed

1. **`$json` after an HTTP node referred to the response, not the parsed message** — `crea-01`
   "Notify Owner" showed `WhatsApp from undefined`. Fixed to `$node['Parse & Guard'].json`.
   Same class fixed in `crea-06` (Record Shoots / Ask Owner) and `crea-07` (Mark Invoiced).
2. **`={{ '{{TOKEN}}' }}/suffix` doesn't concatenate the suffix in n8n** — the URL became just
   the token value, so `crea-06`'s vault call went nowhere (swallowed by `continueErrorOutput`).
   Replaced with plain `{{TOKEN}}/suffix` (literal after `fill-config`) across **27 spots** in
   all workflows + the facet template.
3. **Google Calendar node validation-blocks the whole workflow** when no credential exists
   ("Not a valid Google Calendar ID"). `onError` doesn't catch pre-execution validation.
   → the job **tracker moved to the vault API** (`/pending`, `/jobs?filter=billable`,
   `/job/invoiced`, `/leads`), consistent with CREA's "vault is memory"; Calendar + Drive are
   now **disabled by default**, opt-in once `CREA Google` is connected.
4. **Silent-drop on `continueErrorOutput` with an unwired error output** — a failed enrichment
   node killed the chain and still reported "success". Google/enrichment nodes changed to
   `continueRegularOutput` so the main path continues.
5. **Reading a multi-item HTTP array response** — `Array.isArray(items[0].json)` is false when
   n8n has already split the array into items. Fixed `crea-04/08/10` to read
   `$('Node').all().map(i => i.json)`.
6. **Fan-in race** — `crea-03/08` had two parallel branches into one code node that ran before
   the second branch finished (`referenced node not executed`). Linearised the chains.
7. **Reference to a disabled node throws** — `crea-06` Record Shoots referenced the disabled
   Drive node. Removed the reference; documented how to re-add it when Drive is enabled.

## Not exercised (needs real accounts / production n8n)

- **WhatsApp delivery through a real WAHA container** — the send node is proven; only the WAHA
  endpoint was mocked.
- **Card-pipeline resume** — the gate pause is proven; the resume webhook wasn't hit because
  n8n was restarted repeatedly during testing (which drops in-memory wait timers). In
  production the owner taps the real link and it resumes into Higgsfield + editor notify.
- **Google Calendar / Drive** — disabled by default; enable after connecting `CREA Google`.
- **Real Acuity / Apify / Higgsfield APIs** — mocked; the request shapes match their docs but
  confirm against a live account (Higgsfield especially — see SETUP §9).

## How to reproduce

```bash
cd ~/.claude/n8n/crea
node test/mock-services.js &                 # :5699, captures calls at /_calls
./fill-config.sh test/test.config.env workflows
n8n import:workflow --separate --input=workflows/_filled/
# activate creawasend, creawainbound, creabookingagent, creaacuityintake, creacardpipeline + restart n8n
curl -sX POST localhost:5678/webhook/crea-wa-inbound -H 'content-type: application/json' \
  -d '{"event":"message","session":"default","payload":{"from":"61400000001@c.us","body":"need a listing video","fromMe":false,"type":"chat"}}'
curl -s localhost:5699/_calls | python3 -m json.tool
```
