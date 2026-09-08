# CREA — where your data lives, and how to keep it safe

Everything CREA remembers is **plain text on your Mac**. There is no external database and
nothing is stored on anyone else's system. That's good for privacy and control — but a
single Mac is a single point of failure, and you can't read it from your phone. This is how
to fix that.

---

## What data there is

| What | Where | Written by |
|---|---|---|
| Job notes, leads, WhatsApp inbox, shoot records, draft invoices, failure alerts | `CREA_VAULT_DIR` (default `n8n/vault-api/data/`) — one `.json` + one readable `.md` per item | the vault API |
| Conversation state + transcripts | same folder, `state/` | the assistant |
| The knowledge the assistant answers from | `n8n/knowledge/crea-knowledge.md` | you |
| Everything else CREA tracks (the job pipeline, dashboards) | your CREA Obsidian vault | CREA's own skills |

## The fix: point the vault API at your Obsidian vault, and sync the vault

CREA already keeps its memory in an **Obsidian vault** of plain-text notes. Put the n8n
data there too, and one solution covers backup **and** every device:

1. In `config.env`, set:
   ```
   CREA_VAULT_DIR=~/crea/vault/automations
   ```
   (or wherever your CREA vault is — check `crea status`). Re-run `./go-live.sh`.
   Now the job notes, leads and inbox land inside your vault as markdown you can read in
   Obsidian.

2. **Sync the vault.** Ranked best to minimum:

   | Option | Cost | Devices | Backup | Notes |
   |---|---|---|---|---|
   | **Obsidian Sync** | ~AUD $6/mo (annual) or $8/mo | all — Mac, iPhone, iPad | yes, versioned | **recommended.** End-to-end encrypted, real-time, keeps a version history you can roll back. Built for exactly this. Students get 40% off with an .edu address. |
   | A cloud-synced folder (Dropbox / Google Drive / OneDrive) pointed at the vault | free–cheap | all with the app | yes | Works, but no version history and occasional sync conflicts on notes edited in two places at once. |
   | iCloud Drive | included with the Mac | Apple only | partial | **Careful:** iCloud removes ("evicts") files it thinks are cold, leaving a placeholder. Invisible to you; fatal to CREA, which reads the folder every few minutes — an evicted job note is a job it can't see. Only use iCloud if you keep the vault folder "Downloaded" (right-click → Keep Downloaded). |
   | An external drive + a weekly `rsync`/Time Machine | one-off ~$80 | none | yes | The bare minimum. No phone access, and a backup is only as fresh as the last run. |

3. If you don't want to touch Obsidian at all: at least run **Time Machine** to an external
   drive, or a nightly copy of `CREA_VAULT_DIR` somewhere off the machine. Losing that folder
   means losing every booking, lead and invoice CREA has captured.

## Don't

- Don't put `CREA_VAULT_DIR` on a network drive that isn't always mounted — the vault API
  writes to it constantly.
- Don't edit the same note in Obsidian on two devices while both are offline, then sync —
  that's the one case cloud folders handle badly. Obsidian Sync merges it; the others may
  leave a conflict copy.
- Don't commit `config.env` or `vault-api/data/` to git — the shipped `.gitignore` already
  excludes them.

## TL;DR

Buy **Obsidian Sync**, set `CREA_VAULT_DIR` to a folder inside your CREA vault, re-run
`./go-live.sh`. Your bookings are then on every device and backed up, and it costs about a
coffee a month.
