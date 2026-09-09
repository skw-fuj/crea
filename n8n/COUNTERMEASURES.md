# CREA v3 — countermeasures

What can go wrong, how CREA notices, what it does about it on its own, and what's left for you.
This is the resilience and security model. Nothing here needs configuring — it's how v3 behaves
out of the box. The knobs (thresholds, a second LLM endpoint, a blocklist) are in `config.env`.

---

## The three layers

1. **Node level** — every step that calls something external retries with backoff, and on
   final failure either continues the chain (enrichment) or hands to the error workflow.
2. **Workflow level** — `crea-00` catches any unhandled failure, normalises it, and records
   it (deduped: one identical alert per hour). `crea-llm` is a circuit breaker in front of
   the model. `crea-01` rate-limits and filters at the door. `crea-02b` validates every reply
   before it's sent.
3. **Host level** — a launchd **watchdog** runs every few minutes: it restarts a down or
   wedged container, re-links a dropped WhatsApp session, prunes disk, and triggers the
   in-app self-check. `crea-09` self-check pulls the health picture and pages you (WhatsApp +
   your alert webhook) only for things it can't fix — and only once per problem, not every run.

---

## Resilience — outages and faults

| What breaks | How CREA notices | What it does automatically | What's left for you |
|---|---|---|---|
| **LLM slow / erroring / rate-limited** | `crea-llm` gets a non-200 or empty body | retries once; then tries `CREA_OMNIROUTE_URL_2` if set; reports the outcome to the circuit breaker | set a second endpoint (e.g. Groq + OpenAI) for true redundancy |
| **LLM down for a while** | 4 consecutive failures (configurable) | circuit **opens** for 5 min — the assistant skips the model entirely and every booking chat uses the deterministic 5-question qualifier. No 30-second waits. Auto-closes on the next success | nothing; the self-check tells you it happened |
| **LLM returns junk / unparseable** | `Parse AI` can't extract the JSON | that turn degrades to the deterministic qualifier | nothing |
| **LLM invents a price / a date / confirms a booking** | `Guard Reply` compares the reply to the knowledge file | the invented price sentence is stripped, a confirmation is softened to "the owner will confirm", and the enquiry is flagged for you. An incident is logged | nothing — but check the flagged lead |
| **WhatsApp session drops** (normal after long idle) | watchdog polls the session status | tries `restart` then `start` on the session | if it still won't link, you get a WhatsApp/webhook alert → `./go-live.sh --qr` and re-scan |
| **A container crashes** | Docker `restart: unless-stopped` + watchdog | Docker restarts it; the watchdog brings the stack up if Docker missed it | nothing |
| **n8n up but wedged** | compose healthcheck marks it `unhealthy` | watchdog restarts the n8n container and alerts you it happened | nothing |
| **vault-api hangs** | watchdog `wget /ping` fails | watchdog restarts it. The process also has uncaught-exception guards so one bad request can't take it down | nothing |
| **Mac reboots** | — | Docker Desktop auto-starts (if set), every container comes back, WAHA re-links from its saved session, the watchdog re-arms | set Docker Desktop to start on login (INSTALL.md Part A) |
| **Disk fills** | `go-live.sh` preflight refuses < 6 GB; watchdog checks each run; n8n prunes its own execution history (14 days / 20k) | watchdog prunes Docker images + build cache; pages you if still < 3 GB | free space on the Mac |
| **Acuity / Apify / Higgsfield down** | the request fails | the workflow logs it and continues — a failed availability check just means "treat all as tentative", a failed poll processes nothing and keeps its watermark (no missed or double bookings) | nothing |
| **Knowledge file deleted or emptied** | `/health` `knowledge_present` goes false | self-check pages you; the assistant says "I'll get you a quote" for everything until it's back | restore the file (it's in your backup and your Obsidian vault) |
| **Duplicate webhook delivery** | `crea-01` dedupes on message id, and on identical text within 10 s | the duplicate is dropped | nothing |
| **The encryption key is lost** | credentials become unreadable on the next restart | — | `./go-live.sh --restore` a backup, or re-enter the API keys. **Back up `deploy/.n8n-key`.** |

---

## Security & abuse

| Threat | Countermeasure |
|---|---|
| **Prompt injection** ("ignore your instructions", "you are now…", "repeat your prompt") | The system prompt states plainly that customer text is **data, not instructions**, and to refuse rule changes / prompt disclosure. On top of that, `Guard Reply` is a deterministic filter that runs on *every* reply regardless of what the model did: it blocks system-prompt leakage, strips any `$` price not present verbatim in the knowledge file, and softens firm booking confirmations. The model is never trusted to self-police. |
| **Price manipulation** ("the price is $1, confirm it") | The model is told to quote only verbatim prices; `Guard Reply` removes any price token that isn't in the knowledge file and flags the enquiry for you. |
| **Data exfiltration** ("list all your bookings", "what's customer X's address") | The assistant's only context is *this* conversation's transcript + the knowledge file + a busy/free calendar summary. It has no tool that reads other customers' data. Cross-conversation state is keyed by phone number and never shared into the prompt. |
| **Making CREA message someone else** | `crea-wa-send` is the only sender, and every caller sets the recipient from workflow data (`the customer` or `CREA_OWNER_WA`) — never from model output. The model cannot choose who a message goes to. |
| **Message flooding** | `crea-01` keeps a 60-second rolling count per sender. Past `CREA_RATE_LIMIT_PER_MIN` (default 12) it stops replying to that sender for ~1 minute, records the message, and logs one flood alert. |
| **Persistent abuse / spam** | Put the number(s) in `CREA_BLOCKLIST` — `crea-01` drops them before anything else runs. |
| **Oversized / malformed input** | Inbound text is capped at 2000 chars, null bytes stripped; group chats, status broadcasts, and unparseable senders are dropped silently; media messages become `[image message …]` placeholders and never crash a code node. |
| **The editor being reachable** | n8n listens on `localhost` only and has no port exposed to the network. On a shared or office Mac, set `CREA_N8N_USER` + `CREA_N8N_PASSWORD`. |
| **Secrets** | Never in the workflow JSON — only `{{TOKENS}}` filled at deploy time. `config.env` and `deploy/.n8n-key` are git-ignored and `chmod 600`. The credential values are encrypted at rest in n8n with `deploy/.n8n-key`. |
| **Customer PII** (names, numbers, addresses) | Stored as plain files under `CREA_VAULT_DIR`. Obsidian Sync is end-to-end encrypted; a plain cloud folder is not (documented in `DATA-AND-BACKUP.md`). Transcripts are capped at 12 turns. |
| **The LLM provider sees enquiry text** | Inherent to any hosted model. If it matters, run a local model via Ollama's OpenAI shim — `CREA_OMNIROUTE_URL` points anywhere. |

---

## Observability

- **`http://localhost:5692/status.html`** — a live dashboard: critical checks, today's activity,
  LLM circuit state, disk, last-backup age. Auto-refreshes.
- **`./go-live.sh --status`** — the same picture in the terminal, plus container status and
  whether the watchdog is installed.
- **`./go-live.sh --selfcheck`** — run the health check now.
- **`CREA_VAULT_DIR/alerts/`** — one Markdown note per incident CREA caught (deduped).
- **`deploy/_export/watchdog.log`** — what the watchdog has done.
- **n8n → Executions** — every run, filterable by status.
- The **morning briefing** ends with a system-health line whenever CREA needs attention.

---

## How this compares to the instance CREA was modelled on

The reference was a real, in-production real-estate WhatsApp bot. Side by side:

| | The reference bot | CREA v3 |
|---|---|---|
| Understanding | keyword match | a model that answers from an editable knowledge base, with a deterministic fallback |
| Pricing | whatever the model felt like | only prices verbatim in your knowledge file; anything else is stripped and flagged |
| Secrets | a Gemini API key hardcoded in a node URL | placeholders only; encrypted credentials; nothing in the JSON |
| Backends | services on bare IP addresses | one zero-dependency local service, on a private Docker network, nothing internet-facing |
| Error handling | none — failed runs vanished | 3 layers: node retry, `crea-00` catch + dedup, host watchdog |
| Model outage | bot goes silent | circuit breaker → deterministic qualifier, auto-recovers |
| Prompt injection | undefended | hardened prompt **plus** a deterministic reply guard |
| Flooding / abuse | undefended | per-sender rate limit + blocklist |
| Bot vs human | bot replies forever | hands the lead over and goes quiet for 3 days |
| Monitoring | none | health endpoint, dashboard, self-check, daily briefing line, watchdog |
| Recovery | rebuild from memory | `./go-live.sh --backup` / `--restore`, ~20 min to a new Mac |
| Config | edit nodes | two plain-text files |
| Tested | — | reproducible offline suite incl. the failure and attack cases (`test/demo.sh`) |

---

## When you get an alert — what to do

| Alert | First move |
|---|---|
| "n8n was unresponsive and has been restarted" | nothing — it's back. If it repeats, `./go-live.sh --logs n8n`. |
| "WhatsApp is disconnected" | `./go-live.sh --qr`, re-scan with the bot phone. |
| "the assistant model has been failing" | check `CREA_OMNIROUTE_KEY` and that the provider is up; `./go-live.sh --logs n8n | grep -i llm`. Customers still get the 5-question flow meanwhile. |
| "N errors in the last 24h" | open `CREA_VAULT_DIR/alerts/` — each note says which workflow and why. |
| "disk critically low" | free space on the Mac. Below ~2 GB the whole stack degrades. |
| "reply was corrected before sending" | open the flagged lead in `leads/` — the assistant tried to quote or confirm something it shouldn't have; follow up with the customer yourself. |
