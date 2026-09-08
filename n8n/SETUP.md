# CREA — n8n Hands Layer · Setup

The n8n layer of CREA: a WhatsApp AI booking assistant plus the shoot-ops automations.
n8n runs the workflows; an OpenAI-compatible LLM (OmniRoute) and a small local **vault API**
(shipped in `vault-api/`) provide the brain and the memory. No external database, no Google
account required to start.

Built and verified end-to-end against n8n **2.30.7** and a live model — see `TEST-REPORT.md`
and `test/run-report.html`.

---

## Ship it — one command

```bash
cd n8n
cp config.example.env config.env      # fill the REQUIRED values (see the file)
./go-live.sh
```

`go-live.sh`:
1. starts the **vault API** (`vault-api/server.js`)
2. substitutes `config.env` into the workflows
3. binds any `CREA *` credentials that already exist to the auth nodes
4. imports and activates all 12 workflows
5. restarts n8n
6. prints the steps that need your accounts

`./go-live.sh --status` shows what's running · `--stop` stops the vault API.

**If you're handing this to someone:** give them `HANDOVER.md` — a short gather list, then one
prompt to paste into Claude Code that does all of the above.

---

## The workflows

| Workflow | Trigger | Purpose |
|---|---|---|
| `crea-00-error-handler` | any workflow fails | normalises the failure, POSTs it to `CREA_ALERT_WEBHOOK_URL` + records it in the vault |
| `crea-wa-send` | called | the one place WhatsApp is sent — swap the gateway here only |
| `crea-01-whatsapp-inbound` | WAHA webhook | dedupe, route booking chats to the assistant, everything else → vault inbox + owner ping |
| `crea-02b-ai-assistant` | booking chat (default) | answers from the knowledge base, checks availability read-only, captures the shoot brief, hands the owner a quote-ready enquiry. **Falls through to `crea-02` if the LLM is unreachable.** |
| `crea-02-booking-agent` | AI fallback | fixed 5-question qualifier |
| `crea-03-acuity-intake` | Acuity webhook | new booking → vault job note + owner ping. (Google Calendar node is present but **disabled** — opt-in.) |
| `crea-04-shoot-confirmations` | 17:00 daily | WhatsApp-confirm tomorrow's shoots; record each on the vault `/pending` list |
| `crea-05-chase-noreply` | 09/12/15 daily | nudge unconfirmed clients (max 2), then tell the owner to call |
| `crea-06-card-pipeline` | card-detect webhook | split footage by capture gap → **human gate** → Higgsfield → notify editor. (Drive-folder node **disabled** — opt-in.) |
| `crea-07-monday-invoicing` | Mon 09:00 | draft invoices for completed unpaid jobs — **never sends** |
| `crea-08-morning-briefing` | 06:30 daily | "what to focus on" over WhatsApp |
| `crea-10-apify-leads` | 07:00 daily | new listing leads → digest |

`crea-01` routes booking messages to whatever `CREA_BOOKING_WORKFLOW_ID` names —
`creaaiassistant` (default) or `creabookingagent`.

---

## config.env

Every `{{CREA_*}}` token in the workflow JSON is filled from `config.env`. `config.example.env`
marks each value **REQUIRED** or optional and carries a comment. The required ones:

| Value | What |
|---|---|
| `CREA_OWNER_WA` | your WhatsApp, digits only — booking alerts + briefings land here |
| `CREA_WAHA_API_KEY` | a random string you invent; the same one goes in `waha/.env` |
| `CREA_OMNIROUTE_URL` + `CREA_OMNIROUTE_KEY` | an OpenAI-compatible chat-completions endpoint + its key |

Everything else can stay blank — the workflow that needs it just won't run until you fill it.

---

## The vault API (`vault-api/server.js`)

Zero-dependency Node service that `go-live.sh` starts on `:5692`. It is the memory + job store
+ knowledge + availability + conversation state, all backed by plain files under
`vault-api/data/` (JSON + a readable markdown mirror). Hermes can read the same files.

| Method / path | Used by |
|---|---|
| `GET /knowledge?q=` | crea-02b — section retrieval over `knowledge/crea-knowledge.md` |
| `GET /availability` | crea-02b — calls the real Acuity API if `CREA_ACUITY_*` are set, else a sane default |
| `GET/POST /state` | crea-01/02/02b — conversation state + transcript, merged on write |
| `POST /job` · `POST /job/invoiced` · `GET /jobs?filter=billable` | crea-03, crea-07 |
| `POST /lead` · `POST /leads` · `GET /leads` | crea-02/02b, crea-10 |
| `POST /inbox` | crea-01 |
| `POST /pending` · `GET /pending` · `POST /pending/update` | crea-04, crea-05 |
| `POST /shoots` · `POST /invoice-draft` | crea-06, crea-07 |
| `POST /alert` | crea-00 |

To back knowledge with the full Obsidian vault later instead of the one file, point
`CREA_VAULT_API_URL` at Hermes exposing the same routes — nothing else changes.

---

## The knowledge file (`knowledge/crea-knowledge.md`)

The assistant answers **only** from this file, and quotes a price **only** where a real number
sits in its table. It ships usable — coverage area, booking process, turnaround and FAQ are
real; the Price column is blank, so the assistant says "I'll get you an exact quote" until you
fill it. `knowledge/EXAMPLE-filled.md` shows a completed one. Edit it like any document; no
restart needed.

---

## Credentials in n8n

`go-live.sh` binds these automatically **once they exist**. Create them (or let the
`HANDOVER.md` prompt do it):

| Credential | Type | For |
|---|---|---|
| `CREA OmniRoute` | HTTP Header Auth — `Authorization: Bearer <key>` | the AI node |
| `CREA Acuity` | HTTP Basic Auth — user = Acuity User ID, pass = Acuity API Key | crea-03/04/08 (optional) |
| `CREA Higgsfield` | HTTP Header Auth — `X-Api-Key: <key>` | crea-06 (optional) |
| `CREA Google` | Google OAuth2 | only if you enable the disabled Calendar/Drive nodes |

WAHA and Apify auth travel in the request — no n8n credential.

---

## Your data

CREA stores everything as plain text under `CREA_VAULT_DIR` (blank = `vault-api/data/`).
Point it at your Obsidian vault and turn on Obsidian Sync so your bookings are on every
device and backed up — **`DATA-AND-BACKUP.md`** has the how and the options.

## The two things only you can do

- **Scan the WhatsApp QR** — `cd waha && cp .env.example .env` (set `WAHA_API_KEY`), then
  `docker compose up -d`, open `localhost:3001`, Sessions → default → Start, scan with
  WhatsApp → Linked Devices. Unofficial link — a second SIM is the safer variant.
- **Paste the Acuity webhook** into Acuity → Integrations → Webhooks, event
  `appointment.scheduled`, URL `<your n8n>/webhook/crea-acuity`.

---

## Test it

```bash
node test/mock-services.js &          # stands in for WAHA + the LLM, captures every call
./test/demo.sh                        # runs the AI conversation + the scheduled workflows
./test/demo.sh revert                 # restore clean templates, stop the mock
```

`TEST-REPORT.md` has the full verification run and the bug classes it caught.

## Known opt-ins

- **Google Calendar / Drive** — `crea-03` Calendar and `crea-06` Drive nodes ship disabled
  (the Calendar node hard-fails workflow validation with no credential). Enable them and pick
  `CREA Google` if you want them.
- **Higgsfield API shape** — `crea-06`'s Higgsfield node uses a generic project-intake POST;
  confirm the exact endpoint/body against your Higgsfield account.
