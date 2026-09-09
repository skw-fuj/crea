# CREA v2 — n8n Hands Layer · how it fits together

**To install:** follow `INSTALL.md`. This file is the reference for what the pieces are and
how they connect — read it once you're up, or when you want to change something.

Built and verified end-to-end against n8n **2.30.7** and a live model — see `TEST-REPORT.md`.

---

## The stack

`./go-live.sh` runs three containers with `docker compose` (`deploy/docker-compose.yml`):

| Container | What | Reachable at |
|---|---|---|
| `crea-n8n` | the workflow engine + editor | `http://localhost:5678` |
| `crea-waha` | the WhatsApp gateway (scan the QR once) | `http://localhost:3001` |
| `crea-vault-api` | CREA's memory — knowledge, conversation state, job/lead/inbox notes | internal only (`:5692`) |

They share a private Docker network, so **no public URL or tunnel is needed**. WhatsApp
messages arrive through WAHA; Acuity is polled outbound every 10 minutes; the LLM and other
APIs are outbound HTTPS. `restart: unless-stopped` + Docker Desktop "start on login" means the
whole thing survives a reboot, and WAHA re-links from its saved session.

---

## The workflows

| Workflow | Trigger | Purpose |
|---|---|---|
| `crea-00-error-handler` | any workflow fails | normalises the failure, records it to the vault `/alert`, pings the owner |
| `crea-wa-send` | called by the others | the one place WhatsApp is sent — swap gateways here only |
| `crea-01-whatsapp-inbound` | WAHA message webhook | dedupe, mark an active booking chat, route it to the assistant; everything else → vault inbox + a one-line owner ping |
| `crea-02b-ai-assistant` | booking chat (default) | answers from the knowledge base, checks availability read-only, captures the shoot brief, hands the owner a quote-ready enquiry. **Falls through to `crea-02` if the LLM is unreachable.** |
| `crea-02-booking-agent` | AI fallback / opt-in | fixed 5-question qualifier |
| `crea-03-acuity-intake` | **polls Acuity every 10 min** (+ a local `crea-acuity-poll` webhook for "run now") | new bookings → vault job note + owner ping. Dedupes on a watermark of processed appointment ids. Google Calendar node present but disabled. |
| `crea-04-shoot-confirmations` | 17:00 daily | WhatsApp-confirm tomorrow's shoots; record each on the vault `/pending` list |
| `crea-05-chase-noreply` | 09/12/15 daily | nudge unconfirmed clients (max 2), then tell the owner to call |
| `crea-06-card-pipeline` | `crea-card` webhook (local) | split footage by capture gap → **human gate** → Higgsfield → notify editor. Drive-folder node disabled. |
| `crea-07-monday-invoicing` | Mon 09:00 | draft invoices for completed unpaid jobs — **never sends** |
| `crea-08-morning-briefing` | 06:30 daily | "what to focus on" over WhatsApp |
| `crea-10-apify-leads` | 07:00 daily | new listing leads → digest |

`crea-01` routes booking messages to whatever `CREA_BOOKING_WORKFLOW_ID` names —
`creaaiassistant` (default) or `creabookingagent`.

`go-live.sh` activates the core loop always; the Acuity workflows only when
`CREA_ACUITY_USER_ID` is set; the leads workflow only when `CREA_APIFY_TOKEN` is set.

---

## config.env

Every `{{CREA_*}}` token in the workflow JSON is filled from `config.env` by `fill-config.sh`
(it strips any inline `# comment`). `config.example.env` marks each value REQUIRED or optional.
The required four:

| Value | What |
|---|---|
| `CREA_OWNER_WA` | your WhatsApp, digits only with country code — booking alerts + briefings land here |
| `CREA_WAHA_API_KEY` | a random string you invent (`openssl rand -hex 24`) — protects the local WAHA API |
| `CREA_OMNIROUTE_URL` + `CREA_OMNIROUTE_KEY` | an OpenAI-compatible chat-completions endpoint + its key (Groq by default) |

Everything else can stay blank — the workflow that needs it stays inactive until you fill it
and re-run `./go-live.sh`.

---

## The vault API (`vault-api/server.js`)

Zero-dependency Node service, one file. Runs as the `crea-vault-api` container. Memory + job
store + knowledge + availability + conversation state, all plain files under `CREA_VAULT_DIR`
(JSON + a readable Markdown mirror).

| Method / path | Used by |
|---|---|
| `GET /knowledge?q=` | crea-02b — section retrieval over `knowledge/crea-knowledge.md` |
| `GET /availability` | crea-02b — real Acuity API if `CREA_ACUITY_*` are set, else a sane default |
| `GET/POST /state` | crea-01/02/02b/03 — conversation state, watermarks, merged on write |
| `POST /job` · `POST /job/invoiced` · `GET /jobs?filter=billable` | crea-03, crea-07 |
| `POST /lead` · `POST /leads` · `GET /leads` | crea-02/02b, crea-10 |
| `POST /inbox` | crea-01 |
| `POST /pending` · `GET /pending` · `POST /pending/update` | crea-04, crea-05 |
| `POST /shoots` · `POST /invoice-draft` | crea-06, crea-07 |
| `POST /alert` | crea-00 |

---

## The knowledge file (`knowledge/crea-knowledge.md`)

The assistant answers **only** from this file, and quotes a price **only** where a real number
sits in its table. It ships usable — coverage area, booking process, turnaround and FAQ are
real; the Price column is blank, so the assistant says "I'll get you an exact quote" until you
fill it. `knowledge/EXAMPLE-filled.md` shows a completed one. Edit it like any document; the
container reads it live, no restart.

---

## Credentials

`go-live.sh` creates and binds these from `config.env` — nothing to click in the n8n UI:

| Credential | Type | From |
|---|---|---|
| `CREA OmniRoute` | HTTP Header Auth — `Authorization: Bearer <key>` | `CREA_OMNIROUTE_KEY` |
| `CREA Acuity` | HTTP Basic Auth — user = User ID, pass = API Key | `CREA_ACUITY_USER_ID` / `_API_KEY` (only if set) |
| `CREA Higgsfield` | HTTP Header Auth — `X-Api-Key: <key>` | `CREA_HIGGSFIELD_API_KEY` (only if set) |
| `CREA Google` | Google OAuth2 | you, in the n8n UI, only if you enable the disabled Calendar/Drive nodes |

WAHA and Apify auth travel in the request — no n8n credential.

The n8n encryption key lives in `deploy/.n8n-key` (generated on first run). **Back it up** —
without it n8n can't decrypt the saved credentials.

---

## Your data

Set `CREA_VAULT_DIR` to a folder inside your Obsidian vault and turn on Obsidian Sync — then
every booking, lead and invoice is on every device and backed up. **`DATA-AND-BACKUP.md`** has
the how and the ranked alternatives. Blank = a local Docker volume only (no phone, no backup).

---

## Test it (offline, no accounts)

```bash
node test/mock-services.js &                     # stands in for WAHA + the LLM, logs every call
./test/demo.sh                                   # drives the assistant + the scheduled workflows
DEMO_LLM_URL=<endpoint> DEMO_LLM_KEY=<key> ./test/demo.sh   # ...against a real model
./test/demo.sh revert                            # restore clean templates
```

`TEST-REPORT.md` has the full verification run.

---

## Known opt-ins

- **Google Calendar / Drive** — `crea-03` Calendar and `crea-06` Drive nodes ship disabled
  (the Calendar node hard-fails validation with no credential). Enable them and add a
  `CREA Google` credential in the n8n UI if you want them.
- **Higgsfield API shape** — `crea-06`'s Higgsfield node uses a generic project-intake POST;
  confirm the exact endpoint/body against your Higgsfield account.
