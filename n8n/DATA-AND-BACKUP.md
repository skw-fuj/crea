# CREA v3 — your data, storage, sync & backup

Everything CREA remembers is **plain text on your Mac** — no external database, nothing on
anyone else's system. Great for privacy and control, but a single Mac is a single point of
failure and you can't read it from your phone. This guide fixes both, step by step.

---

## 1. What data there is

| What | Where | Format |
|---|---|---|
| Job records, leads, WhatsApp inbox, shoot records, draft invoices, conversation state, failure alerts | `CREA_VAULT_DIR` — folders: `jobs/ leads/ inbox/ shoots/ invoices/ pending/ state/ alerts/` | one `.json` + one readable `.md` per item |
| What the assistant answers from (prices, coverage, FAQ) | `knowledge/crea-knowledge.md` | Markdown, you edit it |
| The workflows, the encrypted API credentials, execution history | the `n8n_data` Docker volume | n8n's internal SQLite — you don't touch it directly |
| Your API keys | `config.env` | plain text — **secret** |
| The key that decrypts the n8n credentials | `deploy/.n8n-key` | 48 hex chars — **secret, irreplaceable** |

If `CREA_VAULT_DIR` is left blank, the booking data goes into a Docker volume (`crea_vault`)
that lives only on this Mac and isn't visible in Finder. **Set `CREA_VAULT_DIR`.**

---

## 2. Recommended setup — Obsidian + Obsidian Sync (~AUD $6/month)

One solution covers **backup, version history, and every device** (including your phone), and
CREA's data becomes browsable notes.

### 2a. Install Obsidian
1. Download from **<https://obsidian.md>** (free). Install and open it.
2. **Create a vault:** "Create new vault" → name it e.g. `CREA` → choose a location on your
   Mac that is **NOT inside iCloud Drive** (see §5). A folder in your home directory like
   `/Users/<you>/Obsidian/CREA` is perfect.
3. Inside that vault, you don't need to make anything — CREA will create its own
   `automations/` folder.

### 2b. Point CREA at it
In `config.env`:
```
CREA_VAULT_DIR=/Users/<you>/Obsidian/CREA/automations
```
Use the **absolute path** (starts with `/Users/`). `~/Obsidian/CREA/automations` also works.
Then:
```bash
./go-live.sh
```
Within a few minutes of the first booking activity you'll see `automations/jobs/`,
`automations/leads/` etc. appear in Obsidian.

### 2c. Turn on Obsidian Sync
1. In Obsidian: **Settings (gear) → Sync** → "Sign up" (or log in). You need an Obsidian
   account; Sync is a paid add-on, ~**AUD $6/month** billed annually (or ~$8 monthly).
   **Students:** 40% off with a valid .edu email — apply at obsidian.md/education.
2. **Settings → Sync → "Choose remote vault" → Create new** → give it a name and an
   **encryption password** (write this down — it's end-to-end encryption, Obsidian can't
   recover it).
3. **Turn Sync on** (the toggle at the top of the Sync settings).
4. Under **"Selective sync"** you can choose to sync only the `automations/` folder if your
   vault is large — but syncing the whole small vault is simplest.

### 2d. Get it on your phone
1. Install **Obsidian** from the App Store / Play Store.
2. Open it → "Sync" → log in with the same account → it pulls your remote vault down.
3. Enter the same encryption password.
4. Now every booking, lead and enquiry is in your pocket, and you can **edit
   `crea-knowledge.md` (your prices) from your phone** — changes sync back to the Mac and the
   assistant picks them up live.

### 2e. What you'll see
- `automations/leads/` — a note per enquiry: name, phone, what they want, address, date, status.
- `automations/inbox/` — non-booking messages CREA logged.
- `automations/jobs/` — confirmed bookings (from Acuity, if connected).
- `automations/alerts/` — a note each time a background job failed (should be empty).
- `automations/invoices/` — draft invoices (never sent automatically).

They're normal Markdown — link them, tag them, build a dashboard note if you like.

---

## 3. Also keep an offline backup of the crown jewels

Obsidian Sync protects the booking **data**. It does **not** back up `config.env`,
`deploy/.n8n-key`, or the n8n workflow/credential state. Run this before every update and
about once a month:

```bash
./go-live.sh --backup
```

It writes **`backups/crea-<timestamp>.tgz`** containing:
- `config.env` (your keys)
- the n8n **encryption key**
- a full **workflow export** + **credential export**
- **all booking data** (`vault-data.tgz`)

**Move that file off the Mac** — into a password manager's secure file storage (1Password,
Bitpass, etc.), or onto an external drive. It contains secrets: don't email it, don't commit
it to git, don't drop it in a shared folder.

Restore later with `./go-live.sh --restore backups/crea-<timestamp>.tgz`.

---

## 4. If you don't want to pay for Obsidian Sync

Ranked best → minimum. All of these still need the `./go-live.sh --backup` step in §3 for the
secrets and workflows.

| Option | Cost | Phone access | Version history | Watch out for |
|---|---|---|---|---|
| **Obsidian Sync** | ~AUD $6/mo | yes | yes, 1 year | nothing — this is the one built for it |
| **Syncthing** (free, open source, peer-to-peer) | free | Android yes, iOS limited | no | you run it on each device; no cloud, data never leaves your machines. Point it at the vault folder. Great if you're comfortable installing it. |
| **Dropbox / Google Drive / OneDrive** folder containing the vault | free tier or your existing plan | via their app | no | occasional "conflicted copy" files if you edit the same note on two devices at once; make sure the desktop app keeps files **actually downloaded**, not "online-only" |
| **iCloud Drive** | included | Apple only | no | **CREA will break** unless you force-download — see §5 |
| **External drive + Time Machine** (or a nightly `rsync`) | one-off ~AUD $80 | none | Time Machine: hourly | a backup is only as fresh as the last run; no phone access. Minimum acceptable. |

For a plain cloud folder: put the whole Obsidian vault inside `~/Dropbox/` (or Drive), set
`CREA_VAULT_DIR` to `automations/` inside it, and install the Obsidian mobile app pointed at
"sync via [that service]" if it supports it, or just use the service's own mobile app to read
the `.md` files.

---

## 5. The iCloud trap — read this

iCloud Drive "optimises storage" by **evicting** files it thinks are cold — it deletes the
local copy and leaves a placeholder that downloads on demand. That's fine for photos. It is
**fatal for CREA**, which reads `CREA_VAULT_DIR` every few minutes: an evicted job note is a
booking CREA can't see, and an evicted `crea-knowledge.md` means the assistant loses your
prices mid-conversation.

**If you must use iCloud:**
1. Keep the vault folder somewhere like `~/Documents/CREA` (inside iCloud) — never Desktop.
2. Finder → right-click the vault folder → **"Keep Downloaded"**.
3. System Settings → your name → iCloud → iCloud Drive → **turn "Optimise Mac Storage" off**.
4. Check monthly that no file shows a cloud-download icon.

Honestly: use a folder **outside** iCloud and one of the options in §2 or §4 instead. It's
one setting and a lot less to worry about.

---

## 6. Don't

- Don't put `CREA_VAULT_DIR` on a network drive or NAS that isn't always mounted — the vault
  API writes to it constantly and will error every time it's away.
- Don't edit the same note on two devices while both are offline, then reconnect — that's the
  one case plain cloud folders handle badly (Obsidian Sync merges it cleanly).
- Don't keep `config.env` or `deploy/.n8n-key` in a synced/shared folder — those are secrets.
  The CREA folder's `.gitignore` already excludes them from git; extend that care to Dropbox.
- Don't rely on Obsidian Sync alone — it doesn't hold the encryption key or the workflows.
  Run `./go-live.sh --backup` monthly (§3).

---

## 7. TL;DR

1. Install Obsidian, make a vault **outside iCloud**.
2. `CREA_VAULT_DIR=/Users/<you>/Obsidian/CREA/automations` in `config.env` → `./go-live.sh`.
3. Turn on **Obsidian Sync** (~$6/mo) and install the phone app.
4. `./go-live.sh --backup` before every update and monthly; move the `.tgz` off the Mac.
5. Never lose `deploy/.n8n-key`.
