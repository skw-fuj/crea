# CREA — n8n Hands Layer · Setup

The n8n half of CREA (per the [Build Manual](https://skw-fuj.github.io/crea/) §"Technical
Architecture" → *Hands Layer*). Deterministic workflows; brain (Hermes/OmniRoute) and memory
(Obsidian vault) stay outside n8n and are reached over HTTP.

Built and structurally verified against n8n **2.30.7** in the local instance. Every
account-specific value is a `{{CREA_*}}` token resolved by `fill-config.sh` — nothing is
hardcoded.

---

## Handing it to the client

`HANDOVER.md` is written for Connell — a 10-minute gather list, then one prompt he pastes
into his own Claude Code that does the whole setup. Give him that file (it ships in `repo/n8n/`).

## Ship it — one command

```bash
cd ~/.claude/n8n/crea
cp config.example.env config.env    # edit: CREA_OWNER_WA, CREA_WAHA_API_KEY, CREA_OMNIROUTE_URL/KEY
./go-live.sh
```

`go-live.sh` starts the **vault API** (`vault-api/server.js` — real service, no deps: knowledge
from `knowledge/crea-knowledge.md`, availability from Acuity, job/lead/inbox notes written to
`vault-api/data/` as JSON + markdown), fills the workflows, imports and activates them, and
restarts n8n. It then prints the 3 things only you can do (they need your accounts):

  a. **WhatsApp** — `cd waha && docker compose up -d`, scan the QR at `localhost:3001`
  b. **Credentials** in n8n — select `CREA OmniRoute`, `CREA Acuity`, `CREA Higgsfield`
  c. **Acuity webhook** → `…/webhook/crea-acuity`

`./go-live.sh --status` shows what's up · `--stop` stops the vault API.
Verified end-to-end 2026-09-08: real vault API + shipped knowledge file + a live model —
a full booking conversation captured the brief and wrote the lead note to disk.

---

## 0. What's in here

```
crea/
  config.example.env          all accounts / keys / endpoints — the ONLY thing you edit
  fill-config.sh              config.env  ->  workflows/_filled/*.json
  waha/                       WhatsApp gateway (Docker)
  workflows/                  the 10 CREA workflows (templates, with {{CREA_*}} tokens)
  facet-template/             generic reusable shape for any future facet + NEW-FACET.md
  SETUP.md                    this file
```

| Workflow | Trigger | Connect | Purpose |
|---|---|---|---|
| `crea-wa-send` (`creawasend`) | called by others | WAHA | the one place WhatsApp is sent — swap gateway here only |
| `crea-01-whatsapp-inbound` | WAHA webhook | WAHA, state store | front door: dedupe, route booking chats to the agent, else vault inbox + owner ping |
| `crea-02-booking-agent` | called by 01 | state store, vault API | **deterministic** shoot-brief qualifier (fixed 5 questions) — the fallback path |
| `crea-02b-ai-assistant` | called by 01 (**default**) | state store, vault API, OmniRoute, Acuity | **AI** assistant: answers from the knowledge base, checks availability read-only, captures the brief conversationally, hands to owner when quote-ready or stuck; **falls through to `crea-02` if OmniRoute is down** |
| `crea-03-acuity-intake` | Acuity webhook | Acuity (Basic Auth), Google Calendar, Google Sheets, vault API | new booking → job record + calendar event + tracker row |
| `crea-04-shoot-confirmations` | daily 17:00 | Acuity, Google Sheets | WhatsApp-confirm tomorrow's shoots, record on `Pending` tab |
| `crea-05-chase-noreply` | 09/12/15 daily | Google Sheets | nudge unconfirmed (max 2), then tell owner to call |
| `crea-06-card-pipeline` | webhook from CREA card-detect | Google Drive, Higgsfield, vault API | split by capture gap → Drive folders → **human gate** → Higgsfield → notify editor |
| `crea-07-monday-invoicing` | Mon 09:00 | Google Sheets, vault API | draft invoices for completed unpaid jobs (**draft only, never sends**) |
| `crea-08-morning-briefing` | daily 06:30 | Acuity, Google Sheets, OmniRoute | "what to focus on" briefing to owner |
| `crea-10-apify-leads` | daily 07:00 | Apify, Google Sheets | new listing leads → `Leads` tab + digest |

All are **inactive on import**. Activate deliberately, one at a time, after testing.

---

## 1. Prerequisites

- **Docker Desktop running** (for WAHA). `docker info` must succeed.
- **n8n running** — `n8n start` → http://localhost:5678 (owner account already set up on this Mac).
- Accounts: the friend's **WhatsApp** (phone in hand for the QR), **Acuity**, **Google**
  (Calendar + Drive + Sheets), **Higgsfield**, **Apify**. All optional to start — a workflow
  you haven't wired just stays inactive.
- **OmniRoute** running locally (OpenAI-compatible endpoint) for the LLM steps.
- A **vault API** — see §5. Until it exists, the `vault` steps fail softly (they're
  `continueErrorOutput`) and the rest of each workflow still runs.

---

## 2. WhatsApp gateway (WAHA)

```bash
cd ~/.claude/n8n/crea/waha
cp .env.example .env
# edit .env: set WAHA_API_KEY to a long random string
docker compose up -d
open http://localhost:3001            # dashboard
```

In the dashboard: **Sessions → default → Start**, then scan the QR from the phone
(WhatsApp → Linked Devices). CREA now reads/sends as a linked device — the number stays a
normal WhatsApp account. *(Run it with your own number first; re-pair with the friend's
later — one QR scan.)*

**Risk (from the manual):** unofficial library, small chance of number restriction. The
safer variant is a second SIM dedicated to CREA.

WAHA posts inbound events to `WHATSAPP_HOOK_URL` in `.env` — already set to
`http://host.docker.internal:5678/webhook/crea-wa-inbound`.

---

## 3. Fill config & import

```bash
cd ~/.claude/n8n/crea
cp config.example.env config.env
#   edit config.env — every value. CREA_OWNER_WA = your number (digits only) for now.
./fill-config.sh
n8n import:workflow --separate --input=workflows/_filled/
```

Re-run `fill-config.sh` + import any time you change `config.env` (import upserts by id —
your edits in the n8n editor are overwritten, so make config changes in the file).

> The **template** copies (with raw `{{CREA_*}}` tokens) are already imported for structural
> review. Importing `_filled/` overwrites them in place with the real values.

---

## 4. Connect credentials in n8n

Open each workflow, click the coloured nodes, pick/create the credential:

| Credential (n8n) | Type | Used by |
|---|---|---|
| **CREA Acuity** | HTTP Basic Auth — user = `CREA_ACUITY_USER_ID`, pass = `CREA_ACUITY_API_KEY` | Get Appointment(s) |
| **CREA Google** | Google OAuth2 (Calendar + Drive + Sheets scopes) | Calendar Event, Tracker Row, Drive folders |
| **CREA OmniRoute** | HTTP Header Auth — `Authorization: Bearer <CREA_OMNIROUTE_KEY>` | Compose (OmniRoute), LLM Answer |
| **CREA Higgsfield** | HTTP Header Auth — key from Higgsfield settings | Push to Higgsfield |

WAHA and Apify auth travel in the request (API key header / token query) — no n8n credential.

---

## 5. Vault API contract (Hermes or a tiny writer service) — the job store

The workflows use `CREA_VAULT_API_URL` as the **job tracker + memory** (not Google Sheets —
that validation-blocks without a Google credential and doesn't fit CREA's vault-is-memory
model). Implement these (all JSON). A ~80-line Flask/Express service is enough; or Hermes
exposes them. Same shape as the state-store on `:5691`. `test/mock-services.js` is a working
reference implementation.

| Method / path | Body / query | Used by |
|---|---|---|
| `POST /job` | `{jobId, client, phone, address, type, datetime, price, notes, ...}` | crea-03 |
| `POST /job/invoiced` | `{jobId, invoiced:"draft"}` | crea-07 |
| `POST /lead` | `{source, from, brief, status}` | crea-02 |
| `POST /inbox` | `{channel, from, text, type, receivedAt}` | crea-01 |
| `POST /shoots` | `{cardId, shootIndex, start, fileCount, folderName}` | crea-06 |
| `POST /invoice-draft` | `{jobId, client, amount, ...}` — creates a **draft** note, never sends | crea-07 |
| `POST /pending` | `{phone, jobId, client, sentAt, chases, confirmed}` | crea-04 |
| `GET  /pending` | → array of pending confirmation rows | crea-05 |
| `POST /pending/update` | `{jobId, chases, lastChaseAt}` | crea-05 |
| `POST /leads` | one lead object (auto-mapped) | crea-10 |
| `GET  /leads` | → array of known leads `[{key,...}]` for dedupe | crea-10 |
| `GET  /jobs` | → jobs array (briefing counts unpaid/leads) | crea-08 |
| `GET  /jobs?filter=billable` | → completed & not-yet-invoiced jobs | crea-07 |
| `GET  /knowledge?q=` | → `{chunks:[...]}` for LLM grounding | facet-template |

## 5c. The AI booking assistant (`crea-02b`)

**`crea-01` routes booking-tagged messages to whatever `CREA_BOOKING_WORKFLOW_ID` names**
— `creaaiassistant` (default) or `creabookingagent` (deterministic). An in-progress
conversation stays with the same handler until it closes.

The AI assistant:
- **answers only from `knowledge/crea-knowledge.md`** — served via `GET {CREA_VAULT_API_URL}/knowledge?q=`.
  It ships usable — coverage area, process, turnaround, FAQ are real; prices say "quote on
  request" until you add numbers to one table. Anything the file does not cover → "someone
  will follow up" + owner ping. `knowledge/EXAMPLE-filled.md` shows a completed one.
- **quotes a price only if it's verbatim in the file** — otherwise "I'll get you an exact quote".
- **checks Acuity availability read-only** (`GET {CREA_ACUITY_BASE}/availability` → busy blocks)
  and never confirms a slot — "that looks open, {owner} will confirm".
- **builds the brief across turns** (service, property, address, preferred_date, access, notes),
  transcript + brief in the state store (last 12 turns), not model memory.
- **hands to the owner** with the full brief when `booking_ready` (service + address + date) or
  when it can't help.
- **hands the live conversation to the deterministic qualifier** (crea-02) the moment
  OmniRoute is unreachable or returns junk — the customer just gets the structured 5-question
  flow instead, no dropped thread. The two genuinely work together, AI leading.

Verified 2026-09-08 against a live free-tier model: quoted `$450` from the KB, checked
Saturday availability, captured `{service, property, address, preferred_date, access}`, handed
off `status: to-quote`. Off-KB questions and unpriced items correctly went to a human.

**Availability endpoint** the vault/Acuity side must provide:
`GET {CREA_ACUITY_BASE}/availability` → `{ busy: [{date,from,to}], note: "..." }` for the next
~2 weeks. Acuity's own `/availability/times` can back this, or compute it from `/appointments`.

## 5b. Google Calendar + Drive — opt-in

`crea-03` (Calendar Event, Tracker Row) and `crea-06` (Create Drive Folder) ship **disabled**
— the Google Calendar node hard-fails workflow validation with no credential attached. After
you create the `CREA Google` credential: enable those nodes, select the credential, and in
`crea-06` wire `Split by Capture Gap → Create Drive Folder → Record Shoots` and add
`driveFolderId` back to the Record Shoots + Higgsfield bodies.

---

## 6. Wire the external webhooks

| Source | Point at |
|---|---|
| WAHA | `…/webhook/crea-wa-inbound` (set in `waha/.env`) |
| Acuity | Business Settings → Integrations → Webhooks → `appointment.scheduled` → `http://<n8n>/webhook/crea-acuity` |
| CREA card-detect script | `POST http://<n8n>/webhook/crea-card` with `{cardId, files:[{name,path,capturedAt,size}]}` |
| Card-pipeline approval | the owner taps the `resumeUrl` link in the WhatsApp prompt — no setup |

`<n8n>` = `localhost:5678` locally. On the Mac Mini it's the Mini's LAN address or a
Tailscale hostname (the manual already uses Tailscale).

---

## 7. Test order

1. **crea-wa-send** — Executions → *Execute Workflow* with `{"to":"<your number>","text":"CREA test"}`. Expect the WhatsApp to arrive.
2. **crea-01** — send yourself a WhatsApp from another phone; watch the execution; non-booking text → owner ping, "need video quote" → booking agent replies.
3. **crea-02** — continue that booking chat through all 5 questions; confirm the brief hits `POST /lead`.
4. **crea-03** — book a test slot in Acuity; check calendar event + tracker row appear.
5. **crea-04** — set the schedule 2 min ahead temporarily; confirm tomorrow's test booking gets a WhatsApp + a `Pending` row.
6. **crea-05 / 07 / 08 / 10** — run manually (disable the schedule), verify the WhatsApp summary.
7. **crea-06** — `POST /webhook/crea-card` a fake manifest; approve via the link; check Drive folders (Higgsfield step needs the real API — see §9).
8. Activate each only once its test passes.

---

## 8. Move to the friend's Mac Mini

Workflows are portable. On the Mini:
```bash
n8n import:workflow --separate --input=workflows/_filled/
```
Then re-point the **base-URL-dependent** bits:
- `config.env` → `CREA_N8N_BASE_URL`, `CREA_WAHA_URL` (if WAHA also moves)
- WAHA `.env` `WHATSAPP_HOOK_URL`
- Acuity webhook URL
- Google OAuth redirect URI (add the Mini's URL in Google Cloud console)
- CREA card-detect script's target URL

Re-run `fill-config.sh` + import. Re-select credentials (they don't travel in the JSON).

---

## 9. Known gaps (finish before "live")

- **Higgsfield API** — `CREA_HIGGSFIELD_URL` + payload in `crea-06` are a placeholder shape;
  set the real endpoint/body from Higgsfield's API docs once you have access.
- **Acuity address field** — `crea-03` "Build Job" guesses the form field name contains
  "address"/"property". Adjust `pick('address')` to the real intake-form field label.
- **switch / if nodes** — open `crea-01` (Route by Target) and `crea-02` (Brief Complete?)
  once in the editor and re-save; n8n backfills condition IDs on first open.
- **OmniRoute response shape** — `crea-08` / facet-assistant read `choices[0].message.content`
  (OpenAI shape). Adjust "Extract Text" if OmniRoute wraps differently.
- **Alert webhook** — set `ALERT_WEBHOOK_URL` so the TRIS OS Global Error Handler (layer 3)
  actually delivers failure alerts.

---

## 10. Repo drop for `skw-fuj/crea`

`repo/` mirrors this into the CREA repo layout — commit it under `n8n/` there. It carries the
same workflows + a short README; the friend runs `fill-config.sh` on the Mini.
