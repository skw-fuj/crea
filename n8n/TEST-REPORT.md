# CREA v2 n8n — verification

Every workflow was driven end to end through a real n8n **2.30.7** instance against the real
`vault-api/server.js`, with WAHA and the LLM endpoint stood in by `test/mock-services.js`
(which captures every outbound call). `test/demo.sh` reproduces the run.

## v2 re-verification (2026-09-09) — live model

The full suite was re-run with the assistant pointed at a **real OpenAI-compatible model**
(`test/demo.sh` with `DEMO_LLM_URL`/`DEMO_LLM_KEY` set). A three-turn booking conversation:

- Turn 1 "how much for a listing video" → **"The video package is $450"** — the exact figure
  from the knowledge file, nothing invented — and asked for the address.
- Turn 2 "40 Awaba St, Mosman. Can you do this Saturday?" → routed to the assistant (not the
  inbox), checked availability, replied **"that looks open, the owner will confirm"** — never
  confirmed a slot — brief now had address + date → **owner got a "Quote-ready enquiry"** with
  the brief, lead note written to the vault (`status: to-quote`).
- Turn 3 "let's book it. Lockbox 4471, tenant occupied" → captured `access: Lockbox 4471`,
  `notes: Tenant occupied` in the right fields; owner got the updated enquiry.

Final state: `mode: ai`, `booking_ready: true`, clean 6-turn transcript. 8 model calls, 8
knowledge lookups, 8 availability checks, 4 lead notes, 0 errors across 47 executions
(card pipeline correctly `waiting` at the human gate).

Two bugs this pass caught and fixed:

- **Consecutive-message race** — a second message arriving while the first turn's assistant
  run was still finishing was read against stale state and fell to the inbox. `crea-01` now
  marks the conversation `mode: ai` the instant it routes to the assistant, not when the
  assistant finishes.
- **Stateless test stub** — `mock-services.js` `/vault/state` didn't persist, so the
  multi-turn path was never really exercised offline. It now merges and holds state like the
  shipped vault API.

## Result — all workflows reach their designed end

| Workflow | Verified |
|---|---|
| `crea-01` inbound | routes booking-intent messages to the assistant; everything else → vault inbox + a one-line owner ping; ignores its own outgoing messages; dedupes by message id |
| `crea-02b` AI assistant | quoted a price **only** when one was in the knowledge file, otherwise "I'll get you an exact quote"; checked availability and never confirmed a slot ("… will confirm"); built the shoot brief across turns; handed the owner a quote-ready enquiry; wrote the lead note to the vault |
| `crea-02b` fallback | with the LLM endpoint returning 503, the assistant handed the live conversation to `crea-02`; the customer got the deterministic greeting, state advanced — chain all `success` |
| `crea-02` qualifier | the fixed 5-question flow captured a full brief and pushed it to the vault |
| `crea-wa-send` | every WhatsApp send in the suite went through this one node |
| `crea-03` Acuity intake | webhook → fetch appointment → vault job note → owner ping |
| `crea-04` confirmations | tomorrow's appointments → one confirmation each → recorded as pending |
| `crea-05` chase | overdue pending → a nudge; a row at 2 nudges escalates to the owner |
| `crea-06` card pipeline | files split into shoots on the capture gap, recorded, then **paused at the human gate** — nothing pushed downstream without approval |
| `crea-07` invoicing | completed unpaid jobs → one **draft** invoice each → owner summary. Never sends. |
| `crea-08` briefing | today's shoots + counts → LLM phrasing → one WhatsApp to the owner |
| `crea-10` leads | scrape → dedupe against known → new leads → digest |
| `crea-00` error handler | a deliberately failed node landed here, was normalised, and recorded to the vault `/alert` |

## Bug classes found by testing and fixed

1. **`$json` after an HTTP node** referred to the response, not the earlier message — owner
   pings read "from undefined". Repointed to the parse node.
2. **`={{ '{{TOKEN}}' }}/suffix`** dropped the suffix in n8n — a vault call went nowhere and
   was swallowed. Replaced with plain `{{TOKEN}}/suffix` throughout.
3. **A blank required URL validation-blocks the whole workflow** (Google Calendar, Higgsfield)
   — `onError` can't catch a pre-run check. Those nodes now ship disabled (opt-in) and the
   job tracker moved to the vault API.
4. **Silent drop on an unwired `continueErrorOutput`** — a failed enrichment node killed the
   chain and still reported success. Enrichment nodes switched to `continueRegularOutput`.
5. **A multi-item array response read as a single item** — `$('Node').all()` fixes it.
6. **Fan-in race** — a code node ran before its second input finished. Chains linearised.
7. **Reference to a disabled node throws** — removed.

## Not exercised (needs real accounts)

WhatsApp delivery through a live WAHA container · the card-pipeline resume leg · Google
Calendar / Drive · the live Acuity / Apify / Higgsfield APIs. The request shapes match their
docs; confirm Higgsfield's endpoint against a live key.
