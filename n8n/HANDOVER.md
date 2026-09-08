# CREA n8n — handover for Connell

The n8n "Hands Layer" for CREA: a WhatsApp AI booking assistant + shoot-ops automations.
It's in `n8n/` in the CREA repo. This doc has two parts — **what you gather** (10 min), then
**one prompt you paste into Claude Code** and it does the rest.

---

## Part 1 — gather these first (Claude can't get them for you)

| # | Item | Where |
|---|---|---|
| 1 | **Your WhatsApp** on your phone | you'll scan a QR — the number stays a normal account |
| 2 | **OmniRoute** (or any OpenAI-compatible) endpoint URL + API key | your CREA install already runs OmniRoute — `crea status` shows the port. Key from its dashboard. |
| 3 | **Acuity** User ID + API Key | acuityscheduling.com → Business Settings → Integrations → API |
| 4 | **Higgsfield** API key *(only if you want the card→editor pipeline)* | Higgsfield account settings |
| 5 | **Google** OAuth client *(only if you want Calendar/Drive — optional, off by default)* | console.cloud.google.com → Credentials → OAuth client (Desktop) |
| 6 | A **16 GB Mac** with `n8n`, `node`, and Docker installed *(the CREA installer already does n8n + node)* | — |

You do **not** need: WATI, a paid WhatsApp API, a Google account (unless you want #5),
or real prices — the assistant ships saying "I'll get you an exact quote" until you add them.

---

## Part 2 — paste this to Claude Code (run it from the CREA repo root)

> Claude: set up the CREA n8n Hands Layer in `n8n/`.
>
> 1. `cd n8n`
> 2. Copy `config.example.env` to `config.env`. Fill it from the values I give you below.
>    Ask me for anything that's blank and required (`CREA_OWNER_WA`, `CREA_WAHA_API_KEY`,
>    `CREA_OMNIROUTE_URL`, `CREA_OMNIROUTE_KEY`). `CREA_OWNER_WA` is my number, digits only.
>    Invent a long random string for `CREA_WAHA_API_KEY` and use the same one in step 4.
> 3. Create the n8n credentials by writing a JSON file and running
>    `n8n import:credentials --input=<file>` — three credentials:
>    `{"name":"CREA OmniRoute","type":"httpHeaderAuth","data":{"name":"Authorization","value":"Bearer <my OmniRoute key>"}}`,
>    `{"name":"CREA Acuity","type":"httpBasicAuth","data":{"user":"<Acuity User ID>","password":"<Acuity API Key>"}}`,
>    `{"name":"CREA Higgsfield","type":"httpHeaderAuth","data":{"name":"X-Api-Key","value":"<Higgsfield key>"}}`
>    (skip Higgsfield if I didn't give you a key).
> 4. Start the WhatsApp gateway: `cd waha && cp .env.example .env`, set `WAHA_API_KEY` to the
>    string from step 2, `docker compose up -d`, then `cd ..`.
> 5. Run `./go-live.sh`. If it says config is incomplete, fix `config.env` and re-run.
> 6. When it finishes, open each `crea-` workflow in n8n and select the `CREA OmniRoute` and
>    `CREA Acuity` credentials on the auth-typed nodes (the workflow editor flags them).
>    Then tell me it's done and give me:
>      - the WhatsApp QR URL (`http://localhost:3001`) so I can scan it with my phone
>      - the Acuity webhook URL to paste into Acuity (it's `<n8n>/webhook/crea-acuity`)
> 7. Test it: `curl -sX POST http://localhost:5678/webhook/crea-wa-inbound -H 'content-type: application/json'
>    -d '{"event":"message","session":"default","payload":{"from":"<my number>@c.us","body":"how much for a listing video and photos?","fromMe":false,"type":"chat"}}'`
>    then check the WAHA dashboard sent a reply. Show me what the assistant said.
>
> Notes for you, Claude:
> - `go-live.sh --status` shows what's running; `--stop` stops the vault API.
> - The assistant answers ONLY from `knowledge/crea-knowledge.md` — it's pre-filled and usable;
>   tell me to add real prices to the one table when I have them.
> - If OmniRoute is unreachable the assistant automatically falls back to a fixed 5-question
>   flow — that's by design, not a bug.
> - Do NOT invent prices, availability, or policies anywhere.

---

## Part 3 — the two things only you can do

- **Scan the WhatsApp QR** — open `http://localhost:3001`, Sessions → default → Start,
  scan with WhatsApp → Linked Devices. (Or use a second SIM if you'd rather isolate the risk —
  it's an unofficial link, small chance of a number restriction.)
- **Paste the Acuity webhook** into Acuity → Integrations → Webhooks, event
  `appointment.scheduled`.

Once those two are done, CREA is answering WhatsApp booking enquiries.

---

## What each workflow does

| Workflow | When | Does |
|---|---|---|
| WhatsApp Inbound | message arrives | routes booking chats to the AI assistant, everything else to you |
| AI Booking Assistant | (booking chat) | answers from the knowledge base, checks availability (never confirms), captures the brief, hands you a quote-ready enquiry |
| Booking Agent | AI fallback | fixed 5-question qualifier if the model is down |
| Acuity Intake | new Acuity booking | writes a job note + pings you |
| Shoot Confirmations | 5pm daily | WhatsApps tomorrow's clients to confirm |
| Chase Non-Replies | 3×/day | nudges unconfirmed clients, then tells you to call |
| Card Pipeline | card-detect webhook | splits footage into shoots, makes Drive folders, waits for your OK, notifies the editor |
| Monday Invoicing | Mon 9am | drafts invoices for completed jobs (never sends) |
| Morning Briefing | 6:30am | "what to focus on" over WhatsApp |
| Apify Leads | 7am daily | new listing leads → digest |

Activate them one at a time as you're ready — `go-live.sh` turns them all on, but you can
deactivate any in the n8n UI.
