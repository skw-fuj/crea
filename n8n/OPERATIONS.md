# CREA v2 — operating & maintaining it

Everything you'll do after it's running: change prices and wording, add or drop features,
take updates, keep it backed up, recover from trouble. `INSTALL.md` is the one-time setup;
this is day two onward.

**Golden rules**
1. **`knowledge/crea-knowledge.md` and `config.env` are the two files you edit.** Almost every
   change you'll want is in one of them.
2. **Back up before any update or risky change:** `./go-live.sh --backup`.
3. **`./go-live.sh` is always safe to re-run** — it's idempotent. When in doubt, run it.
4. **Never delete `deploy/.n8n-key`.** It decrypts your saved API keys. Back it up once, keep it forever.

---

## 1. Change prices, packages, wording, business info

All of this lives in **`knowledge/crea-knowledge.md`**. It's a plain Markdown file — open it in
any editor (TextEdit, Obsidian, VS Code). **The assistant reads it live: save the file and the
next customer message uses the new version. No restart, no `go-live.sh`.**

| To change… | Do this |
|---|---|
| **A price** | Edit the number in the **Price** column of the `## Packages & pricing` table. Blank = the assistant says "I'll get you an exact quote". |
| **Add a package** | Add a row to the pricing table. Mention it in the FAQ or coverage sections if useful. |
| **Remove a package** | Delete its row. The assistant simply stops offering it. |
| **Coverage area, suburbs** | Edit the `## Coverage area` section. |
| **Turnaround times** | Edit `## Turnaround`. |
| **Booking process, deposit, payment terms** | Edit those sections. |
| **FAQ answers** | Edit `## FAQ`. Add Q&A pairs freely — the assistant will use them. |
| **Tone / what it should never say** | Add a short `## House rules` section in plain English (e.g. "Never promise a same-week slot." "Always mention the twilight add-on for waterfront listings."). The assistant follows the file. |

The assistant **only** says what's in this file and never invents a price, a date, or a
policy. If it's not in the file, it defers to you. `knowledge/EXAMPLE-filled.md` is a
worked example.

> **Tip:** it's just a file in the CREA folder. To edit it from your phone and have it backed
> up, either keep the whole CREA folder in a synced location, or open the pack's `knowledge/`
> folder as a folder in your Obsidian vault (Obsidian → open folder as vault, or add it). The
> container reads it live either way.

---

## 2. Change settings — your name, business name, number, keys, schedules

These live in **`config.env`**. After editing it, run **`./go-live.sh`** — it re-fills the
workflows, reloads them, and restarts n8n (about 30 seconds; customers mid-conversation are
fine, their next message just waits a moment).

```bash
open -e config.env      # edit
./go-live.sh            # apply
```

| To change… | Key(s) in `config.env` |
|---|---|
| Your name (how the assistant refers to you) | `CREA_OWNER_NAME` |
| Business name | `CREA_BUSINESS_NAME` |
| Where booking alerts go | `CREA_OWNER_WA` (digits, country code, no `+`) |
| The editor's number (card pipeline) | `CREA_EDITOR_WA` |
| Timezone (schedules, timestamps) | `CREA_TIMEZONE` |
| LLM provider / model | `CREA_OMNIROUTE_URL`, `CREA_OMNIROUTE_KEY`, `CREA_LLM_MODEL` |
| Turn Acuity on (later) | add `CREA_ACUITY_USER_ID` + `CREA_ACUITY_API_KEY` → `./go-live.sh` activates the shoot-ops workflows |
| Turn on listing leads | add `CREA_APIFY_TOKEN` (+ `CREA_APIFY_ACTOR`) |
| Turn on the card→video pipeline's Higgsfield step | add `CREA_HIGGSFIELD_API_KEY` + `CREA_HIGGSFIELD_URL` |
| Password-protect the n8n editor | set `CREA_N8N_USER` + `CREA_N8N_PASSWORD` |
| Which booking flow runs | `CREA_BOOKING_WORKFLOW_ID` = `creaaiassistant` (AI) or `creabookingagent` (fixed 5 questions) |

### Rotating a key (e.g. a leaked or expired API key)
Paste the new value into `config.env`, run `./go-live.sh`. Done — it recreates the credential
inside n8n.

### Changing a schedule (briefing time, confirmation time, chase times)
These are set inside the workflows, not `config.env`. See §4 (edit in the n8n editor).
Current defaults: morning briefing 06:30, shoot confirmations 17:00, chase-ups 09:00/12:00/15:00,
Monday invoicing 09:00, listing leads 07:00, Acuity poll every 10 min.

---

## 3. Change the WhatsApp number

1. `./go-live.sh --stop`
2. On the phone that holds the **old** number: WhatsApp → Linked Devices → remove "CREA" / the linked device.
3. Put the new number in `config.env` (`CREA_OWNER_WA` if it's also your alert number).
4. `./go-live.sh` then `./go-live.sh --qr` and scan with the **new** phone.
5. `./go-live.sh --test`.

Your booking history and knowledge file are untouched — only the WhatsApp link changes.

---

## 4. Change how CREA behaves — the n8n editor

The visual editor is at **http://localhost:5678** (Executions tab shows every run; the
canvas shows the workflows). Use it to change timings, message wording inside a workflow,
routing, or to build something new.

**Understand the source-of-truth model — this matters:**

- The files in **`workflows/`** are the master copy. `./go-live.sh` imports them, **overwriting
  whatever is in the editor.**
- So a change made **only** in the editor is live immediately (on Save + Activate) and survives
  restarts — **but the next `./go-live.sh` will revert it.**

**Two safe ways to make a permanent change:**

**A — small tweak, keep it simple:** make the change in the editor, Save, Activate, test it.
Then **don't run `./go-live.sh`** unless you also fold the change into the file. To capture the
current editor state as files you can diff:
```bash
./go-live.sh --export        # writes deploy/_export/<timestamp>/*.json
```
Compare those to `workflows/` and copy the relevant edits across (they'll have your real
values baked in where the originals have `{{TOKENS}}` — only copy the part you changed).

**B — proper change:** edit the JSON file in `workflows/` directly (a code editor with JSON
support helps), then `./go-live.sh`. This keeps the master copy authoritative. Good for
anything you want to survive updates.

**Every workflow's top note (`meta.note`) explains what it does.** Read it before you change it.

### Safe editing checklist
- Change **one thing**, Save, Activate, send a test message, check the **Executions** tab
  (green = ok). Undo (⌘Z) if it misbehaves — or `./go-live.sh` to snap everything back to the files.
- Don't touch these unless you know exactly why: `crea-00` (error handler), `crea-wa-send`
  (the one WhatsApp sender), `crea-01` (inbound router), `crea-02b` (the assistant core).
- The assistant's "personality" is the system prompt in **`crea-02b` → "Build Prompt"** node.
  You can tighten its rules there — but prefer a `## House rules` section in the knowledge
  file (§1), which needs no editor and no restart.

---

## 5. Add a feature

### Add a new automation (workflow)
1. Build it in the editor (http://localhost:5678 → new workflow). Or start from a copy of the
   closest existing `crea-*` workflow.
2. When it sends WhatsApp, call the **`crea-wa-send`** sub-workflow — never add a second place
   that talks to WhatsApp.
3. Store any state or notes via the **vault API** (`http://vault-api:5692/...`) so it's backed
   up with everything else. `SETUP.md` lists the routes.
4. If it fails, it should land in `crea-00` — set the workflow's **Settings → Error Workflow**
   to `CREA — Error Handler`.
5. Test it in isolation, then Activate.
6. **Make it permanent:** `./go-live.sh --export`, copy the new file into `workflows/`,
   replace your real values with `{{TOKENS}}`, add those tokens to `config.example.env`, and
   from then on `./go-live.sh` manages it too.

### Add a new channel (Telegram, SMS, Instagram DM, web form)
The design already separates this out. Look at **`facet-template/channel-send.atomic.json`** —
it's `crea-wa-send` generalised with a switch on the channel. Add your channel's send call
there (or make a sibling of `crea-wa-send`), point `crea-01`'s inbound at the new channel's
webhook, and the assistant works unchanged.

### Add a knowledge source bigger than one file
Right now the assistant reads `knowledge/crea-knowledge.md`. To back it with a folder of notes
or a real search index later, point `CREA_VAULT_API_URL` at a service that exposes the same
`/knowledge?q=` route — nothing else changes. (`vault-api/server.js` is ~150 lines of plain
Node; it's meant to be extended.)

### Use a different / better LLM
Any OpenAI-compatible chat endpoint. Put its URL + key + model name in `config.env`
(`CREA_OMNIROUTE_*`, `CREA_LLM_MODEL`), `./go-live.sh`. Examples: OpenAI (`gpt-4o-mini`),
Anthropic via a proxy, a local model via Ollama's OpenAI shim, OpenRouter.

---

## 6. Remove a feature

**Prefer deactivating over deleting.**

- **Turn a workflow off:** editor → open it → toggle **Active** off. Or:
  ```bash
  cd deploy && docker compose exec -T n8n n8n update:workflow --id=<id> --active=false
  ```
  (ids: `creashootconfirm`, `creachasenoreply`, `creamorningbrief`, `creaacuityintake`,
  `creaapifyleads`, `creacardpipeline`, `creamondayinvoice` — the safe-to-disable ones.)
- **Stop a whole capability:** remove its key from `config.env` and `./go-live.sh` —
  it deactivates the workflows that need it (e.g. clear `CREA_ACUITY_USER_ID` → the four
  Acuity workflows switch off).
- **Delete it entirely:** remove the file from `workflows/`, remove its tokens from
  `config.example.env`, then in the editor delete the workflow (trash icon), then `./go-live.sh`.

**Never remove:** `crea-00`, `crea-wa-send`, `crea-01`, `crea-02b`, `crea-02`. That's the
core loop and the safety net.

---

## 7. Storage & backup — the full guide

CREA writes every booking, lead, inbox message, shoot record, draft invoice and conversation
as **plain Markdown + JSON files**. Where they go is `CREA_VAULT_DIR` in `config.env`.

**See `DATA-AND-BACKUP.md` for the complete step-by-step** — installing Obsidian, buying and
turning on Obsidian Sync, getting it on your phone, the free alternatives, and the iCloud
trap. The short version:

1. In `config.env` set `CREA_VAULT_DIR` to an **absolute path inside your Obsidian vault**,
   e.g. `/Users/connell/Obsidian/CREA/automations`. Run `./go-live.sh`.
2. Turn on **Obsidian Sync** (~AUD $6/month) — Obsidian → Settings → Sync. Now every booking
   is encrypted, versioned, on your phone, and backed up. This is the recommended setup.
3. **Also** keep an offline copy of the crown jewels:
   ```bash
   ./go-live.sh --backup
   ```
   writes `backups/crea-<timestamp>.tgz` — your `config.env`, the encryption key, a full
   workflow + credential export, and all booking data. **Copy that file somewhere safe**
   (a password manager's file vault, an external drive). It contains secrets — don't email
   it, don't put it in the repo.

**Do a `--backup` before every update and before any big change.** Set a monthly reminder
to run one and move the file off the Mac.

---

## 8. Take an update (new version of CREA)

1. **Back up:** `./go-live.sh --backup` and copy the `.tgz` off the Mac.
2. **Note what you changed** in `knowledge/crea-knowledge.md` and any workflow you edited in
   the editor. If you edited workflows in the editor, run `./go-live.sh --export` first and
   keep that folder.
3. **Unzip the new version** over your folder, but **keep your own**:
   - `config.env`
   - `deploy/.n8n-key`
   - `knowledge/crea-knowledge.md` (your prices!)
   - `backups/`
   ```bash
   cd ~/crea-automations
   # unzip the new "crea's automations" next to the current one, then:
   cp "crea's automations/config.env"            "crea's automations NEW/"   2>/dev/null
   cp "crea's automations/deploy/.n8n-key"        "crea's automations NEW/deploy/"
   cp "crea's automations/knowledge/crea-knowledge.md" "crea's automations NEW/knowledge/"
   cp -R "crea's automations/backups"            "crea's automations NEW/"   2>/dev/null
   # then swap the folders (rename old to -OLD, new to the real name)
   ```
   Or simpler: unzip the new version into a fresh folder, then copy those four things across
   from the old one.
4. **Review** `VERSION` and the release notes for anything that changed in `config.example.env`
   — if there are new keys, add them to your `config.env`.
5. `./go-live.sh`
6. `./go-live.sh --test`, then send a real WhatsApp and confirm a normal booking conversation.
7. **Rollback if needed:** keep the old folder for a week. To go back: `./go-live.sh --stop`
   in the new folder, then `./go-live.sh` in the old folder. Your data (in `CREA_VAULT_DIR`)
   is shared and untouched. If a workflow update misbehaves, `./go-live.sh --restore <backup>`
   then run the old folder.

**What an update will and won't touch:**
- **Touches:** the workflow files, `vault-api/server.js`, the scripts, the docs, `config.example.env`.
- **Never touches:** your `config.env`, `deploy/.n8n-key`, your `CREA_VAULT_DIR` data, your
  WhatsApp pairing (unless the release notes say otherwise).

---

## 9. Monitoring — is it healthy?

| Check | How | Healthy looks like |
|---|---|---|
| Everything running | `./go-live.sh --status` | n8n reachable, WhatsApp session `WORKING` |
| Recent activity | http://localhost:5678 → any workflow → **Executions** | green ticks; a customer message = one `crea-01` run + one `crea-02b` run + `crea-wa-send` runs |
| Failures | Vault: the `alerts/` folder in `CREA_VAULT_DIR` | empty. Each file = one failure `crea-00` caught, with which workflow and why |
| What CREA said today | Vault: `leads/`, `inbox/` folders (open in Obsidian) | new `.md` files for new enquiries |
| Live logs | `./go-live.sh --logs n8n` | steady, no repeating errors (Ctrl-C to stop watching) |

If `crea-00` fires, you also get a WhatsApp alert. It records — it doesn't stop CREA; the
assistant keeps working while a background job retries.

---

## 10. Disaster recovery — the Mac died

1. New Mac: install Docker Desktop (INSTALL.md Part A).
2. Get your latest `backups/crea-<ts>.tgz` (or, if you only have Obsidian Sync, install
   Obsidian on the new Mac and let the vault sync down — your booking data is all there).
3. Fresh copy of the CREA folder (the zip). From the folder:
   ```bash
   ./go-live.sh --restore /path/to/crea-<ts>.tgz     # restores config.env + .n8n-key
   ```
   If the backup has `vault-data.tgz` and you're not using Obsidian Sync, extract it into
   your `CREA_VAULT_DIR`.
4. `./go-live.sh`
5. `./go-live.sh --qr` and re-scan with your WhatsApp — the link doesn't survive a machine move.
6. `./go-live.sh --test`.

Recovery time: ~20 minutes plus the Docker image download.

---

## 11. Security & running it properly

- **`config.env` and `deploy/.n8n-key` are secrets.** They're git-ignored. Don't put the folder
  in a shared drive or iCloud with those in it. `chmod 600 config.env deploy/.n8n-key` (the
  scripts already do this for the key).
- **The n8n editor has no password by default** — fine on a personal Mac (it only listens on
  localhost). If the Mac is shared, in an office, or you've forwarded the port: set
  `CREA_N8N_USER` + `CREA_N8N_PASSWORD` in `config.env` and `./go-live.sh`.
- **The WhatsApp gateway** is protected by `CREA_WAHA_API_KEY`. Keep it long and random.
- **Customer data** (names, numbers, addresses) lives in `CREA_VAULT_DIR`. Obsidian Sync is
  end-to-end encrypted. A plain Dropbox/Drive folder is not — fine for most, but know it.
- **Nothing is exposed to the internet.** No inbound ports, no tunnel. WhatsApp is
  same-machine; Acuity and the LLM are outbound calls. Keep it that way unless you have a
  specific reason and know what you're doing.
- **Updates:** take CREA updates when they come (§8). Docker Desktop updates itself — let it,
  but keep ~15 GB disk free so an update can't half-finish.
- **The LLM sees customer messages.** With Groq/OpenAI that means their API processes the
  text of booking enquiries. That's normal for this kind of tool; if it's a concern, a local
  model via Ollama keeps everything on the Mac (slower, needs 16 GB+).

---

## 12. Cost & scale

| | Cost | When it changes |
|---|---|---|
| Groq (LLM) | free | Free tier is generous (thousands of messages/day). If you hit limits, switch `CREA_OMNIROUTE_*` to OpenAI (`gpt-4o-mini`, ~US$0.15 per 1000 enquiries) — one config change. |
| Obsidian Sync | ~AUD $6/mo | flat |
| Acuity, Higgsfield, Apify | your existing plans | — |
| The Mac | electricity | A dedicated Mac mini (~AUD $900 once) is the upgrade when you don't want CREA sharing your laptop. |
| n8n, WAHA, vault API | free, self-hosted | — |

**Growth signs and what to do:**
- Assistant slow to reply → the LLM is the bottleneck; try a faster model (`openai/gpt-oss-20b`
  on Groq) or OpenAI.
- Mac struggling → move to a dedicated Mac mini; copy the folder + `--restore` a backup.
- Many bookings/day, want a team to see them → they're already Markdown in your Obsidian
  vault; share that vault (Obsidian Sync supports multiple devices) or a folder view.

---

## Quick reference

```bash
./go-live.sh              # apply config changes / start / recover
./go-live.sh --status     # health
./go-live.sh --test       # send a test message through the assistant
./go-live.sh --qr         # re-pair WhatsApp
./go-live.sh --logs n8n   # watch what it's doing
./go-live.sh --backup     # full backup -> backups/crea-<ts>.tgz   (do this before updates)
./go-live.sh --export     # dump live workflows to keep editor changes
./go-live.sh --restore f  # restore config + key from a backup
./go-live.sh --stop       # pause      ./go-live.sh --down = remove containers (data kept)
```

- **Prices & wording:** `knowledge/crea-knowledge.md` — edit, save, done.
- **Settings & keys:** `config.env` — edit, `./go-live.sh`.
- **Behaviour & new features:** the editor at http://localhost:5678, then `./go-live.sh --export`.
- **Back up before every update.** Never lose `deploy/.n8n-key`.
