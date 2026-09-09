# CREA v2 — n8n Hands Layer

A **WhatsApp AI booking assistant** plus the shoot-ops automations (Acuity intake, shoot
confirmations, chase, card pipeline, invoicing, morning briefing, listing leads).

Verified end-to-end against a live model on n8n 2.30.7 — see `TEST-REPORT.md`.

---

## Install

**Full runbook: `INSTALL.md`** — about an hour, mostly account signups and downloads.

Short version, once Docker Desktop is installed and running:

```bash
cp config.example.env config.env      # fill: CREA_OWNER_WA, CREA_WAHA_API_KEY, CREA_OMNIROUTE_KEY
./go-live.sh                           # brings the whole stack up and wires everything
./go-live.sh --qr                      # scan once with the bot phone
./go-live.sh --test                    # prove it's live
```

Then put your prices in `knowledge/crea-knowledge.md`.

**Handing it to someone:** give them `HANDOVER.md` + `INSTALL.md`.

---

## How it fits together

```mermaid
flowchart LR
  cust([Customer WhatsApp]) <--> waha[WAHA container<br/>localhost:3001]
  waha -->|message webhook| n01[crea-01<br/>inbound router]
  n01 -->|marks mode:ai, routes| n02b[crea-02b<br/>AI assistant]
  n02b -.->|LLM unreachable| n02[crea-02<br/>5-question qualifier]
  n02b --> vapi[(vault-api container<br/>knowledge · availability<br/>state · jobs · leads)]
  n02b --> llm[LLM<br/>OpenAI-compatible]
  n02b --> wsend[crea-wa-send] --> waha
  n02b -->|quote-ready| owner([Owner WhatsApp])
  acuity([Acuity]) -->|polled every 10 min| n03[crea-03 intake] --> vapi
  sched{{schedules}} --> n04[confirmations] & n05[chase] & n07[invoicing] & n08[briefing] & n10[leads]
  n04 & n05 & n07 & n08 & n10 --> wsend
  card([card-detect webhook]) -->|local| n06[crea-06<br/>card pipeline] -->|human gate| higgs([Higgsfield]) --> editor([Editor WhatsApp])
  anyfail[[any failure]] --> n00[crea-00<br/>error handler] --> vapi
```

Three containers on one Mac (`deploy/docker-compose.yml`): **n8n**, **WAHA**, **vault-api**.
Private Docker network — **no public URL, no tunnel**. WhatsApp comes in through WAHA; Acuity
is polled outbound; the LLM is outbound HTTPS. `vault-api/server.js` has no dependencies and
stores everything as plain files under `CREA_VAULT_DIR`.

---

## What's here

| Path | |
|---|---|
| `INSTALL.md` | the runbook — start here |
| `deploy/docker-compose.yml` · `go-live.sh` · `fill-config.sh` | the whole stack + one-command deploy |
| `workflows/` | 12 workflows (table in `SETUP.md`) |
| `vault-api/server.js` | memory + job store + knowledge + availability + conversation state — one zero-dep service |
| `knowledge/crea-knowledge.md` | what the assistant answers from. Ships usable; put prices in one table. `EXAMPLE-filled.md` shows a done one. |
| `config.example.env` | every account/key, each marked REQUIRED/optional |
| `HANDOVER.md` · `SETUP.md` · `DATA-AND-BACKUP.md` · `TEST-REPORT.md` | cover note, reference, keeping data safe, verification |
| `facet-template/` | the same shape generalised for any other assistant — `NEW-FACET.md` |
| `test/` | `mock-services.js` + `demo.sh` — reproduce the verification run offline |

---

## Design rules

- Every workflow is a MACRO with named steps (`meta.steps`); sub-workflows keep it decomposed.
- Three-layer error handling: node `retryOnFail` + `onError` · `crea-00` as every workflow's `errorWorkflow` · a layer-3 alert.
- **Placeholders only** — no secrets in the JSON. `fill-config.sh` substitutes `config.env` (inline comments stripped).
- Conversation state + transcript live in the vault API, **never model memory**.
- The assistant answers **only** from `knowledge/crea-knowledge.md` and never invents a price, a time, or a policy.
- Money and outbound publishes are human-gated (invoices draft only; card pipeline waits for the owner's OK).
- No public ingress: WhatsApp is same-machine via WAHA, Acuity is polled, everything else is outbound.

## Why this beats a keyword bot

The instance this was modelled from was a keyword-match chatbot with a Gemini API key
hardcoded in a node URL, backends on raw IP addresses, and no error handling. This one:
answers real questions from an editable knowledge file, quotes only verified prices, degrades
to a deterministic flow when the model is down, keeps every value in one config file, records
every failure, holds conversation state so fast follow-up messages don't get misrouted, and
ships with a reproducible test.
