# CREA v2 — install & go live

This is the whole runbook. Follow it top to bottom once and CREA is answering WhatsApp,
capturing shoot briefs, and (if you connect Acuity) running your shoot-ops automations.

**Time:** about an hour, most of it waiting for downloads and creating accounts.
**You need:** a Mac that stays on during business hours, ~10 GB free disk, and the accounts in Part B.

---

## Part A — set up the machine (once, ~20 min)

1. **Pick the Mac.** Your main Mac is fine, or a cheap Mac mini left on in a cupboard. It must
   be awake during the hours you want the bot to reply. 16 GB RAM is comfortable; 8 GB works.
   Check free disk: **Apple menu → About This Mac → More Info → Storage.** You want **~15 GB
   free** — the WhatsApp gateway image alone is ~3.5 GB, and n8n's database grows over time.
   `go-live.sh` refuses to start below 6 GB and warns below 15 GB.

2. **Install Docker Desktop.**
   - Download from <https://www.docker.com/products/docker-desktop/> (choose Apple Silicon or Intel to match your Mac).
   - Install it, open it, accept the terms.
   - **Docker Desktop → Settings (gear) → General → tick "Start Docker Desktop when you sign in".**
     This is what makes CREA come back after a reboot.
   - Wait until the whale icon in the menu bar is steady (not animating). That means the engine is running.

3. **Install Obsidian** — <https://obsidian.md> (free). Open it and create a vault for CREA,
   or open the one you already use.

4. **Turn on Obsidian Sync** (~AUD $6/mo) — Obsidian → Settings → Sync → set it up and pick
   (or create) a remote vault. This is your backup **and** how bookings show up on your phone.
   Cheaper/free alternatives and the trade-offs are in **DATA-AND-BACKUP.md** — read it if $6/mo
   is a blocker, but don't skip backup entirely.

---

## Part B — gather your accounts & keys (~15 min)

Write these down; you'll paste them into one file in Part C.

| # | What | Where to get it |
|---|---|---|
| 1 | **A WhatsApp number for the bot** | Best: a cheap prepaid SIM or eSIM in a spare phone, so the bot is separate from your personal WhatsApp. OK: your own number (you'll see the bot's replies in your own chats). Install WhatsApp on that phone and verify the number — that's all. |
| 2 | **An LLM API key** (the assistant's brain) | **Groq — free, no credit card.** <https://console.groq.com> → sign up → **API Keys → Create API Key** → copy the `gsk_...` string. (Alternative: OpenAI at <https://platform.openai.com/api-keys> — needs a card.) |
| 3 | **Acuity User ID + API Key** *(optional — turns on the shoot-ops automations)* | Acuity → **Integrations** → scroll to **API** → copy **User ID** and **API Key**. No webhook to set up — CREA polls Acuity every 10 minutes. |
| 4 | **Higgsfield API key** *(optional — the card → video pipeline)* | Your Higgsfield account settings. |
| 5 | **Apify token** *(optional — listing-lead scraping)* | <https://console.apify.com> → Settings → Integrations → API token. |

Only #1 and #2 are required. Everything else you can add later by editing `config.env` and
re-running `./go-live.sh`.

---

## Part C — install CREA (~10 min, mostly automated)

1. **Unzip `crea's automations.zip` somewhere permanent.** For example:
   ```bash
   mkdir -p ~/crea-automations
   ditto -x -k ~/Downloads/"crea's automations.zip" ~/crea-automations
   ```
   Not in Downloads (gets cleared), **not** inside iCloud Drive (iCloud evicts files and breaks it).

2. **Open Terminal** and go to the folder:
   ```bash
   cd ~/crea-automations/"crea's automations"
   ```

3. **Create your config:**
   ```bash
   cp config.example.env config.env
   open -e config.env
   ```
   Fill every line marked `◀ REQUIRED`:
   - `CREA_OWNER_WA` — your WhatsApp, digits only, with country code, no `+` or spaces. e.g. `61412345678`
   - `CREA_WAHA_API_KEY` — run `openssl rand -hex 24` in Terminal and paste the result
   - `CREA_OMNIROUTE_KEY` — your Groq key from Part B #2
   - `CREA_OMNIROUTE_URL` and `CREA_LLM_MODEL` are already set for Groq — leave them unless you chose OpenAI
   
   Recommended while you're here:
   - `CREA_OWNER_NAME`, `CREA_BUSINESS_NAME` — your name and business name
   - `CREA_ACUITY_USER_ID` + `CREA_ACUITY_API_KEY` — from Part B #3
   - `CREA_VAULT_DIR` — an **absolute** path to a folder inside your Obsidian vault, e.g.
     `/Users/connell/Obsidian/CREA/automations` (the folder will be created). This is what makes
     Obsidian Sync back up your bookings.
   
   Save and close.

4. **Go live:**
   ```bash
   ./go-live.sh
   ```
   First run takes ~5 minutes (it downloads the n8n and WhatsApp images). It will:
   check Docker → generate an encryption key → start n8n + WhatsApp gateway + the vault API →
   import all 12 workflows → create the API credentials → activate everything → restart n8n.
   
   It stops at **"WhatsApp pairing"** — that's the one manual step, next.

5. **Pair WhatsApp:**
   ```bash
   ./go-live.sh --qr
   ```
   Then open <http://localhost:3001/dashboard>, click the session called **default**, and scan the
   QR with the **bot phone**: WhatsApp → **Settings → Linked Devices → Link a Device**.
   Wait until the dashboard shows the session as **WORKING**.

6. **Prove it works:**
   ```bash
   ./go-live.sh --test
   ```
   This pushes a real *"how much for a listing video?"* through the assistant. You should see a
   state blob come back with `mode: ai`. Then send a WhatsApp **from a different phone** to the
   bot number:
   > hi, how much for a listing video for a 3 bed house in Mosman?
   
   You should get a reply within a few seconds. Give it an address and a date and you'll get a
   **"Quote-ready enquiry"** message on your own WhatsApp.

---

## Part D — make the assistant actually useful (~10 min)

1. **Put your prices in.** Open `knowledge/crea-knowledge.md`. In the **`## Packages & pricing`**
   table, fill the **Price** column with your real numbers. **Until you do this, the assistant
   will not quote a price** — it says *"I'll get you an exact quote"* instead. See
   `knowledge/EXAMPLE-filled.md` for a completed example.

2. While you're in that file, make the rest true for your business: coverage area, turnaround
   times, booking process, payment terms, the FAQ. The assistant answers **only** from this file
   and never invents anything. Save — no restart needed.

---

## Part E — running it day to day

| Command | What it does |
|---|---|
| `./go-live.sh --status` | is everything up? is WhatsApp connected? |
| `./go-live.sh --qr` | re-print the pairing QR (if the link drops) |
| `./go-live.sh --test` | send a test message through the assistant |
| `./go-live.sh --logs n8n` | watch what n8n is doing (Ctrl-C to stop watching) |
| `./go-live.sh --stop` | pause everything (data kept) |
| `./go-live.sh` | start again / apply config changes |
| `./go-live.sh --down` | remove the containers (your data volumes are kept) |

- **After a reboot:** if Docker Desktop is set to start on login (Part A.2), the whole stack
  comes back on its own and WhatsApp re-links from the saved session. Nothing to do.
- **Changing a setting:** edit `config.env`, then `./go-live.sh` again.
- **Updating CREA:** unzip the new version over the folder but **keep your `config.env` and
  `deploy/.n8n-key`**, then `./go-live.sh`.

### Back these up (once, to your password manager)
- `config.env` — your keys
- `deploy/.n8n-key` — the n8n encryption key. **If you lose this, n8n can't read its saved
  credentials** and you'd re-enter the API keys.

---

## What runs, and what needs which key

| Workflow | On when | Needs |
|---|---|---|
| WhatsApp assistant (`crea-01`, `crea-02b`), fallback qualifier (`crea-02`), sender (`crea-wa-send`), error handler (`crea-00`), invoicing (`crea-07`), card pipeline (`crea-06`) | always | the required keys only |
| Acuity intake / confirmations / chase / morning briefing (`crea-03`, `-04`, `-05`, `-08`) | when `CREA_ACUITY_USER_ID` is set | Acuity keys |
| Listing leads (`crea-10`) | when `CREA_APIFY_TOKEN` is set | Apify token |
| Google Calendar / Drive steps | off by default | edit the workflow in n8n, add a `CREA Google` credential |

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| `go-live.sh` says "Docker Desktop is not running" | Open Docker Desktop, wait for the steady whale icon, re-run. If it won't start: check you have ~15 GB free disk — Docker fails badly when the disk fills. |
| First run is very slow / seems stuck | It's downloading ~5 GB of images (the WhatsApp gateway is the big one). `./go-live.sh --logs` in another Terminal tab to watch. |
| `no matching manifest for linux/arm64` | You're on an old copy — `go-live.sh` now picks the right WhatsApp-gateway image for your CPU automatically. Re-unzip the latest. |
| QR won't scan or session stuck on `SCAN_QR_CODE` | `./go-live.sh --qr` again. In the dashboard, **Stop** then **Start** the `default` session. Make sure the bot phone has signal and WhatsApp is up to date. |
| Assistant replies *"I'll pass this to the team"* to everything | The LLM key is wrong or the provider is down. Check `CREA_OMNIROUTE_KEY`, then `./go-live.sh --logs n8n`. |
| It never quotes a price | You haven't filled the Price column in `knowledge/crea-knowledge.md` (Part D). |
| No "Quote-ready enquiry" pings | `CREA_OWNER_WA` must be your real number, digits only, with country code. |
| Acuity bookings don't appear | Check the User ID / API Key. `crea-03` polls every 10 min, so allow time. `./go-live.sh --logs n8n` and look for `Acuity`. |
| Everything was working, then stopped after a reboot | Docker Desktop didn't auto-start. Set it in Part A.2, or open it manually, then `./go-live.sh --status`. |
| Want to move it to another Mac | Copy the whole folder **including `config.env` and `deploy/.n8n-key`**, install Docker there, `./go-live.sh`, re-scan the QR. |

---

## The architecture, in one paragraph

Three containers on one Mac: **n8n** (the workflow engine + editor at `localhost:5678`),
**WAHA** (the WhatsApp gateway at `localhost:3001`), and **vault-api** (CREA's memory —
knowledge, conversation state, job/lead notes — internal only). They talk to each other on a
private Docker network, so **no public URL or tunnel is needed**. WhatsApp messages come in
through WAHA; Acuity is polled outbound every 10 minutes; the LLM and any other APIs are
outbound HTTPS. Your booking data is written as plain Markdown to `CREA_VAULT_DIR` (your
Obsidian vault) so Obsidian Sync backs it up and puts it on your phone.
